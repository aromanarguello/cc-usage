import Darwin
import Foundation

struct ProcessInfo: Sendable {
    let pid: Int
    let parentPID: Int         // Parent process ID
    let elapsedSeconds: Int
    let memoryKB: Int          // Resident Set Size in KB
    let cpuPercent: Double     // CPU percentage
    let isSubagent: Bool

    var isOrphaned: Bool {     // Orphaned if parent is init (PID 1) and is a subagent
        parentPID == 1 && isSubagent
    }
}

struct AgentCount: Sendable {
    let sessions: Int      // Main interactive sessions
    let subagents: Int     // Spawned subagents
    let hangingSubagents: [ProcessInfo]  // Subagents running > 3 hours
    let totalMemoryMB: Int // Total memory used by all agents
    var total: Int { sessions + subagents }
}

actor AgentCounter {
    private let hangingThresholdSeconds = 3 * 60 * 60  // 3 hours

    func countAgents() async -> AgentCount {
        let processes = await getClaudeProcesses()

        let sessions = processes.filter { !$0.isSubagent }.count
        let subagents = processes.filter { $0.isSubagent }.count
        let hangingSubagents = processes.filter { $0.isSubagent && $0.elapsedSeconds > hangingThresholdSeconds }
        let totalMemoryKB = processes.reduce(0) { $0 + $1.memoryKB }
        let totalMemoryMB = totalMemoryKB / 1024

        return AgentCount(sessions: sessions, subagents: subagents, hangingSubagents: hangingSubagents, totalMemoryMB: totalMemoryMB)
    }

    func killHangingAgents(_ processes: [ProcessInfo]) async -> Int {
        var killedCount = 0

        for process in processes {
            // Try SIGTERM first
            let termResult = sendSignal(SIGTERM, to: process.pid)
            if termResult {
                // Wait briefly to see if process exits
                try? await Task.sleep(for: .milliseconds(500))

                // Check if still running, escalate to SIGKILL if needed
                if isProcessRunning(process.pid) {
                    _ = sendSignal(SIGKILL, to: process.pid)
                }
                killedCount += 1
            }
        }

        return killedCount
    }

    func detectOrphanedSubagents() async -> [ProcessInfo] {
        let processes = await getClaudeProcesses()
        let sessions = processes.filter { !$0.isSubagent }
        let subagents = processes.filter { $0.isSubagent }

        // Multi-signal orphan detection:
        // 1. Parent PID = 1 (reparented to init)
        // 2. No active sessions OR session count is 0
        // 3. Low CPU activity (< 1%)
        let orphans = subagents.filter { subagent in
            let parentGone = subagent.parentPID == 1
            let noSessions = sessions.isEmpty
            let lowCPU = subagent.cpuPercent < 1.0

            return parentGone && noSessions && lowCPU
        }

        return orphans
    }

    func killProcesses(_ processes: [ProcessInfo]) async -> Int {
        var killedCount = 0

        for process in processes {
            let termResult = sendSignal(SIGTERM, to: process.pid)
            if termResult {
                try? await Task.sleep(for: .milliseconds(500))

                if isProcessRunning(process.pid) {
                    _ = sendSignal(SIGKILL, to: process.pid)
                }
                killedCount += 1
            }
        }

        return killedCount
    }

    func getAllSubagents() async -> [ProcessInfo] {
        let processes = await getClaudeProcesses()
        return processes.filter { $0.isSubagent }
    }

    private func getClaudeProcesses() async -> [ProcessInfo] {
        do {
            let (output, _) = try await runProcessAsync(
                executablePath: "/bin/zsh",
                arguments: ["-c", "ps -eo pid,ppid,etime,rss,%cpu,command | grep -E '( |/)claude( |$)' | grep -v grep | grep -v ClaudeCodeUsage"],
                timeout: Duration.seconds(5)
            )

            return output.split(separator: "\n").compactMap { line -> ProcessInfo? in
                let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
                guard parts.count >= 6,
                      let pid = Int(parts[0]),
                      let parentPID = Int(parts[1]),
                      let memoryKB = Int(parts[3]),
                      let cpuPercent = Double(parts[4]) else { return nil }

                let etime = String(parts[2])
                let command = String(parts[5])

                let elapsedSeconds = parseEtime(etime)
                let isSubagent = command.contains("--output-format")

                return ProcessInfo(
                    pid: pid,
                    parentPID: parentPID,
                    elapsedSeconds: elapsedSeconds,
                    memoryKB: memoryKB,
                    cpuPercent: cpuPercent,
                    isSubagent: isSubagent
                )
            }
        } catch {
            return []
        }
    }

    // Parse etime format: [[dd-]hh:]mm:ss
    private func parseEtime(_ etime: String) -> Int {
        var days = 0
        var hours = 0
        var minutes = 0
        var seconds = 0

        var remaining = etime

        // Check for days (dd-)
        if let dashIndex = remaining.firstIndex(of: "-") {
            days = Int(remaining[..<dashIndex]) ?? 0
            remaining = String(remaining[remaining.index(after: dashIndex)...])
        }

        let parts = remaining.split(separator: ":").map { String($0) }

        switch parts.count {
        case 3:  // hh:mm:ss
            hours = Int(parts[0]) ?? 0
            minutes = Int(parts[1]) ?? 0
            seconds = Int(parts[2]) ?? 0
        case 2:  // mm:ss
            minutes = Int(parts[0]) ?? 0
            seconds = Int(parts[1]) ?? 0
        case 1:  // ss
            seconds = Int(parts[0]) ?? 0
        default:
            break
        }

        return days * 86400 + hours * 3600 + minutes * 60 + seconds
    }

    private func sendSignal(_ signal: Int32, to pid: Int) -> Bool {
        return kill(Int32(pid), signal) == 0
    }

    private func isProcessRunning(_ pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0
    }
}
