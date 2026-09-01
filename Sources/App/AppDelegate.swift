import AppKit

/// Receives `magnet:` links and `.torrent` files from LaunchServices.
///
/// This deliberately does *not* live in a `.onOpenURL` view modifier. Two things break there:
/// the URL can arrive before the download engine has finished starting (a magnet click that
/// launches the app cold), and a view modifier can't fire at all once the window has been closed.
/// Sitting in the app delegate solves both — URLs are received regardless of window state, and
/// anything that arrives before the app is ready is buffered until it is.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handler: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []

    /// Installs the handler that actually adds torrents, and immediately drains anything that
    /// arrived beforehand. Call this only once startup has completed — that is what makes the
    /// buffering meaningful.
    @MainActor
    func setHandler(_ handler: @escaping ([URL]) -> Void) {
        self.handler = handler
        guard !pendingURLs.isEmpty else { return }
        let buffered = pendingURLs
        pendingURLs.removeAll()
        handler(buffered)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showWindow()
        if let handler {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

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

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // When every window has been closed there is nothing to raise; SwiftUI re-creates one via
        // -applicationShouldHandleReopen: above, which AppKit calls as part of the activation.
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
