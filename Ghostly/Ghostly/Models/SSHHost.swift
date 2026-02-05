import Foundation

struct SSHHost: Identifiable, Codable, Hashable {
    let id: String
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyCommand: String?
    var proxyJump: String?

    // User-configurable
    var isManaged: Bool = false
    var isFavorite: Bool = false
    var group: String?

    var displayName: String {
        alias
    }

    var effectiveHostName: String {
        hostName ?? alias
    }

    var effectiveUser: String {
        user ?? NSUserName()
    }

    var effectivePort: Int {
        port ?? 22
    }

    var sshTarget: String {
        // Use alias so ssh picks up the full config
        alias
    }

    init(alias: String) {
        self.id = alias
        self.alias = alias
    }

    // Infer group from naming pattern (e.g., "dandy-08" → "dandy")
    var inferredGroup: String? {
        let parts = alias.split(separator: "-")
        if parts.count >= 2 {
            return String(parts.first!)
        }
        return nil
    }
}
