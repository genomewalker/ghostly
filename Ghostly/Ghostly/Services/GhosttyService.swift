import AppKit
import Foundation
import os

actor GhosttyService {
    private var ghosttyPath: String?
    private let sessionService = SessionService()
    private let logger = Logger(subsystem: "com.ghostly.app", category: "Terminal")

    // MARK: - Terminal Detection

    /// Detect Ghostty binary location
    func detectGhostty() async -> String? {
        if let cached = ghosttyPath { return cached }

        // Check user override first
        let override = UserDefaults.standard.string(forKey: "ghosttyPath") ?? ""
        if !override.isEmpty && FileManager.default.isExecutableFile(atPath: override) {
            ghosttyPath = override
            return override
        }

        let candidates = [
            "/usr/local/bin/ghostty",
            "/opt/homebrew/bin/ghostty",
            "/Applications/Ghostty.app/Contents/MacOS/ghostty",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                ghosttyPath = path
                return path
            }
        }

        do {
            let result = try await ShellCommand.run("which ghostty")
            if result.succeeded && !result.output.isEmpty {
                ghosttyPath = result.output
                return result.output
            }
        } catch {}

        return nil
    }

    /// Detect if iTerm2 is installed
    func detectITerm() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
    }

    /// Resolve which terminal to use based on preference + availability
    func resolveTerminal() async -> PreferredTerminal {
        let pref = PreferredTerminal(
            rawValue: UserDefaults.standard.string(forKey: "preferredTerminal") ?? "auto"
        ) ?? .auto

        guard pref == .auto else { return pref }

        if await detectGhostty() != nil { return .ghostty }
        if detectITerm() { return .iterm2 }
        return .terminal
    }

    // MARK: - Public API

    func connect(host: String, sessionName: String = "default", backend: SessionBackend? = nil, openMode: TerminalOpenMode? = nil) async throws {
        let actualBackend: SessionBackend
        if let backend {
            actualBackend = backend
        } else {
            actualBackend = await sessionService.ensureGhostlySession(on: host)
        }
        let sshCommand = await sessionService.connectCommand(
            host: host,
            sessionName: sessionName,
            backend: actualBackend
        )
        let mode = openMode ?? resolvedDefaultMode()
        try await openTerminal(command: sshCommand, mode: mode)
    }

    func reattach(host: String, sessionName: String, backend: SessionBackend = .ghostly, openMode: TerminalOpenMode? = nil) async throws {
        let sshCommand = await sessionService.reattachCommand(
            host: host,
            sessionName: sessionName,
            backend: backend
        )
        let mode = openMode ?? resolvedDefaultMode()
        try await openTerminal(command: sshCommand, mode: mode)
    }

    func plainSSH(host: String, openMode: TerminalOpenMode? = nil) async throws {
        let mode = openMode ?? resolvedDefaultMode()
        try await openTerminal(command: "ssh \(host)", mode: mode)
    }

    // MARK: - Mode Resolution

    private func resolvedDefaultMode() -> TerminalOpenMode {
        TerminalOpenMode(
            rawValue: UserDefaults.standard.string(forKey: "terminalOpenMode") ?? "window"
        ) ?? .newWindow
    }

    // MARK: - Terminal Dispatch

    private func openTerminal(command: String, mode: TerminalOpenMode) async throws {
        let terminal = await resolveTerminal()
        await AppLog.shared.log("Terminal: \(terminal.rawValue), mode: \(mode.rawValue)")

        switch terminal {
        case .ghostty, .auto:
            try await openInGhostty(command: command, mode: mode)
        case .iterm2:
            try await openInITerm(command: command, mode: mode)
        case .terminal:
            try await openInTerminalApp(command: command, mode: mode)
        }
    }

    // MARK: - Ghostty

    private func openInGhostty(command: String, mode: TerminalOpenMode) async throws {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")

        // If Ghostty is not running, always use new window
        let isRunning = isAppRunning("com.mitchellh.ghostty")

        if !isRunning || mode == .newWindow {
            guard let ghostty = await detectGhostty() else {
                // Fall back to Terminal.app
                try await openInTerminalApp(command: command, mode: mode)
                return
            }
            _ = try await ShellCommand.run("\(ghostty) -e \"\(escaped)\" &", timeout: 5)
            return
        }

        // Ghostty is running — use System Events for tab/split
        switch mode {
        case .newWindow:
            break // handled above
        case .newTab:
            let script = """
            tell application "Ghostty" to activate
            delay 0.2
            tell application "System Events"
                tell process "Ghostty"
                    keystroke "t" using command down
                    delay 0.3
                    keystroke "\(escaped)" & return
                end tell
            end tell
            """
            try await runAppleScript(script)
        case .splitPane:
            // Ghostty uses Cmd+D for vertical split (or Cmd+Shift+D for horizontal)
            let script = """
            tell application "Ghostty" to activate
            delay 0.2
            tell application "System Events"
                tell process "Ghostty"
                    keystroke "d" using command down
                    delay 0.3
                    keystroke "\(escaped)" & return
                end tell
            end tell
            """
            try await runAppleScript(script)
        }
    }

    // MARK: - iTerm2

    private func openInITerm(command: String, mode: TerminalOpenMode) async throws {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")

        switch mode {
        case .newWindow:
            let script = """
            tell application "iTerm2"
                activate
                create window with default profile command "\(escaped)"
            end tell
            """
            try await runAppleScript(script)

        case .newTab:
            let script = """
            tell application "iTerm2"
                activate
                if (count of windows) = 0 then
                    create window with default profile command "\(escaped)"
                else
                    tell current window
                        create tab with default profile command "\(escaped)"
                    end tell
                end if
            end tell
            """
            try await runAppleScript(script)

        case .splitPane:
            let script = """
            tell application "iTerm2"
                activate
                if (count of windows) = 0 then
                    create window with default profile command "\(escaped)"
                else
                    tell current session of current window
                        split vertically with default profile command "\(escaped)"
                    end tell
                end if
            end tell
            """
            try await runAppleScript(script)
        }
    }

    // MARK: - Terminal.app

    private func openInTerminalApp(command: String, mode: TerminalOpenMode) async throws {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")

        switch mode {
        case .newWindow:
            let script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
            try await runAppleScript(script)

        case .newTab:
            let script = """
            tell application "Terminal"
                activate
                tell application "System Events"
                    tell process "Terminal"
                        keystroke "t" using command down
                    end tell
                end tell
                delay 0.3
                do script "\(escaped)" in front window
            end tell
            """
            try await runAppleScript(script)

        case .splitPane:
            // Terminal.app doesn't support splits — fall back to new tab
            logger.info("Terminal.app doesn't support split panes, falling back to new tab")
            try await openInTerminalApp(command: command, mode: .newTab)
        }
    }

    // MARK: - Helpers

    private func runAppleScript(_ source: String) async throws {
        let escaped = source.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await ShellCommand.run("osascript -e '\(escaped)'", timeout: 10)
    }

    private func isAppRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil
    }
}
