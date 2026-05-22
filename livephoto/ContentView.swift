import SwiftUI

struct ContentView: View {
    @ObservedObject var store: MomentStore

    var body: some View {
        TabView {
            CaptureView(store: store)
                .tabItem {
                    Label("拍摄", systemImage: "camera")
                }

            MomentListView()
                .tabItem {
                    Label("我的动态照片", systemImage: "photo.on.rectangle")
                }
        }
    }
}
