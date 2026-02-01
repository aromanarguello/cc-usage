# File Cache Fallback Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add file-based credential cache as fallback when keychain ACLs break.

**Architecture:** Insert file cache layer between app keychain and Claude's file credentials. When any source succeeds, cache to both keychain AND file. File cache is immune to code signing changes.

**Tech Stack:** Swift FileManager, JSONSerialization, POSIX permissions

---

## Task 1: Add File Cache Path Properties

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift:58-95`

**Step 1: Add path properties after line 76 (envTokenKey)**

Add these computed properties inside the `CredentialService` actor:

```swift
// App's file-based cache (fallback when keychain ACL broken)
private var appCacheDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config")
        .appendingPathComponent("claudecodeusage")
}

private var fileCachePath: URL {
    appCacheDirectory.appendingPathComponent("oauth-cache.json")
}
```

**Step 2: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): add file cache path properties"
```

---

## Task 2: Add File Cache Write Method

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

**Step 1: Add cacheTokenInFile method after clearAppKeychainCache() (line ~289)**

```swift
// MARK: - App's File Token Cache

/// Saves token to file cache (fallback when keychain ACL is broken)
private func cacheTokenInFile(_ token: String) {
    do {
        try FileManager.default.createDirectory(
            at: appCacheDirectory,
            withIntermediateDirectories: true
        )

        let payload: [String: String] = [
            "token": token,
            "cached": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: fileCachePath, options: [.atomic])

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileCachePath.path
        )
    } catch {
        #if DEBUG
        print("[CredentialService] Failed to cache token in file: \(error)")
        #endif
    }
}
```

**Step 2: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): add file cache write method"
```

---

## Task 3: Add File Cache Read Method

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

**Step 1: Add getTokenFromFileCache method after cacheTokenInFile**

```swift
/// Retrieves token from file cache
private func getTokenFromFileCache() -> String? {
    guard FileManager.default.fileExists(atPath: fileCachePath.path) else {
        return nil
    }

    do {
        let data = try Data(contentsOf: fileCachePath)
        guard data.count < 100_000 else { return nil }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              isValidTokenFormat(token) else {
            return nil
        }
        return token
    } catch {
        return nil
    }
}
```

**Step 2: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): add file cache read method"
```

---

## Task 4: Add File Cache Clear Method

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

**Step 1: Add clearFileCache method after getTokenFromFileCache**

```swift
/// Clears the file cache
private func clearFileCache() {
    try? FileManager.default.removeItem(at: fileCachePath)
}
```

**Step 2: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): add file cache clear method"
```

---

## Task 5: Add CredentialSource.fileCache Enum Case

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift:41-48`

**Step 1: Add fileCache case to CredentialSource enum**

Update the enum to:

```swift
/// Tracks where the credential was retrieved from (for debugging)
enum CredentialSource: String {
    case environment = "Environment Variable"
    case memoryCache = "Memory Cache"
    case appCache = "App Keychain Cache"
    case fileCache = "App File Cache"
    case file = "File System"
    case keychain = "Claude Code Keychain"
}
```

**Step 2: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): add fileCache credential source"
```

---

## Task 6: Integrate File Cache into getAccessToken()

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift:346-399`

**Step 1: Add file cache read between app keychain and file credentials**

Find the comment `// 4. Check file-based credentials` (around line 367) and insert BEFORE it:

```swift
// 4. Check app's file cache (fallback when keychain ACL broken)
if let fileCachedToken = getTokenFromFileCache() {
    cachedToken = fileCachedToken
    tokenCacheTimestamp = Date()
    lastCredentialSource = .fileCache
    return fileCachedToken
}
```

Then renumber the subsequent comments:
- `// 4. Check file-based credentials` → `// 5. Check file-based credentials`
- `// 5. If keychain access was recently denied` → `// 6. If keychain access was recently denied`
- `// 6. Try OAuth token from Claude's keychain` → `// 7. Try OAuth token from Claude's keychain`

**Step 2: Add file caching when reading from file credentials (around line 368-375)**

Update the file credentials block to also cache to file:

```swift
// 5. Check file-based credentials (used on Linux, may exist on Mac)
if let fileToken = getTokenFromFile() {
    cachedToken = fileToken
    tokenCacheTimestamp = Date()
    cacheTokenInAppKeychain(fileToken)
    cacheTokenInFile(fileToken)  // NEW
    lastCredentialSource = .file
    return fileToken
}
```

