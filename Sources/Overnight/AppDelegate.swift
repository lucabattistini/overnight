import AppKit
import OvernightCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var isMenuOpen = false
    private var needsRefreshOnOpen = true
    private let customTime = CustomTimeWindowController()

    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        menu.delegate = self
        menu.autoenablesItems = false

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.menu = menu
        statusItem = item

        model.onChange = { [weak self] in self?.modelChanged() }
        model.start()
        repaintStatusItem()
    }

    // MARK: - Status item

    private func modelChanged() {
        repaintStatusItem()
        // The menu is a snapshot taken when it opened. Both run-loop sources now fire during
        // tracking, so state can move underneath it -- and a menu cannot be restructured while
        // open. Dropping tracking is what stops a pick landing on a stale row.
        if isMenuOpen { menu.cancelTracking() }
    }

    private func repaintStatusItem() {
        guard let button = statusItem?.button else { return }
        let active = model.status.isActive
        button.image = MenuBarIcon.image(active: active)
        button.setAccessibilityLabel(MenuBarIcon.label(active: active))
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Once per open session, not once per half-second: a reopen inside the old window
        // skipped the refresh entirely and rebuilt the menu from the previous status.
        if needsRefreshOnOpen {
            needsRefreshOnOpen = false
            model.refresh()
        }
        MenuBuilder.apply(presentation(), to: menu, target: self, action: #selector(pick(_:)))
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        model.prepareNotifications()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        needsRefreshOnOpen = true
    }

    /// Nothing in the status menu has a key equivalent, so AppKit never needs to build it to
    /// answer a keystroke -- which is the other thing that calls menuNeedsUpdate:.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }

    private func presentation() -> MenuPresentation {
        MenuPresentation.make(
            status: model.status,
            onBatteryWhileActive: model.onBatteryWhileActive,
            lastError: model.lastError,
            isBusy: model.isBusy
        )
    }

    // MARK: - Actions

    @objc private func pick(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuPresentation.Action else { return }
        switch action {
        case .enable(let hour, let minute):
            model.enable(hour: hour, minute: minute)
        case .chooseCustomTime:
            presentCustomTime()
        case .turnOff, .cleanUpStaleState:
            model.disable()
        case .copyRecoveryCommand:
            copyRecoveryCommand()
        case .refresh:
            model.refresh()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private func copyRecoveryCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(OvernightPaths.recoveryCommand, forType: .string)
    }

    private func presentCustomTime() {
        customTime.present { [weak self] hour, minute in
            self?.model.enable(hour: hour, minute: minute)
        }
    }
}
