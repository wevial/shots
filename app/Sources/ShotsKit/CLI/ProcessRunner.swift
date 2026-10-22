import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a command to completion without blocking the caller's thread.
enum ProcessRunner {
    static func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            // `Process` and the blocking pipe reads live on a GCD thread, so neither the main
            // actor nor Swift's small cooperative thread pool waits on a 30-second cloud call.
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment { process.environment = environment }
                let stdout = Pipe(), stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain stderr on a second thread: if either pipe fills up while we only read
                // the other, the child blocks on write and never exits.
                let stderrData = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    stderrData.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: ProcessOutput(
                    status: process.terminationStatus,
                    stdout: stdoutData,
                    stderr: stderrData.data
                ))
            }
        }
    }
}

/// Written by one thread, read by another only after `DispatchGroup.wait()`, which orders the two.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
