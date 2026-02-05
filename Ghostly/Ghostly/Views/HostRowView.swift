import SwiftUI

struct HostRowView: View {
    let host: SSHHost
    let status: ConnectionStatus
    let sessions: [GhostlySession]
    let remoteInfo: RemoteInfo?
    let errorMessage: String?

    let onConnect: () -> Void
    let onReattach: (GhostlySession) -> Void
    let onInstallBackend: () -> Void
    let onToggleManaged: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Main row: status icon + name + session count
            HStack(spacing: 6) {
                Image(systemName: status.icon)
                    .foregroundColor(status.color)
                    .font(.system(size: 8))

                Text(host.displayName)
                    .font(.system(size: 13, weight: .medium))

                if !sessions.isEmpty {
                    Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if host.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                }
            }

            // Remote info line (if available)
            if let info = remoteInfo, !info.summary.isEmpty {
                Text(info.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 14)
            }

            // Error line
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.leading, 14)
            }

            // Status-specific message
            if status == .reconnecting {
                Text("reconnecting...")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                    .padding(.leading, 14)
            }

            // Session backend not installed notice
            if let info = remoteInfo, !info.hasSessionBackend, status == .connected {
                HStack(spacing: 4) {
                    Text("no session backend")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Button("Install") {
                        onInstallBackend()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
    }
}
