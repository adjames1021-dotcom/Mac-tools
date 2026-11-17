import SwiftUI
import AppKit

/// Pages of the native Spotify player.
enum SpotifyPage: Hashable {
    case home
    case search(String)
    case liked
    case playlist(SpotifyPlaylist)
    case album(id: String, name: String)
    case artist(id: String, name: String)

    var title: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .liked: return "Liked Songs"
        case .playlist(let playlist): return playlist.name
        case .album(_, let name): return name
        case .artist(_, let name): return name
        }
    }
}

/// Loads one thing from the Web API for a page and keeps it while the page is open.
final class SpotifyLoader<Value>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var started = false

    func load(force: Bool = false, _ fetch: (@escaping (Result<Value, Error>) -> Void) -> Void) {
        guard force || !started else { return }
        started = true
        loading = true
        error = nil
        fetch { [weak self] result in
            guard let self = self else { return }
            self.loading = false
            switch result {
            case .success(let value): self.value = value
            case .failure(let error): self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func replace(_ value: Value) { self.value = value }
}

extension SpotifyClient {
    /// Follows a "next" link from a page of results.
    func getNext<T: Decodable>(_ next: String, as type: T.Type, completion: @escaping (Result<T, Error>) -> Void) {
        guard let components = URLComponents(string: next) else { return }
        let path = components.path.hasPrefix("/v1") ? String(components.path.dropFirst(3)) : components.path
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        get(path, query: query, as: type, completion: completion)
    }

    /// Starts at a random song, then turns shuffle on.
    func shufflePlay(context: String? = nil, uris: [String]? = nil, count: Int) {
        let start = count > 0 ? Int.random(in: 0..<min(count, 100)) : nil
        play(context: context, uris: uris, position: start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.call("PUT", "/me/player/shuffle", query: ["state": "true"]) { _ in }
        }
    }
}

// MARK: - Root

struct SpotifyNativeView: View {
    @ObservedObject private var client = SpotifyClient.shared
    @StateObject private var playlists = SpotifyLoader<Paging<SpotifyPlaylist>>()
    @State private var stack: [SpotifyPage] = [.home]

    var body: some View {
        if client.isSignedIn {
            player
        } else {
            SpotifySetupView()
        }
    }

    private var current: SpotifyPage { stack.last ?? .home }

    private func open(_ page: SpotifyPage) { stack.append(page) }
    private func reset(_ page: SpotifyPage) { stack = [page] }

    private var player: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 210)
                Divider()
                VStack(spacing: 0) {
                    navigationBar
                    Divider()
                    page(current)
                        .id(stack.count)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            SpotifyNowPlayingBar(open: open)
        }
        .onAppear {
            client.startWatching()
            playlists.load { done in client.get("/me/playlists", query: ["limit": "50"], as: Paging<SpotifyPlaylist>.self, completion: done) }
            showPendingSearch()
        }
        .onDisappear { client.stopWatching() }
        .onChange(of: client.pendingSearch) { _ in showPendingSearch() }
    }

    private func showPendingSearch() {
        guard let search = client.pendingSearch else { return }
        client.pendingSearch = nil
        reset(.search(search))
    }

    @ViewBuilder
    private func page(_ page: SpotifyPage) -> some View {
        switch page {
        case .home: SpotifyHomePage(open: open)
        case .search(let query): SpotifySearchPage(initial: query, open: open)
        case .liked: SpotifyLikedPage(open: open)
        case .playlist(let playlist): SpotifyPlaylistPage(playlist: playlist, open: open)
        case .album(let id, _): SpotifyAlbumPage(id: id, open: open)
        case .artist(let id, _): SpotifyArtistPage(id: id, open: open)
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button {
                if stack.count > 1 { stack.removeLast() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(stack.count <= 1)
            Text(current.title).font(.headline).lineLimit(1)
            Spacer()
            if !client.message.isEmpty {
                Label(client.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            } else if let problem = client.engineProblem {
                Label(problem, systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            SpotifySidebarButton(title: "Home", icon: "house", selected: current == .home) { reset(.home) }
            SpotifySidebarButton(title: "Search", icon: "magnifyingglass", selected: { if case .search = current { return true }; return false }()) {
                reset(.search(""))
            }
            SpotifySidebarButton(title: "Liked Songs", icon: "heart.fill", selected: current == .liked) { reset(.liked) }
            Divider().padding(.vertical, 6)
            Text("Playlists")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(playlists.value?.items ?? [], id: \.id) { playlist in
                        SpotifySidebarButton(title: playlist.name, icon: "music.note.list",
                                             selected: current == .playlist(playlist)) {
                            reset(.playlist(playlist))
                        }
                    }
                }
            }
            Divider()
            HStack {
                Image(systemName: "person.crop.circle")
                Text(client.user?.displayName ?? "Signed in").lineLimit(1)
                Spacer()
                Button("Sign Out") { client.signOut() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .font(.callout)
            .padding(8)
        }
        .padding(.top, 8)
        .padding(.horizontal, 6)
    }
}

private struct SpotifySidebarButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Building blocks

struct SpotifyArtwork: View {
    let url: URL?
    let size: CGFloat
    var round = false

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Color.primary.opacity(0.08)
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: round ? size / 2 : 4))
    }
}

private func spotifyTime(_ milliseconds: Double) -> String {
    let seconds = max(0, Int(milliseconds / 1000))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

struct SpotifyTrackRow: View {
    let index: Int
    let track: SpotifyTrack
    let showArtwork: Bool
    let play: () -> Void
    let open: (SpotifyPage) -> Void
    @ObservedObject private var client = SpotifyClient.shared
    @State private var hovering = false

    private var isCurrent: Bool { client.playback?.item?.uri == track.uri }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if hovering {
                    Button(action: play) { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                } else if isCurrent && client.playback?.isPlaying == true {
                    Image(systemName: "speaker.wave.2.fill").foregroundColor(.green)
                } else {
                    Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: 28)
            if showArtwork {
                SpotifyArtwork(url: track.artwork(64), size: 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(track.name)
                        .lineLimit(1)
                        .foregroundColor(isCurrent ? .green : .primary)
                    if track.explicit == true {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.3)))
                    }
                }
                Text(track.artistNames).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let album = track.album, let id = album.id {
                Button(album.name) { open(.album(id: id, name: album.name)) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            Text(spotifyTime(Double(track.durationMs ?? 0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("Play", action: play)
            if let artist = track.artists?.first, let id = artist.id {
                Button("Go to \(artist.name)") { open(.artist(id: id, name: artist.name)) }
            }
            if let album = track.album, let id = album.id {
                Button("Go to Album") { open(.album(id: id, name: album.name)) }
            }
            Divider()
            Button("Open in Spotify App") { SpotifyClient.openInApp(track.uri) }
            Button("Copy Song Link") {
                ClipboardHelper.copy("https://open.spotify.com/track/" + (track.id ?? ""))
            }
            .disabled(track.id == nil)
        }
    }
}

struct SpotifyTrackList: View {
    let tracks: [SpotifyTrack]
    var showArtwork = true
    let play: (Int) -> Void
    let open: (SpotifyPage) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                SpotifyTrackRow(index: index, track: track, showArtwork: showArtwork, play: { play(index) }, open: open)
            }
        }
    }
}

struct SpotifyTile: View {
    let title: String
    let subtitle: String
    let image: URL?
    var round = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                SpotifyArtwork(url: image, size: 140, round: round)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private let spotifyGrid = [GridItem(.adaptive(minimum: 140), spacing: 16)]

struct SpotifySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            content()
        }
    }
}