**Step 3: Add file caching when reading from Claude's keychain (around line 383-391)**

Update the Claude keychain success block to also cache to file:

```swift
do {
    let token = try getClaudeCodeToken()
    cachedToken = token
    tokenCacheTimestamp = Date()
    cacheTokenInAppKeychain(token)
    cacheTokenInFile(token)  // NEW
    lastCredentialSource = .keychain
    return token
} catch let error as CredentialError {
```

**Step 4: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): integrate file cache into token retrieval"
```

---

## Task 7: Update invalidateCache() to Clear File

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift:401-409`

**Step 1: Add clearFileCache() call to invalidateCache()**

```swift
func invalidateCache() {
    cachedToken = nil
    tokenCacheTimestamp = nil
    cachedManualKey = nil
    clearAppKeychainCache()
    clearFileCache()
}
```

**Step 2: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): clear file cache on invalidation"
```

---

## Task 8: Update clearTokenCache() to Clear File

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift:411-418`

**Step 1: Add clearFileCache() call to clearTokenCache()**

```swift
func clearTokenCache() {
    cachedToken = nil
    tokenCacheTimestamp = nil
    clearAppKeychainCache()
    clearFileCache()
    lastDenialTimestamp = nil
}
```

**Step 2: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): clear file cache on token reset"
```

---

## Task 9: Update hasCachedToken() to Include File Cache

**Files:**
- Modify: `Sources/ClaudeCodeUsage/Services/CredentialService.swift:592-595`

**Step 1: Update hasCachedToken to check file cache**

```swift
func hasCachedToken() -> Bool {
    return cachedToken != nil || getTokenFromAppCache() != nil || getTokenFromFileCache() != nil
}
```

**Step 2: Verify build**

Run: `make build`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/ClaudeCodeUsage/Services/CredentialService.swift
git commit -m "feat(credentials): include file cache in hasCachedToken check"
```

---

## Task 10: Integration Test

**Step 1: Build release version**

Run: `make release`
Expected: BUILD SUCCEEDED, app in `release/ClaudeCodeUsage.app`

**Step 2: Install and launch with env var to populate caches**

```bash
pkill ClaudeCodeUsage 2>/dev/null
cp -R release/ClaudeCodeUsage.app /Applications/
TOKEN=$(security find-generic-password -s 'Claude Code-credentials' -w | /usr/bin/jq -r '.claudeAiOauth.accessToken')
CLAUDE_USAGE_OAUTH_TOKEN="$TOKEN" /Applications/ClaudeCodeUsage.app/Contents/MacOS/ClaudeCodeUsage &
```

Wait for app to show usage data, then quit.

**Step 3: Verify file cache was created**

Run: `cat ~/.config/claudecodeusage/oauth-cache.json`
Expected: `{"token":"sk-ant-...","cached":"2026-..."}`

Run: `ls -la ~/.config/claudecodeusage/oauth-cache.json`
Expected: `-rw-------` (permissions 600)

**Step 4: Test recovery from broken keychain**

```bash
# Delete app's keychain entry
security delete-generic-password -s 'ClaudeCodeUsage-oauth' 2>/dev/null

# Restart without env var - should recover from file cache
pkill ClaudeCodeUsage
open /Applications/ClaudeCodeUsage.app
```

Expected: App shows usage data (recovered from file cache)

**Step 5: Commit completion**

```bash
git add -A
git commit -m "feat(credentials): file cache fallback complete

Adds ~/.config/claudecodeusage/oauth-cache.json as fallback when
keychain ACLs break due to code signing changes. Self-healing:
any successful credential read populates both caches."
```

---

## Verification Summary

| Test | Command | Expected |
|------|---------|----------|
| Build | `make build` | BUILD SUCCEEDED |
| File created | `cat ~/.config/claudecodeusage/oauth-cache.json` | JSON with token |
| Permissions | `ls -la ~/.config/claudecodeusage/oauth-cache.json` | `-rw-------` |
| Recovery | Delete keychain, restart app | Shows usage data |
| Clear | Use "Reset Authentication" in app | Both caches cleared |
