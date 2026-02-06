import SwiftUI

struct HostRowView: View {
    let host: SSHHost
    let status: ConnectionStatus
    let sessions: [GhostlySession]
    let remoteInfo: RemoteInfo?
    let errorMessage: String?
    @Binding var isExpanded: Bool

    let onConnect: () -> Void
    let onReattach: (GhostlySession) -> Void
    let onNewSession: () -> Void
    let onKillSession: (GhostlySession) -> Void
    let onInstallBackend: () -> Void
    let onToggleManaged: () -> Void
    let onToggleFavorite: () -> Void
    let onShowInfo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Header row: status pill + name + session badge + star + info button
            HStack(spacing: 6) {
                statusIndicator

                Button {
                    if status == .connected {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    } else if status == .disconnected || status == .error || status == .unknown {
                        onConnect()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(host.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if status == .connected {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                }

                Spacer()

                if host.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.yellow)
                }

                if status == .connected {
                    Button {
                        onShowInfo()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Host details")
                }
            }

            // Expandable detail section
            if isExpanded && status == .connected {
                VStack(alignment: .leading, spacing: 4) {
                    // Info chips
                    if let info = remoteInfo {
                        infoChips(info)
                    }

                    // Sessions + New Session button
                    sessionsSection
                }
                .padding(.leading, 14)
            }

            // Error line (always visible)
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.leading, 14)
            }

            // Status-specific message (always visible)
            if status == .reconnecting {
                Text("reconnecting...")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
                    .padding(.leading, 14)
            }

            // Version mismatch warning
            if let info = remoteInfo, info.hasVersionMismatch, status == .connected {
                Text("version mismatch: remote \(info.remoteVersion ?? "?") ≠ \(ghostlyVersion)")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .padding(.leading, 14)
            }

            // Session backend not installed notice (always visible)
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

    // MARK: - Sessions Section

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sessions) { session in
                HStack(spacing: 0) {
                    Button {
                        onReattach(session)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(session.isActive ? Color.green : Color.gray)
                                .frame(width: 5, height: 5)
                            Text(session.name)
                                .font(.system(size: 11))
                            if session.isActive {
                                Text("attached")
                                    .font(.system(size: 9))
                                    .foregroundColor(.green.opacity(0.8))
                            }
                            if let dur = session.durationLabel {
                                Text(dur)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(session.isActive ? Color.green.opacity(0.04) : Color.accentColor.opacity(0.06))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.borderless)
                    .help(session.isActive ? "Attach to \(session.name) (multi-attach)" : "Attach to \(session.name)")

                    // Kill button
                    Button {
                        onKillSession(session)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Kill session \(session.name)")
                    .padding(.leading, 2)
                }
            }

            Button {
                onNewSession()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 8))
                    Text("New Session")
                        .font(.system(size: 10))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Create new session")
        }
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - Info Chips

    @ViewBuilder
    private func infoChips(_ info: RemoteInfo) -> some View {
        let chips = buildChips(info)
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(chips, id: \.label) { chip in
                    infoChip(icon: chip.icon, label: chip.label, color: chip.color)
                }

                if info.hasSessionBackend {
                    backendBadge(info.sessionBackend)
                }
            }
        }
    }

    private func infoChip(icon: String, label: String, color: Color = .secondary) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(label)
                .font(.system(size: 10))
        }
        .foregroundColor(color)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(color.opacity(0.1))
        .cornerRadius(3)
    }

    private func backendBadge(_ backend: SessionBackend) -> some View {
        Text(backend.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(3)
    }

    // MARK: - Chip Data

    private struct ChipData {
        let icon: String
        let label: String
        let color: Color
    }

    private func buildChips(_ info: RemoteInfo) -> [ChipData] {
        var chips: [ChipData] = []

        if let load = info.loadAverage {
            let trimmed = load.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                chips.append(ChipData(icon: "cpu", label: trimmed, color: .secondary))
            }
        }

        if let disk = info.diskUsage {
            let trimmed = disk.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let color = diskColor(trimmed)
                chips.append(ChipData(icon: "externaldrive", label: trimmed, color: color))
            }
        }

        if let jobs = info.slurmJobs, jobs != "N/A", jobs != "0" {
            chips.append(ChipData(icon: "list.bullet", label: "\(jobs) jobs", color: .secondary))
        }

        if let env = info.condaEnv, env != "none", !env.isEmpty {
            chips.append(ChipData(icon: "flask", label: env, color: .secondary))
        }

        return chips
    }

    private func diskColor(_ usage: String) -> Color {
        // Parse percentage from strings like "67%", "50% /home", or "1.2T/2T (60%)"
        // Extract the number immediately before a % sign
        guard let range = usage.range(of: #"\d+%"#, options: .regularExpression),
              let pct = Int(usage[range].dropLast()) else {
            return .secondary
        }
        if pct >= 90 { return .red }
        if pct >= 80 { return .orange }
        return .secondary
    }
}