struct SpotifyStatus: View {
    let loading: Bool
    let error: String?

    var body: some View {
        if loading {
            ProgressView().controlSize(.small).padding()
        } else if let error = error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .padding()
        }
    }
}

/// Big header for a playlist or album, with Play, Shuffle and "Download in Spotify App".
struct SpotifyCollectionHeader: View {
    let image: URL?
    let kind: String
    let title: String
    let subtitle: String
    let uri: String?
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            SpotifyArtwork(url: image, size: 160)
                .shadow(radius: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                Text(title).font(.largeTitle.bold()).lineLimit(2)
                Text(subtitle).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Button(action: play) { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle") }
                    if let uri = uri {
                        Button {
                            SpotifyClient.openInApp(uri)
                        } label: {
                            Label("Download in Spotify App", systemImage: "arrow.down.circle")
                        }
                        .help("Opens this in the Spotify app. Turn on its Download switch to listen offline (Premium).")
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }
}

// MARK: - Pages

struct SpotifyHomePage: View {
    let open: (SpotifyPage) -> Void
    @ObservedObject private var client = SpotifyClient.shared
    @StateObject private var recent = SpotifyLoader<Paging<SpotifyPlayHistory>>()
    @StateObject private var top = SpotifyLoader<Paging<SpotifyTrack>>()
    @StateObject private var playlists = SpotifyLoader<Paging<SpotifyPlaylist>>()
    @StateObject private var albums = SpotifyLoader<Paging<SpotifySavedAlbum>>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(greeting).font(.largeTitle.bold())
                let recentTracks = uniqueRecent
                if !recentTracks.isEmpty {
                    SpotifySection(title: "Recently Played") {
                        SpotifyTrackList(tracks: recentTracks, play: { client.play(uris: recentTracks.map(\.uri), position: $0) }, open: open)
                    }
                }
                if let tracks = top.value?.items, !tracks.isEmpty {
                    SpotifySection(title: "Your Top Songs Lately") {
                        SpotifyTrackList(tracks: tracks, play: { client.play(uris: tracks.map(\.uri), position: $0) }, open: open)
                    }
                }
                if let items = playlists.value?.items, !items.isEmpty {
                    SpotifySection(title: "Your Playlists") {
                        LazyVGrid(columns: spotifyGrid, alignment: .leading, spacing: 16) {
                            ForEach(items, id: \.id) { playlist in
                                SpotifyTile(title: playlist.name, subtitle: playlist.owner?.displayName ?? "Playlist",
                                            image: SpotifyImage.best(playlist.images, size: 300)) { open(.playlist(playlist)) }
                            }
                        }
                    }
                }
                if let items = albums.value?.items, !items.isEmpty {
                    SpotifySection(title: "Your Albums") {
                        LazyVGrid(columns: spotifyGrid, alignment: .leading, spacing: 16) {
                            ForEach(items, id: \.album.id) { saved in
                                SpotifyTile(title: saved.album.name, subtitle: saved.album.artistNames,
                                            image: SpotifyImage.best(saved.album.images, size: 300)) {
                                    open(.album(id: saved.album.id, name: saved.album.name))
                                }
                            }
                        }
                    }
                }
                SpotifyStatus(loading: recent.loading && top.loading, error: recent.error ?? top.error ?? playlists.error)
            }
            .padding(20)
        }
        .onAppear {
            recent.load { client.get("/me/player/recently-played", query: ["limit": "30"], as: Paging<SpotifyPlayHistory>.self, completion: $0) }
            top.load { client.get("/me/top/tracks", query: ["limit": "10", "time_range": "short_term"], as: Paging<SpotifyTrack>.self, completion: $0) }
            playlists.load { client.get("/me/playlists", query: ["limit": "50"], as: Paging<SpotifyPlaylist>.self, completion: $0) }
            albums.load { client.get("/me/albums", query: ["limit": "30"], as: Paging<SpotifySavedAlbum>.self, completion: $0) }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    /// Recently played without repeats, newest first, at most ten.
    private var uniqueRecent: [SpotifyTrack] {
        var seen = Set<String>()
        var out: [SpotifyTrack] = []
        for item in recent.value?.items ?? [] where seen.insert(item.track.uri).inserted {
            out.append(item.track)
            if out.count == 10 { break }
        }
        return out
    }
}

struct SpotifySearchPage: View {
    let open: (SpotifyPage) -> Void
    @ObservedObject private var client = SpotifyClient.shared
    @StateObject private var results = SpotifyLoader<SpotifySearchResults>()
    @State private var query: String
    @State private var searched = ""

