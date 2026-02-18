import Foundation

enum ProcessError: Error {
    case timeout
    case executionFailed(Error)
    case terminated(exitCode: Int32)

    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}

/// Runs a subprocess asynchronously with timeout support.
/// On timeout, the process is terminated via SIGTERM to prevent leaked zombies.
func runProcessAsync(
    executablePath: String,
    arguments: [String],
    timeout: Duration = .seconds(10)
) async throws -> (output: String, exitCode: Int32) {
    try await withThrowingTaskGroup(of: (String, Int32).self) { group in
        group.addTask {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                throw ProcessError.executionFailed(error)
            }

            // On cancellation (timeout), terminate the process so waitUntilExit returns.
            // The GCD block always resumes the continuation exactly once.
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        process.waitUntilExit()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: data, encoding: .utf8) ?? ""
                        continuation.resume(returning: (output, process.terminationStatus))
                    }
                }
            } onCancel: {
                process.terminate()
            }
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw ProcessError.timeout
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
