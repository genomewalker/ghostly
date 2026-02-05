import AppKit
import Foundation
import os

enum TerminalError: LocalizedError {
    case binaryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let host):
            return "ghostly-session not found on \(host). Run setup first."
        }
    }
}

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

        // Preflight: verify binary exists for ghostly backend
        if actualBackend == .ghostly {
            try await preflightCheck(host: host)
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
        // Preflight: verify binary exists for ghostly backend
        if backend == .ghostly {
            try await preflightCheck(host: host)
        }

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

    // MARK: - Preflight & Mode Resolution

    /// Verify ghostly-session binary exists on remote before opening a terminal
    private func preflightCheck(host: String) async throws {
        do {
            let result = try await ShellCommand.ssh(
                host: host,
                command: "test -x ~/.local/bin/ghostly-session",
                timeout: 10
            )
            if !result.succeeded {
                await AppLog.shared.log("Preflight: ghostly-session not found on \(host)", level: .error)
                throw TerminalError.binaryNotFound(host)
            }
        } catch let error as TerminalError {
            throw error
        } catch {
            // SSH connection failed — let the terminal command show the error
            await AppLog.shared.log("Preflight SSH failed for \(host): \(error)", level: .warning)
        }
    }

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
        guard let ghosttyBin = await detectGhostty() else {
            try await openInTerminalApp(command: command, mode: mode)
            return
        }

        switch mode {
        case .newWindow:
            // Launch ghostty directly with -e — no System Events needed
            try launchGhosttyProcess(ghosttyBin: ghosttyBin, command: command)

        case .newTab, .splitPane:
            // Tabs and splits require System Events keystrokes
            let isRunning = isAppRunning("com.mitchellh.ghostty")
            if !isRunning {
                _ = try await ShellCommand.run("open -a Ghostty", timeout: 10)
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }

            let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
            let modeKeystroke = mode == .newTab
                ? "keystroke \"t\" using command down"
                : "keystroke \"d\" using command down"

            let script = """
            tell application "Ghostty" to activate
            delay 0.3
            tell application "System Events"
                tell process "Ghostty"
                    \(modeKeystroke)
                    delay 0.5
                    keystroke "\(escaped)"
                    keystroke return
                end tell
            end tell
            """
            try await runAppleScript(script)
        }
    }

    /// Launch ghostty with -e flag — command is a flat SSH invocation, no nested quoting
    private func launchGhosttyProcess(ghosttyBin: String, command: String) throws {
        // Single bash -c layer for error visibility (keeps window open on failure)
        let wrappedCommand = "\(command); ret=$?; if [ $ret -ne 0 ]; then echo ''; echo \"[Exit code: $ret] Press Enter to close.\"; read; fi"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghosttyBin)
        process.arguments = ["-e", "/bin/bash", "-c", wrappedCommand]
        // Don't suppress output — let ghostty manage its own terminal
        try process.run()
        // Don't wait — ghostty runs independently
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
        let src = source
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                var errorInfo: NSDictionary?
                let script = NSAppleScript(source: src)
                script?.executeAndReturnError(&errorInfo)
                if let errorInfo = errorInfo,
                   let msg = errorInfo[NSAppleScript.errorMessage] as? String {
                    AppLog.shared.log("AppleScript error: \(msg)", level: .error)
                    continuation.resume(throwing: NSError(domain: "AppleScript", code: -1, userInfo: [NSLocalizedDescriptionKey: msg]))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func isAppRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil
    }
}
