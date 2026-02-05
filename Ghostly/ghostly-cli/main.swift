import Foundation

// Minimal CLI without ArgumentParser dependency
// Usage: ghostly <command> [args]

let ghostlyVersion = "1.2.0"
let args = CommandLine.arguments
let verbose = args.contains("-v") || args.contains("--verbose")
let startTime = Date()

func vlog(_ msg: String) {
    guard verbose else { return }
    let elapsed = String(format: "%.3f", Date().timeIntervalSince(startTime))
    FileHandle.standardError.write("[\(elapsed)s] \(msg)\n".data(using: .utf8)!)
}

func printUsage() {
    let usage = """
    Ghostly CLI - SSH + ghostly-session connection manager

    Usage:
      ghostly connect <host> [-s session]    Connect to host (creates/attaches session)
      ghostly attach <host> <session>        Reattach to existing session
      ghostly ssh <host>                     Plain SSH (no session multiplexer)
      ghostly list                           List all SSH hosts from config
      ghostly sessions [host]                List sessions (all hosts if none specified)
      ghostly status                         Show connection status
      ghostly setup <host>                   Install ghostly-session on remote host
      ghostly version                        Show version info
      ghostly completions [bash|zsh]         Generate shell completions

    Options:
      -s, --session <name>    Session name (default: "default")
      -v, --verbose           Show timing debug info
      -h, --help              Show this help

    Examples:
      ghostly connect myhost
      ghostly connect myhost -s coding
      ghostly attach myhost coding
      ghostly attach myhost coding -v
      ghostly sessions myhost
      ghostly sessions
    """
    print(usage)
}

func parseSSHConfig() -> [(alias: String, hostname: String?)] {
    let path = NSString(string: "~/.ssh/config").expandingTildeInPath
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        return []
    }

    var hosts: [(String, String?)] = []
    var currentAlias: String?
    var currentHostname: String?

    for line in content.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }

        if parts[0].lowercased() == "host" {
            if let alias = currentAlias {
                hosts.append((alias, currentHostname))
            }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.contains("*") || value.contains("?") {
                currentAlias = nil
                currentHostname = nil
            } else {
                currentAlias = value
                currentHostname = nil
            }
        } else if parts[0].lowercased() == "hostname", currentAlias != nil {
            currentHostname = parts[1].trimmingCharacters(in: .whitespaces)
        }
    }
    if let alias = currentAlias {
        hosts.append((alias, currentHostname))
    }
    return hosts
}

