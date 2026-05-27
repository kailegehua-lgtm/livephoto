import SwiftUI

struct ContentView: View {
    @ObservedObject var store: MomentStore
    @StateObject private var captureViewModel: CaptureViewModel

    init(store: MomentStore) {
        self.store = store
        _captureViewModel = StateObject(wrappedValue: CaptureViewModel(store: store))
    }

    var body: some View {
        TabView {
            CaptureView(viewModel: captureViewModel)
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
