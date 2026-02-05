import Foundation
import SwiftUI
import UserNotifications

@Observable
@MainActor
final class ConnectionManager {
    // MARK: - Published State
    var hosts: [SSHHost] = []
    var connectionStates: [String: ConnectionStatus] = [:]
    var sessions: [String: [GhostlySession]] = [:]
    var remoteInfos: [String: RemoteInfo] = [:]
    var lastError: [String: String] = [:]
    var isLoading: Bool = false

    // MARK: - Services
    private let configParser = SSHConfigParser()
    private let sshService = SSHService()
    private let sessionService = SessionService()
    private let remoteInfoService = RemoteInfoService()
    let ghosttyService = GhosttyService()
    let networkMonitor = NetworkMonitor()
    let batteryMonitor = BatteryMonitor()

    // MARK: - Polling
    private var pollingTask: Task<Void, Never>?
    private var retryCount: [String: Int] = [:]
    private let maxRetries = 3
    private let basePollInterval: TimeInterval = 30

    // MARK: - Persistence
    private let managedHostsKey = "managedHosts"
    private let favoriteHostsKey = "favoriteHosts"

    // MARK: - Computed
    var managedHosts: [SSHHost] {
        hosts.filter(\.isManaged).sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.alias < b.alias
        }
    }

    var favoriteHosts: [SSHHost] {
        hosts.filter(\.isFavorite).sorted { $0.alias < $1.alias }
    }

    var unmanagedHosts: [SSHHost] {
        hosts.filter { !$0.isManaged }.sorted { $0.alias < $1.alias }
    }

    var groupedUnmanagedHosts: [(String, [SSHHost])] {
        let grouped = Dictionary(grouping: unmanagedHosts) { $0.inferredGroup ?? "Other" }
        return grouped.sorted { $0.key < $1.key }
    }

    var connectedCount: Int {
        managedHosts.filter { connectionStates[$0.id] == .connected }.count
    }

    var menuBarIcon: String {
        if managedHosts.isEmpty { return "ghost" }
        let allConnected = managedHosts.allSatisfy { connectionStates[$0.id] == .connected }
        let anyReconnecting = managedHosts.contains { connectionStates[$0.id] == .reconnecting }
        if allConnected { return "ghost.fill" }
        if anyReconnecting { return "ghost.circle" }
        return "ghost"
    }

    // MARK: - Init
    init() {
        networkMonitor.onNetworkChange { [weak self] in
            Task { @MainActor in
                self?.handleNetworkChange()
            }
        }
    }

    // MARK: - Load Hosts
    func loadHosts() async {
        isLoading = true
        defer { isLoading = false }

        let parsed = await configParser.parse()
        let savedManaged = Set(UserDefaults.standard.stringArray(forKey: managedHostsKey) ?? [])
        let savedFavorites = Set(UserDefaults.standard.stringArray(forKey: favoriteHostsKey) ?? [])

        hosts = parsed.map { host in
            var h = host
            h.isManaged = savedManaged.contains(h.id)
            h.isFavorite = savedFavorites.contains(h.id)
            return h
        }

        // Watch for config changes
        await configParser.watchForChanges { [weak self] in
            Task { @MainActor in
                await self?.loadHosts()
            }
        }

        // Initial check for managed hosts
        await refreshManagedHosts()
    }

    // MARK: - Host Management
    func toggleManaged(_ host: SSHHost) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx].isManaged.toggle()
        savePreferences()

        if hosts[idx].isManaged {
            Task {
                await checkHost(hosts[idx])
            }
        } else {
            connectionStates[host.id] = nil
            sessions[host.id] = nil
            remoteInfos[host.id] = nil
        }
    }

    func toggleFavorite(_ host: SSHHost) {
        guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[idx].isFavorite.toggle()
        savePreferences()
    }

    // MARK: - Connection Checks
    func refreshManagedHosts() async {
        let managed = managedHosts
        guard !managed.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for host in managed {
                group.addTask { @MainActor in
                    await self.checkHost(host)
                }
            }
        }

        startPolling()
    }

    func checkHost(_ host: SSHHost) async {
        connectionStates[host.id] = connectionStates[host.id] == .connected ? .connected : .reconnecting

        let reachable = await sshService.testConnection(host: host.sshTarget)

        if reachable {
            connectionStates[host.id] = .connected
            retryCount[host.id] = 0
            lastError[host.id] = nil
            AppLog.shared.log("Host \(host.alias) connected")

            // Fetch sessions and info concurrently
            async let sessionsResult = sessionService.listSessions(on: host.sshTarget)
            async let infoResult = host.showRemoteInfo
                ? remoteInfoService.fetchInfo(host: host.sshTarget)
                : nil

            sessions[host.id] = await sessionsResult
            if let info = await infoResult {
                remoteInfos[host.id] = info
            }
        } else {
            let attempts = (retryCount[host.id] ?? 0) + 1
            retryCount[host.id] = attempts

            if attempts >= maxRetries {
                connectionStates[host.id] = .disconnected
                lastError[host.id] = "Unreachable after \(maxRetries) attempts"
                AppLog.shared.log("Host \(host.alias) unreachable after \(maxRetries) attempts", level: .error)
            } else {
                connectionStates[host.id] = .error
                lastError[host.id] = "Connection failed (attempt \(attempts)/\(maxRetries))"
                AppLog.shared.log("Host \(host.alias) check failed (\(attempts)/\(maxRetries))", level: .warning)
            }
        }
    }

    // MARK: - Actions
    func connect(host: SSHHost, sessionName: String = "default", openMode: TerminalOpenMode? = nil) async {
        AppLog.shared.log("Connecting to \(host.alias) session=\(sessionName)")
        do {
            try await ghosttyService.connect(host: host.sshTarget, sessionName: sessionName, openMode: openMode)
            AppLog.shared.log("Connected to \(host.alias)")
            // Brief delay then check status
            try? await Task.sleep(for: .seconds(2))
            await checkHost(host)
        } catch {
            lastError[host.id] = error.localizedDescription
            AppLog.shared.log("Connect to \(host.alias) failed: \(error.localizedDescription)", level: .error)
        }
    }

    func reattach(host: SSHHost, session: GhostlySession, openMode: TerminalOpenMode? = nil) async {
        AppLog.shared.log("Reattaching \(host.alias)/\(session.name)")
        do {
            try await ghosttyService.reattach(host: host.sshTarget, sessionName: session.name, backend: session.backend, openMode: openMode)
            AppLog.shared.log("Reattached \(host.alias)/\(session.name)")
        } catch {
            lastError[host.id] = error.localizedDescription
            AppLog.shared.log("Reattach \(host.alias)/\(session.name) failed: \(error.localizedDescription)", level: .error)
        }
    }

    func plainSSH(host: SSHHost, openMode: TerminalOpenMode? = nil) async {
        AppLog.shared.log("Plain SSH to \(host.alias)")
        do {
            try await ghosttyService.plainSSH(host: host.sshTarget, openMode: openMode)
        } catch {
            lastError[host.id] = error.localizedDescription
            AppLog.shared.log("Plain SSH to \(host.alias) failed: \(error.localizedDescription)", level: .error)
        }
    }

    func installSessionBackend(on host: SSHHost) async {
        AppLog.shared.log("Installing ghostly-session on \(host.alias)")
        lastError[host.id] = nil
        do {
            try await sessionService.installGhostlySession(on: host.sshTarget)
            AppLog.shared.log("Installed ghostly-session on \(host.alias)")
            await checkHost(host)
        } catch {
            lastError[host.id] = error.localizedDescription
            AppLog.shared.log("Install on \(host.alias) failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Polling
    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                let multiplier = batteryMonitor.pollIntervalMultiplier
                if multiplier == 0 {
                    // Low battery, pause
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }

                let interval = basePollInterval * multiplier
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }

                await refreshManagedHosts()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Network Change
    private func handleNetworkChange() {
        guard networkMonitor.isConnected else {
            AppLog.shared.log("Network lost — marking all hosts disconnected", level: .warning)
            for host in managedHosts {
                connectionStates[host.id] = .disconnected
            }
            return
        }

        AppLog.shared.log("Network changed — reconnecting managed hosts")
        for host in managedHosts {
            connectionStates[host.id] = .reconnecting
        }

        Task {
            await refreshManagedHosts()

            let reconnectedCount = managedHosts.filter {
                connectionStates[$0.id] == .connected
            }.count

            if reconnectedCount > 0 {
                AppLog.shared.log("Reconnected to \(reconnectedCount) host(s)")
                sendNotification("Reconnected to \(reconnectedCount) host\(reconnectedCount == 1 ? "" : "s")")
            }
        }
    }

    // MARK: - Notifications
    private func sendNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Ghostly"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence
    private func savePreferences() {
        let managed = hosts.filter(\.isManaged).map(\.id)
        let favorites = hosts.filter(\.isFavorite).map(\.id)
        UserDefaults.standard.set(managed, forKey: managedHostsKey)
        UserDefaults.standard.set(favorites, forKey: favoriteHostsKey)
    }
}
