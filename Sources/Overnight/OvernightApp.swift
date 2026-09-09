import SwiftUI

@main
struct OvernightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.status.isActive ? "moon.stars.fill" : "moon")
        }
        // The window style lets the deadline picker live inline. A plain menu would force the
        // time choice into a chain of nested items.
        .menuBarExtraStyle(.window)
    }
}
