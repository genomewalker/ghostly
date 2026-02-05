import SwiftUI

@main
struct GhostlyApp: App {
    @State private var connectionManager = ConnectionManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(connectionManager)
                .task {
                    await connectionManager.loadHosts()
                }
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
