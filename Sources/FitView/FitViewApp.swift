import SwiftUI

@main
struct FitViewApp: App {
    /// Owned here rather than inside `BatchOverviewView` because the macOS
    /// `Settings` scene below is a *sibling* of `WindowGroup`, not a
    /// descendant — the only place both can read the same instance from is the
    /// `App` itself. See `AppModel`.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }

        #if os(macOS)
        // Gives ⌘, and the standard app-menu Settings… item. iOS presents the
        // same content as a sheet from the overview's toolbar.
        Settings {
            SettingsContent()
                .environment(model)
                .frame(width: 460)
        }
        #endif
    }
}