    init(initial: String, open: @escaping (SpotifyPage) -> Void) {
        self.open = open
        _query = State(initialValue: initial)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Songs, artists, albums or playlists", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .onSubmit(search)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                .frame(maxWidth: 520)

                if let tracks = results.value?.tracks?.items, !tracks.isEmpty {
                    SpotifySection(title: "Songs") {
                        SpotifyTrackList(tracks: Array(tracks.prefix(10)), play: { index in
                            client.play(uris: tracks.map(\.uri), position: index)
                        }, open: open)
                    }
                }
                if let artists = results.value?.artists?.items, !artists.isEmpty {
                    SpotifySection(title: "Artists") {
                        LazyVGrid(columns: spotifyGrid, alignment: .leading, spacing: 16) {
                            ForEach(artists, id: \.id) { artist in
                                SpotifyTile(title: artist.name, subtitle: "Artist", image: SpotifyImage.best(artist.images, size: 300), round: true) {
                                    open(.artist(id: artist.id, name: artist.name))
                                }
                            }
                        }
                    }
                }
                if let albums = results.value?.albums?.items, !albums.isEmpty {
                    SpotifySection(title: "Albums") {
                        LazyVGrid(columns: spotifyGrid, alignment: .leading, spacing: 16) {
                            ForEach(albums, id: \.id) { album in
                                SpotifyTile(title: album.name, subtitle: album.artistNames, image: SpotifyImage.best(album.images, size: 300)) {
                                    open(.album(id: album.id, name: album.name))
                                }
                            }
                        }
                    }
                }
                if let playlists = results.value?.playlists?.items, !playlists.isEmpty {
                    SpotifySection(title: "Playlists") {
                        LazyVGrid(columns: spotifyGrid, alignment: .leading, spacing: 16) {
                            ForEach(playlists, id: \.id) { playlist in
                                SpotifyTile(title: playlist.name, subtitle: playlist.owner?.displayName ?? "Playlist",
                                            image: SpotifyImage.best(playlist.images, size: 300)) { open(.playlist(playlist)) }
                            }
                        }
                    }
                }
                SpotifyStatus(loading: results.loading, error: results.error)
            }
            .padding(20)
        }
        .onAppear { if !query.trimmed.isEmpty { search() } }
    }

    private func search() {
        let text = query.trimmed
        guard !text.isEmpty, text != searched else { return }
        searched = text
        results.load(force: true) { done in
            client.get("/search", query: ["q": text, "type": "track,artist,album,playlist", "limit": "20"],
                       as: SpotifySearchResults.self, completion: done)
        }
    }
}

