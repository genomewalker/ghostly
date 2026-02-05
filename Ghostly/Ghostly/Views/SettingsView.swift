import SwiftUI
import AppKit

// MARK: - Settings Window Controller
// Manages settings window manually — SettingsLink/openSettings don't work in MenuBarExtra LSUIElement apps

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Ghostly Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("defaultSessionName") private var defaultSessionName = "default"
    @AppStorage("pollIntervalPlugged") private var pollIntervalPlugged: Double = 30
    @AppStorage("pollIntervalBattery") private var pollIntervalBattery: Double = 90
    @AppStorage("showNotifications") private var showNotifications = true
    @AppStorage("autoStartOnLogin") private var autoStartOnLogin = false
    @AppStorage("ghosttyPath") private var ghosttyPath = ""
    @AppStorage("preferredTerminal") private var preferredTerminal = "auto"
    @AppStorage("terminalOpenMode") private var terminalOpenMode = "window"

    var body: some View {
        Form {
            Section("General") {
                TextField("Default session name:", text: $defaultSessionName)

                Toggle("Show notifications", isOn: $showNotifications)

                Toggle("Start on login", isOn: $autoStartOnLogin)
                    .onChange(of: autoStartOnLogin) { _, newValue in
                        if newValue {
                            installLaunchAgent()
                        } else {
                            removeLaunchAgent()
                        }
                    }
            }

            Section("Polling Intervals") {
                HStack {
                    Text("Plugged in:")
                    Slider(value: $pollIntervalPlugged, in: 10...120, step: 10)
                    Text("\(Int(pollIntervalPlugged))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("On battery:")
                    Slider(value: $pollIntervalBattery, in: 30...300, step: 30)
                    Text("\(Int(pollIntervalBattery))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }

            Section("Terminal") {
                Picker("Preferred terminal:", selection: $preferredTerminal) {
                    ForEach(PreferredTerminal.allCases, id: \.rawValue) { terminal in
                        Text(terminal.label).tag(terminal.rawValue)
                    }
                }

                Picker("Default open mode:", selection: $terminalOpenMode) {
                    ForEach(TerminalOpenMode.allCases, id: \.rawValue) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode.rawValue)
                    }
                }

                TextField("Ghostty path (auto-detected):", text: $ghosttyPath)
                    .font(.system(.body, design: .monospaced))

                Text("Leave empty to auto-detect. Tip: Option+click = tab, Shift+click = split.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 380)
        .padding()
    }

    private func installLaunchAgent() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.ghostly.app</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>Ghostly</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """

        let path = NSString(string: "~/Library/LaunchAgents/com.ghostly.app.plist").expandingTildeInPath
        try? plist.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func removeLaunchAgent() {
        let path = NSString(string: "~/Library/LaunchAgents/com.ghostly.app.plist").expandingTildeInPath
        try? FileManager.default.removeItem(atPath: path)
    }
}
