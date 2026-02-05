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

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var automationStatus: String = "Unknown"
    @State private var automationGranted: Bool? = nil
    @State private var checkingAutomation = false
    @State private var cliInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ghostly")
    @State private var cliInstalling = false
    @State private var cliError: String?

    var body: some View {
        Form {
            Section("CLI Tool") {
                HStack {
                    Image(systemName: cliInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(cliInstalled ? .green : .secondary)
                    Text("ghostly")
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    if cliInstalled {
                        Text("/usr/local/bin/ghostly")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if cliInstalling {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(cliInstalled ? "Reinstall" : "Install") {
                            installCLI()
                        }
                        .font(.caption)
                    }
                }
                if let error = cliError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Text("Installs the `ghostly` command to /usr/local/bin for terminal usage.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Permissions") {
                // Accessibility
                HStack {
                    Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(accessibilityGranted ? .green : .red)
                    Text("Accessibility")
                    Text("— tabs & splits")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !accessibilityGranted {
                        Button("Grant") {
                            openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                }

                // Automation
                HStack {
                    if let granted = automationGranted {
                        Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(granted ? .green : .red)
                    } else {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.secondary)
                    }
                    Text("Automation")
                    Text("— terminal control")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if automationGranted != true {
                        Button("Open Settings") {
                            openAutomationSettings()
                        }
                        .font(.caption)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        refreshPermissions()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                            Text("Refresh")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                }

                if !accessibilityGranted {
                    Text("Note: After granting access in System Settings, you may need to restart Ghostly for it to take effect.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

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
        .frame(width: 420, height: 500)
        .padding()
        .onAppear {
            accessibilityGranted = AXIsProcessTrusted()
            cliInstalled = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ghostly")
            checkAutomationPermission()
        }
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        checkAutomationPermission()
    }

    private func openAccessibilitySettings() {
        // Prompt the system dialog + open settings
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkAutomationPermission() {
        checkingAutomation = true
        // Determine which terminal to test based on preference
        let terminalApp: String
        let pref = PreferredTerminal(rawValue: preferredTerminal) ?? .auto
        switch pref {
        case .iterm2: terminalApp = "iTerm2"
        case .terminal: terminalApp = "Terminal"
        default: terminalApp = "Ghostty"
        }

        // Test automation by sending a harmless AppleScript
        Task.detached {
            let script = "tell application \"System Events\" to name of first process whose name is \"Finder\""
            var errorInfo: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            let result = appleScript?.executeAndReturnError(&errorInfo)
            let granted = result != nil && errorInfo == nil

            await MainActor.run {
                automationGranted = granted
                accessibilityGranted = AXIsProcessTrusted()
                checkingAutomation = false
            }
        }
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

    // MARK: - CLI Installation

    private func installCLI() {
        cliInstalling = true
        cliError = nil

        Task.detached {
            do {
                // Find CLI source files — try app bundle first, then common locations
                let (mainSource, ipcSource) = try findCLISources()

                // Compile to temp location
                let tmpBinary = "/tmp/ghostly-cli-build"
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
                process.arguments = ["-O", "-o", tmpBinary, mainSource, ipcSource]
                let errPipe = Pipe()
                process.standardError = errPipe
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                    throw CLIInstallError.compileFailed(errMsg)
                }

                // Install to /usr/local/bin (may need admin)
                let installDir = "/usr/local/bin"
                let installPath = "\(installDir)/ghostly"

                // Try direct copy first
                let fm = FileManager.default
                if fm.isWritableFile(atPath: installDir) {
                    try? fm.removeItem(atPath: installPath)
                    try fm.copyItem(atPath: tmpBinary, toPath: installPath)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installPath)
                } else {
                    // Use AppleScript to get admin privileges
                    let script = "do shell script \"mkdir -p \(installDir) && cp \(tmpBinary) \(installPath) && chmod 755 \(installPath)\" with administrator privileges"
                    var errorInfo: NSDictionary?
                    let appleScript = NSAppleScript(source: script)
                    appleScript?.executeAndReturnError(&errorInfo)
                    if let errorInfo, let msg = errorInfo[NSAppleScript.errorMessage] as? String {
                        throw CLIInstallError.installFailed(msg)
                    }
                }

                try? fm.removeItem(atPath: tmpBinary)

                await MainActor.run {
                    cliInstalled = true
                    cliInstalling = false
                }
            } catch {
                await MainActor.run {
                    cliError = error.localizedDescription
                    cliInstalling = false
                }
            }
        }
    }

    private enum CLIInstallError: LocalizedError {
        case sourceNotFound
        case compileFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .sourceNotFound:
                return "CLI source files not found in app bundle"
            case .compileFailed(let msg):
                return "Compile failed: \(msg)"
            case .installFailed(let msg):
                return "Install failed: \(msg)"
            }
        }
    }

    private func findCLISources() throws -> (String, String) {
        // Check app bundle Resources
        if let main = Bundle.main.path(forResource: "ghostly-cli-main", ofType: "swift"),
           let ipc = Bundle.main.path(forResource: "ghostly-cli-IPCClient", ofType: "swift") {
            return (main, ipc)
        }

        // Check next to the app bundle (dev builds)
        let appPath = Bundle.main.bundlePath
        let devCandidates = [
            NSString(string: appPath).deletingLastPathComponent + "/../../../ghostly-cli",
            NSString(string: appPath).deletingLastPathComponent + "/../../../../Ghostly/ghostly-cli",
        ]

        for dir in devCandidates {
            let mainPath = dir + "/main.swift"
            let ipcPath = dir + "/IPCClient.swift"
            if FileManager.default.fileExists(atPath: mainPath) && FileManager.default.fileExists(atPath: ipcPath) {
                return (mainPath, ipcPath)
            }
        }

        // Try source checkout paths
        let srcCandidates = [
            NSString(string: "~/Downloads/ghostly/Ghostly/ghostly-cli").expandingTildeInPath,
            NSString(string: "~/src/ghostly/Ghostly/ghostly-cli").expandingTildeInPath,
        ]
        for dir in srcCandidates {
            let mainPath = dir + "/main.swift"
            let ipcPath = dir + "/IPCClient.swift"
            if FileManager.default.fileExists(atPath: mainPath) && FileManager.default.fileExists(atPath: ipcPath) {
                return (mainPath, ipcPath)
            }
        }

        throw CLIInstallError.sourceNotFound
    }
}
