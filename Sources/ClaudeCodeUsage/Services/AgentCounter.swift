import Foundation

actor AgentCounter {
    struct AgentCount {
        let sessions: Int      // Main interactive sessions
        let subagents: Int     // Spawned subagents
        var total: Int { sessions + subagents }
    }

    func countAgents() async -> AgentCount {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["aux"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return AgentCount(sessions: 0, subagents: 0)
            }

            let lines = output.components(separatedBy: "\n")

            var sessions = 0
            var subagents = 0

            for line in lines {
                // Skip non-claude processes
                guard line.contains("claude") else { continue }
                // Skip grep itself
                guard !line.contains("grep") else { continue }
                // Skip our app
                guard !line.contains("ClaudeCodeUsage") else { continue }

                if line.contains("--output-format stream-json") {
                    // This is a subagent spawned by Task tool
                    subagents += 1
                } else if line.contains("/claude") || line.hasSuffix("claude") || line.contains("claude --") {
                    // This is a main interactive session
                    sessions += 1
                }
            }

            return AgentCount(sessions: sessions, subagents: subagents)
        } catch {
            return AgentCount(sessions: 0, subagents: 0)
        }
    }
}
