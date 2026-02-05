import Foundation

actor RemoteInfoService {
    /// Fetch system info from a remote host.
    /// Uses ghostly-session info if available, otherwise falls back to shell commands.
    func fetchInfo(host: String) async -> RemoteInfo? {
        // Try ghostly-session first (single binary, fast)
        if let info = await fetchViaGhostly(host: host) {
            return info
        }
        // Fallback to shell commands
        return await fetchViaShell(host: host)
    }

    private func fetchViaGhostly(host: String) async -> RemoteInfo? {
        do {
            let result = try await ShellCommand.ssh(
                host: host,
                command: "ghostly-session info 2>/dev/null || ~/.local/bin/ghostly-session info 2>/dev/null",
                timeout: 10
            )
            guard result.succeeded, !result.output.isEmpty else { return nil }
            // ghostly-session info outputs KEY:VALUE lines (plain-text mode)
            return parseInfo(result.output)
        } catch {
            return nil
        }
    }

    private func fetchViaShell(host: String) async -> RemoteInfo? {
        let command = """
        echo "USER:$(whoami)"
        echo "CONDA:${CONDA_DEFAULT_ENV:-none}"
        echo "LOAD:$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}')"
        echo "DISK:$(df -h ~ 2>/dev/null | tail -1 | awk '{print $5}')"
        command -v squeue > /dev/null 2>&1 && echo "JOBS:$(squeue -u $USER -h 2>/dev/null | wc -l | tr -d ' ')" || echo "JOBS:N/A"
        command -v ghostly-session > /dev/null 2>&1 && echo "MUX:ghostly" || (command -v tmux > /dev/null 2>&1 && echo "MUX:tmux" || (command -v screen > /dev/null 2>&1 && echo "MUX:screen" || echo "MUX:none"))
        command -v ghostly-session > /dev/null 2>&1 && echo "SESSIONS:$(ghostly-session list --json 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ')" || (command -v tmux > /dev/null 2>&1 && echo "SESSIONS:$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')" || (command -v screen > /dev/null 2>&1 && echo "SESSIONS:$(screen -ls 2>/dev/null | grep -c 'tached')" || echo "SESSIONS:0"))
        command -v ghostly-session > /dev/null 2>&1 && echo "VERSION:$(ghostly-session version 2>/dev/null | awk '{print $2}')" || echo "VERSION:N/A"
        """

        do {
            let result = try await ShellCommand.ssh(host: host, command: command, timeout: 15)
            guard result.succeeded else { return nil }
            return parseInfo(result.output)
        } catch {
            return nil
        }
    }

    private func parseInfo(_ output: String) -> RemoteInfo {
        var info = RemoteInfo()

        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "USER":
                info.user = value
            case "CONDA":
                info.condaEnv = value
            case "LOAD":
                info.loadAverage = value
            case "DISK":
                info.diskUsage = value
            case "JOBS":
                info.slurmJobs = value
            case "MUX":
                info.sessionBackend = SessionBackend(rawValue: value) ?? .none
            case "SESSIONS":
                info.activeSessions = Int(value) ?? 0
            case "VERSION":
                if value != "N/A" { info.remoteVersion = value }
            default:
                break
            }
        }

        info.lastUpdated = Date()
        return info
    }
}
