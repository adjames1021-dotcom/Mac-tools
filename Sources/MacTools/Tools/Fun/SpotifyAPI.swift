import Foundation
import AppKit
import WebKit
import CryptoKit

// MARK: - Models (Spotify Web API, snake_case keys converted to camelCase)

struct SpotifyImage: Decodable, Hashable {
    let url: String
    let width: Int?
    let height: Int?

    /// The smallest image at least `size` points wide (or the biggest there is).
    static func best(_ images: [SpotifyImage]?, size: Int) -> URL? {
        guard let images = images, !images.isEmpty else { return nil }
        let sorted = images.sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        let pick = sorted.first { ($0.width ?? 0) >= size } ?? sorted.last
        return pick.flatMap { URL(string: $0.url) }
    }
}

struct SpotifyArtistRef: Decodable, Hashable {
    let id: String?
    let name: String
    let uri: String?
}

struct SpotifyAlbumRef: Decodable, Hashable {
    let id: String?
    let name: String
    let uri: String?
    let images: [SpotifyImage]?
}

struct SpotifyTrack: Decodable, Hashable {
    let id: String?
    let name: String
    let uri: String
    let durationMs: Int?
    let artists: [SpotifyArtistRef]?
    let album: SpotifyAlbumRef?
    let explicit: Bool?
    /// Podcast episodes have their own images.
    let images: [SpotifyImage]?

    var artistNames: String { (artists ?? []).map(\.name).joined(separator: ", ") }
    func artwork(_ size: Int) -> URL? { SpotifyImage.best(album?.images ?? images, size: size) }
}

/// A page of results. Items Spotify returns as null (it does that for some playlists) are skipped.
struct Paging<T: Decodable & Hashable>: Decodable, Hashable {
    let items: [T]
    let next: String?
    let total: Int?

    private struct Lossy: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    enum CodingKeys: String, CodingKey { case items, next, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = ((try? c.decode([Lossy].self, forKey: .items)) ?? []).compactMap { $0.value }
        next = try? c.decodeIfPresent(String.self, forKey: .next)
        total = try? c.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct SpotifyAlbum: Decodable, Hashable {
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
    let artists: [SpotifyArtistRef]?
    let releaseDate: String?
    let totalTracks: Int?
    let tracks: Paging<SpotifyTrack>?

    var artistNames: String { (artists ?? []).map(\.name).joined(separator: ", ") }
}

struct SpotifyArtist: Decodable, Hashable {
    struct Followers: Decodable, Hashable { let total: Int? }
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
    let genres: [String]?
    let followers: Followers?
}

struct SpotifyPlaylist: Decodable, Hashable {
    struct Owner: Decodable, Hashable { let id: String?; let displayName: String? }
    struct Count: Decodable, Hashable { let total: Int? }
    let id: String
    let name: String
    let uri: String
    let images: [SpotifyImage]?
    let owner: Owner?
    let tracks: Count?
    let description: String?
}

struct SpotifyUser: Decodable {
    let id: String
    let displayName: String?
    let product: String?
    let images: [SpotifyImage]?
}

struct SpotifyDevice: Decodable, Hashable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool
    let volumePercent: Int?

