import SwiftUI

enum ConnectionStatus: String, Codable {
    case connected
    case disconnected
    case reconnecting
    case error
    case unknown

    var color: Color {
        switch self {
        case .connected: return .green
        case .disconnected: return .red
        case .reconnecting: return .yellow
        case .error: return .red
        case .unknown: return .gray
        }
    }

    var icon: String {
        switch self {
        case .connected: return "circle.fill"
        case .disconnected: return "circle.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.circle.fill"
        case .unknown: return "circle"
        }
    }

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .disconnected: return "Offline"
        case .reconnecting: return "Reconnecting..."
        case .error: return "Error"
        case .unknown: return "Unknown"
        }
    }
}
