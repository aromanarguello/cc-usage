import Foundation

enum ProcessError: Error {
    case timeout
    case executionFailed(Error)
    case terminated(exitCode: Int32)
}

/// Runs a subprocess asynchronously with timeout support
/// This prevents blocking the actor/main thread during process execution
func runProcessAsync(
    executablePath: String,
    arguments: [String],
    timeout: Duration = .seconds(10)
) async throws -> (output: String, exitCode: Int32) {
    try await withThrowingTaskGroup(of: (String, Int32).self) { group in
        // Main task: run the process
        group.addTask {
            try await withCheckedThrowingContinuation { continuation in
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executablePath)
                task.arguments = arguments

                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice

                do {
                    try task.run()
                } catch {
                    continuation.resume(throwing: ProcessError.executionFailed(error))
                    return
                }

                // Run blocking wait on background thread
                DispatchQueue.global(qos: .utility).async {
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, task.terminationStatus))
                }
            }
        }

        // Timeout task
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ProcessError.timeout
        }

        // Return first result, cancel the other
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