    var icon: String {
        switch type.lowercased() {
        case "smartphone": return "iphone"
        case "computer": return "laptopcomputer"
        case "speaker": return "hifispeaker"
        case "tv": return "tv"
        case "tablet": return "ipad"
        default: return "speaker.wave.2"
        }
    }
}

struct SpotifyPlayback: Decodable {
    struct Context: Decodable { let uri: String? }
    var device: SpotifyDevice?
    var shuffleState: Bool?
    var repeatState: String?
    var isPlaying: Bool
    var progressMs: Int?
    var item: SpotifyTrack?
    var context: Context?
}

/// A playlist entry or a liked song: `{ "track": … }`.
struct SpotifyTrackItem: Decodable, Hashable { let track: SpotifyTrack? }
struct SpotifySavedAlbum: Decodable, Hashable { let album: SpotifyAlbum }
struct SpotifyPlayHistory: Decodable, Hashable { let track: SpotifyTrack }

struct SpotifySearchResults: Decodable {
    let tracks: Paging<SpotifyTrack>?
    let artists: Paging<SpotifyArtist>?
    let albums: Paging<SpotifyAlbum>?
    let playlists: Paging<SpotifyPlaylist>?
}

struct SpotifyTopTracks: Decodable { let tracks: [SpotifyTrack] }
struct SpotifyDeviceList: Decodable { let devices: [SpotifyDevice] }

enum SpotifyError: LocalizedError {
    case notSignedIn
    case http(status: Int, message: String, reason: String)
    case network(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Spotify first."
        case let .http(status, message, reason):
            if reason == "PREMIUM_REQUIRED" { return "Spotify says this needs Premium." }
            if reason == "NO_ACTIVE_DEVICE" { return "No Spotify device is ready. Pick one from the device menu, or open Spotify on your phone or Mac." }
            switch status {
            case 401: return "Spotify signed you out. Sign in again."
            case 403: return "Spotify refused that" + (message.isEmpty ? "." : ": \(message)") + " If you just set up your developer app, check your account's email is added under User Management."
            case 404: return "Spotify couldn't find that" + (message.isEmpty ? "." : ": \(message)")
            case 429: return "Spotify is busy – try again in a moment."
            default: return "Spotify error \(status)" + (message.isEmpty ? "." : ": \(message)")
            }
        case .network(let message):
            return "Couldn't reach Spotify: \(message)"
        case .unreadable:
            return "Spotify sent something MacTools couldn't read."
        }
    }

    static func from(status: Int, data: Data?) -> SpotifyError {
        var message = "", reason = ""
        if let data = data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                message = (error["message"] as? String) ?? ""
                reason = (error["reason"] as? String) ?? ""
            } else if let text = object["error_description"] as? String {
                message = text
            }
        }
        return .http(status: status, message: message, reason: reason)
    }
}

// MARK: - Client

/// Signs in with Spotify (PKCE, no client secret) and talks to the Spotify Web API. Also keeps the current playback
/// state for the player's now-playing bar.
final class SpotifyClient: ObservableObject {
    static let shared = SpotifyClient()

