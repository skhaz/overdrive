import AppKit
import WebKit

private final class Handle: NSView {
    var dropped: (() -> Void)?
    var hovered: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        dropped?()
    }
}

@Observable
final class YouTube: NSObject, WKNavigationDelegate, NSWindowDelegate {
    nonisolated struct Configuration {
        var store = URL.applicationSupportDirectory.appending(path: "Overdrive/Videos.plist")
        var transport = URLSession.shared
        var defaults = UserDefaults.standard
    }

    enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var name: String {
            switch self {
            case .topLeft: "Top Left"
            case .topRight: "Top Right"
            case .bottomLeft: "Bottom Left"
            case .bottomRight: "Bottom Right"
            }
        }
    }

    private enum Mode {
        case loading, ready, failed, login, video
    }

    private static let account = URL(string: "https://www.youtube.com/account")!
    private static let resident = URL(string: "https://www.youtube.com/embed/?controls=0&rel=0&playsinline=1&iv_load_policy=3&cc_load_policy=0")!

    private static let layout = """
    (() => {
        if (!location.pathname.startsWith('/embed/')) return;
        const style = document.createElement('style');
        style.textContent = 'body :not(:has(video)):not(video) { display: none !important; } body { background: #000 !important; } video { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important; object-fit: contain !important; }';
        document.documentElement.append(style);
    })();
    """

    var browser: Bool { didSet { Log.youTube.info("browser", metadata: ["on": "\(browser)"]); configuration.defaults.set(browser, forKey: "youtube.browser") } }
    var corner: Corner {
        didSet {
            configuration.defaults.set(corner.rawValue, forKey: "youtube.corner")
            place()
        }
    }
    var searching = false
    private(set) var showing: Track?

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let player: Player
    @ObservationIgnored private var videos: [String: String]
    @ObservationIgnored private let web: WKWebView
    @ObservationIgnored private let panel: NSPanel
    @ObservationIgnored private let handle = Handle()
    @ObservationIgnored private var mode = Mode.loading
    @ObservationIgnored private var track: Track?
    @ObservationIgnored private var logged = false
    @ObservationIgnored private var signedIn = false
    @ObservationIgnored private var request = 0
    @ObservationIgnored private var retry: Task<Void, Never>?

    init(player: Player, _ configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.player = player
        browser = configuration.defaults.object(forKey: "youtube.browser") as? Bool ?? false
        corner = configuration.defaults.string(forKey: "youtube.corner").flatMap(Corner.init) ?? .bottomRight
        videos = (try? Data(contentsOf: configuration.store)).flatMap { try? PropertyListDecoder().decode([String: String].self, from: $0) } ?? [:]

        let settings = WKWebViewConfiguration()
        settings.mediaTypesRequiringUserActionForPlayback = []
        settings.preferences.isElementFullscreenEnabled = true
        settings.userContentController.addUserScript(WKUserScript(source: YouTube.layout, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        handle.dropped = { [weak self] in self?.snap() }
        handle.hovered = { [weak self] in self?.panel.standardWindowButton(.closeButton)?.animator().alphaValue = $0 ? 1 : 0 }
        player.resumed = { [weak self] in
            guard let self else { return }

            if panel.isVisible {
                panel.close()
            } else {
                cancel()
            }
        }

        load()

        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                if mode == .ready || mode == .failed, !panel.isVisible, !searching { load() }
            }
        }
    }

    private func load() {
        Log.youTube.info("load player page")
        mode = .loading
        var request = URLRequest(url: YouTube.resident)
        request.setValue("https://\((Bundle.main.bundleIdentifier ?? "org.delduca.Overdrive").lowercased())/", forHTTPHeaderField: "Referer")
        web.load(request)
    }

    func watch(_ track: Track) {
        Log.youTube.info("watch", metadata: ["artist": "\(track.artist)", "title": "\(track.title)", "mode": "\(mode)", "searching": "\(searching)"])
        guard !searching else { return }

        self.track = track
        searching = true
        request += 1

        switch mode {
        case .ready, .video: Task { await find() }
        case .failed: load()
        case .loading, .login: break
        }
    }

    private func find() async {
        guard let track else { return }

        guard browser || logged else {
            show(.login)
            web.load(URLRequest(url: YouTube.account))
            return
        }

        self.track = nil
        let current = request
        defer { if request == current { searching = false } }

        let name = "\(track.artist)\u{1F}\(track.title)"
        var id = videos[name]

        if id == nil {
            do {
                id = try await search(track)
            } catch {
                return stop(error.localizedDescription)
            }
        }

        guard request == current else { return }
        guard let id else { return stop("No video found for “\(track.artist) - \(track.title)”.") }

        Log.youTube.info("video", metadata: ["id": "\(id)", "artist": "\(track.artist)", "title": "\(track.title)"])

        if videos[name] != id {
            videos[name] = id
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            if let data = try? encoder.encode(videos) { Persist.write(data, to: configuration.store) }
        }

        player.pause()

        guard !browser else {
            NSWorkspace.shared.open(URL(string: "https://www.youtube.com/watch?v=\(id)")!)
            return
        }

        player.intercept = { [weak self] in self?.remote($0) }

        let script = """
        document.getElementById('movie_player').loadVideoById(id);
        const video = document.querySelector('video');
        await new Promise(resolve => {
            video.addEventListener('playing', resolve, { once: true });
            setTimeout(resolve, 3000);
        });
        """
        do {
            _ = try await web.callAsyncJavaScript(script, arguments: ["id": id], contentWorld: .page)
        } catch {
            guard request == current else { return }

            player.intercept = nil
            return stop(error.localizedDescription)
        }

        guard request == current else {
            _ = try? await web.evaluateJavaScript("document.getElementById('movie_player').stopVideo()")
            return
        }

        showing = track
        show(.video)
    }

    private func stop(_ message: String) {
        Log.youTube.error("stop", metadata: ["reason": "\(message)"])
        if panel.isVisible { panel.close() }
        alert(message)
    }

    func close() {
        Log.youTube.info("close", metadata: ["visible": "\(panel.isVisible)"])
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0.0
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.panel.close()
                self.panel.alphaValue = 1.0
            }
        }
    }

    func signOut() async {
        Log.youTube.info("sign out")
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records.filter { $0.displayName.contains("youtube") || $0.displayName.contains("google") })
        logged = false
        if panel.isVisible { panel.close() }
        load()
    }

    private func show(_ mode: Mode) {
        Log.youTube.info("show", metadata: ["mode": "\(mode)"])
        self.mode = mode
        handle.isHidden = mode != .video
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.standardWindowButton(.closeButton)?.animator().alphaValue = mode == .video ? 0 : 1
        }
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1.0
        }
        
        place()
        panel.makeKeyAndOrderFront(nil)
    }

    private func place() {
        guard let screen = panel.screen ?? NSScreen.main else { return }

        let margin: CGFloat = 20
        let area = screen.visibleFrame.insetBy(dx: margin, dy: margin)
        let saved = configuration.defaults.object(forKey: "youtube.width") as? Double ?? 640
        let width = min(mode == .login ? max(saved, 800) : saved, area.width).rounded()
        let size = NSSize(width: width, height: (width * 9 / 16).rounded())

        let x = corner == .topLeft || corner == .bottomLeft ? area.minX : area.maxX - size.width
        let y = corner == .bottomLeft || corner == .bottomRight ? area.minY : area.maxY - size.height
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        }
    }

    private func snap() {
        guard let screen = panel.screen else { return }

        let left = panel.frame.midX < screen.visibleFrame.midX
        let bottom = panel.frame.midY < screen.visibleFrame.midY
        corner = bottom ? (left ? .bottomLeft : .bottomRight) : (left ? .topLeft : .topRight)
        place()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let youTube = webView.url?.host() == YouTube.account.host()
        let path = webView.url?.path() ?? ""
        Log.youTube.info("page finished", metadata: ["url": "\(webView.url?.absoluteString ?? "")", "mode": "\(mode)"])

        if mode == .login {
            guard youTube else { return }

            if path == YouTube.account.path() {
                signedIn = true
                return load()
            }

            guard path.hasPrefix("/embed") else { return }
        } else {
            guard mode == .loading else { return }

            guard youTube, path.hasPrefix("/embed") else {
                return track == nil ? failed(URLError(.badServerResponse)) : show(.login)
            }
        }

        Task {
            logged = (try? await webView.evaluateJavaScript("ytcfg.get('LOGGED_IN')")) as? Bool ?? false || signedIn
            signedIn = false
            mode = .ready
            if track != nil { await find() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.youTube.error("web content process ended")
        mode = .failed
        if panel.isVisible { panel.close() }
        load()
    }

    private func failed(_ error: any Error) {
        Log.youTube.error("failed", metadata: ["mode": "\(mode)", "error": "\(error)"])
        guard mode == .loading, (error as? URLError)?.code != .cancelled else { return }

        mode = .failed

        retry?.cancel()
        retry = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(60))) != nil, let self, mode == .failed, !panel.isVisible else { return }

            load()
        }

        guard track != nil else { return }

        track = nil
        searching = false
        stop(error.localizedDescription)
    }

    private func search(_ track: Track) async throws -> String? {
        let script = """
        const context = structuredClone(ytcfg.get('INNERTUBE_CONTEXT'));
        context.client.clientName = 'WEB';
        delete context.thirdParty;
        const response = await fetch('/youtubei/v1/search?prettyPrint=false', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ context, query }) });
        return await response.text();
        """
        let text = try await web.callAsyncJavaScript(script, arguments: ["query": "\(track.artist) \(track.title)"], contentWorld: .page) as? String ?? ""
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8))
        Log.youTube.info("search", metadata: ["artist": "\(track.artist)", "title": "\(track.title)", "bytes": "\(text.utf8.count)", "matches": Log.list(YouTube.match(YouTube.results(json), track.artist, track.title).prefix(5))])

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
        guard mode == .video else { return }

        configuration.defaults.set(Double(panel.frame.width), forKey: "youtube.width")
        place()
    }

    private func cancel() {
        request += 1
        track = nil
        searching = false
        player.intercept = nil
    }

    func windowWillClose(_ notification: Notification) {
        showing = nil
        cancel()

        if mode == .video {
            mode = .ready
            web.evaluateJavaScript("document.getElementById('movie_player').stopVideo()")
        } else {
            load()
        }
    }
}
