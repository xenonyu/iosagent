import SwiftUI

@main
struct PrivateAIApp: App {
    let persistence = PersistenceController.shared
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistence.container.viewContext)
                .environmentObject(appState)
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willResignActiveNotification)
                ) { _ in
                    persistence.save()
                }
        }
    }
}