    /// Add exactly this as a Redirect URI in your Spotify developer app. Nothing needs to run on it: the sign-in
    /// window catches the redirect itself.
    static let redirectURI = "http://127.0.0.1:8573/callback"
    static let dashboard = URL(string: "https://developer.spotify.com/dashboard")!
    private static let scopes = [
        "user-read-private", "user-read-email", "streaming",
        "user-read-playback-state", "user-modify-playback-state", "user-read-currently-playing",
        "playlist-read-private", "playlist-read-collaborative",
        "user-library-read", "user-library-modify", "user-read-recently-played", "user-top-read",
    ].joined(separator: " ")
    private static let refreshAccount = "spotify-refresh-token"

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmed, forKey: "spotifyClientID") }
    }
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var signingIn = false
    @Published private(set) var user: SpotifyUser?
    @Published private(set) var playback: SpotifyPlayback?
    /// When `playback` was fetched, to move the progress bar smoothly between checks.
    @Published private(set) var playbackFetchedAt = Date()
    @Published private(set) var devices: [SpotifyDevice] = []
    @Published private(set) var currentLiked = false
    @Published private(set) var engineDeviceID: String?
    @Published private(set) var engineProblem: String?
    @Published var message = ""
    /// A search to show next time the player opens (e.g. "Christmas" from the Christmas page).
    @Published var pendingSearch: String?

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var refreshToken: String?
    private var refreshing = false
    private var tokenWaiters: [(Result<String, Error>) -> Void] = []
    private var pollTimer: Timer?
    private var watchers = 0
    private var lastLikedCheck = ""
    private var lastDeviceLoad = Date.distantPast
    private var authFlow: SpotifyAuthFlow?

    private init() {
        clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
        isSignedIn = UserDefaults.standard.bool(forKey: "spotifySignedIn")
    }

    // MARK: Sign-in

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters[Int.random(in: 0..<characters.count, using: &generator)] })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func signIn() {
        let id = clientID.trimmed
        guard !id.isEmpty else {
            message = "Paste your Client ID first."
            return
        }
        let verifier = Self.randomString(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomString(16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { return }
        message = ""
        signingIn = true
        let flow = SpotifyAuthFlow(url: url, redirect: Self.redirectURI) { [weak self] callback in
            self?.finishSignIn(callback, verifier: verifier, state: state)
        }
        authFlow = flow
        flow.start()
    }

    private func finishSignIn(_ callback: URL?, verifier: String, state: String) {
        authFlow = nil
        signingIn = false
        guard let callback = callback,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            message = "Sign-in was cancelled."
            return
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            message = error == "access_denied" ? "You didn't allow MacTools to use Spotify." : "Spotify said: \(error)"
            return
        }
        guard value("state") == state, let code = value("code") else {
            message = "Sign-in didn't finish. Try again."
            return
        }
        tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID.trimmed,
            "code_verifier": verifier,
        ]) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.isSignedIn = true
                UserDefaults.standard.set(true, forKey: "spotifySignedIn")
                self.loadUser()
                SpotifyEngine.shared.start()
                self.refreshPlayback()
            case .failure(let error):
                self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func signOut() {
        Keychain.set(nil, for: Self.refreshAccount)
        accessToken = nil
        refreshToken = nil
        accessExpiry = .distantPast
        isSignedIn = false
        UserDefaults.standard.set(false, forKey: "spotifySignedIn")
        user = nil
        playback = nil
        devices = []
        SpotifyEngine.shared.stop()
    }

    /// POSTs to Spotify's token endpoint and stores the tokens it returns.
    private func tokenRequest(_ fields: [String: String], completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(SpotifyError.network(error.localizedDescription)))
                    return
                }
                guard status == 200, let data = data,
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let token = object["access_token"] as? String else {
                    completion(.failure(SpotifyError.from(status: status, data: data)))
                    return
                }
                self.accessToken = token
                self.accessExpiry = Date().addingTimeInterval((object["expires_in"] as? Double) ?? 3600)
                if let refresh = object["refresh_token"] as? String {
                    self.refreshToken = refresh
                    Keychain.set(refresh, for: Self.refreshAccount)
                }
                completion(.success(token))
            }
        }.resume()
    }

    /// A valid access token, refreshing it when it's about to expire.
    func withToken(_ completion: @escaping (Result<String, Error>) -> Void) {
        if let token = accessToken, accessExpiry > Date().addingTimeInterval(60) {
            completion(.success(token))
            return
        }
        tokenWaiters.append(completion)
        guard !refreshing else { return }
        guard isSignedIn, let refresh = refreshToken ?? Keychain.string(Self.refreshAccount), !clientID.trimmed.isEmpty else {
            finishRefresh(.failure(SpotifyError.notSignedIn))
            return
        }
        refreshing = true
        tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID.trimmed]) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result, case SpotifyError.http(let status, _, _)? = error as? SpotifyError, status == 400 {
                self.signOut()   // the sign-in was revoked or expired
            }
            self.finishRefresh(result)
        }
    }

    private func finishRefresh(_ result: Result<String, Error>) {
        refreshing = false
        let waiters = tokenWaiters
        tokenWaiters = []
        waiters.forEach { $0(result) }
    }

    // MARK: Requests

    /// Calls the Web API. Retries once after refreshing an expired token, and once after a rate limit.
    func call(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil, retry: Bool = true,
              completion: @escaping (Result<Data, Error>) -> Void) {
        withToken { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let token):
                var components = URLComponents(string: "https://api.spotify.com/v1" + path)
                if !query.isEmpty {
                    components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
                }
                guard let url = components?.url else {
                    completion(.failure(SpotifyError.unreadable))
                    return
                }
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.httpMethod = method
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let body = body, let data = try? JSONSerialization.data(withJSONObject: body) {
                    request.httpBody = data
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
                URLSession.shared.dataTask(with: request) { data, response, error in
                    let http = response as? HTTPURLResponse
                    let status = http?.statusCode ?? 0
                    let retryAfter = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                    DispatchQueue.main.async {
                        if let error = error {
                            completion(.failure(SpotifyError.network(error.localizedDescription)))
                            return
                        }
                        if status == 401 && retry {
                            self.accessToken = nil
                            self.call(method, path, query: query, body: body, retry: false, completion: completion)
                            return
                        }
                        if status == 429 && retry {
                            DispatchQueue.main.asyncAfter(deadline: .now() + min(retryAfter, 10)) {
                                self.call(method, path, query: query, body: body, retry: false, completion: completion)
                            }
                            return
                        }
                        guard (200..<300).contains(status) else {
                            completion(.failure(SpotifyError.from(status: status, data: data)))
                            return
                        }
                        completion(.success(data ?? Data()))
                    }
                }.resume()
            }
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type,
                           completion: @escaping (Result<T, Error>) -> Void) {
        call("GET", path, query: query) { result in
            completion(result.flatMap { data -> Result<T, Error> in
                do {
                    return .success(try Self.decoder.decode(T.self, from: data))
                } catch {
                    return .failure(SpotifyError.unreadable)
                }
            })
        }
    }

    /// Runs a player command, shows any error, then re-reads the player state.
    private func command(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil) {
        call(method, path, query: query, body: body) { [weak self] result in
            guard let self = self else { return }
            if case .failure(let error) = result {
                self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            } else {
                self.message = ""
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refreshPlayback() }
        }
    }

    // MARK: Player state

    func loadUser() {
        get("/me", as: SpotifyUser.self) { [weak self] result in
            if case .success(let user) = result { self?.user = user }
        }
    }

    /// The player page calls this while it's on screen, so the now-playing bar stays current.
    func startWatching() {
        watchers += 1
        guard isSignedIn else { return }
        SpotifyEngine.shared.start()
        if user == nil { loadUser() }
        refreshPlayback()
        loadDevices()
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.refreshPlayback()
            }
        }
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    func refreshPlayback() {
        guard isSignedIn else { return }
        call("GET", "/me/player", query: ["additional_types": "track,episode"]) { [weak self] result in
            guard let self = self, case .success(let data) = result else { return }
            self.playback = data.isEmpty ? nil : (try? Self.decoder.decode(SpotifyPlayback.self, from: data))
            self.playbackFetchedAt = Date()
            self.checkLiked()
            if Date().timeIntervalSince(self.lastDeviceLoad) > 15 { self.loadDevices() }
        }
    }

    func loadDevices() {
        lastDeviceLoad = Date()
        get("/me/player/devices", as: SpotifyDeviceList.self) { [weak self] result in
            if case .success(let list) = result { self?.devices = list.devices }
        }
    }

    private func checkLiked() {
        guard let id = playback?.item?.id else {
            currentLiked = false
            return
        }
        guard id != lastLikedCheck else { return }
        lastLikedCheck = id
        get("/me/tracks/contains", query: ["ids": id], as: [Bool].self) { [weak self] result in
            if case .success(let flags) = result { self?.currentLiked = flags.first ?? false }
        }
    }

    fileprivate func engineChanged(deviceID: String?, problem: String?) {
        engineDeviceID = deviceID
        engineProblem = problem
        if deviceID != nil { loadDevices() }
    }

    // MARK: Controls

    /// Where new playback goes: the active device, or MacTools itself.
    private var targetDevice: String? { playback?.device?.id ?? engineDeviceID }

    /// Plays a playlist/album (context) or a list of songs, optionally starting at a position or song.
    func play(context: String? = nil, uris: [String]? = nil, position: Int? = nil, startURI: String? = nil) {
        var body: [String: Any] = [:]
        if let context = context { body["context_uri"] = context }
        if let uris = uris { body["uris"] = Array(uris.prefix(100)) }
        if let position = position {
            body["offset"] = ["position": position]
        } else if let startURI = startURI {
            body["offset"] = ["uri": startURI]
        }
        var query: [String: String] = [:]
        if let device = targetDevice { query["device_id"] = device }
        if targetDevice == nil {
            message = "Nothing is ready to play on yet. Pick a device from the speaker menu, or open Spotify on your phone or Mac."
        }
        if var current = playback {
            current.isPlaying = true
            playback = current
        }
        command("PUT", "/me/player/play", query: query, body: body)
    }

    func togglePlay() {
        if playback?.isPlaying == true {
            if var current = playback {
                current.isPlaying = false
                current.progressMs = Int(position)
                playback = current
                playbackFetchedAt = Date()
            }
            command("PUT", "/me/player/pause")
        } else if playback == nil, let engine = engineDeviceID {
            // Nothing active: start on MacTools itself, picking up where Spotify left off.
            command("PUT", "/me/player", body: ["device_ids": [engine], "play": true])
        } else {
            if var current = playback {
                current.isPlaying = true
                playback = current
                playbackFetchedAt = Date()
            }
            command("PUT", "/me/player/play")
        }
    }

    func next() { command("POST", "/me/player/next") }
    func previous() { command("POST", "/me/player/previous") }

    func seek(to milliseconds: Double) {
        if var current = playback {
            current.progressMs = Int(milliseconds)
            playback = current
            playbackFetchedAt = Date()
        }
        command("PUT", "/me/player/seek", query: ["position_ms": String(Int(milliseconds))])
    }

    func toggleShuffle() {
        let on = !(playback?.shuffleState ?? false)
        playback?.shuffleState = on
        command("PUT", "/me/player/shuffle", query: ["state": on ? "true" : "false"])
    }

    /// off → whole playlist → this song → off
    func cycleRepeat() {
        let next: String
        switch playback?.repeatState ?? "off" {
        case "off": next = "context"
        case "context": next = "track"
        default: next = "off"
        }
        playback?.repeatState = next
        command("PUT", "/me/player/repeat", query: ["state": next])
    }

    func setVolume(_ percent: Double) {
        command("PUT", "/me/player/volume", query: ["volume_percent": String(Int(max(0, min(100, percent))))])
    }

    func transfer(to device: SpotifyDevice) {
        guard let id = device.id else { return }
        command("PUT", "/me/player", body: ["device_ids": [id], "play": playback?.isPlaying ?? true])
    }

    func toggleLike() {
        guard let id = playback?.item?.id else { return }
        let liked = currentLiked
        currentLiked = !liked
        command(liked ? "DELETE" : "PUT", "/me/tracks", query: ["ids": id])
    }

    /// The playback position right now, in milliseconds (moves on smoothly between checks).
    var position: Double {
        guard let playback = playback else { return 0 }
        let base = Double(playback.progressMs ?? 0)
        let elapsed = playback.isPlaying ? Date().timeIntervalSince(playbackFetchedAt) * 1000 : 0
        return min(Double(playback.item?.durationMs ?? 0), base + elapsed)
    }

    /// Opens something in the Spotify app – where Premium's Download switch saves it for offline listening.
    static func openInApp(_ uri: String) {
        if let url = URL(string: uri), NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            let parts = uri.split(separator: ":")
            let web = parts.count >= 3 ? "https://open.spotify.com/\(parts[1])/\(parts[2])" : "https://open.spotify.com/"
            if let url = URL(string: web) { NSWorkspace.shared.open(url) }
        }
    }
}

