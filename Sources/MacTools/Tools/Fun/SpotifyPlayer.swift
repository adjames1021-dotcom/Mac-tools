import SwiftUI
import AppKit
import WebKit

/// Spotify's web player, built into MacTools. One web view lives for the whole session, so music keeps
/// playing while you use other tools, and the sign-in is kept on disk like any browser's.
final class SpotifyPlayer: NSObject, ObservableObject {
    static let shared = SpotifyPlayer()
    static let home = URL(string: "https://open.spotify.com/")!

    enum Control { case playPause, next, previous }

    @Published private(set) var address = ""
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// True once the player has been opened this session (it isn't loaded until you first use it).
    @Published private(set) var started = false

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 720), configuration: configuration)
        // Spotify only serves its player to browsers it knows, so this one introduces itself as Safari.
        view.customUserAgent = SchoolWeb.userAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    private var parking: NSWindow?
    private var popups: [NSWindow] = []

    func loadIfNeeded() {
        guard !started else { return }
        started = true
        webView.load(URLRequest(url: Self.home))
    }

    func goHome() {
        started = true
        webView.load(URLRequest(url: Self.home))
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { webView.reload() }

    /// Opens the Spotify page in MacTools with a search (e.g. "Christmas" playlists) – in the native player when
    /// you're signed in to it, otherwise in the web player.
    func show(search: String) {
        if SpotifyClient.shared.isSignedIn {
            UserDefaults.standard.set("player", forKey: "spotifyMode")
            SpotifyClient.shared.pendingSearch = search
            AppState.shared.selection = .spotify
            AppState.showMainWindow()
            return
        }
        UserDefaults.standard.set("web", forKey: "spotifyMode")
        started = true
        let query = search.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? search
        if let url = URL(string: "https://open.spotify.com/search/\(query)/playlists") {
            webView.load(URLRequest(url: url))
        }
        AppState.shared.selection = .spotify
        AppState.showMainWindow()
    }

    /// Play/pause, next or previous: through the native player when you're signed in to it, otherwise by pressing
    /// the web player's own buttons.
    func control(_ control: Control) {
        let client = SpotifyClient.shared
        if client.isSignedIn {
            switch control {
            case .playPause:
                // The menu bar may not have fresh state; read it first so play/pause does the right thing.
                client.refreshPlayback()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { client.togglePlay() }
            case .next: client.next()
            case .previous: client.previous()
            }
            return
        }
        guard started else {
            if control == .playPause { loadIfNeeded() }
            return
        }
        let id: String
        switch control {
        case .playPause: id = "control-button-playpause"
        case .next: id = "control-button-skip-forward"
        case .previous: id = "control-button-skip-back"
        }
        let script = "(function(){var b=document.querySelector('[data-testid=\"\(id)\"]');if(b){b.click();return true}return false})()"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Opens what's on screen in the Spotify app instead (or the Spotify website if the app isn't installed).
    func openInApp() {
        var uri = "spotify:"
        if let url = webView.url, url.host == "open.spotify.com" {
            let parts = url.path.split(separator: "/").map(String.init).filter { !$0.hasPrefix("intl-") }
            if parts.count >= 2, ["track", "album", "playlist", "artist", "episode", "show"].contains(parts[0]) {
                uri = "spotify:\(parts[0]):\(parts[1])"
            }
        }
        if let app = URL(string: uri), NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else {
            NSWorkspace.shared.open(webView.url ?? Self.home)
        }
    }

    /// When the Spotify page is closed, the player moves into a hidden window so the music keeps playing.
    func parkSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.started, self.webView.window == nil else { return }
            if self.parking == nil {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled],
                                      backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.isExcludedFromWindowsMenu = true
                window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
                self.parking = window
            }
            self.webView.removeFromSuperview()
            self.webView.frame = self.parking?.contentView?.bounds ?? self.webView.frame
            self.parking?.contentView?.addSubview(self.webView)
        }
    }

    fileprivate func refresh() {
        address = webView.url?.absoluteString ?? ""
        loading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    fileprivate func openPopup(configuration: WKWebViewConfiguration) -> WKWebView {
        // Sign-in pop-ups (Google, Apple, Facebook) must use the configuration WebKit hands us.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 700), configuration: configuration)
        popup.customUserAgent = SchoolWeb.userAgent
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Spotify"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    fileprivate func closePopup(_ view: WKWebView) {
        guard let window = popups.first(where: { $0.contentView === view }) else { return }
        window.close()
        popups.removeAll { $0 === window }
    }
}

extension SpotifyPlayer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { refresh() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { refresh() }
}

extension SpotifyPlayer: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openPopup(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(webView)
    }
}

struct SpotifyView: View {
    @ObservedObject private var player = SpotifyPlayer.shared
    @AppStorage("spotifyMode") private var mode = "player"

    var body: some View {
        ToolPage(tool: .spotify, scrolls: false) {
            Picker("", selection: $mode) {
                Text("Player").tag("player")
                Text("Web Player").tag("web")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            if mode == "web" {
                webPlayer
            } else {
                SpotifyNativeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            }
        }
    }

    private var webPlayer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { player.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!player.canGoBack)
                    .help("Back")
                Button { player.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!player.canGoForward)
                    .help("Forward")
                Button { player.goHome() } label: { Image(systemName: "house") }
                    .help("Spotify home")
                Button { player.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload")
                Divider().frame(height: 18)
                Button { player.control(.previous) } label: { Image(systemName: "backward.fill") }
                    .help("Previous")
                Button { player.control(.playPause) } label: { Image(systemName: "playpause.fill") }
                    .help("Play / Pause")
                Button { player.control(.next) } label: { Image(systemName: "forward.fill") }
                    .help("Next")
                if player.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open in Spotify App") { player.openInApp() }
            }
            HostedNSView(view: player.webView)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Spotify's own web page. Sign in once – MacTools remembers it, and music keeps playing when you switch tools.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { player.loadIfNeeded() }
        .onDisappear { player.parkSoon() }
    }
}
