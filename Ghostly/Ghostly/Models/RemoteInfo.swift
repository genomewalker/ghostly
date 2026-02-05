import Foundation

struct RemoteInfo {
    var user: String?
    var condaEnv: String?
    var loadAverage: String?
    var diskUsage: String?
    var slurmJobs: String?
    var activeSessions: Int?
    var sessionBackend: SessionBackend = .none
    var lastUpdated: Date = Date()

    var hasSessionBackend: Bool {
        sessionBackend != .none
    }

    var summary: String {
        var parts: [String] = []
        if let env = condaEnv, env != "none" { parts.append(env) }
        if let jobs = slurmJobs, jobs != "N/A", jobs != "0" { parts.append("\(jobs) jobs") }
        if let load = loadAverage { parts.append("load \(load.trimmingCharacters(in: .whitespaces))") }
        return parts.isEmpty ? "" : parts.joined(separator: " | ")
    }

    var isStale: Bool {
        Date().timeIntervalSince(lastUpdated) > 120
    }
}
