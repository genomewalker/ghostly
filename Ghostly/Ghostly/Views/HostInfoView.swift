import SwiftUI
import AppKit

// MARK: - Host Info Window Controller

@MainActor
final class HostInfoWindowController {
    static let shared = HostInfoWindowController()
    private var window: NSWindow?
    private var hostingController: NSHostingController<HostInfoView>?

    func show(host: SSHHost, info: RemoteInfo?, sessions: [GhostlySession], status: ConnectionStatus) {
        let view = HostInfoView(host: host, info: info, sessions: sessions, status: status)

        if let window, window.isVisible, let hostingController {
            hostingController.rootView = view
            window.title = "\(host.displayName) — Info"
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hc = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hc)
        window.title = "\(host.displayName) — Info"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 400, height: 350))
        window.minSize = NSSize(width: 320, height: 250)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        self.window = window
        self.hostingController = hc

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Host Info View

struct HostInfoView: View {
    let host: SSHHost
    let info: RemoteInfo?
    let sessions: [GhostlySession]
    let status: ConnectionStatus

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text(status.label)
                            .foregroundColor(status.color)
                    }
                }

                if let info, info.hasSessionBackend {
                    LabeledContent("Backend") {
                        Text(info.sessionBackend.rawValue)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                if let info, let remoteVer = info.remoteVersion {
                    LabeledContent("Remote version") {
                        HStack(spacing: 4) {
                            Text(remoteVer)
                                .font(.system(.body, design: .monospaced))
                            if info.hasVersionMismatch {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                            }
                        }
                    }
                    if info.hasVersionMismatch {
                        Text("Version mismatch: app \(ghostlyVersion), remote \(remoteVer). Run setup to update.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                LabeledContent("Host alias") {
                    Text(host.alias)
                        .font(.system(.body, design: .monospaced))
                }

                if let hostname = host.hostName {
                    LabeledContent("Hostname") {
                        Text(hostname)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                if let user = host.user {
                    LabeledContent("User") {
                        Text(user)
                    }
                }

                LabeledContent("Port") {
                    Text("\(host.effectivePort)")
                }
            }

            if let info {
                Section("System") {
                    if let load = info.loadAverage, !load.trimmingCharacters(in: .whitespaces).isEmpty {
                        LabeledContent("Load average") {
                            Text(load.trimmingCharacters(in: .whitespaces))
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let disk = info.diskUsage, !disk.trimmingCharacters(in: .whitespaces).isEmpty {
                        LabeledContent("Disk usage") {
                            Text(disk.trimmingCharacters(in: .whitespaces))
                        }
                    }

                    if let env = info.condaEnv, env != "none", !env.isEmpty {
                        LabeledContent("Conda env") {
                            Text(env)
                                .font(.system(.body, design: .monospaced))
                        }
                    }

                    if let jobs = info.slurmJobs, jobs != "N/A", jobs != "0" {
                        LabeledContent("SLURM jobs") {
                            Text(jobs)
                        }
                    }

                    LabeledContent("Last updated") {
                        Text(info.lastUpdated, style: .relative)
                            .foregroundColor(info.isStale ? .orange : .secondary)
                    }
                }
            }

            if !sessions.isEmpty {
                Section("Sessions (\(sessions.count))") {
                    ForEach(sessions) { session in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(session.isActive ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                            Text(session.name)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(session.isActive ? "attached" : "detached")
                                .font(.caption)
                                .foregroundColor(session.isActive ? .green : .secondary)
                            if let dur = session.durationLabel {
                                Text(dur)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 300, minHeight: 200)
    }
}
