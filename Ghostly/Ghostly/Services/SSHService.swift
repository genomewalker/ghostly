import Foundation

actor SSHService {
    /// Test if a host is reachable via SSH
    func testConnection(host: String, timeout: TimeInterval = 10) async -> Bool {
        await ShellCommand.sshReachable(host: host, timeout: timeout)
    }

    /// Run a command on a remote host
    func execute(host: String, command: String, timeout: TimeInterval = 15) async throws -> ShellResult {
        try await ShellCommand.ssh(host: host, command: command, timeout: timeout)
    }

    /// Batch test multiple hosts concurrently
    func testHosts(_ hosts: [String], timeout: TimeInterval = 10) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool).self) { group in
            for host in hosts {
                group.addTask {
                    let reachable = await ShellCommand.sshReachable(host: host, timeout: timeout)
                    return (host, reachable)
                }
            }

            var results: [String: Bool] = [:]
            for await (host, reachable) in group {
                results[host] = reachable
            }
            return results
        }
    }
}
