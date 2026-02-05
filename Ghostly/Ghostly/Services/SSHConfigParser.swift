import Foundation

actor SSHConfigParser {
    private let configPath: String
    private var fileWatcher: DispatchSourceFileSystemObject?

    init(configPath: String = "~/.ssh/config") {
        self.configPath = NSString(string: configPath).expandingTildeInPath
    }

    func parse() -> [SSHHost] {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return []
        }

        var hosts: [SSHHost] = []
        var current: SSHHost?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Split into key and value
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            if key == "host" {
                // Save previous host
                if let h = current {
                    hosts.append(h)
                }
                // Skip wildcard-only patterns
                if value == "*" || value.contains("*") || value.contains("?") {
                    current = nil
                    continue
                }
                current = SSHHost(alias: value)
            } else if var h = current {
                switch key {
                case "hostname":
                    h.hostName = value
                case "user":
                    h.user = value
                case "port":
                    h.port = Int(value)
                case "identityfile":
                    h.identityFile = NSString(string: value).expandingTildeInPath
                case "proxycommand":
                    h.proxyCommand = value
                case "proxyjump":
                    h.proxyJump = value
                default:
                    break
                }
                current = h
            }
        }

        // Don't forget the last host
        if let h = current {
            hosts.append(h)
        }

        return hosts
    }

    func watchForChanges(onChange: @escaping @Sendable () -> Void) {
        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global()
        )

        source.setEventHandler {
            onChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatcher = source
    }

    func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
    }
}