struct SpotifyLikedPage: View {
    let open: (SpotifyPage) -> Void
    @ObservedObject private var client = SpotifyClient.shared
    @StateObject private var page = SpotifyLoader<Paging<SpotifyTrackItem>>()
    @State private var tracks: [SpotifyTrack] = []
    @State private var next: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SpotifyCollectionHeader(image: nil, kind: "Playlist", title: "Liked Songs",
                                        subtitle: page.value?.total.map { "\($0) songs" } ?? "",
                                        uri: "spotify:collection:tracks",
                                        play: { play(0) },
                                        shuffle: { client.shufflePlay(uris: tracks.map(\.uri), count: tracks.count) })
                SpotifyTrackList(tracks: tracks, play: play, open: open)
                if let next = next {
                    Button("Load More") { loadMore(next) }
                }
                SpotifyStatus(loading: page.loading, error: page.error)
            }
            .padding(20)
        }
        .onAppear {
            page.load { done in
                client.get("/me/tracks", query: ["limit": "50"], as: Paging<SpotifyTrackItem>.self) { result in
                    if case .success(let first) = result {
                        tracks = first.items.compactMap(\.track)
                        next = first.next
                    }
                    done(result)
                }
            }
        }
    }

    private func play(_ index: Int) {
        client.play(uris: Array(tracks.dropFirst(index).prefix(100)).map(\.uri))
    }

    private func loadMore(_ link: String) {
        client.getNext(link, as: Paging<SpotifyTrackItem>.self) { result in
            if case .success(let more) = result {
                tracks += more.items.compactMap(\.track)
                next = more.next
            }
        }
    }
}

