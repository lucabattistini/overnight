import AppKit
import OvernightCore

enum MenuBuilder {

    static func apply(
        _ presentation: MenuPresentation,
        to menu: NSMenu,
        target: AnyObject,
        action: Selector
    ) {
        menu.removeAllItems()
        // AppKit second-guesses isEnabled from target/action validation unless this is off, and
        // MenuPresentation is the authority on what may be picked.
        menu.autoenablesItems = false
        for item in presentation.items {
            menu.addItem(build(item, target: target, action: action))
        }
    }

    private static func build(
        _ item: MenuPresentation.Item,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        guard !item.isSeparator else { return .separator() }

        let menuItem = NSMenuItem()
        menuItem.title = item.title
        menuItem.toolTip = item.tooltip
        menuItem.image = image(for: item.symbol)
        menuItem.state = item.isChecked ? .on : .off
        menuItem.isEnabled = item.isEnabled

        if let children = item.children {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in children {
                submenu.addItem(build(child, target: target, action: action))
            }
            menuItem.submenu = submenu
        } else if let itemAction = item.action {
            menuItem.target = target
            menuItem.action = action
            menuItem.representedObject = itemAction
            // Only on enabled items: an attributedTitle fights AppKit's own greying of a
            // disabled row, and the times that need aligning are all pickable.
            if item.isEnabled, item.title.contains(where: \.isNumber) {
                menuItem.attributedTitle = monospacedDigits(item.title)
            }
        }

        return menuItem
    }

    private static let monospacedDigitFont =
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private static let warningImage: NSImage? = {
        let image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Warning"
        )
        image?.isTemplate = true
        return image
    }()

    private static func monospacedDigits(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: monospacedDigitFont])
    }

    private static func image(for symbol: MenuPresentation.Symbol?) -> NSImage? {
        guard let symbol else { return nil }
        switch symbol {
        case .warning: return warningImage
        }
    }
}
