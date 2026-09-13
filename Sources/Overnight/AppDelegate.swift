import AppKit
import OvernightCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = AppModel()
    private var statusItem: NSStatusItem?

    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        statusItem = item

        model.onChange = { [weak self] in self?.repaintStatusItem() }
        model.start()
        repaintStatusItem()
    }

    private func repaintStatusItem() {
        guard let button = statusItem?.button else { return }
        let active = model.status.isActive
        button.image = MenuBarIcon.image(active: active)
        button.setAccessibilityLabel(MenuBarIcon.label(active: active))
    }
}
