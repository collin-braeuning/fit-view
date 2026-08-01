import SwiftUI

struct ContentView: View {
    @State private var path: [SessionRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            BatchOverviewView(path: $path)
        }
    }
}

#Preview {
    ContentView()
}
