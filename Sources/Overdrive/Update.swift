import Foundation

enum Update {
    nonisolated struct Release: Equatable, Sendable {
        let version: String
        let url: URL
    }

    enum State: Equatable {
        case checking
        case current
        case available(Release)
        case unknown
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    nonisolated static let endpoint = URL(string: "https://api.github.com/repos/skhaz/overdrive/releases/latest")!
    nonisolated static let timeout: TimeInterval = 10
    static let lifetime = Duration.seconds(3600)
    private static var cached: (release: Release, time: ContinuousClock.Instant)?

    nonisolated static let session: Transport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        return { try await session.data(for: $0) }
    }()

    private nonisolated struct Latest: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let latest = try? JSONDecoder().decode(Latest.self, from: data), latest.draft != true, latest.prerelease != true,
              let version = numbers(latest.tag_name) else { return nil }

        return Release(version: version.map(String.init).joined(separator: "."), url: latest.html_url)
    }

    nonisolated static func numbers(_ text: String) -> [Int]? {
        let parts = (text.hasPrefix("v") ? text.dropFirst() : Substring(text)).split(separator: ".", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0) }
        return !values.isEmpty && values.count == parts.count ? values : nil
    }

    nonisolated static func newer(_ latest: String, than current: String) -> Bool {
        guard let latest = numbers(latest), let current = numbers(current) else { return false }

        for index in 0..<max(latest.count, current.count) {
            let one = index < latest.count ? latest[index] : 0
            let two = index < current.count ? current[index] : 0
            if one != two { return one > two }
        }
        return false
    }

    static func check(current: String, transport: Transport = session) async -> State {
        if let cached, ContinuousClock.now - cached.time < lifetime {
            return state(cached.release, current)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Overdrive/\(current)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let release = parse(data) else {
                Log.app.info("update check unavailable", metadata: ["status": "\(status)", "bytes": "\(data.count)"])
                return .unknown
            }

            cached = (release, .now)
            Log.app.info("update check", metadata: ["latest": "\(release.version)", "current": "\(current)"])
            return state(release, current)
        } catch {
            Log.app.info("update check unavailable", metadata: ["error": "\(error)"])
            return .unknown
        }
    }

    static func forget() {
        cached = nil
    }

    private static func state(_ release: Release, _ current: String) -> State {
        newer(release.version, than: current) ? .available(release) : .current
    }
}