@discardableResult
func shell(_ command: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

func shellOutput(_ command: String) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Find the ghostly-session.cpp source file for remote installation
func findCppSource() -> String? {
    let execPath = CommandLine.arguments[0]
    let candidates = [
        NSString(string: execPath).deletingLastPathComponent + "/../ghostly-session/ghostly-session.cpp",
        NSString(string: "~/.local/share/ghostly/ghostly-session.cpp").expandingTildeInPath,
        "./ghostly-session/ghostly-session.cpp",
    ]
    for path in candidates {
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
    }
    // Check app bundle
    if let bundlePath = Bundle.main.path(forResource: "ghostly-session", ofType: "cpp") {
        return bundlePath
    }
    return nil
}

// MARK: - Commands

guard args.count >= 2 else {
    printUsage()
    exit(0)
}

let command = args[1]

switch command {
case "connect":
    guard args.count >= 3 else {
        print("Error: specify a host")
        exit(1)
    }
    let host = args[2]
    var sessionName = "default"

    // Parse -s/--session flag
    if let idx = args.firstIndex(where: { $0 == "-s" || $0 == "--session" }),
       idx + 1 < args.count {
        sessionName = args[idx + 1]
    }

    print("Connecting to \(host) (session: \(sessionName))...")

    // Version check — warn if remote ghostly-session version differs
    if let remoteVersion = shellOutput("ssh -o ConnectTimeout=5 -o BatchMode=yes \(host) '~/.local/bin/ghostly-session version 2>/dev/null'") {
        let remote = remoteVersion.replacingOccurrences(of: "ghostly-session ", with: "")
        if remote != ghostlyVersion {
            print("Warning: version mismatch — CLI \(ghostlyVersion), remote \(remote)")
        }
        vlog("Remote version: \(remote)")
    }

    vlog("Sending IPC notification...")
    IPCClient.notifyConnect(host: host, session: sessionName)
    vlog("IPC done. Starting SSH...")
    let sshVerbose = verbose ? "-v" : ""
    let sshCmd = "ssh -t \(sshVerbose) \(host) '~/.local/bin/ghostly-session open \(sessionName)'"
    vlog("Command: \(sshCmd)")
    let status = shell(sshCmd)
    IPCClient.notifyDisconnect(host: host)
    exit(status)

case "attach":
    guard args.count >= 4 else {
        print("Usage: ghostly attach <host> <session>")
        exit(1)
    }
    let host = args[2]
    let session = args[3]

    print("Reattaching to \(host):\(session)...")

    // Version check
    if let remoteVersion = shellOutput("ssh -o ConnectTimeout=5 -o BatchMode=yes \(host) '~/.local/bin/ghostly-session version 2>/dev/null'") {
        let remote = remoteVersion.replacingOccurrences(of: "ghostly-session ", with: "")
        if remote != ghostlyVersion {
            print("Warning: version mismatch — CLI \(ghostlyVersion), remote \(remote)")
        }
    }

    vlog("Sending IPC notification...")
    IPCClient.notifyConnect(host: host, session: session)
    vlog("IPC done. Starting SSH...")
    let sshVerbose = verbose ? "-v" : ""
    let sshCmd = "ssh -t \(sshVerbose) \(host) '~/.local/bin/ghostly-session open \(session)'"
    vlog("Command: \(sshCmd)")
    let status = shell(sshCmd)
    IPCClient.notifyDisconnect(host: host)
    exit(status)

case "ssh":
    guard args.count >= 3 else {
        print("Error: specify a host")
        exit(1)
    }
    let host = args[2]
    IPCClient.notifyConnect(host: host)
    let sshVerbose = verbose ? "-v" : ""
    let status = shell("ssh \(sshVerbose) \(host)")
    IPCClient.notifyDisconnect(host: host)
    exit(status)

case "list":
    let hosts = parseSSHConfig()
    if hosts.isEmpty {
        print("No hosts found in ~/.ssh/config")
    } else {
        print("SSH Hosts (\(hosts.count)):")
        for (alias, hostname) in hosts {
            if let hn = hostname {
                print("  \(alias) → \(hn)")
            } else {
                print("  \(alias)")
            }
        }
    }

case "sessions":
    if args.count >= 3 {
        // Single host
        let host = args[2]
        print("Sessions on \(host):")
        let status = shell("ssh \(host) '~/.local/bin/ghostly-session list 2>/dev/null || echo ghostly-session not installed'")
        exit(status)
    } else {
        // All managed hosts — check each SSH host for sessions
        let hosts = parseSSHConfig()
        if hosts.isEmpty {
            print("No hosts in ~/.ssh/config")
            exit(0)
        }
        print("Scanning \(hosts.count) hosts for active sessions...\n")
        var foundAny = false
        for (alias, _) in hosts {
            if let output = shellOutput("ssh -o ConnectTimeout=5 -o BatchMode=yes \(alias) '~/.local/bin/ghostly-session list' 2>/dev/null") {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.contains("not installed") {
                    print("\(alias):")
                    for line in trimmed.components(separatedBy: .newlines) {
                        print("  \(line)")
                    }
                    print()
                    foundAny = true
                }
            }
        }
        if !foundAny {
            print("No active sessions found on any host.")
        }
        exit(0)
    }

case "status":
    let hosts = parseSSHConfig()
    print("Ghostly Status")
    print("──────────────")
    print("SSH config: \(hosts.count) hosts")

    // Check if menu bar app is running
    if let _ = shellOutput("pgrep -f Ghostly.app") {
        print("Menu bar app: running")
    } else {
        print("Menu bar app: not running")
    }

    // Check network
    if let output = shellOutput("networksetup -getinfo Wi-Fi 2>/dev/null | head -1") {
        print("Network: \(output)")
    }

case "setup":
    guard args.count >= 3 else {
        print("Error: specify a host")
        exit(1)
    }
    let host = args[2]
    print("Installing ghostly-session on \(host)...")

    // Check if already installed
    if let _ = shellOutput("ssh \(host) 'test -x ~/.local/bin/ghostly-session && echo found' 2>/dev/null") {
        print("ghostly-session is already installed on \(host)")
        exit(0)
    }

    // Find the C++ source
    guard let sourcePath = findCppSource() else {
        print("Error: cannot find ghostly-session.cpp source file")
        print("Expected locations:")
        print("  ./ghostly-session/ghostly-session.cpp")
        print("  ~/.local/share/ghostly/ghostly-session.cpp")
        exit(1)
    }

    print("Compiling ghostly-session from source on \(host)...")

    // Upload source and compile remotely
    let scpStatus = shell("scp -q '\(sourcePath)' \(host):/tmp/ghostly-session.cpp")
    if scpStatus != 0 {
        print("Failed to upload source to \(host)")
        exit(1)
    }

    let compileStatus = shell("""
    ssh \(host) 'mkdir -p ~/.local/bin && \
    CXX=$(command -v g++ || command -v clang++ || echo "") && \
    if [ -z "$CXX" ]; then echo "No C++ compiler found"; exit 1; fi && \
    LDFLAGS="" && case "$(uname -s)" in Linux) LDFLAGS="-lutil" ;; esac && \
    $CXX -O2 -std=c++11 -o ~/.local/bin/ghostly-session /tmp/ghostly-session.cpp $LDFLAGS && \
    chmod 755 ~/.local/bin/ghostly-session && \
    rm -f /tmp/ghostly-session.cpp && \
    grep -q "local/bin" ~/.bashrc 2>/dev/null || echo "export PATH=\\"\\$HOME/.local/bin:\\$PATH\\"" >> ~/.bashrc && \
    echo "ghostly-session installed successfully"'
    """)

    if compileStatus == 0 {
        print("ghostly-session compiled and installed to ~/.local/bin/ on \(host)")
    } else {
        print("Failed to install ghostly-session. Ensure g++ or clang++ is available on \(host)")
        exit(1)
    }

case "version", "--version":
    print("ghostly \(ghostlyVersion)")

case "-h", "--help", "help":
    printUsage()

case "completions":
    // Shell completion generation
    let shellType = args.count >= 3 ? args[2] : "bash"
    let hosts = parseSSHConfig().map(\.0)
    let hostList = hosts.joined(separator: " ")

    if shellType == "bash" {
        print("""
        _ghostly() {
            local cur prev commands
            COMPREPLY=()
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"
            commands="connect attach ssh list sessions status setup help"

            case "$prev" in
                ghostly)
                    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
                    ;;
                connect|attach|ssh|sessions|setup)
                    COMPREPLY=( $(compgen -W "\(hostList)" -- "$cur") )
                    ;;
            esac
        }
        complete -F _ghostly ghostly
        """)
    } else if shellType == "zsh" {
        print("""
        #compdef ghostly
        _ghostly() {
            local -a commands hosts
            commands=(connect attach ssh list sessions status setup help)
            hosts=(\(hostList))

            _arguments '1:command:($commands)' '2:host:($hosts)'
        }
        compdef _ghostly ghostly
        """)
    }

default:
    print("Unknown command: \(command)")
    printUsage()
    exit(1)
}
