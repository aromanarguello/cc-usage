# Credential Service Improvements Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address code review suggestions to improve CredentialService consistency, performance, and UX.

**Architecture:** Refactor CredentialService to add manual API key caching, extract duplicate code to helper functions, add "Retry Keychain" button to UI, and fix minor inconsistencies.

**Tech Stack:** Swift 6.0, SwiftUI, Security framework (Keychain)

---

## Task 1: Fix clearAccessDeniedState() Inconsistency

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift:73-75`

**Step 1: Update clearAccessDeniedState() to use the property setter**

Change from:
```swift
func clearAccessDeniedState() {
    UserDefaults.standard.removeObject(forKey: accessDeniedKey)
}
```

To:
```swift
func clearAccessDeniedState() {
    lastAccessDenied = false
}
```

**Step 2: Build to verify no errors**

Run: `make build`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "refactor: use property setter in clearAccessDeniedState()"
```

---

## Task 2: Extract Access Denied Status Check Helper

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

**Step 1: Add helper function after line 75**

Add this private helper function:
```swift
/// Checks if an OSStatus indicates keychain access was denied by user
private func isAccessDeniedStatus(_ status: OSStatus) -> Bool {
    // errSecAuthFailed (-25293): Authentication failed (user denied)
    // errSecInteractionNotAllowed (-25308): User interaction not allowed
    // errSecUserCanceled (-128): User canceled the operation
    status == errSecAuthFailed ||
    status == errSecInteractionNotAllowed ||
    status == errSecUserCanceled
}
```

**Step 2: Update getClaudeCodeToken() to use helper**

In `getClaudeCodeToken()` around line 146-150, change from:
```swift
if status == errSecAuthFailed ||
   status == errSecInteractionNotAllowed ||
   status == errSecUserCanceled {
    throw CredentialError.accessDenied
}
```

To:
```swift
if isAccessDeniedStatus(status) {
    throw CredentialError.accessDenied
}
```

**Step 3: Update getManualAPIKey() to use helper**

In `getManualAPIKey()` around line 237-241, change from:
```swift
if status == errSecAuthFailed ||
   status == errSecInteractionNotAllowed ||
   status == errSecUserCanceled {
    throw CredentialError.accessDenied
}
```

To:
```swift
if isAccessDeniedStatus(status) {
    throw CredentialError.accessDenied
}
```

**Step 4: Build to verify no errors**

Run: `make build`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "refactor: extract isAccessDeniedStatus() helper to reduce duplication"
```

---

## Task 3: Add Manual API Key Caching

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

**Step 1: Add cache variables after line 59**

After the OAuth token cache variables, add:
```swift
// Manual API key cache to reduce keychain access frequency
private var cachedManualKey: String?
private var manualKeyCacheTime: Date?
private let manualKeyCacheTTL: TimeInterval = 300 // 5 minutes
```

**Step 2: Update getManualAPIKey() to use cache**

At the beginning of `getManualAPIKey()`, before the keychain query, add cache check:
```swift
func getManualAPIKey() throws -> String {
    // Check cache first
    if let cached = cachedManualKey,
       let cacheTime = manualKeyCacheTime,
       Date().timeIntervalSince(cacheTime) < manualKeyCacheTTL {
        return cached
    }

    let query: [String: Any] = [
        // ... existing code
```

And at the end before returning, cache the result:
```swift
    guard let data = result as? Data,
          let key = String(data: data, encoding: .utf8) else {
        throw CredentialError.invalidData
    }

    // Cache the result
    cachedManualKey = key
    manualKeyCacheTime = Date()

    return key
}
```

**Step 3: Update invalidateCache() to clear manual key cache too**

Change:
```swift
func invalidateCache() {
    cachedToken = nil
    tokenCacheTime = nil
}
```

To:
```swift
func invalidateCache() {
    cachedToken = nil
    tokenCacheTime = nil
    cachedManualKey = nil
    manualKeyCacheTime = nil
}
```

**Step 4: Update saveManualAPIKey() to update cache**

After saving successfully and before `lastAccessDenied = false`, add:
```swift
// Update cache with newly saved key
cachedManualKey = trimmed
manualKeyCacheTime = Date()

// Clear access denied state - user now has a valid credential
lastAccessDenied = false
```

**Step 5: Update deleteManualAPIKey() to clear cache**

At the end of `deleteManualAPIKey()`, add:
```swift
// Clear the cache
cachedManualKey = nil
manualKeyCacheTime = nil
```

**Step 6: Build to verify no errors**

Run: `make build`
Expected: Build succeeds

**Step 7: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat: add caching for manual API key to reduce keychain access"
```

---

## Task 4: Add Retry Keychain Button to UI

**Files:**
- Modify: `Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift`
- Modify: `Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift`

**Step 1: Add retryKeychainAccess() method to UsageViewModel**

After `forceRefresh()` method around line 68, add:
```swift
/// Clears keychain access denied state and retries
func retryKeychainAccess() async {
    await credentialService.clearAccessDeniedState()
    await credentialService.invalidateCache()
    self.keychainAccessDenied = false
    await refresh()
}
```

**Step 2: Add Retry button to keychainDeniedView() in UsagePopoverView**

In `keychainDeniedView()`, after the help text HStack and before the closing `.padding(24)`, add a retry button:

```swift
            // Help text
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                Text("Stored securely in Keychain")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)

            // Retry keychain access link
            Button(action: {
                Task { await viewModel.retryKeychainAccess() }
            }) {
                Text("Retry Keychain Access")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
```

**Step 3: Build to verify no errors**

Run: `make build`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add Sources/ClaudeCodeUsage/ViewModels/UsageViewModel.swift Sources/ClaudeCodeUsage/Views/UsagePopoverView.swift
git commit -m "feat: add 'Retry Keychain Access' button to keychain denied view"
```

---

## Task 5: Build and Test Release

**Step 1: Build release version**

Run: `make release`
Expected: Universal binary built successfully

**Step 2: Test the app**

Run: `open /Users/alejandroroman/Code/cc-usage/release/ClaudeCodeUsage.app`

Manual verification:
1. If keychain access is denied, verify "Retry Keychain Access" link appears
2. Click "Retry Keychain Access" - should prompt for keychain again
3. If you have an API key saved, verify it loads without repeated keychain prompts (caching working)

**Step 3: Final commit with version bump (optional)**

If all tests pass and you want to release:
```bash
# Update version in Resources/Info.plist and scripts/build.sh
git add -A
git commit -m "chore: credential service improvements from code review"
```

---

## Summary of Changes

| Task | Description | Files |
|------|-------------|-------|
| 1 | Fix clearAccessDeniedState() inconsistency | CredentialService.swift |
| 2 | Extract isAccessDeniedStatus() helper | CredentialService.swift |
| 3 | Add manual API key caching | CredentialService.swift |
| 4 | Add "Retry Keychain Access" button | UsageViewModel.swift, UsagePopoverView.swift |
| 5 | Build and test release | - |

**Note:** Task order matters - Task 2 should be done before Task 3 since Task 3 modifies similar areas.
