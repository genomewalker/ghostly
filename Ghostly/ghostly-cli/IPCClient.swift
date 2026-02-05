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

    /// Send a message to the menu bar app (fire and forget, non-blocking)
    static func send(_ message: Message) {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // Set non-blocking so we never hang on a stale socket
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

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
        // Non-blocking connect returns EINPROGRESS if pending, 0 if immediate
        guard connectResult == 0 || errno == EINPROGRESS else { return }

        // Wait briefly for connection (100ms max)
        if connectResult != 0 {
            var pollFd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pollFd, 1, 100)
            guard ready > 0 else { return }
        }

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
