import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [SessionRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            BatchOverviewView(path: $path)
        }
        // Opens the store for the current data source, scans the watched
        // folder if that's the source, and loads the batch. Here rather than
        // in `BatchOverviewView` so it runs once for the window's lifetime
        // instead of on every re-presentation of the overview.
        .task { await model.activate() }
        // Coming back to the app is the moment new files are most likely to
        // have appeared — dropped in from Finder, or synced down from another
        // device while this one was in the background. A no-op unless the
        // watched folder is the active source, and debounced inside the model
        // so the `.active` that lands right after launch doesn't rescan what
        // `activate()` just scanned.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.rescanFolder()
                await model.syncPolar()
            }
        }
    }
}

/// See `BatchOverviewPreviewHost` — the model has to live in `@State` to
/// survive a preview re-render.
private struct ContentPreviewHost: View {
    @State private var model = AppModel()

    var body: some View {
        ContentView().environment(model)
    }
}

#Preview {
    ContentPreviewHost()
}
