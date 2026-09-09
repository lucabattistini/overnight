import AppKit
import SwiftUI

@main
struct OvernightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            // One curved band, continuous while Overnight holds the machine awake and broken in
            // the middle while it does not. See MenuBarIcon.
            let active = model.status.isActive
            Image(nsImage: MenuBarIcon.image(active: active))
                .accessibilityLabel(MenuBarIcon.label(active: active))
        }
        // The window style lets the deadline picker live inline. A plain menu would force the
        // time choice into a chain of nested items.
        .menuBarExtraStyle(.window)
    }
}
