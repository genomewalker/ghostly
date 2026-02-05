import SwiftUI

struct MenuBarView: View {
    @Environment(ConnectionManager.self) private var manager
    @AppStorage("terminalOpenMode") private var terminalOpenMode = "window"
    @State private var searchText = ""
    @State private var newSessionName = ""
    @State private var showNewSessionFor: String?
    @State private var showConsole = false
    @State private var expandedHosts: Set<String> = []

    private var selectedMode: TerminalOpenMode {
        TerminalOpenMode(rawValue: terminalOpenMode) ?? .newWindow
    }

    /// Determine open mode from modifier keys, falling back to the selected default
    private func openMode(for event: NSEvent? = NSApp.currentEvent) -> TerminalOpenMode {
        guard let flags = event?.modifierFlags else { return selectedMode }
        if flags.contains(.option) { return .newTab }
        if flags.contains(.shift) { return .splitPane }
        return selectedMode
    }

    // MARK: - Filtered hosts

    private var filteredManagedHosts: [SSHHost] {
        if searchText.count < 3 { return manager.managedHosts }
        let q = searchText.lowercased()
        return manager.managedHosts.filter { $0.alias.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }

    private var filteredUnmanagedHosts: [SSHHost] {
        guard searchText.count >= 3 else { return [] }
        let q = searchText.lowercased()
        return manager.unmanagedHosts.filter { $0.alias.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("Ghostly")
                    .font(.system(size: 14, weight: .bold))

                Spacer()

                // Mode picker
                ForEach(TerminalOpenMode.allCases, id: \.rawValue) { mode in
                    Button {
                        terminalOpenMode = mode.rawValue
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10))
                            .foregroundColor(selectedMode == mode ? .accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("\(mode.label) (\(mode.shortcutHint))")
                }

                if manager.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await manager.refreshManagedHosts() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh all hosts")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Search box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search hosts...", text: $searchText)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Favorites section (always visible if any exist)
                    if !manager.favoriteHosts.isEmpty {
                        sectionHeader("Favorites")

                        ForEach(manager.favoriteHosts) { host in
                            favoriteHostRow(host)
                            Divider().padding(.horizontal, 12)
                        }
                    }

                    // Managed hosts section
                    if !filteredManagedHosts.isEmpty {
                        sectionHeader("Managed Hosts")

                        ForEach(filteredManagedHosts) { host in
                            managedHostRow(host)
                            Divider().padding(.horizontal, 12)
                        }
                    }

                    // Search results (unmanaged hosts)
                    if !filteredUnmanagedHosts.isEmpty {
                        sectionHeader("SSH Hosts")

                        ForEach(filteredUnmanagedHosts) { host in
                            unmanagedHostRow(host)
                        }
                    }

                    // Empty states
                    if manager.hosts.isEmpty {
                        VStack(spacing: 8) {
                            Text("No SSH hosts found")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text("Add hosts to ~/.ssh/config")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else if searchText.count >= 3 && filteredManagedHosts.isEmpty && filteredUnmanagedHosts.isEmpty {
                        Text("No hosts matching \"\(searchText)\"")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    } else if searchText.isEmpty && manager.unmanagedHosts.count > 0 && manager.managedHosts.isEmpty {
                        Text("Type 3+ letters to search \(manager.unmanagedHosts.count) hosts")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    } else if searchText.count > 0 && searchText.count < 3 && manager.unmanagedHosts.count > 0 {
                        Text("Type \(3 - searchText.count) more letter\(3 - searchText.count == 1 ? "" : "s") to search...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 400)

            // Console panel
            if showConsole {
                Divider()
                ConsoleView()
            }

            Divider()

            // Footer bar
            HStack(spacing: 12) {
                // Status indicators (compact)
                HStack(spacing: 6) {
                    Image(systemName: manager.networkMonitor.isConnected ? "wifi" : "wifi.slash")
                        .font(.system(size: 9))
                        .foregroundColor(manager.networkMonitor.isConnected ? .green : .red)
                    Image(systemName: manager.batteryMonitor.isOnBattery ? "battery.25" : "battery.100.bolt")
                        .font(.system(size: 9))
                        .foregroundColor(manager.batteryMonitor.isLowBattery ? .red : .secondary)
                }

                Spacer()

                // Action buttons
                Button {
                    showConsole.toggle()
                } label: {
                    Image(systemName: showConsole ? "terminal.fill" : "terminal")
                        .font(.system(size: 11))
                        .foregroundColor(showConsole ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help("Toggle console")

                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gear")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Settings")

                Button {
                    manager.stopPolling()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Quit Ghostly")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 320)
        .onAppear {
            AppLog.shared.log("Ghostly started")
        }
    }

    // MARK: - Section Header
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Managed Host Row
    @ViewBuilder
    private func managedHostRow(_ host: SSHHost) -> some View {
        let status = manager.connectionStates[host.id] ?? .unknown
        let hostSessions = manager.sessions[host.id] ?? []
        let info = manager.remoteInfos[host.id]
        let error = manager.lastError[host.id]

        VStack(alignment: .leading, spacing: 4) {
            HostRowView(
                host: host,
                status: status,
                sessions: hostSessions,
                remoteInfo: info,
                errorMessage: error,
                isExpanded: Binding(
                    get: { expandedHosts.contains(host.id) },
                    set: { newValue in
                        if newValue { expandedHosts.insert(host.id) }
                        else { expandedHosts.remove(host.id) }
                    }
                ),
                onConnect: {
                    let mode = openMode()
                    Task { await manager.connect(host: host, openMode: mode) }
                },
                onReattach: { session in
                    let mode = openMode()
                    Task { await manager.reattach(host: host, session: session, openMode: mode) }
                },
                onNewSession: {
                    AppLog.shared.log("New session tapped for \(host.alias)")
                    showNewSessionFor = host.id
                    newSessionName = ""
                },
                onKillSession: { session in
                    Task {
                        await manager.killSession(host: host, session: session)
                    }
                },
                onInstallBackend: { Task { await manager.installSessionBackend(on: host) } },
                onToggleManaged: { manager.toggleManaged(host) },
                onToggleFavorite: { manager.toggleFavorite(host) }
            )

            // Action buttons
            if status == .connected {
                HStack(spacing: 8) {
                    Button("Connect") {
                        let mode = openMode()
                        Task { await manager.connect(host: host, openMode: mode) }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .help("Option+click: tab, Shift+click: split")

                    Spacer()

                    // Context menu
                    Menu {
                        Button("Plain SSH") {
                            let mode = openMode()
                            Task { await manager.plainSSH(host: host, openMode: mode) }
                        }
                        Button(host.isFavorite ? "Unfavorite" : "Favorite") {
                            manager.toggleFavorite(host)
                        }
                        Divider()
                        Button("Remove from managed") {
                            manager.toggleManaged(host)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.leading, 14)
            } else if status == .disconnected || status == .error {
                HStack(spacing: 8) {
                    Button("Retry") {
                        Task { await manager.checkHost(host) }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)

                    Spacer()

                    Button {
                        manager.toggleManaged(host)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from managed")
                }
                .padding(.leading, 14)
            }

            // New session name input
            if showNewSessionFor == host.id {
                HStack(spacing: 6) {
                    TextField("Session name", text: $newSessionName)
                        .font(.system(size: 11))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            createNewSession(host: host)
                        }
                    Button {
                        createNewSession(host: host)
                    } label: {
                        Text("Create")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    Button {
                        showNewSessionFor = nil
                        newSessionName = ""
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Unmanaged Host Row
    @ViewBuilder
    private func unmanagedHostRow(_ host: SSHHost) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "circle")
                .font(.system(size: 6))
                .foregroundColor(.gray)

            Text(host.displayName)
                .font(.system(size: 12))

            Spacer()

            Button {
                manager.toggleFavorite(host)
            } label: {
                Image(systemName: host.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundColor(host.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help(host.isFavorite ? "Remove from favorites" : "Add to favorites")

            Button("Connect") {
                let mode = openMode()
                Task { await manager.connect(host: host, openMode: mode) }
            }
            .font(.system(size: 10))
            .buttonStyle(.borderless)
            .help("Option+click: tab, Shift+click: split")

            Button {
                manager.toggleManaged(host)
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Add to managed hosts")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: - Favorite Host Row
    @ViewBuilder
    private func favoriteHostRow(_ host: SSHHost) -> some View {
        let status = host.isManaged ? (manager.connectionStates[host.id] ?? .unknown) : nil

        HStack(spacing: 6) {
            if let status {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 6, height: 6)
            }

            Text(host.displayName)
                .font(.system(size: 12))

            Spacer()

            Button("Connect") {
                let mode = openMode()
                Task { await manager.connect(host: host, openMode: mode) }
            }
            .font(.system(size: 10))
            .buttonStyle(.borderless)
            .help("Option+click: tab, Shift+click: split")

            Button {
                manager.toggleFavorite(host)
            } label: {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.yellow)
            }
            .buttonStyle(.borderless)
            .help("Remove from favorites")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    // MARK: - New Session Helper
    private func createNewSession(host: SSHHost) {
        let name = newSessionName.trimmingCharacters(in: .whitespaces)
        let sessionName = name.isEmpty ? "session-\(Int.random(in: 100...999))" : name
        AppLog.shared.log("Creating new session '\(sessionName)' on \(host.alias)")
        let mode = openMode()
        Task { await manager.connect(host: host, sessionName: sessionName, openMode: mode) }
        showNewSessionFor = nil
        newSessionName = ""
    }

    private func statusColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .disconnected: return .red
        case .reconnecting: return .orange
        case .error: return .red
        case .unknown: return .gray
        }
    }
}