// MARK: - Sign-in window

/// Shows Spotify's sign-in page and catches the redirect back to MacTools (nothing has to listen on that address).
final class SpotifyAuthFlow: NSObject {
    private let url: URL
    private let redirect: String
    private let done: (URL?) -> Void
    private var window: NSWindow?
    private var webView: WKWebView?
    private var finished = false

    init(url: URL, redirect: String, done: @escaping (URL?) -> Void) {
        self.url = url
        self.redirect = redirect
        self.done = done
    }

    func start() {
        let view = SchoolWeb.makeWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 740))
        view.navigationDelegate = self
        view.uiDelegate = self
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign in to Spotify"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.delegate = self
        window.center()
        webView = view
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        view.load(URLRequest(url: url))
    }

    fileprivate func check(_ candidate: URL?) {
        guard !finished, let candidate = candidate, candidate.absoluteString.hasPrefix(redirect) else { return }
        finished = true
        webView?.stopLoading()
        window?.delegate = nil
        window?.close()
        done(candidate)
    }

    fileprivate func closedByUser() {
        guard !finished else { return }
        finished = true
        done(nil)
    }
}

extension SpotifyAuthFlow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { check(webView.url) }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) { check(webView.url) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { check(webView.url) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Loading the redirect address fails (nothing runs there), but the error says which address it was.
        let info = (error as NSError).userInfo
        let failing = (info[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (info[NSURLErrorFailingURLStringErrorKey] as? String).flatMap { URL(string: $0) }
        check(failing ?? webView.url)
    }
}

extension SpotifyAuthFlow: WKUIDelegate {
    /// "Continue with Google/Apple/Facebook" pop-ups open in the same window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

extension SpotifyAuthFlow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { closedByUser() }
}

// MARK: - Playback engine

/// Spotify's Web Playback SDK in a hidden web view: it makes MacTools itself a Spotify device called "MacTools",
/// so music plays right here. (Needs Premium; Spotify streams it, nothing is saved.)
final class SpotifyEngine: NSObject {
    static let shared = SpotifyEngine()

