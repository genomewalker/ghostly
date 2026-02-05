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
                    checkPermissionsOnStart()
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

    private func checkPermissionsOnStart() {
        let accessibility = AXIsProcessTrusted()

        // Test App Management by checking /Applications writability
        let testPath = "/Applications/.ghostly-permission-test"
        let appManagement = FileManager.default.createFile(atPath: testPath, contents: nil)
        if appManagement {
            try? FileManager.default.removeItem(atPath: testPath)
        }

        if !accessibility || !appManagement {
            AppLog.shared.log("Missing permissions — opening Settings", level: .warning)
            SettingsWindowController.shared.show()
        }
    }
}