struct SpotifyPlaylistPage: View {
    let playlist: SpotifyPlaylist
    let open: (SpotifyPage) -> Void
    @ObservedObject private var client = SpotifyClient.shared
    @StateObject private var page = SpotifyLoader<Paging<SpotifyTrackItem>>()
    @State private var tracks: [SpotifyTrack] = []
    @State private var next: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SpotifyCollectionHeader(
                    image: SpotifyImage.best(playlist.images, size: 300), kind: "Playlist", title: playlist.name,
                    subtitle: [playlist.owner?.displayName, playlist.tracks?.total.map { "\($0) songs" }].compactMap { $0 }.joined(separator: " · "),
                    uri: playlist.uri,
                    play: { client.play(context: playlist.uri, position: 0) },
                    shuffle: { client.shufflePlay(context: playlist.uri, count: playlist.tracks?.total ?? tracks.count) })
                SpotifyTrackList(tracks: tracks, play: { index in
                    client.play(context: playlist.uri, startURI: tracks[index].uri)
                }, open: open)
                if let next = next {
                    Button("Load More") { loadMore(next) }
                }
                SpotifyStatus(loading: page.loading, error: page.error)
            }
            .padding(20)
        }
        .onAppear {
            page.load { done in
                client.get("/playlists/\(playlist.id)/tracks", query: ["limit": "100"], as: Paging<SpotifyTrackItem>.self) { result in
                    if case .success(let first) = result {
                        tracks = first.items.compactMap(\.track)
                        next = first.next
                    }
                    done(result)
                }
            }
        }
    }

    private func loadMore(_ link: String) {
        client.getNext(link, as: Paging<SpotifyTrackItem>.self) { result in
            if case .success(let more) = result {
                tracks += more.items.compactMap(\.track)
                next = more.next
            }
        }
    }
}

struct SpotifyAlbumPage: View {
    let id: String
    let open: (SpotifyPage) -> Void
    @ObservedObject private var client = SpotifyClient.shared
    @StateObject private var album = SpotifyLoader<SpotifyAlbum>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let album = album.value {
                    let tracks = album.tracks?.items ?? []
                    SpotifyCollectionHeader(
                        image: SpotifyImage.best(album.images, size: 300), kind: "Album", title: album.name,
                        subtitle: [album.artistNames, album.releaseDate.map { String($0.prefix(4)) }].compactMap { $0 }.joined(separator: " · "),
                        uri: album.uri,
                        play: { client.play(context: album.uri, position: 0) },
                        shuffle: { client.shufflePlay(context: album.uri, count: tracks.count) })
                    if let artist = album.artists?.first, let artistID = artist.id {
                        Button("More by \(artist.name)") { open(.artist(id: artistID, name: artist.name)) }
                            .buttonStyle(.link)
                    }
                    SpotifyTrackList(tracks: tracks, showArtwork: false, play: { index in
                        client.play(context: album.uri, position: index)
                    }, open: open)
                }
                SpotifyStatus(loading: album.loading, error: album.error)
            }
            .padding(20)
        }
        .onAppear {
            album.load { client.get("/albums/\(id)", as: SpotifyAlbum.self, completion: $0) }
        }
    }
}

