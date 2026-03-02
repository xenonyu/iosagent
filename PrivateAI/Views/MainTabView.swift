import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.managedObjectContext) private var context
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ChatView(viewModel: ChatViewModel(context: context, appState: appState))
                .tabItem {
                    Label("助理", systemImage: "bubble.left.and.bubble.right.fill")
                }
                .tag(0)

            TimelineView(viewModel: TimelineViewModel(context: context))
                .tabItem {
                    Label("时光轴", systemImage: "calendar")
                }
                .tag(1)

            ProfileView(viewModel: ProfileViewModel(context: context))
                .tabItem {
                    Label("我", systemImage: "person.fill")
                }
                .tag(2)

            SettingsView(viewModel: SettingsViewModel(context: context, appState: appState))
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .accentColor(Color("AccentPrimary"))
    }
}
