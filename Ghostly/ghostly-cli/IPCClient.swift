import Foundation

/// Communicates with the Ghostly menu bar app via Unix domain socket
struct IPCClient {
    static let socketPath = "/tmp/ghostly.sock"

    struct Message: Codable {
        let type: String      // "connect", "disconnect", "session_created"
        let host: String
        let session: String?
        let timestamp: Date

        init(type: String, host: String, session: String? = nil) {
            self.type = type
            self.host = host
            self.session = session
            self.timestamp = Date()
        }
    }

    /// Send a message to the menu bar app (fire and forget)
    static func send(_ message: Message) {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else { return }

        guard let data = try? JSONEncoder().encode(message) else { return }
        let str = String(data: data, encoding: .utf8)! + "\n"
        str.withCString { cstr in
            _ = write(fd, cstr, strlen(cstr))
        }
    }

    static func notifyConnect(host: String, session: String? = nil) {
        send(Message(type: "connect", host: host, session: session))
    }

    static func notifyDisconnect(host: String) {
        send(Message(type: "disconnect", host: host))
    }
}
