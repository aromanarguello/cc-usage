# ClaudeGuard Design Document

**Date:** 2026-01-31
**Status:** Draft
**Author:** Claude + Ale

## Overview

ClaudeGuard is a native macOS menu bar app for Claude Code security monitoring. It acts as a security gateway, intercepting API requests to detect and optionally block sensitive data exfiltration.

**Separate product from cc-usage** - cc-usage remains free for usage tracking, ClaudeGuard is a pro product for security and agent management.

## Problem Statement

Claude Code has full access to your codebase. There's currently no way to:
- Audit what's being sent to the API
- Detect if secrets/credentials are being exfiltrated
- Monitor active agents and their resource usage
- Kill orphaned or runaway agents

## Core Features (v1)

| Priority | Feature | Description |
|----------|---------|-------------|
| 1 | **Security Scanning** | Detect API keys, passwords, PII in outgoing requests |
| 2 | **Agent Dashboard** | View sessions, subagents, kill orphans |
| 3 | Token Tracking | Per-request counts, session totals (v2) |
| 4 | Request Logging | Save prompts to disk for audit (v2) |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  ClaudeGuard.app                                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ ProxyServer │  │ Security    │  │ SessionFileParser   │  │
│  │ (Actor)     │  │ Scanner     │  │ (Actor)             │  │
│  │             │  │ (Actor)     │  │                     │  │
│  │ NWListener  │  │             │  │ ~/.claude/projects  │  │
│  │ :8080       │──▶ Regex scan  │  │                     │  │
│  │             │  │ Alert/Block │  │                     │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│         │                                    │              │
│         ▼                                    ▼              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  AppState (@Observable, @MainActor)                     ││
│  │  - proxyStatus, alertCount, blockedCount                ││
│  │  - sessions: [AgentSession]                             ││
│  └─────────────────────────────────────────────────────────┘│
│         │                                                   │
│         ▼                                                   │
│  ┌──────────────┐  ┌────────────────────────────────────┐   │
│  │ MenuBarExtra │  │ Window: AgentDashboardView         │   │
│  │ 🛡️ 3 │ ⚠️ 2   │  │ - Session list + details           │   │
│  └──────────────┘  │ - Security alerts panel            │   │
│                    │ - Proxy controls                   │   │
│                    └────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## Components

### ProxyServer (Actor)

HTTP relay proxy using Network.framework (NWListener). Listens on localhost:8080, intercepts requests, scans for secrets, forwards to upstream API.

```swift
actor ProxyServer {
    private var listener: NWListener?
    private let scanner: SecurityScanner
    private let port: UInt16

    enum ProxyEvent: Sendable {
        case requestIntercepted(RequestInfo)
        case securityAlert(SecurityScanner.Finding)
        case requestBlocked(reason: String)
        case upstreamError(Error)
    }

    var onEvent: (@Sendable (ProxyEvent) -> Void)?

    func start() async throws
    func stop() async
}
```

**Request flow:**
1. Claude Code sends HTTP to localhost:8080
2. ProxyServer parses JSON body
3. SecurityScanner checks for secrets
4. If clean: forward via URLSession to api.anthropic.com
5. If alert: log finding, optionally block
6. Return response to Claude Code

### SecurityScanner (Actor)

Pattern-based secret detection with configurable threat levels.

```swift
actor SecurityScanner {
    enum ThreatLevel: Int, Sendable {
        case critical = 3  // API keys, passwords
        case high = 2      // PII, credentials
        case medium = 1    // Internal paths, IPs
        case low = 0       // Suspicious patterns
    }

    struct Finding: Sendable, Identifiable {
        let id: UUID
        let pattern: String
        let category: String
        let threat: ThreatLevel
        let context: String
        let timestamp: Date
    }

    func scan(_ content: String) -> [Finding]
}
```

**Detection patterns (v1):**

| Category | Examples | Threat |
|----------|----------|--------|
| API Keys | `sk-...`, `AKIA...`, `ghp_...` | Critical |
| Passwords | `password=`, `secret=`, `.env` contents | Critical |
| Private Keys | `-----BEGIN RSA PRIVATE KEY-----` | Critical |
| PII | Email regex, SSN patterns, credit cards | High |
| Internal | `192.168.x.x`, `/Users/*/...` paths | Medium |

**Behavior options:**
- Alert only - Log finding, show notification, allow request
- Block - Reject request, show alert with details
- Redact - Replace matched content with `[REDACTED]`, forward

