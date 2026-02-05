import Foundation

struct GhostlySession: Identifiable, Hashable {
    var id: String { "\(hostAlias):\(name)" }
    let name: String
    let isActive: Bool
    let createdAt: Date?
    let hostAlias: String
    let backend: SessionBackend

    var statusLabel: String {
        let status = isActive ? "attached" : "detached"
        if let created = createdAt {
            let elapsed = Date().timeIntervalSince(created)
            let formatted = Self.formatDuration(elapsed)
            return "\(status), \(formatted)"
        }
        return status
    }

    var backendLabel: String {
        backend.displayName
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}
