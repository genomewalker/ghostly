import SwiftUI

@main
@MainActor
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

    // Permissions are checked in Settings (gear icon) — no auto-open on startup
    // to avoid triggering macOS permission dialogs that can freeze system input.
}
