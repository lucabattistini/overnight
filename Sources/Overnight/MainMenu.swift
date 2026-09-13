import AppKit

enum MainMenu {

    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(titled: "Overnight", items: appItems()))
        main.addItem(submenu(titled: "Edit", items: editItems()))
        return main
    }

    private static func submenu(titled title: String, items: [NSMenuItem]) -> NSMenuItem {
        let container = NSMenuItem()
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        container.submenu = menu
        return container
    }

    private static func appItems() -> [NSMenuItem] {
        [NSMenuItem(title: "Quit Overnight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")]
    }

    private static func editItems() -> [NSMenuItem] {
        [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]
    }
}
