import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level {
        case info, warning, error

        var color: String {
            switch self {
            case .info: return "green"
            case .warning: return "yellow"
            case .error: return "red"
            }
        }
    }
}

@Observable
@MainActor
final class AppLog {
    static let shared = AppLog()

    private(set) var entries: [LogEntry] = []
    private let maxEntries = 200

    private init() {}

    func log(_ message: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
