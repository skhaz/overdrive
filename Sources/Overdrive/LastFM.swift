import Foundation
import CryptoKit

@Observable
final class LastFM {
    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private static let defaults = UserDefaults.standard

    static let key = Bundle.main.object(forInfoDictionaryKey: "LastFMKey") as? String ?? ""
    static let secret = Bundle.main.object(forInfoDictionaryKey: "LastFMSecret") as? String ?? ""

    var session = Keychain.read("lastfm.session") { didSet { Keychain.write("lastfm.session", session) } }
    var user = Keychain.read("lastfm.user") { didSet { Keychain.write("lastfm.user", user) } }
    var pending = defaults.array(forKey: "lastfm.pending") as? [[String: String]] ?? [] { didSet { LastFM.defaults.set(pending, forKey: "lastfm.pending") } }
    var status = ""
    var connecting = false

    @ObservationIgnored private var flushing = false

    struct Failure: Error {
        let code: Int
        let message: String
    }

    func connect(_ username: String, _ password: String) async {
        connecting = true
        defer { connecting = false }

        do {
            let result = try await call("auth.getMobileSession", ["username": username, "password": password])["session"] as! [String: Any]
            session = result["key"] as! String
            user = result["name"] as! String
            status = ""
            await flush()
        } catch let failure as Failure {
            status = failure.message
        } catch {
            status = error.localizedDescription
        }
    }

    func disconnect() {
        session = ""
        user = ""
    }

    func nowPlaying(_ track: Track) {
        guard !session.isEmpty else { return }

        Task { _ = try? await call("track.updateNowPlaying", parameters(track), session: true) }
    }

    func scrobble(_ track: Track, at date: Date) {
        pending.append(parameters(track).merging(["timestamp": String(Int(date.timeIntervalSince1970))]) { $1 })

        Task { await flush() }
    }

    func flush() async {
        guard !session.isEmpty, !flushing else { return }

        flushing = true
        defer { flushing = false }

        let limit = Date.now.addingTimeInterval(-14 * 86400).timeIntervalSince1970
        pending.removeAll { (Double($0["timestamp"]!) ?? 0) < limit }

        while !pending.isEmpty, !session.isEmpty {
            let batch = pending.prefix(50)
            var parameters: [String: String] = [:]

            for (index, entry) in batch.enumerated() {
                for (name, value) in entry {
                    parameters["\(name)[\(index)]"] = value
                }
            }

            do {
                _ = try await call("track.scrobble", parameters, session: true)
                pending.removeFirst(batch.count)
                status = ""
            } catch let failure as Failure {
                status = failure.message

                switch failure.code {
                case 9: disconnect()
                case 6, 7, 13: pending.removeFirst(batch.count)
                default: return
                }
            } catch {
                status = error.localizedDescription
                return
            }
        }
    }

    private func parameters(_ track: Track) -> [String: String] {
        var parameters = ["artist": track.artist, "track": track.title, "album": track.album]
        if track.duration > 0 { parameters["duration"] = String(Int(track.duration)) }
        return parameters
    }

    private func call(_ method: String, _ parameters: [String: String], session: Bool = false) async throws -> [String: Any] {
        var parameters = parameters
        parameters["method"] = method
        parameters["api_key"] = LastFM.key
        if session { parameters["sk"] = self.session }

        let signature = parameters.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + LastFM.secret
        parameters["api_sig"] = Insecure.MD5.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        parameters["format"] = "json"

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        var request = URLRequest(url: LastFM.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(parameters.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if let code = json["error"] as? Int {
            throw Failure(code: code, message: json["message"] as? String ?? "Last.fm error \(code)")
        }

        return json
    }
}
