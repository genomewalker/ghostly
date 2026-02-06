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
        // Try to focus existing terminal window first (only for default/window mode)
        let mode = openMode ?? resolvedDefaultMode()
        if mode == .newWindow {
            let terminal = await resolveTerminal()
            if await focusExistingTerminal(host: host, terminal: terminal) {
                await AppLog.shared.log("Focused existing terminal for \(host)")
                return
            }
        }

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
        try await openTerminal(command: sshCommand, mode: mode)
    }

    func reattach(host: String, sessionName: String, backend: SessionBackend = .ghostly, openMode: TerminalOpenMode? = nil) async throws {
        // Try to focus existing terminal window (only for default/window mode — tabs and splits should always open new)
        let mode = openMode ?? resolvedDefaultMode()
        if mode == .newWindow {
            let terminal = await resolveTerminal()
            if await focusExistingTerminal(host: host, terminal: terminal) {
                await AppLog.shared.log("Focused existing terminal for \(host)")
                return
            }
        }

        // Preflight: verify binary exists for ghostly backend
        if backend == .ghostly {
            try await preflightCheck(host: host)
        }

        let sshCommand = await sessionService.reattachCommand(
            host: host,
            sessionName: sessionName,
            backend: backend
        )
        try await openTerminal(command: sshCommand, mode: mode)
    }

    func plainSSH(host: String, openMode: TerminalOpenMode? = nil) async throws {
        let mode = openMode ?? resolvedDefaultMode()
        try await openTerminal(command: "ssh \(host)", mode: mode)
    }

    /// Connect multiple hosts in a tiled Ghostty layout.
    /// Layout: 2→side by side, 3→2+1, 4→2×2, 5→3+2, etc.
    func connectTiled(hosts: [(host: String, sessionName: String, backend: SessionBackend)]) async throws {
        var commands: [String] = []
        for h in hosts {
            let cmd = await sessionService.connectCommand(
                host: h.host, sessionName: h.sessionName, backend: h.backend
            )
            commands.append(cmd)
        }
        try await openTiled(commands: commands)
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

        let isRunning = isAppRunning("com.mitchellh.ghostty")

        // If Ghostty isn't running yet, launch it with the command directly.
        // This is the only time we use `open -a` — subsequent windows/tabs/splits
        // all use CGEvent to keep everything in the SAME Ghostty process.
        if !isRunning {
            try launchGhosttyProcess(ghosttyBin: ghosttyBin, command: command)
            return
        }

        // Ghostty is running — use CGEvent keystroke injection for ALL modes.
        // This ensures all windows/tabs/splits stay in the same process,
        // so splits always go to the window the user was focused on.
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            await AppLog.shared.log("Accessibility required — opening in new process as fallback", level: .warning)
            try launchGhosttyProcess(ghosttyBin: ghosttyBin, command: command)
            return
        }

        guard let ghosttyApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.mitchellh.ghostty"
        ).first else {
            try launchGhosttyProcess(ghosttyBin: ghosttyBin, command: command)
            return
        }

        // Key codes: N=0x2D, T=0x11, D=0x02
        let keyCode: CGKeyCode
        switch mode {
        case .newWindow: keyCode = 0x2D  // Cmd+N
        case .newTab:    keyCode = 0x11  // Cmd+T
        case .splitPane: keyCode = 0x02  // Cmd+D
        }

        do {
            try await injectIntoGhostty(
                app: ghosttyApp,
                command: command,
                keyCode: keyCode,
                shift: false
            )
        } catch {
            await AppLog.shared.log("Keystroke injection failed: \(error.localizedDescription)", level: .warning)
            try launchGhosttyProcess(ghosttyBin: ghosttyBin, command: command)
        }
    }

    // MARK: - Tiled Layout

    /// Open N commands in a tiled Ghostty window.
    /// Layout: 1→window, 2→[A|B], 3→[A|B / C], 4→[A|B / C|D], 5→[A|B|C / D|E], etc.
    /// Top row gets ceil(N/2) panes, bottom row gets floor(N/2).
    private func openTiled(commands: [String]) async throws {
        guard !commands.isEmpty else { return }
        guard let ghosttyBin = await detectGhostty() else { return }

        if commands.count == 1 {
            try await openTerminal(command: commands[0], mode: .newWindow)
            return
        }

        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            await AppLog.shared.log("Accessibility required for tiled layout", level: .warning)
            // Fall back: open each in a separate window
            for cmd in commands {
                try launchGhosttyProcess(ghosttyBin: ghosttyBin, command: cmd)
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            return
        }

        let n = commands.count
        let topCount = (n + 1) / 2   // ceil(n/2)

        let isRunning = isAppRunning("com.mitchellh.ghostty")

        // Always open a NEW window for tiling — don't disturb existing windows.
        if isRunning {
            // Ghostty running — activate it, Cmd+N for new window, paste first command
            guard let ghosttyApp = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.mitchellh.ghostty"
            ).first else { return }

            await MainActor.run {
                NSApp.deactivate()
                ghosttyApp.activate()
            }
            try await Task.sleep(nanoseconds: 500_000_000)

            // Cmd+N for new window — wait longer for it to fully appear
            postKey(0x2D, flags: .maskCommand)
            try await Task.sleep(nanoseconds: 1_500_000_000)

            // Paste first command into the new window
            await clipboardPaste(command: commands[0])
        } else {
            // Ghostty not running — launch with first command
            try launchGhosttyProcess(ghosttyBin: ghosttyBin, command: commands[0])
            try await Task.sleep(nanoseconds: 2_000_000_000)

            guard let ghosttyApp = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.mitchellh.ghostty"
            ).first else { return }

            await MainActor.run { ghosttyApp.activate() }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // Now split and fill remaining panes
        if n == 2 {
            // Simple: Cmd+D (split right), paste commands[1]
            await clipboardPasteWithKeystroke(keyCode: 0x02, flags: .maskCommand, command: commands[1])
            return
        }

        // 3+ panes: create top/bottom split first
        // Cmd+Shift+D (split down) → focus moves to bottom pane
        await clipboardPasteWithKeystroke(
            keyCode: 0x02, // D
            flags: [.maskCommand, .maskShift],
            command: commands[topCount]
        )

        // Fill remaining bottom panes (left to right)
        for i in (topCount + 1)..<n {
            await clipboardPasteWithKeystroke(keyCode: 0x02, flags: .maskCommand, command: commands[i])
        }

        // Navigate to top-left pane: Alt+K (top)
        postKey(0x28, flags: .maskAlternate) // K
        try await Task.sleep(nanoseconds: 300_000_000)

        // Fill remaining top panes (commands[0] already there)
        for i in 1..<topCount {
            await clipboardPasteWithKeystroke(keyCode: 0x02, flags: .maskCommand, command: commands[i])
        }

        await AppLog.shared.log("Tiled \(n) panes: \(topCount) top + \(n - topCount) bottom")
    }

    /// Paste a command into the current pane via clipboard (Cmd+V + Return).
    private func clipboardPaste(command: String) async {
        let saved = await MainActor.run { () -> String in
            let pb = NSPasteboard.general
            let s = pb.string(forType: .string) ?? ""
            pb.clearContents()
            pb.setString(command, forType: .string)
            return s
        }
        postKey(0x09, flags: .maskCommand) // Cmd+V
        do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
        postKey(0x24, flags: []) // Return
        do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(saved, forType: .string)
        }
    }

    /// Send a keystroke to create a split/tab, then paste a command via clipboard.
    private func clipboardPasteWithKeystroke(keyCode: CGKeyCode, flags: CGEventFlags, command: String) async {
        // Save clipboard
        let saved = await MainActor.run { () -> String in
            let pb = NSPasteboard.general
            let s = pb.string(forType: .string) ?? ""
            pb.clearContents()
            pb.setString(command, forType: .string)
            return s
        }

        // Send split/tab keystroke
        postKey(keyCode, flags: flags)
        do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }

        // Paste + Return
        postKey(0x09, flags: .maskCommand) // Cmd+V
        do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
        postKey(0x24, flags: []) // Return
        do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }

        // Restore clipboard
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(saved, forType: .string)
        }
    }

    /// Launch Ghostty with the given command.
    /// Uses `open -a` (not `-na`) to reuse the existing Ghostty process when possible.
    /// Only used when Ghostty is NOT yet running — all subsequent windows use CGEvent.
    private func launchGhosttyProcess(ghosttyBin: String, command: String) throws {
        let wrappedCommand = "\(command); ret=$?; if [ $ret -ne 0 ]; then echo ''; echo \\\"[Exit code: $ret] Press Enter to close.\\\"; read; fi"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Ghostty", "--args", "-e", "/bin/bash", "-c", wrappedCommand]
        try process.run()
    }

    // MARK: - CGEvent Keystroke Injection (Ghostty tab/split)

    /// Find the topmost Ghostty window using CGWindowList (Z-order).
    /// Returns the PID of the Ghostty process that owns it.
    /// This is the window the user was looking at before clicking the menu bar.
    private func findTopmostGhosttyPID() -> pid_t? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windowList {
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  ownerName == "Ghostty",
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0  // Normal window layer (not menubar, dock, etc.)
            else { continue }
            return pid  // First match = topmost in Z-order
        }
        return nil
    }

    /// Raise a specific Ghostty window using the Accessibility API.
    /// Finds the frontmost window of the process and performs AXRaise.
    private func raiseGhosttyWindow(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let firstWindow = windows.first
        else { return }
        AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, true as CFTypeRef)
    }

    /// Inject a command into the focused Ghostty window via CGEvent keystrokes.
    /// Uses direct HID event posting — no AppleScript, no Automation permission,
    /// just Accessibility. Much more reliable from a menu bar app.
    private func injectIntoGhostty(app: NSRunningApplication, command: String, keyCode: CGKeyCode, shift: Bool) async throws {
        // 1. Find which Ghostty window was topmost BEFORE we steal focus,
        //    then activate that specific process and raise its window.
        let targetPID = findTopmostGhosttyPID()
        let targetApp: NSRunningApplication
        if let pid = targetPID,
           let found = NSRunningApplication.runningApplications(
               withBundleIdentifier: "com.mitchellh.ghostty"
           ).first(where: { $0.processIdentifier == pid }) {
            targetApp = found
        } else {
            targetApp = app
        }

        await MainActor.run {
            NSApp.deactivate()
            targetApp.activate()
        }
        // Raise the specific window via Accessibility API
        if let pid = targetPID {
            raiseGhosttyWindow(pid: pid)
        }
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s for activation

        // 2. Save clipboard, set command
        let savedClip = await MainActor.run { () -> String in
            let pb = NSPasteboard.general
            let saved = pb.string(forType: .string) ?? ""
            pb.clearContents()
            pb.setString(command, forType: .string)
            return saved
        }

        // 3. Send Cmd+<key> (Cmd+D for split, Cmd+T for tab)
        var flags: CGEventFlags = .maskCommand
        if shift { flags.insert(.maskShift) }
        postKey(keyCode, flags: flags)
        try await Task.sleep(nanoseconds: 800_000_000) // 0.8s for split/tab to appear

        // 4. Paste (Cmd+V) + Return
        postKey(0x09, flags: .maskCommand) // V
        try await Task.sleep(nanoseconds: 150_000_000)
        postKey(0x24, flags: []) // Return
        try await Task.sleep(nanoseconds: 100_000_000)

        // 5. Restore clipboard
        try await Task.sleep(nanoseconds: 400_000_000)
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(savedClip, forType: .string)
        }
    }

    /// Post a single key event (down + up) to the HID event tap.
    /// Key codes: D=0x02, T=0x11, V=0x09, Return=0x24
    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    // MARK: - iTerm2

    private func openInITerm(command: String, mode: TerminalOpenMode) async throws {
        // Fall back to Terminal.app if iTerm2 is not installed
        guard detectITerm() else {
            await AppLog.shared.log("iTerm2 not found, falling back to Terminal.app", level: .warning)
            try await openInTerminalApp(command: command, mode: mode)
            return
        }

        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

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
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

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

    private func runAppleScriptReturningBool(_ source: String) async -> Bool {
        let src = source
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                var errorInfo: NSDictionary?
                let script = NSAppleScript(source: src)
                let result = script?.executeAndReturnError(&errorInfo)
                if errorInfo != nil || result == nil {
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: result!.booleanValue)
                }
            }
        }
    }

    // MARK: - Focus Existing Terminal Window

    private func focusExistingTerminal(host: String, terminal: PreferredTerminal) async -> Bool {
        let escaped = host.replacingOccurrences(of: "\"", with: "\\\"")
        switch terminal {
        case .ghostty, .auto:
            return await focusGhosttyWindow(host: escaped)
        case .iterm2:
            return await focusITermWindow(host: escaped)
        case .terminal:
            return await focusTerminalAppWindow(host: escaped)
        }
    }

    private func focusGhosttyWindow(host: String) async -> Bool {
        guard isAppRunning("com.mitchellh.ghostty") else { return false }
        let script = """
        tell application "System Events"
            tell process "Ghostty"
                repeat with w in every window
                    if name of w contains "\(host)" then
                        perform action "AXRaise" of w
                        set frontmost to true
                        return true
                    end if
                end repeat
            end tell
        end tell
        return false
        """
        return await runAppleScriptReturningBool(script)
    }

    private func focusITermWindow(host: String) async -> Bool {
        guard isAppRunning("com.googlecode.iterm2") else { return false }
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if name of s contains "\(host)" then
                            select t
                            tell w to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
        return await runAppleScriptReturningBool(script)
    }

    private func focusTerminalAppWindow(host: String) async -> Bool {
        guard isAppRunning("com.apple.Terminal") else { return false }
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if name of t contains "\(host)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
        return await runAppleScriptReturningBool(script)
    }

    private func isAppRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil
    }
}