### SessionFileParser (Actor)

Parses Claude Code session files from `~/.claude/projects/*/sessions-index.json`. Ported from cc-usage-pro.

### AgentSession Model

```swift
struct AgentSession: Identifiable, Sendable {
    let id: String
    let pid: Int?
    let projectPath: String
    let projectName: String
    let gitBranch: String?
    let agentType: AgentType
    let taskDescription: String
    let status: AgentStatus
    let startTime: Date
    let cpuPercent: Double
    let memoryMB: Int
    var subagents: [AgentSession]

    // Security stats per session
    var requestCount: Int = 0
    var alertCount: Int = 0
    var blockedCount: Int = 0
}

enum AgentType: String, Sendable, CaseIterable {
    case main = "Main Session"
    case explore = "Explore"
    case plan = "Plan"
    case bash = "Bash"
    case codeReviewer = "Code Reviewer"
    case unknown = "Unknown"
}

enum AgentStatus: String, Sendable {
    case active
    case working
    case idle
    case orphaned
    case completed
}
```

## User Interface

### Menu Bar

```
[🛡️ 3 │ ⚠️ 2]
```

- Number = active agents
- Alert badge = unacknowledged alerts
- Color: green (ok), yellow (alerts), red (blocked/error)

Click opens main dashboard window.

### Dashboard Window

```
┌─────────────────────────────────────────────────────────────┐
│  ClaudeGuard                                    ⚙️  ─  ☐  ✕ │
├─────────────────────────────────────────────────────────────┤
│  🛡️ Security: 2 alerts │ 0 blocked    [Start Proxy]        │
├──────────────────────┬──────────────────────────────────────┤
│  Sessions            │  cc-usage (main)                     │
│  ─────────────────── │  ────────────────────────────────    │
│  ● cc-usage          │  PID: 1234  CPU: 2.1%  Mem: 45MB     │
│    ├─ explore        │  Branch: feature/proxy               │
│    └─ bash           │  Runtime: 0:23                       │
│  ● other-project     │                                      │
│                      │  Task: "Implement security scanning" │
│                      │                                      │
│                      │  Security                            │
│                      │  ─────────                           │
│                      │  Requests: 47  Alerts: 2  Blocked: 0 │
│                      │                                      │
│                      │  [View Alerts]  [Kill Session]       │
├──────────────────────┴──────────────────────────────────────┤
│  3 sessions │ 2 subagents │ 89 MB          Updated: 5s ago  │
└─────────────────────────────────────────────────────────────┘
```

## CLI Wrapper

Users run `claudeguard` instead of `claude` to route through the proxy.

```bash
#!/bin/bash
# ~/.local/bin/claudeguard

export ANTHROPIC_BASE_URL="http://127.0.0.1:8080"
exec claude "$@"
```

**Installation:** App prompts on first launch to install CLI to `~/.local/bin` or `/usr/local/bin`.

## Tech Stack

- **Swift 6.0**, SwiftUI, AppKit
- **Network.framework** (NWListener) for proxy
- **URLSession** for upstream HTTPS
- **Zero external dependencies**
- **macOS 14+** (Sonoma)

## Project Setup

1. Fresh fork from current cc-usage (gets wake recovery, retry logic, etc.)
2. Port from cc-usage-pro:
   - `AgentDashboardView`
   - `AgentSession` model
   - `SessionFileParser`
   - `AgentDashboardViewModel`
3. New components:
   - `ProxyServer`
   - `SecurityScanner`
   - CLI wrapper script
   - Settings for security behavior

## Future (v2+)

- **Token Tracking** - Per-request token counts, cost estimates
- **Request Logging** - Save all prompts/responses to disk
- **Compliance/Audit** - Export logs for SOC2, HIPAA
- **Custom Rules** - User-defined patterns and actions
- **Enterprise Features** - Central policy management

## Open Questions

- Pricing model? One-time vs subscription
- Free tier? (e.g., agent dashboard free, security scanning paid)
- Distribution? Direct download vs Mac App Store

## References

- [tokentap](https://github.com/jmuncor/tokentap) - Inspiration for proxy approach
- [Network.framework servers](http://www.alwaysrightinstitute.com/network-framework/)
- [NWHTTPProtocol](https://github.com/helje5/NWHTTPProtocol) - HTTP framing reference
