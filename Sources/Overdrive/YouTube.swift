import AppKit
import WebKit

private final class Handle: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@Observable
final class YouTube: NSObject, NSWindowDelegate {
    nonisolated struct Configuration {
        var endpoint = URL(string: "https://www.googleapis.com/youtube/v3/search")!
        var store = URL.applicationSupportDirectory.appending(path: "Overdrive/Videos.plist")
        var rules = URL.applicationSupportDirectory.appending(path: "Overdrive/Rules")
        var transport = URLSession.shared
        var defaults = UserDefaults.standard
    }

    struct Failure: Error {
        let message: String
    }

    private static let blocked = ["doubleclick.net", "googlesyndication.com", "googleadservices.com", "imasdk.googleapis.com", "youtube.com/api/stats/ads",
                                  "youtube.com/pagead/", "youtube.com/ptracking", "youtube.com/get_midroll_", "youtube-nocookie.com/api/stats/ads"]

    private static let prune = """
    (() => {
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

    var key: String { didSet { configuration.defaults.set(key, forKey: "youtube.key") } }
    var browser: Bool { didSet { configuration.defaults.set(browser, forKey: "youtube.browser") } }
    var searching = false

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let player: Player
    @ObservationIgnored private var videos: [String: String]
    @ObservationIgnored private let web: WKWebView
    @ObservationIgnored private let panel: NSPanel

    init(player: Player, _ configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.player = player
        key = configuration.defaults.string(forKey: "youtube.key") ?? ""
        browser = configuration.defaults.object(forKey: "youtube.browser") as? Bool ?? false
        videos = (try? Data(contentsOf: configuration.store)).flatMap { try? PropertyListDecoder().decode([String: String].self, from: $0) } ?? [:]

        let settings = WKWebViewConfiguration()
        settings.websiteDataStore = .nonPersistent()
        settings.mediaTypesRequiringUserActionForPlayback = []
        settings.preferences.isElementFullscreenEnabled = true
        settings.userContentController.addUserScript(WKUserScript(source: YouTube.prune, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        panel.isMovableByWindowBackground = true

        let container = NSView()
        let handle = Handle()
        for view in [web, handle] {
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        panel.contentView = container
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        super.init()
        panel.delegate = self

        let rules = YouTube.blocked.map { ["trigger": ["url-filter": NSRegularExpression.escapedPattern(for: $0)], "action": ["type": "block"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let store = WKContentRuleListStore(url: configuration.rules) else { return }

        try? FileManager.default.createDirectory(at: configuration.rules, withIntermediateDirectories: true)
        store.compileContentRuleList(forIdentifier: "Ads", encodedContentRuleList: String(decoding: data, as: UTF8.self)) { [weak self] list, _ in
            if let list { self?.web.configuration.userContentController.add(list) }
        }
    }

    func watch(_ track: Track) async {
        searching = true
        defer { searching = false }

        do {
            guard let id = try await search(track) else { return alert("No video found for “\(track.artist) - \(track.title)”.") }

            player.pause()

            if browser {
                NSWorkspace.shared.open(URL(string: "https://www.youtube.com/watch?v=\(id)")!)
                return
            }

            player.intercept = { [weak self] in self?.remote($0) }

            var request = URLRequest(url: URL(string: "https://www.youtube.com/embed/\(id)?autoplay=1&controls=0&rel=0&playsinline=1&iv_load_policy=3&cc_load_policy=0")!)
            request.setValue("https://\((Bundle.main.bundleIdentifier ?? "org.delduca.Overdrive").lowercased())/", forHTTPHeaderField: "Referer")
            web.load(request)

            if let frame = configuration.defaults.string(forKey: "youtube.frame") {
                panel.setFrame(from: frame)
                var frame = panel.frame
                frame.size.height = (frame.width * 9 / 16).rounded()
                panel.setFrame(frame, display: false)
            } else if !panel.isVisible {
                panel.center()
            }

            panel.makeKeyAndOrderFront(nil)
        } catch let failure as Failure {
            alert(failure.message)
        } catch {
            alert(error.localizedDescription)
        }
    }

    private func search(_ track: Track) async throws -> String? {
        let name = "\(track.artist)\u{1F}\(track.title)"
        if let id = videos[name] { return id }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = ["part": "snippet", "type": "video", "videoEmbeddable": "true", "maxResults": "10", "q": "\(track.artist) \(track.title)", "key": key]
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")

        let (data, _) = try await configuration.transport.data(from: URL(string: "\(configuration.endpoint.absoluteString)?\(query)")!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if let error = json["error"] as? [String: Any] {
            throw Failure(message: error["message"] as? String ?? "YouTube error")
        }

        guard let id = YouTube.match(json["items"] as? [[String: Any]] ?? [], track.artist, track.title) else { return nil }

        videos[name] = id
        if let data = try? PropertyListEncoder().encode(videos) { Persist.write(data, to: configuration.store) }
        return id
    }

    static func match(_ items: [[String: Any]], _ artist: String, _ title: String) -> String? {
        let artist = normalize(artist)
        let stripped = normalize(title.replacing(/\s*[(\[][^)\]]*[)\]]/, with: "").replacing(/\s+-\s+.*$/, with: ""))
        let title = stripped.isEmpty ? normalize(title) : stripped
        guard !artist.isEmpty, !title.isEmpty else { return nil }

        for item in items {
            guard let id = (item["id"] as? [String: Any])?["videoId"] as? String, let snippet = item["snippet"] as? [String: Any] else { continue }

            let channel = snippet["channelTitle"] as? String ?? ""
            guard !channel.hasSuffix(" - Topic") else { continue }

            let name = " \(normalize(unescape(snippet["title"] as? String ?? ""))) "
            guard name.contains(" \(title) ") else { continue }

            if name.contains(" \(artist) ") || normalize(channel).replacing(" ", with: "").contains(artist.replacing(" ", with: "")) { return id }
        }

        return nil
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ")
            .map { String($0) }
            .joined(separator: " ")
    }

    private static func unescape(_ text: String) -> String {
        text.replacing("&quot;", with: "\"").replacing("&#39;", with: "'").replacing("&lt;", with: "<").replacing("&gt;", with: ">").replacing("&amp;", with: "&")
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
        configuration.defaults.set(panel.frameDescriptor, forKey: "youtube.frame")
    }

    func windowDidMove(_ notification: Notification) {
        configuration.defaults.set(panel.frameDescriptor, forKey: "youtube.frame")
    }

    func windowWillClose(_ notification: Notification) {
        player.intercept = nil
        web.pauseAllMediaPlayback()
        web.load(URLRequest(url: URL(string: "about:blank")!))
    }
}