struct SpotifyArtistPage: View {
    let id: String
    let open: (SpotifyPage) -> Void
    @ObservedObject private var client = SpotifyClient.shared
    @StateObject private var artist = SpotifyLoader<SpotifyArtist>()
    @StateObject private var top = SpotifyLoader<SpotifyTopTracks>()
    @StateObject private var albums = SpotifyLoader<Paging<SpotifyAlbum>>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let artist = artist.value {
                    HStack(alignment: .bottom, spacing: 18) {
                        SpotifyArtwork(url: SpotifyImage.best(artist.images, size: 300), size: 160, round: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ARTIST").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(artist.name).font(.largeTitle.bold())
                            if let followers = artist.followers?.total {
                                Text("\(followers.formatted()) followers").foregroundStyle(.secondary)
                            }
                            HStack {
                                Button {
                                    client.play(context: artist.uri)
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                Button("Open in Spotify App") { SpotifyClient.openInApp(artist.uri) }
                            }
                        }
                        Spacer()
                    }
                }
                if let tracks = top.value?.tracks, !tracks.isEmpty {
                    SpotifySection(title: "Popular") {
                        SpotifyTrackList(tracks: Array(tracks.prefix(10)), play: { index in
                            client.play(uris: tracks.map(\.uri), position: index)
                        }, open: open)
                    }
                }
                if let items = albums.value?.items, !items.isEmpty {
                    SpotifySection(title: "Albums & Singles") {
                        LazyVGrid(columns: spotifyGrid, alignment: .leading, spacing: 16) {
                            ForEach(items, id: \.id) { album in
                                SpotifyTile(title: album.name, subtitle: album.releaseDate.map { String($0.prefix(4)) } ?? "",
                                            image: SpotifyImage.best(album.images, size: 300)) {
                                    open(.album(id: album.id, name: album.name))
                                }
                            }
                        }
                    }
                }
                SpotifyStatus(loading: artist.loading, error: artist.error ?? top.error)
            }
            .padding(20)
        }
        .onAppear {
            artist.load { client.get("/artists/\(id)", as: SpotifyArtist.self, completion: $0) }
            top.load { client.get("/artists/\(id)/top-tracks", query: ["market": "from_token"], as: SpotifyTopTracks.self, completion: $0) }
            albums.load {
                client.get("/artists/\(id)/albums", query: ["include_groups": "album,single", "limit": "30"],
                           as: Paging<SpotifyAlbum>.self, completion: $0)
            }
        }
    }
}

// MARK: - Now playing

