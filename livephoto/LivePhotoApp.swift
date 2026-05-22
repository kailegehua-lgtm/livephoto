import SwiftUI

@main
struct LivePhotoApp: App {
    @StateObject private var momentStore = MomentStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: momentStore)
                .environmentObject(momentStore)
        }
    }
}