    private var webView: WKWebView?
    private var window: NSWindow?

    private static let html = """
    <!doctype html><html><head><meta charset="utf-8"></head><body>
    <script>
    function post(message) { window.webkit.messageHandlers.mt.postMessage(message); }
    var tokenCallback = null;
    function provideToken(token) { if (tokenCallback) { tokenCallback(token); tokenCallback = null; } }
    window.onSpotifyWebPlaybackSDKReady = function () {
      var player = new Spotify.Player({
        name: 'MacTools',
        getOAuthToken: function (callback) { tokenCallback = callback; post({ type: 'token' }); },
        volume: 0.8
      });
      window.mtPlayer = player;
      player.addListener('ready', function (e) { post({ type: 'ready', device_id: e.device_id }); });
      player.addListener('not_ready', function (e) { post({ type: 'not_ready', device_id: e.device_id }); });
      ['initialization_error', 'authentication_error', 'account_error', 'playback_error'].forEach(function (name) {
        player.addListener(name, function (e) { post({ type: 'error', kind: name, message: (e && e.message) || name }); });
      });
      player.connect().then(function (ok) { if (!ok) { post({ type: 'error', kind: 'connect', message: 'Could not connect' }); } });
    };
    </script>
    <script src="https://sdk.scdn.co/spotify-player.js"></script>
    </body></html>
    """

