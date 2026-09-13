import AppKit
import SwiftUI
import OvernightCore

@MainActor
final class CustomTimeWindowController {

    private static let storageKey = "customWakeMinutes"
    private static let fallbackMinutes = 7 * 60 + 30

    private var window: NSWindow?

    /// Clamped on the way out: the value comes from user defaults, and a poisoned one must not
    /// reach Deadline and the privileged argument path.
    static var storedMinutes: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) != nil else { return fallbackMinutes }
        let stored = defaults.integer(forKey: storageKey)
        // Deadline owns the hour and minute range rule; asking it is what keeps this from
        // becoming a second home for the same invariant.
        guard (try? Deadline(minutesSinceMidnight: stored)) != nil else { return fallbackMinutes }
        return stored
    }

    func present(onConfirm: @escaping (Int, Int) -> Void) {
        if let window {
            bringForward(window)
            return
        }

        let view = CustomTimeView(
            minutesSinceMidnight: Self.storedMinutes,
            onConfirm: { [weak self] hour, minute in
                UserDefaults.standard.set(hour * 60 + minute, forKey: Self.storageKey)
                self?.close()
                onConfirm(hour, minute)
            },
            onCancel: { [weak self] in self?.close() }
        )

        let hosting = NSHostingView(rootView: view)
        let created = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        created.title = "Wake Time"
        created.contentView = hosting
        created.isReleasedWhenClosed = false
        created.center()
        window = created
        bringForward(created)
    }

    func close() {
        window?.close()
        window = nil
    }

    /// The app is an accessory with no Dock icon, so a new window does not come forward on its
    /// own. activate(ignoringOtherApps:) is deprecated as of the macOS 14 SDK but is what is
    /// available at the macOS 13 deployment target.
    private func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
