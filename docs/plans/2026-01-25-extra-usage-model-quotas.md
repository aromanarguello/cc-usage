# Extra Usage & Model Quotas Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Display extra usage (monthly spending) and model-specific quotas (Sonnet, Opus) in the popover UI.

**Architecture:** Extend existing `UsageData` model with optional `ExtraUsage` struct and model-specific `UsageWindow` fields. Parse new fields from API response. Add new UI sections that conditionally render when data is present.

**Tech Stack:** Swift 6.0, SwiftUI, existing `UsageData`/`UsageAPIResponse` patterns

---

## API Response Reference

```json
{
  "five_hour": { "utilization": 22, "resets_at": "..." },
  "seven_day": { "utilization": 31, "resets_at": "..." },
  "seven_day_sonnet": { "utilization": 25, "resets_at": "..." },
  "seven_day_opus": null,
  "extra_usage": {
    "utilization": 44.9,
    "monthly_limit": 2000,
    "used_credits": 898,
    "is_enabled": true
  }
}
```

---

### Task 1: Add ExtraUsage Model

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Models/UsageData.swift`

**Step 1: Add ExtraUsage struct after UsageWindow**

Add this code after the `UsageWindow` struct closing brace (around line 34):

```swift
struct ExtraUsage: Sendable {
    let utilization: Double      // 0-100 percentage
    let usedCredits: Int         // in cents
    let monthlyLimit: Int        // in cents
    let isEnabled: Bool

    var percentage: Int {
        Int(utilization)
    }

    var usedUSD: String {
        let dollars = Double(usedCredits) / 100.0
        return String(format: "$%.2f", dollars)
    }

    var limitUSD: String {
        let dollars = Double(monthlyLimit) / 100.0
        return String(format: "$%.2f", dollars)
    }
}
```

**Step 2: Build to verify syntax**

Run: `make build`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Models/UsageData.swift
git commit -m "$(cat <<'EOF'
feat: add ExtraUsage model for monthly spending tracking

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Extend UsageData with New Fields

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Models/UsageData.swift`

**Step 1: Add optional fields to UsageData struct**

Update the `UsageData` struct (lines 3-7) to include new fields:

```swift
struct UsageData: Sendable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let sevenDaySonnet: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let extraUsage: ExtraUsage?
    let subscription: String
    let lastUpdated: Date
```

**Step 2: Update the placeholder static property**

Update the `placeholder` (around line 36) to include new fields:

```swift
static let placeholder = UsageData(
    fiveHour: UsageWindow(utilization: 0.20, resetsAt: Date().addingTimeInterval(4 * 3600 + 54 * 60)),
    sevenDay: UsageWindow(utilization: 0.51, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
    sevenDaySonnet: UsageWindow(utilization: 0.25, resetsAt: Date().addingTimeInterval(5 * 24 * 3600)),
    sevenDayOpus: nil,
    extraUsage: ExtraUsage(utilization: 44.9, usedCredits: 898, monthlyLimit: 2000, isEnabled: true),
    subscription: "Pro",
    lastUpdated: Date()
)
```

**Step 3: Build to verify**

Run: `make build`
Expected: Build fails - `toUsageData()` needs updating (expected)

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/Models/UsageData.swift
git commit -m "$(cat <<'EOF'
feat: extend UsageData with model quotas and extra usage fields

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Update API Response Decoding

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Models/UsageData.swift`

**Step 1: Add ExtraUsageResponse struct**

Add after `UsageWindowResponse` struct (around line 58):

```swift
struct ExtraUsageResponse: Decodable {
    let utilization: Double
    let monthlyLimit: Int
    let usedCredits: Int
    let isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case utilization
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case isEnabled = "is_enabled"
    }
}
```

**Step 2: Add new fields to UsageAPIResponse**

Update `UsageAPIResponse` struct to include optional fields:

```swift
struct UsageAPIResponse: Decodable {
    let fiveHour: UsageWindowResponse
    let sevenDay: UsageWindowResponse
    let sevenDaySonnet: UsageWindowResponse?
    let sevenDayOpus: UsageWindowResponse?
    let extraUsage: ExtraUsageResponse?

