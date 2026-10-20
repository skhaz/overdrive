import AppKit
import WebKit

private final class Handle: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@Observable
final class YouTube: NSObject, WKNavigationDelegate, NSWindowDelegate {
    nonisolated struct Configuration {
        var store = URL.applicationSupportDirectory.appending(path: "Overdrive/Videos.plist")
        var rules = URL.applicationSupportDirectory.appending(path: "Overdrive/Rules")
        var transport = URLSession.shared
        var defaults = UserDefaults.standard
    }

    private enum Mode {
        case idle, checking, login, searching, video, refreshing
    }

    private static let account = URL(string: "https://www.youtube.com/account")!
    private static let home = URL(string: "https://www.youtube.com/")!

    private static let blocked = ["doubleclick.net", "googlesyndication.com", "googleadservices.com", "imasdk.googleapis.com", "youtube.com/api/stats/ads",
                                  "youtube.com/pagead/", "youtube.com/ptracking", "youtube.com/get_midroll_", "youtube-nocookie.com/api/stats/ads"]

    private static let prune = """
    (() => {
        if (!location.pathname.startsWith('/embed/')) return;
        const keys = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
        const prune = o => { for (const k of keys) delete o[k]; };
        const clean = o => {
            if (o && typeof o === 'object') {
                prune(o);
                if (o.playerResponse && typeof o.playerResponse === 'object') prune(o.playerResponse);
            }
            return o;
        };
        const parse = JSON.parse;
        JSON.parse = function () { return clean(parse.apply(this, arguments)); };
        const json = Response.prototype.json;
        Response.prototype.json = function () { return json.apply(this, arguments).then(clean); };
        for (const name of ['ytInitialPlayerResponse', 'playerResponse']) {
            let value;
            Object.defineProperty(window, name, { configurable: true, get: () => value, set: v => { value = clean(v); } });
        }
        const style = document.createElement('style');
        style.textContent = 'body :not(:has(video)):not(video) { display: none !important; } body { background: #000 !important; } video { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; object-fit: contain !important; }';
        document.documentElement.append(style);
    })();
    """

    var browser: Bool { didSet { configuration.defaults.set(browser, forKey: "youtube.browser") } }
    var searching = false

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let player: Player
    @ObservationIgnored private var videos: [String: String]
    @ObservationIgnored private let web: WKWebView
    @ObservationIgnored private let panel: NSPanel
    @ObservationIgnored private let handle = Handle()
    @ObservationIgnored private var mode = Mode.idle
    @ObservationIgnored private var video = ""
    @ObservationIgnored private var track: Track?

    init(player: Player, _ configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.player = player
        browser = configuration.defaults.object(forKey: "youtube.browser") as? Bool ?? false
        videos = (try? Data(contentsOf: configuration.store)).flatMap { try? PropertyListDecoder().decode([String: String].self, from: $0) } ?? [:]

        let settings = WKWebViewConfiguration()
        settings.mediaTypesRequiringUserActionForPlayback = []
        settings.preferences.isElementFullscreenEnabled = true
        settings.userContentController.addUserScript(WKUserScript(source: YouTube.prune, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let safari = Bundle(url: URL(filePath: "/Applications/Safari.app"))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "26.0"
        settings.applicationNameForUserAgent = "Version/\(safari) Safari/605.1.15"
        web = WKWebView(frame: .zero, configuration: settings)

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = .black
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = NSSize(width: 16, height: 9)

        let container = NSView()
        for view in [web, handle] {
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        panel.contentView = container
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init()
        web.navigationDelegate = self
        panel.delegate = self

        let rules = YouTube.blocked.map { ["trigger": ["url-filter": NSRegularExpression.escapedPattern(for: $0)], "action": ["type": "block"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let store = WKContentRuleListStore(url: configuration.rules) else { return }

        try? FileManager.default.createDirectory(at: configuration.rules, withIntermediateDirectories: true)
        store.compileContentRuleList(forIdentifier: "Ads", encodedContentRuleList: String(decoding: data, as: UTF8.self)) { [weak self] list, _ in
            if let list { self?.web.configuration.userContentController.add(list) }
        }

        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3600))
                await self?.refresh()
            }
        }
    }

    private func refresh() async {
        guard mode == .idle, await web.configuration.websiteDataStore.httpCookieStore.allCookies().contains(where: { $0.name == "LOGIN_INFO" }), mode == .idle else { return }

        mode = .refreshing
        web.load(URLRequest(url: YouTube.account))
        try? await Task.sleep(for: .seconds(30))
        guard mode == .refreshing else { return }

        mode = .idle
        web.load(URLRequest(url: URL(string: "about:blank")!))
    }

    func watch(_ track: Track) {
        guard !searching else { return }

        self.track = track
        searching = true
        mode = .checking
        web.load(URLRequest(url: browser ? YouTube.home : YouTube.account))
    }

    private func find() async {
        defer { searching = false }
        guard let track else { return }

        let name = "\(track.artist)\u{1F}\(track.title)"
        var id = videos[name]

        if id == nil {
            do {
                id = try await search(track)
            } catch {
                return stop(error.localizedDescription)
            }
        }

        guard let id else { return stop("No video found for “\(track.artist) - \(track.title)”.") }

        if videos[name] != id {
            videos[name] = id
            if let data = try? PropertyListEncoder().encode(videos) { Persist.write(data, to: configuration.store) }
        }

        player.pause()

        guard !browser else {
            NSWorkspace.shared.open(URL(string: "https://www.youtube.com/watch?v=\(id)")!)
            return stop(nil)
        }

        video = id
        player.intercept = { [weak self] in self?.remote($0) }
        play()
    }

    private func stop(_ message: String?) {
        if panel.isVisible {
            panel.close()
        } else {
            mode = .idle
            web.load(URLRequest(url: URL(string: "about:blank")!))
        }

        if let message { alert(message) }
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("youtube") || $0.displayName.contains("google") })
    }

