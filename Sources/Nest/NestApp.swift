import SwiftUI
import NestLib

@main
struct NestApp: App {
    @StateObject private var store = SiteStore()
    @StateObject private var processController = ProcessController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(processController)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 960, height: 640)
    }
}