    func start() {
        guard webView == nil, SpotifyClient.shared.isSignedIn else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "mt")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        view.customUserAgent = SchoolWeb.userAgent
        // Kept in a window that's never shown, so it keeps playing like a background browser tab.
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentView = view
        self.window = window
        webView = view
        view.loadHTMLString(Self.html, baseURL: URL(string: "https://localhost/"))
    }

    func stop() {
        webView?.evaluateJavaScript("window.mtPlayer && window.mtPlayer.disconnect()", completionHandler: nil)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mt")
        webView = nil
        window = nil
        SpotifyClient.shared.engineChanged(deviceID: nil, problem: nil)
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "token":
            SpotifyClient.shared.withToken { [weak self] result in
                guard case .success(let token) = result,
                      let data = try? JSONSerialization.data(withJSONObject: [token]) else { return }
                // Passed as JSON so it's always a safe string literal.
                self?.webView?.evaluateJavaScript("provideToken(\(String(decoding: data, as: UTF8.self))[0])", completionHandler: nil)
            }
        case "ready":
            SpotifyClient.shared.engineChanged(deviceID: message["device_id"] as? String, problem: nil)
        case "not_ready":
            SpotifyClient.shared.engineChanged(deviceID: nil, problem: nil)
        case "error":
            let kind = (message["kind"] as? String) ?? ""
            let text = (message["message"] as? String) ?? "Unknown problem"
            let problem = kind == "account_error"
                ? "Playing inside MacTools needs Spotify Premium."
                : "MacTools can't play here (\(text)). Pick another device from the speaker menu."
            SpotifyClient.shared.engineChanged(deviceID: nil, problem: problem)
        default:
            break
        }
    }
}

extension SpotifyEngine: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        received(message.body)
    }
}
