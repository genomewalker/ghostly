import Foundation

/// Session backend detected on the remote host
enum SessionBackend: String, Codable {
    case ghostly
    case tmux
    case screen
    case none

    var displayName: String {
        switch self {
        case .ghostly: return "ghostly-session"
        case .tmux: return "tmux"
        case .screen: return "screen"
        case .none: return "none"
        }
    }
}

/// Manages persistent sessions on remote hosts.
/// Prefers ghostly-session, falls back to tmux or screen.
actor SessionService {
    enum SessionError: Error, LocalizedError {
        case noMultiplexer(String)
        case sessionNotFound(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .noMultiplexer(let host):
                return "No session backend found on \(host)"
            case .sessionNotFound(let name):
                return "Session '\(name)' not found"
            case .installFailed(let msg):
                return "Failed to install ghostly-session: \(msg)"
            }
        }
    }

    /// Embedded C++ source path (in app bundle or from ghostly-session directory)
    private static let cppSourceName = "ghostly-session.cpp"

    /// Detect which session backend is available on a remote host
    func detectBackend(on host: String) async -> SessionBackend {
        do {
            let result = try await ShellCommand.ssh(
                host: host,
                command: "bash -l -c 'command -v ghostly-session >/dev/null 2>&1 && echo ghostly || (command -v tmux >/dev/null 2>&1 && echo tmux || (command -v screen >/dev/null 2>&1 && echo screen || echo none))'"
            )
            if result.output.contains("ghostly") { return .ghostly }
            if result.output.contains("tmux") { return .tmux }
            if result.output.contains("screen") { return .screen }
            return .none
        } catch {
            return .none
        }
    }

    /// Install ghostly-session on a remote host.
    /// Tries curl-based installer from GitHub first, falls back to uploading source via SSH.
    func installGhostlySession(on host: String) async throws {
        // Try the quick curl installer first
        let curlInstall = """
        FETCH=""; command -v curl >/dev/null 2>&1 && FETCH="curl -fsSL" || { command -v wget >/dev/null 2>&1 && FETCH="wget -qO-"; }
        if [ -n "$FETCH" ]; then
            $FETCH https://raw.githubusercontent.com/genomewalker/ghostly/main/install.sh | bash 2>&1
            command -v ghostly-session >/dev/null 2>&1 && echo "GHOSTLY_INSTALLED" && exit 0
            [ -x "$HOME/.local/bin/ghostly-session" ] && echo "GHOSTLY_INSTALLED" && exit 0
        fi
        echo "CURL_FAILED"
        """

        let curlResult = try await ShellCommand.ssh(host: host, command: curlInstall, timeout: 90)
        if curlResult.output.contains("GHOSTLY_INSTALLED") {
            return
        }

        // Fallback: upload source directly via SSH heredoc
        let compileScript = """
        mkdir -p ~/.local/bin && cd /tmp && cat > ghostly-session.cpp << 'GHOSTLY_EOF'
        """

        let cppSource = try loadCppSource()

        let fullScript = compileScript + cppSource + """

        GHOSTLY_EOF
        CXX=$(command -v g++ || command -v clang++ || echo "")
        if [ -z "$CXX" ]; then echo "NO_COMPILER"; exit 1; fi
        LDFLAGS=""
        case "$(uname -s)" in Linux) LDFLAGS="-lutil" ;; esac
        $CXX -O2 -std=c++11 -o /tmp/ghostly-session /tmp/ghostly-session.cpp $LDFLAGS 2>&1
        if [ $? -ne 0 ]; then echo "COMPILE_FAILED"; exit 1; fi
        mv /tmp/ghostly-session ~/.local/bin/ghostly-session
        chmod 755 ~/.local/bin/ghostly-session
        rm -f /tmp/ghostly-session.cpp
        grep -q 'local/bin' ~/.bashrc 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
        echo "GHOSTLY_INSTALLED"
        """

        let result = try await ShellCommand.ssh(host: host, command: fullScript, timeout: 60)
        if !result.output.contains("GHOSTLY_INSTALLED") {
            let detail = result.output.isEmpty ? result.errorOutput : result.output
            throw SessionError.installFailed(detail)
        }
    }

    /// Load the C++ source for remote compilation
    private func loadCppSource() throws -> String {
        // Try app bundle first
        if let bundlePath = Bundle.main.path(forResource: "ghostly-session", ofType: "cpp") {
            return try String(contentsOfFile: bundlePath, encoding: .utf8)
        }
        // Try relative to executable (for CLI tool)
        let execDir = ProcessInfo.processInfo.arguments[0]
        let candidates = [
            NSString(string: execDir).deletingLastPathComponent + "/../ghostly-session/ghostly-session.cpp",
            NSString(string: "~/.local/share/ghostly/ghostly-session.cpp").expandingTildeInPath,
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return try String(contentsOfFile: path, encoding: .utf8)
            }
        }
        throw SessionError.installFailed("Cannot find ghostly-session.cpp source")
    }

    /// Ensure ghostly-session is available, auto-installing if needed
    func ensureGhostlySession(on host: String) async -> SessionBackend {
        let backend = await detectBackend(on: host)
        if backend == .ghostly { return .ghostly }

        // Try auto-install
        do {
            try await installGhostlySession(on: host)
            return .ghostly
        } catch {
            // Fall back to whatever is available
            return backend
        }
    }

    /// List active sessions on a remote host
    func listSessions(on host: String, backend: SessionBackend? = nil) async -> [GhostlySession] {
        let actualBackend: SessionBackend
        if let backend {
            actualBackend = backend
        } else {
            actualBackend = await detectBackend(on: host)
        }

        switch actualBackend {
        case .ghostly:
            return await listGhostlySessions(on: host)
        case .tmux:
            return await listTmuxSessions(on: host)
        case .screen:
            return await listScreenSessions(on: host)
        case .none:
            return []
        }
    }

    // MARK: - ghostly-session

    private func listGhostlySessions(on host: String) async -> [GhostlySession] {
        do {
            let result = try await ShellCommand.ssh(
                host: host,
                command: "bash -l -c 'ghostly-session list --json' 2>/dev/null"
            )
            guard result.succeeded else { return [] }
            return parseGhostlySessions(result.output, hostAlias: host)
        } catch {
            return []
        }
    }

    private func parseGhostlySessions(_ output: String, hostAlias: String) -> [GhostlySession] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [[String: Any]]
        else { return [] }

        return sessions.compactMap { s in
            guard let name = s["name"] as? String else { return nil }
            let clients = s["clients"] as? Int ?? 0
            let created: Date?
            if let epoch = s["created"] as? TimeInterval, epoch > 0 {
                created = Date(timeIntervalSince1970: epoch)
            } else {
                created = nil
            }
            return GhostlySession(
                name: name,
                isActive: clients > 0,
                createdAt: created,
                hostAlias: hostAlias,
                backend: .ghostly
            )
        }
    }

    /// Explicit path in single quotes — prevents local ~ expansion, remote shell expands it
    func ghostlyConnectCommand(host: String, sessionName: String = "default") -> String {
        "ssh -t \(host) '~/.local/bin/ghostly-session open \(sessionName)'"
    }

    func ghostlyReattachCommand(host: String, sessionName: String) -> String {
        // Use 'open' instead of 'attach' — open creates-or-attaches, more resilient if session disappeared
        "ssh -t \(host) '~/.local/bin/ghostly-session open \(sessionName)'"
    }

    /// Kill a ghostly session
    func killGhostlySession(on host: String, sessionName: String) async throws {
        _ = try await ShellCommand.ssh(
            host: host,
            command: "~/.local/bin/ghostly-session kill \(sessionName) 2>/dev/null"
        )
    }

    // MARK: - tmux

    private func listTmuxSessions(on host: String) async -> [GhostlySession] {
        do {
            let result = try await ShellCommand.ssh(
                host: host,
                command: "tmux list-sessions -F '#{session_name}:#{session_attached}:#{session_created}' 2>/dev/null || true"
            )
            guard result.succeeded else { return [] }
            return parseTmuxSessions(result.output, hostAlias: host)
        } catch {
            return []
        }
    }

    private func parseTmuxSessions(_ output: String, hostAlias: String) -> [GhostlySession] {
        output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let parts = trimmed.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return nil }

            let name = parts[0]
            let attached = parts[1] != "0"
            var created: Date?
            if parts.count >= 3, let epoch = TimeInterval(parts[2]) {
                created = Date(timeIntervalSince1970: epoch)
            }

            return GhostlySession(
                name: name,
                isActive: attached,
                createdAt: created,
                hostAlias: hostAlias,
                backend: .tmux
            )
        }
    }

    func tmuxConnectCommand(host: String, sessionName: String = "default") -> String {
        "ssh -t \(host) 'tmux new-session -A -s \(sessionName)'"
    }

    func tmuxReattachCommand(host: String, sessionName: String) -> String {
        "ssh -t \(host) 'tmux attach-session -t \(sessionName)'"
    }

    // MARK: - screen

    private func listScreenSessions(on host: String) async -> [GhostlySession] {
        do {
            let result = try await ShellCommand.ssh(
                host: host,
                command: "screen -ls 2>/dev/null || true"
            )
            guard result.succeeded else { return [] }
            return parseScreenSessions(result.output, hostAlias: host)
        } catch {
            return []
        }
    }

    private func parseScreenSessions(_ output: String, hostAlias: String) -> [GhostlySession] {
        output.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("."),
                  (trimmed.contains("Detached") || trimmed.contains("Attached"))
            else { return nil }

            let parts = trimmed.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = parts.first else { return nil }

            let dotParts = first.split(separator: ".", maxSplits: 1).map(String.init)
            let name = dotParts.count >= 2 ? dotParts[1] : first
            let isAttached = trimmed.contains("Attached")

            return GhostlySession(
                name: name,
                isActive: isAttached,
                createdAt: nil,
                hostAlias: hostAlias,
                backend: .screen
            )
        }
    }

    func screenConnectCommand(host: String, sessionName: String = "default") -> String {
        "ssh -t \(host) 'screen -RD -S \(sessionName)'"
    }

    func screenReattachCommand(host: String, sessionName: String) -> String {
        "ssh -t \(host) 'screen -r \(sessionName)'"
    }

    // MARK: - Unified interface

    func connectCommand(host: String, sessionName: String = "default", backend: SessionBackend) -> String {
        switch backend {
        case .ghostly:
            return ghostlyConnectCommand(host: host, sessionName: sessionName)
        case .tmux:
            return tmuxConnectCommand(host: host, sessionName: sessionName)
        case .screen:
            return screenConnectCommand(host: host, sessionName: sessionName)
        case .none:
            return "ssh \(host)"
        }
    }

    func reattachCommand(host: String, sessionName: String, backend: SessionBackend) -> String {
        switch backend {
        case .ghostly:
            return ghostlyReattachCommand(host: host, sessionName: sessionName)
        case .tmux:
            return tmuxReattachCommand(host: host, sessionName: sessionName)
        case .screen:
            return screenReattachCommand(host: host, sessionName: sessionName)
        case .none:
            return "ssh \(host)"
        }
    }
}
