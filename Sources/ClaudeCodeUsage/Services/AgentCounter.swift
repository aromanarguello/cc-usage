import Foundation

struct AgentCount: Sendable {
    let sessions: Int      // Main interactive sessions
    let subagents: Int     // Spawned subagents
    var total: Int { sessions + subagents }
}

actor AgentCounter {
    func countAgents() async -> AgentCount {
        // Use pgrep for simpler, more reliable process counting
        let sessions = countProcesses(matching: "claude$|claude --dangerously")
        let subagents = countProcesses(matching: "claude.*--output-format")

        return AgentCount(sessions: sessions, subagents: subagents)
    }

    private func countProcesses(matching pattern: String) -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "ps aux | grep -E '\(pattern)' | grep -v grep | grep -v ClaudeCodeUsage | wc -l"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let count = Int(output) {
                return count
            }
        } catch {
            // Silently fail
        }

        return 0
    }
}