    private func play() {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/embed/\(video)?autoplay=1&controls=0&rel=0&playsinline=1&iv_load_policy=3&cc_load_policy=0")!)
        request.setValue("https://\((Bundle.main.bundleIdentifier ?? "org.delduca.Overdrive").lowercased())/", forHTTPHeaderField: "Referer")
        web.load(request)
        show(.video)
    }

    private func show(_ mode: Mode) {
        self.mode = mode
        handle.isHidden = mode != .video

        if let frame = configuration.defaults.string(forKey: "youtube.frame") {
            panel.setFrame(from: frame)
        } else if !panel.isVisible {
            panel.center()
        }

        var frame = panel.frame
        if mode == .login { frame.size.width = max(frame.width, 800) }
        frame.size.height = (frame.width * 9 / 16).rounded()
        panel.setFrame(frame, display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard mode == .checking || mode == .login, let url = webView.url, url.host() == YouTube.account.host(),
              url.path() == (browser ? YouTube.home : YouTube.account).path() else { return }

        mode = .searching
        Task { await find() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard mode == .checking, webView.url?.host() != YouTube.account.host() else { return }

        show(.login)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        guard mode == .checking else { return }

        searching = false
        stop(error.localizedDescription)
    }

    private func search(_ track: Track) async throws -> String? {
        let script = """
        const response = await fetch('/youtubei/v1/search?prettyPrint=false', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ context: ytcfg.get('INNERTUBE_CONTEXT'), query }) });
        return await response.text();
        """
        let text = try await web.callAsyncJavaScript(script, arguments: ["query": "\(track.artist) \(track.title)"], contentWorld: .page) as? String ?? ""
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8))

        for id in YouTube.match(YouTube.results(json), track.artist, track.title).prefix(5) {
            if browser { return id }

            var components = URLComponents(string: "https://www.youtube.com/oembed")!
            components.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)")]
            if let (_, response) = try? await configuration.transport.data(from: components.url!), (response as? HTTPURLResponse)?.statusCode == 200 { return id }
        }

        return nil
    }

    static func results(_ json: Any) -> [(id: String, title: String, channel: String)] {
        var results: [(id: String, title: String, channel: String)] = []

        func text(_ value: Any?) -> String {
            ((value as? [String: Any])?["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }

        func walk(_ value: Any) {
            if let array = value as? [Any] {
                array.forEach(walk)
            } else if let object = value as? [String: Any] {
                if let video = object["videoRenderer"] as? [String: Any], let id = video["videoId"] as? String {
                    let channel = text(video["ownerText"])
                    results.append((id, text(video["title"]), channel.isEmpty ? text(video["longBylineText"]) : channel))
                } else {
                    object.values.forEach(walk)
                }
            }
        }

        walk(json)
        return results
    }

    static func match(_ results: [(id: String, title: String, channel: String)], _ artist: String, _ title: String) -> [String] {
        let artist = normalize(artist)
        let stripped = normalize(title.replacing(/\s*[(\[][^)\]]*[)\]]/, with: "").replacing(/\s+-\s+.*$/, with: ""))
        let title = stripped.isEmpty ? normalize(title) : stripped
        guard !artist.isEmpty, !title.isEmpty else { return [] }

        return results.filter { result in
            guard !result.channel.hasSuffix(" - Topic") else { return false }

            let name = " \(normalize(result.title)) "
            return name.contains(" \(title) ") && (name.contains(" \(artist) ") || normalize(result.channel).replacing(" ", with: "").contains(artist.replacing(" ", with: "")))
        }.map(\.id)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ")
            .map { String($0) }
            .joined(separator: " ")
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    private func remote(_ command: Player.Remote) {
        let action = switch command {
        case .play: "v.play()"
        case .pause: "v.pause()"
        case .toggle: "v.paused ? v.play() : v.pause()"
        case .next, .previous: ""
        }
        guard !action.isEmpty else { return }

        web.evaluateJavaScript("(v => { if (v) { \(action) } })(document.querySelector('video'))")
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if mode == .video { configuration.defaults.set(panel.frameDescriptor, forKey: "youtube.frame") }
    }

    func windowDidMove(_ notification: Notification) {
        if mode == .video { configuration.defaults.set(panel.frameDescriptor, forKey: "youtube.frame") }
    }

    func windowWillClose(_ notification: Notification) {
        mode = .idle
        player.intercept = nil
        web.pauseAllMediaPlayback()
        web.load(URLRequest(url: URL(string: "about:blank")!))
    }
}
