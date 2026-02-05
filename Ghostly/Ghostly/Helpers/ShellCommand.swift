import Foundation

enum ShellError: Error, LocalizedError {
    case timeout
    case nonZeroExit(code: Int32, stderr: String)
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Command timed out"
        case .nonZeroExit(let code, let stderr):
            return "Exit code \(code): \(stderr)"
        case .processError(let msg):
            return msg
        }
    }
}

struct ShellResult {
    let output: String
    let errorOutput: String
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 }
}

actor ShellCommand {
    static func run(
        _ command: String,
        arguments: [String] = [],
        timeout: TimeInterval = 30
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                process.terminate()
            }
            timer.resume()

            do {
                try process.run()
                process.waitUntilExit()
                timer.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                let result = ShellResult(
                    output: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    errorOutput: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                    exitCode: process.terminationStatus
                )
                continuation.resume(returning: result)
            } catch {
                timer.cancel()
                continuation.resume(throwing: ShellError.processError(error.localizedDescription))
            }
        }
    }

    /// Run a command via SSH on a remote host
    static func ssh(
        host: String,
        command remoteCommand: String,
        timeout: TimeInterval = 15
    ) async throws -> ShellResult {
        let escaped = remoteCommand.replacingOccurrences(of: "'", with: "'\\''")
        let fullCommand = "ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \(host) '\(escaped)'"
        return try await run(fullCommand, timeout: timeout)
    }

    /// Quick connectivity check
    static func sshReachable(host: String, timeout: TimeInterval = 10) async -> Bool {
        do {
            let result = try await ssh(host: host, command: "echo ok", timeout: timeout)
            return result.succeeded && result.output.contains("ok")
        } catch {
            return false
        }
    }
}
