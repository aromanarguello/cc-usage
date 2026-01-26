# Keychain Prompt Mitigation - Implementation Summary

**Version:** 1.10.0
**Date:** January 25, 2026
**Status:** Shipped

---

## Problem

Users experienced repeated macOS keychain access prompts when the app tried to read Claude Code OAuth credentials. The prompts appeared seemingly "random" even after clicking "Allow".

## Root Cause

**Ad-hoc code signing** during development caused each build to have a unique app identity. macOS keychain ACL grants are tied to app identity (bundle ID + code signature), so:

- Build #1 gets "Always Allow" → ACL entry created for Build #1's signature
- Build #2 has different signature → macOS treats it as a different app → prompts again
- This cycle repeats with every rebuild

## Solution Implemented

### P0: Critical Fixes

#### 1. Fixed Bundle ID Mismatch (`09a06c9`)

**File:** `scripts/build.sh`

The build script had an incorrect bundle ID that didn't match Info.plist:

```bash
# Before
BUNDLE_ID="ClaudeUsageTracker"

# After
BUNDLE_ID="com.claudecodeusage.app"
```

This ensures the app bundle identifier is consistent and matches what's declared in Info.plist.

#### 2. Added Signed Debug Build Target (`6a27768`)

**Files:** `Makefile`, `scripts/build.sh`

Added new make targets for development that produce properly signed builds:

```bash
# New commands
make debug-app    # Build signed debug version
make run-signed   # Build and run signed debug version
```

The `debug-app` target:
- Compiles a debug build with symbols
- Signs it with Developer ID certificate (not ad-hoc)
- Creates a proper app bundle in `release/`

This gives developers a stable app identity during development, eliminating the "new app on every build" problem.

### P1: User Experience

#### 3. First-Run Onboarding View (`2591a3b`, `88c5c36`, `b957d64`)

**Files:**
- `Sources/ClaudeCodeUsage/Views/OnboardingView.swift` (new)
- `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`
- `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

On first launch, users now see an onboarding screen that:
- Explains keychain access is needed for OAuth tokens
- Emphasizes clicking **"Always Allow"** (not just "Allow")
- Sets expectations before the system prompt appears

State is tracked via `@AppStorage("hasCompletedOnboarding")`.

#### 4. "Open Keychain Access" Recovery Button (`ce4a255`)

**File:** `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

If keychain access is denied, the error view now includes:
- Clear explanation of what went wrong
- **"Open Keychain Access"** button that launches `/System/Applications/Utilities/Keychain Access.app`
- Instructions for manually granting access via the Keychain Access app

```swift
private func openKeychainAccess() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app"))
}
```

---

## Commits

| Commit | Description |
|--------|-------------|
| `09a06c9` | Fix BUNDLE_ID to match Info.plist |
| `6a27768` | Add debug-app target for signed development builds |
| `2591a3b` | Add OnboardingView for first-run keychain guidance |
| `88c5c36` | Add onboarding state management to UsageViewModel |
| `b957d64` | Display onboarding view on first run |
| `ce4a255` | Add Open Keychain Access button to denied view |
| `f0d658b` | Bump version to 1.10.0 |

---

## User Impact

### Before (v1.9.x)
- Repeated keychain prompts after every app rebuild
- No guidance on "Always Allow" vs "Allow"
- No recovery path if access denied

### After (v1.10.0)
- Stable app identity with signed builds
- First-run onboarding educates users
- One-click recovery to Keychain Access app
- Prompts stop permanently after "Always Allow"

---

## Developer Workflow

### Old workflow (caused prompts):
```bash
make build && make run  # Ad-hoc signed, unique identity each time
```

### New workflow (stable identity):
```bash
make debug-app          # Developer ID signed, stable identity
# or
make run-signed         # Build + run signed version
```

---

## Technical Notes

### Why Not Sign Debug Builds Automatically?

The default `make build` still produces unsigned builds because:
1. Signing requires Developer ID certificate (not all contributors have one)
2. Faster iteration for non-keychain-related changes
3. CI/CD environments may not have signing credentials

The `debug-app` target is opt-in for developers who need stable keychain access.

### Keychain ACL Behavior

macOS keychain grants access based on:
1. **Bundle Identifier** - must match exactly
2. **Code Signature** - must be from same certificate

With Developer ID signing:
- Certificate is tied to developer account
- All builds signed with same certificate have same "identity"
- "Always Allow" creates a permanent ACL entry that persists across rebuilds

### App Sandbox

The app intentionally does NOT use app sandboxing (`com.apple.security.app-sandbox = false`) because:
- Claude Code CLI creates keychain items outside our app's sandbox
- Sandboxed apps can only access their own keychain items
- Cross-app keychain access requires non-sandboxed entitlement

---

## Files Changed

```
scripts/build.sh                                    # Bundle ID fix + debug-app target
Makefile                                            # New make targets
Sources/ClaudeCodeUsage/Views/OnboardingView.swift  # New - first run UX
Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift # Onboarding + recovery button
Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift # Onboarding state
Resources/Info.plist                                # Version bump
```

---

## Verification

To verify the fix is working:

```bash
# Check app signature
codesign -d -vv release/ClaudeCodeUsage.app

# Should show:
# Identifier=com.claudecodeusage.app
# Authority=Developer ID Application: [Your Name]
# (NOT "Signature=adhoc")
```

---

## Related Documentation

- `docs/KEYCHAIN-INVESTIGATION-SUMMARY.md` - Full investigation details
- `docs/keychain-prompt-mitigation-plan.md` - Original implementation plan
- `docs/keychain-acl-findings.md` - ACL technical deep-dive
