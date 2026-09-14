import AppKit

/// Receives `magnet:` links and `.torrent` files from LaunchServices, and guarantees that only one
/// copy of the app is ever running.
///
/// URL delivery deliberately does *not* live in a `.onOpenURL` view modifier. Two things break
/// there: the URL can arrive before the download engine has finished starting (a magnet click that
/// launches the app cold), and a view modifier can't fire at all once the window has been closed.
/// Sitting in the app delegate solves both — URLs are received regardless of window state, and
/// anything that arrives before the app is ready is buffered until it is.
///
/// Everything here runs on the main thread: AppKit calls delegate methods there, and a
/// distributed notification is delivered on the run loop its observer was registered from — the
/// main one, since `applicationWillFinishLaunching` registers it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Carries URLs from a duplicate launch to the instance that is already running. Derived from
    /// the bundle ID so it can't collide with another app's notifications.
    private static let forwardedURLs = Notification.Name(
        (Bundle.main.bundleIdentifier ?? "TorrentApp") + ".forwardedURLs"
    )
    private static let urlsKey = "urls"

    private var handler: (([URL]) -> Void)?
    private var reopenWindow: (() -> Void)?
    private var pendingURLs: [URL] = []

    /// Non-nil when another copy was already running when this process launched, which makes this
    /// process a duplicate whose only job is to hand its URLs over and quit.
    private var primaryInstance: NSRunningApplication?

    // MARK: - Single instance

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Decided here, before any window or libtorrent session exists, so a duplicate can bow out
        // without ever having touched the shared Application Support directory.
        primaryInstance = Self.olderRunningInstance()
        guard primaryInstance == nil else { return }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(receiveForwardedURLs(_:)),
            name: Self.forwardedURLs,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let primaryInstance else { return }
        // A duplicate launch with no URL attached — a stray double-click on a second copy of the
        // bundle, say. Step aside rather than becoming a second instance fighting over the same
        // session directory. The grace period covers the uncommon case of the URL Apple event
        // landing after launch finishes instead of before it; an ordinary magnet click has already
        // been forwarded by -application:openURLs: by the time we get here.
        primaryInstance.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    /// The oldest other process running this bundle ID, or `nil` when this process is that one.
    ///
    /// Matching on bundle ID rather than path is the point. LaunchServices keys *applications* by
    /// path, so to it a leftover copy elsewhere on disk is a different app that it is happy to run
    /// alongside this one; to this check they are the same app.
    private static func olderRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier }
        // The oldest process wins, so that two copies launched at the same instant can't both
        // stand aside and leave nothing running.
        let launched = { (app: NSRunningApplication) in app.launchDate ?? .distantFuture }
        guard let oldest = others.min(by: { launched($0) < launched($1) }),
              launched(oldest) < launched(current)
        else { return nil }
        return oldest
    }

    /// Hands URLs to the instance that is already running, then exits without finishing launch, so
    /// no second Dock icon or window ever appears.
    private func forward(_ urls: [URL], to primary: NSRunningApplication) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.forwardedURLs,
            object: nil,
            userInfo: [Self.urlsKey: urls.map(\.absoluteString)],
            deliverImmediately: true
        )
        primary.activate(options: [.activateAllWindows])
        exit(0)
    }

    // MARK: - URLs

    /// Installs the handler that actually adds torrents, plus the action that brings the app's
    /// single window back once it has been closed, and immediately drains anything that arrived
    /// beforehand. Call this only once startup has completed — that is what makes the buffering
    /// meaningful.
    @MainActor
    func configure(reopenWindow: @escaping () -> Void, handler: @escaping ([URL]) -> Void) {
        self.reopenWindow = reopenWindow
        self.handler = handler
        drain()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let primaryInstance {
            forward(urls, to: primaryInstance)
            return
        }
        accept(urls)
    }

    @objc private func receiveForwardedURLs(_ notification: Notification) {
        let strings = notification.userInfo?[Self.urlsKey] as? [String] ?? []
        let urls = strings.compactMap(URL.init(string:))
        guard !urls.isEmpty else { return }
        accept(urls)
    }

    private func accept(_ urls: [URL]) {
        showWindow()
        pendingURLs.append(contentsOf: urls)
        drain()
    }

    private func drain() {
        guard let handler, !pendingURLs.isEmpty else { return }
        let buffered = pendingURLs
        pendingURLs.removeAll()
        handler(buffered)
    }

    // MARK: - Window lifecycle

    /// Keeps transfers running when the window is closed. A torrent client that stopped
    /// downloading on ⌘W would be surprising, and quitting on close would also mean every magnet
    /// click is a cold launch.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Lets a Dock-icon click restore the window after it's been closed. Returning `true` is what
    /// gives SwiftUI the chance to re-create the `WindowGroup`'s window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /// Brings the existing window forward — never creates a second one. The `Window` scene in
    /// `TorrentAppMain` guarantees there is at most one to find; `reopenWindow` re-opens that same
    /// window by id when it has been closed outright.
    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.canBecomeMain }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            reopenWindow?()
        }
    }
}
