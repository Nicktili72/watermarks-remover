import SwiftUI

@main
struct WatermarksRemoverApp: App {
    @StateObject private var service = ServiceModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(service)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 700)
    }
}