struct SpotifyNowPlayingBar: View {
    let open: (SpotifyPage) -> Void
    @ObservedObject private var client = SpotifyClient.shared
    @State private var scrub: Double?
    @State private var volume: Double?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { _ in
            bar
        }
    }

    private var bar: some View {
        let playback = client.playback
        let track = playback?.item
        let duration = Double(track?.durationMs ?? 0)
        let position = scrub ?? client.position
        return HStack(spacing: 16) {
            HStack(spacing: 10) {
                SpotifyArtwork(url: track?.artwork(128), size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    if let track = track {
                        Button(track.name) {
                            if let album = track.album, let id = album.id { open(.album(id: id, name: album.name)) }
                        }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        Text(track.artistNames).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Nothing playing").foregroundStyle(.secondary)
                        Text("Pick a song, or press play to carry on where Spotify left off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if track?.id != nil {
                    Button {
                        client.toggleLike()
                    } label: {
                        Image(systemName: client.currentLiked ? "heart.fill" : "heart")
                            .foregroundColor(client.currentLiked ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(client.currentLiked ? "Remove from Liked Songs" : "Save to Liked Songs")
                }
            }
            .frame(width: 290, alignment: .leading)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                HStack(spacing: 18) {
                    Button { client.toggleShuffle() } label: {
                        Image(systemName: "shuffle").foregroundColor(playback?.shuffleState == true ? .green : .secondary)
                    }
                    .help("Shuffle")
                    Button { client.previous() } label: { Image(systemName: "backward.fill") }
                        .help("Previous")
                    Button { client.togglePlay() } label: {
                        Image(systemName: playback?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                    }
                    .help(playback?.isPlaying == true ? "Pause" : "Play")
                    Button { client.next() } label: { Image(systemName: "forward.fill") }
                        .help("Next")
                    Button { client.cycleRepeat() } label: {
                        Image(systemName: playback?.repeatState == "track" ? "repeat.1" : "repeat")
                            .foregroundColor((playback?.repeatState ?? "off") != "off" ? .green : .secondary)
                    }
                    .help("Repeat")
                }
                .buttonStyle(.borderless)
                HStack(spacing: 8) {
                    Text(spotifyTime(position))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Slider(value: Binding(get: { min(position, max(duration, 1)) }, set: { scrub = $0 }),
                           in: 0...max(duration, 1),
                           onEditingChanged: { editing in
                               if !editing, let target = scrub {
                                   client.seek(to: target)
                                   scrub = nil
                               }
                           })
                        .controlSize(.small)
                        .disabled(track == nil)
                    Text(spotifyTime(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)
                }
            }
            .frame(maxWidth: 470)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Menu {
                    ForEach(client.devices, id: \.self) { device in
                        Button {
                            client.transfer(to: device)
                        } label: {
                            Label(device.name + (device.isActive ? "  ✓" : ""), systemImage: device.icon)
                        }
                    }
                    if client.devices.isEmpty {
                        Text("No devices yet – open Spotify on your phone or Mac")
                    }
                    Divider()
                    Button("Refresh Devices") { client.loadDevices() }
                } label: {
                    Image(systemName: playback?.device?.icon ?? "hifispeaker")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(playback?.device.map { "Playing on \($0.name)" } ?? "Choose where to play")
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { volume ?? Double(playback?.device?.volumePercent ?? 50) }, set: { volume = $0 }),
                       in: 0...100,
                       onEditingChanged: { editing in
                           if !editing, let level = volume {
                               client.setVolume(level)
                               DispatchQueue.main.asyncAfter(deadline: .now() + 2) { volume = nil }
                           }
                       })
                    .controlSize(.small)
                    .frame(width: 100)
            }
            .frame(width: 210, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Setup

struct SpotifySetupView: View {
    @ObservedObject private var client = SpotifyClient.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect Spotify").font(.title2.bold())
                Text("The player talks to Spotify through its official developer connection. Set it up once – it takes about two minutes:")
                    .foregroundStyle(.secondary)
                step(1, "Open the Spotify Developer Dashboard and sign in with your Spotify account.") {
                    Link("Open the Dashboard", destination: SpotifyClient.dashboard)
                }
                step(2, "Click “Create app”. Any name and description is fine (for example “MacTools”).") { EmptyView() }
                step(3, "Under Redirect URIs, add exactly this address:") {
                    HStack {
                        Text(SpotifyClient.redirectURI)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(text: SpotifyClient.redirectURI)
                    }
                }
                step(4, "Under “Which API/SDKs are you planning to use?”, tick Web API and Web Playback SDK, agree to the terms and Save.") { EmptyView() }
                step(5, "Open the app's Settings, copy its Client ID, and paste it here:") {
                    HStack {
                        TextField("Client ID", text: $client.clientID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 330)
                        Button("Sign In with Spotify") { client.signIn() }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(client.clientID.trimmed.isEmpty || client.signingIn)
                    }
                }
                step(6, "If Spotify says you aren't allowed in, open the app's User Management page and add the email address of your Spotify account.") { EmptyView() }
                if !client.message.isEmpty {
                    Label(client.message, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                }
                Text("MacTools keeps only a sign-in token (in your Mac's keychain), never your password. Music streams from Spotify exactly like in its own app. To listen offline, use the Download switch in the Spotify app – the player's “Download in Spotify App” button takes you there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    private func step<Extra: View>(_ number: Int, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.green))
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                extra()
            }
        }
    }
}