    struct UsageWindowResponse: Decodable {
        let utilization: Double
        let resetsAt: Date

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct ExtraUsageResponse: Decodable {
        let utilization: Double
        let monthlyLimit: Int
        let usedCredits: Int
        let isEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case utilization
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case isEnabled = "is_enabled"
        }
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOpus = "seven_day_opus"
        case extraUsage = "extra_usage"
    }
```

**Step 3: Update toUsageData() method**

Replace the existing `toUsageData()` method:

```swift
func toUsageData() -> UsageData {
    UsageData(
        fiveHour: UsageData.UsageWindow(
            utilization: fiveHour.utilization / 100.0,
            resetsAt: fiveHour.resetsAt
        ),
        sevenDay: UsageData.UsageWindow(
            utilization: sevenDay.utilization / 100.0,
            resetsAt: sevenDay.resetsAt
        ),
        sevenDaySonnet: sevenDaySonnet.map { response in
            UsageData.UsageWindow(
                utilization: response.utilization / 100.0,
                resetsAt: response.resetsAt
            )
        },
        sevenDayOpus: sevenDayOpus.map { response in
            UsageData.UsageWindow(
                utilization: response.utilization / 100.0,
                resetsAt: response.resetsAt
            )
        },
        extraUsage: extraUsage.map { response in
            UsageData.ExtraUsage(
                utilization: response.utilization,
                usedCredits: response.usedCredits,
                monthlyLimit: response.monthlyLimit,
                isEnabled: response.isEnabled
            )
        },
        subscription: "Max",
        lastUpdated: Date()
    )
}
```

**Step 4: Build to verify**

Run: `make build`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/Models/UsageData.swift
git commit -m "$(cat <<'EOF'
feat: parse extra_usage and model quotas from API response

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add Model Quota UI Sections

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

**Step 1: Add Sonnet quota section after Weekly section**

Find the Weekly section (around line 82-89) and add after it:

```swift
// Weekly
usageSection(
    icon: "calendar",
    title: "Weekly",
    window: data.sevenDay,
    color: Color(hex: "F59E0B"),
    resetPrefix: "Resets"
)

// Model-specific quotas
if let sonnet = data.sevenDaySonnet {
    Divider()

    usageSection(
        icon: "sparkles",
        title: "Weekly (Sonnet)",
        window: sonnet,
        color: Color(hex: "A855F7"),
        resetPrefix: "Resets"
    )
}

if let opus = data.sevenDayOpus {
    Divider()

    usageSection(
        icon: "star.fill",
        title: "Weekly (Opus)",
        window: opus,
        color: Color(hex: "EC4899"),
        resetPrefix: "Resets"
    )
}
```

**Step 2: Build to verify**

Run: `make build`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift
git commit -m "$(cat <<'EOF'
feat: display model-specific quotas (Sonnet, Opus) in popover

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Add Extra Usage UI Section

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

**Step 1: Add extraUsageSection helper method**

Add this method after the `hangingAgentsWarning` method (around line 410):

```swift
@ViewBuilder
private func extraUsageSection(extraUsage: UsageData.ExtraUsage) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center) {
            Image(systemName: "dollarsign.circle")
                .foregroundColor(.secondary)
            Text("Extra Usage")
            Spacer()
            Text("\(extraUsage.percentage)%")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
        }

        UsageBarView(progress: extraUsage.utilization / 100.0, color: Color(hex: "10B981"))

        Text("\(extraUsage.usedUSD) / \(extraUsage.limitUSD) this month")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .padding()
}
```

**Step 2: Add extra usage section to body**

Find where model quotas were added (after Opus section) and add:

```swift
if let opus = data.sevenDayOpus {
    Divider()

    usageSection(
        icon: "star.fill",
        title: "Weekly (Opus)",
        window: opus,
        color: Color(hex: "EC4899"),
        resetPrefix: "Resets"
    )
}

// Extra Usage (monthly spending)
if let extraUsage = data.extraUsage, extraUsage.isEnabled {
    Divider()

    extraUsageSection(extraUsage: extraUsage)
}

// Active Agents
```

**Step 3: Build to verify**

Run: `make build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift
git commit -m "$(cat <<'EOF'
feat: display extra usage (monthly spending) in popover

Shows used/limit in USD with progress bar.
Only displays when extra_usage.is_enabled is true.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Manual Testing

**Step 1: Build release version**

Run: `make release`
Expected: Build completes successfully

**Step 2: Launch app**

Run: `open release/ClaudeCodeUsage.app`
Expected: App appears in menu bar

**Step 3: Verify new sections appear**

Click the menu bar icon and verify:
- [ ] 5-Hour Window shows with percentage and reset time
- [ ] Weekly shows with percentage and reset time
- [ ] Weekly (Sonnet) shows if your account has it (purple color)
- [ ] Weekly (Opus) shows if your account has it (pink color)
- [ ] Extra Usage shows with "$X.XX / $Y.YY this month" format (green color)

**Step 4: Verify Debug still works**

Click gear → Debug → "Copy Raw API Response"
Expected: JSON copied to clipboard with all fields

**Step 5: Final commit if any fixes needed**

```bash
git add -A
git commit -m "$(cat <<'EOF'
fix: address any issues from manual testing

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Add ExtraUsage model | UsageData.swift |
| 2 | Extend UsageData struct | UsageData.swift |
| 3 | Update API response decoding | UsageData.swift |
| 4 | Add model quota UI sections | UsagePopoverView.swift |
| 5 | Add extra usage UI section | UsagePopoverView.swift |
| 6 | Manual testing | - |

**Colors used:**
- 5-Hour: `#4ADE80` (green)
- Weekly: `#F59E0B` (amber)
- Sonnet: `#A855F7` (purple)
- Opus: `#EC4899` (pink)
- Extra Usage: `#10B981` (emerald)
