# Credential Fallback Implementation Plan

**Goal**: Make credential retrieval more resilient by adding multiple fallback mechanisms, inspired by CodexBar's approach.

**Current State**: Single source (Claude's keychain item) → fails if ACL denies access

**Target State**: Multiple sources with graceful fallbacks → works even if primary source fails

---

## Revised Implementation Order (Updated 2026-01-26)

Based on diagnostic feedback from GitHub Issue #3:
- Keychain item **exists** but app lacks ACL permission to read it
- File-based credentials (`~/.claude/.credentials.json`) **do not exist** for affected users

**New priority order:**
1. **Phase 2: Environment Variable** - Immediate workaround for power users
2. **Phase 4: App's Keychain Cache** - Cache after one successful grant
3. **Phase 3: Preflight Check** - Better error messages for ACL issues
4. **Phase 1: File Fallback** - Still useful for Linux/cross-platform users
5. **Phase 5: Debug Mode** - Support tooling

---

## Phase 1: File System Fallback

**Priority**: Low (Most macOS users don't have this file)

### Task 1.1: Add File-Based Credential Reading

**What**: Check `~/.claude/.credentials.json` when keychain access fails.

**Why**: This file exists on Linux and may exist on macOS for users who:
- Sync dotfiles across machines
- Used older Claude Code versions
- Have alternative installation methods

**Implementation**:

```swift
// In CredentialService.swift

/// Path to Claude Code's file-based credentials (used on Linux, may exist on Mac)
private var fileCredentialsPath: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
        .appendingPathComponent(".credentials.json")
}

/// Attempts to read OAuth token from file system
private func getTokenFromFile() throws -> String {
    let fileURL = fileCredentialsPath

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw CredentialError.notFound
    }

    let data = try Data(contentsOf: fileURL)

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauthData = json["claudeAiOauth"] as? [String: Any],
          let accessToken = oauthData["accessToken"] as? String else {
        throw CredentialError.tokenNotFound
    }

    return accessToken
}
```

**Files to modify**:
- `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

**Testing**:
1. Create test file at `~/.claude/.credentials.json` with valid structure
2. Block keychain access
3. Verify app reads from file

---

### Task 1.2: Update getAccessToken() with File Fallback

**What**: Modify the main token retrieval method to try file system after keychain fails.

**Implementation**:

```swift
func getAccessToken() throws -> String {
    // 1. Check cached token
    if let cached = cachedToken {
        return cached
    }

    // 2. If previously denied, skip keychain and try file
    if lastAccessDenied {
        // Try file fallback before giving up
        if let fileToken = try? getTokenFromFile() {
            cachedToken = fileToken
            return fileToken
        }
        throw CredentialError.accessDenied
    }

    // 3. Try keychain first
    do {
        let token = try getClaudeCodeToken()
        cachedToken = token
        return token
    } catch let error as CredentialError {
        // 4. On keychain failure, try file fallback
        if let fileToken = try? getTokenFromFile() {
            cachedToken = fileToken
            return fileToken
        }

        // Track access denied state
        if error.isAccessDenied {
            lastAccessDenied = true
        }
        throw error
    }
}
```

**Files to modify**:
- `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

---

### Task 1.3: Add Credential Source Tracking

**What**: Track where credentials came from for debugging/UI purposes.

**Implementation**:

```swift
enum CredentialSource {
    case keychain
    case file
    case environment
    case cached
}

// Add to CredentialService
private(set) var lastCredentialSource: CredentialSource?

// Update getAccessToken() to set this when returning a token
```

**Why**: Helps with debugging and could show users where their credentials are being read from.

---

## Phase 2: Environment Variable Override

**Priority**: Medium (Useful for power users, CI/CD, debugging)

### Task 2.1: Add Environment Variable Check

**What**: Check for `CLAUDE_USAGE_OAUTH_TOKEN` environment variable as highest priority.

**Why**:
- Allows users to bypass keychain issues entirely
- Useful for CI/CD environments
- Debugging aid

**Implementation**:

```swift
/// Environment variable name for OAuth token override
private let envTokenKey = "CLAUDE_USAGE_OAUTH_TOKEN"

/// Checks for token in environment variable
private func getTokenFromEnvironment() -> String? {
    ProcessInfo.processInfo.environment[envTokenKey]
}
```

**Update getAccessToken()**:

```swift
func getAccessToken() throws -> String {
    // 0. Environment variable (highest priority)
    if let envToken = getTokenFromEnvironment() {
        lastCredentialSource = .environment
        return envToken
    }

    // 1. Check cached token
    if let cached = cachedToken {
        lastCredentialSource = .cached
        return cached
    }

    // ... rest of method
}
```

**Files to modify**:
- `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

---

### Task 2.2: Document Environment Variable

**What**: Add documentation for the environment variable option.

**Where**: README.md or help text in app

**Content**:
```markdown
## Troubleshooting

If you're having keychain access issues, you can set the OAuth token directly:

```bash
export CLAUDE_USAGE_OAUTH_TOKEN="your-token-here"
```

To get your token, run:
```bash
security find-generic-password -s "Claude Code-credentials" -w | jq -r '.claudeAiOauth.accessToken'
```
```

---

## Phase 3: Keychain Preflight Check

**Priority**: Medium (Better UX, prevents repeated prompts)

### Task 3.1: Add LAContext Preflight

**What**: Before querying keychain, check if it will require user interaction.

**Why**:
- Avoid triggering prompts when we know they'll fail
- Provide better error messages
- Can skip to fallbacks proactively

**Implementation**:

```swift
import LocalAuthentication

enum KeychainAccessStatus {
    case allowed          // Can access without prompt
    case notFound         // Item doesn't exist
    case interactionRequired  // Will prompt user
    case failure(OSStatus)    // Other error
}

/// Checks keychain access status without triggering prompts
private func preflightKeychainAccess() -> KeychainAccessStatus {
    let context = LAContext()
    context.interactionNotAllowed = true

    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: serviceName,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
        kSecUseAuthenticationContext as String: context
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    switch status {
    case errSecSuccess:
        return .allowed
    case errSecItemNotFound:
        return .notFound
    case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
        return .interactionRequired
    default:
        return .failure(status)
    }
}
```

**Files to modify**:
- `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

**Note**: Requires adding `LocalAuthentication` framework to the project.

---

### Task 3.2: Use Preflight in Token Retrieval

**What**: Integrate preflight check into the credential flow.

**Implementation**:

```swift
func getAccessToken() throws -> String {
    // ... environment and cache checks ...

    // Preflight: check if keychain access will prompt
    let preflightStatus = preflightKeychainAccess()

    switch preflightStatus {
    case .allowed:
        // Safe to query keychain
        let token = try getClaudeCodeToken()
        cachedToken = token
        lastCredentialSource = .keychain
        return token

    case .notFound:
        // Item doesn't exist, try file fallback
        if let fileToken = try? getTokenFromFile() {
            cachedToken = fileToken
            lastCredentialSource = .file
            return fileToken
        }
        throw CredentialError.notFound

    case .interactionRequired:
        // Would prompt user - try fallbacks first
        if let fileToken = try? getTokenFromFile() {
            cachedToken = fileToken
            lastCredentialSource = .file
            return fileToken
        }
        // No fallback available, will need to prompt
        let token = try getClaudeCodeToken()
        cachedToken = token
        lastCredentialSource = .keychain
        return token

    case .failure(let status):
        throw CredentialError.keychainError(status)
    }
}
```

---

## Phase 4: App's Own Keychain Cache

**Priority**: Low (Nice to have, reduces prompts long-term)

### Task 4.1: Cache Token in App's Keychain

**What**: After successfully reading Claude's token, store a copy in app's own keychain entry.

**Why**:
- Future reads don't require accessing Claude's restricted item
- Users grant permission once, never again
- Survives app restarts

**Implementation**:

```swift
private let cachedTokenService = "ClaudeCodeUsage-cachedToken"
private let cachedTokenAccount = "oauth-token-cache"

/// Saves token to app's own keychain cache
private func cacheTokenInKeychain(_ token: String) {
    guard let data = token.data(using: .utf8) else { return }

    // Delete existing
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: cachedTokenService,
        kSecAttrAccount as String: cachedTokenAccount
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    // Add new
    let addQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: cachedTokenService,
        kSecAttrAccount as String: cachedTokenAccount,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
    ]
    SecItemAdd(addQuery as CFDictionary, nil)
}

/// Retrieves token from app's own keychain cache
private func getTokenFromCache() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: cachedTokenService,
        kSecAttrAccount as String: cachedTokenAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess,
          let data = result as? Data,
          let token = String(data: data, encoding: .utf8) else {
        return nil
    }

    return token
}
```

**Files to modify**:
- `Sources/ClaudeCodeUsage/Services/CredentialService.swift`

---

### Task 4.2: Integrate Cache into Flow

**What**: Add app's keychain cache as a credential source.

**Updated priority order**:
1. Environment variable
2. In-memory cache
3. **App's keychain cache** (new)
4. File system
5. Claude's keychain (may prompt)

---

### Task 4.3: Cache Invalidation

**What**: Clear the cached token when it fails (401 error).

**Implementation**: Update `invalidateCache()` to also delete the keychain-cached token.

```swift
func invalidateCache() {
    cachedToken = nil
    cachedManualKey = nil

    // Also clear keychain cache
    let deleteQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: cachedTokenService,
        kSecAttrAccount as String: cachedTokenAccount
    ]
    SecItemDelete(deleteQuery as CFDictionary)
}
```

---

## Phase 5: Debug Mode

**Priority**: Low (Helpful for support, not critical)

### Task 5.1: Add Credential Debug Info

**What**: Expose diagnostic information for troubleshooting.

**Implementation**:

```swift
struct CredentialDiagnostics {
    let keychainItemExists: Bool
    let keychainAccessStatus: KeychainAccessStatus
    let fileCredentialsExist: Bool
    let environmentVariableSet: Bool
    let appCacheExists: Bool
    let lastSource: CredentialSource?
    let lastError: String?
}

func getDiagnostics() -> CredentialDiagnostics {
    // Gather all diagnostic info
}
```

### Task 5.2: Add Debug View in Settings

**What**: Add a "Debug" section in settings showing credential status.

**UI**:
```
┌─────────────────────────────────────┐
│ Credential Status                   │
├─────────────────────────────────────┤
│ Keychain item:     ✓ Found          │
│ Keychain access:   ⚠ Requires prompt│
│ File credentials:  ✗ Not found      │
│ Environment var:   ✗ Not set        │
│ App cache:         ✓ Valid          │
│ Current source:    App cache        │
├─────────────────────────────────────┤
│ [Copy Diagnostics]                  │
└─────────────────────────────────────┘
```

---

## Implementation Order

### Recommended sequence:

```
Phase 1 (File Fallback)     ← Start here, biggest impact
    ↓
Phase 2 (Environment Var)   ← Quick addition
    ↓
Phase 3 (Preflight)         ← Better UX
    ↓
Phase 4 (App Cache)         ← Long-term fix
    ↓
Phase 5 (Debug Mode)        ← Support tooling
```

### Estimated complexity:

| Phase | Tasks | Complexity | Files Changed |
|-------|-------|------------|---------------|
| 1     | 3     | Low        | 1             |
| 2     | 2     | Low        | 1-2           |
| 3     | 2     | Medium     | 1             |
| 4     | 3     | Medium     | 1             |
| 5     | 2     | Medium     | 2-3           |

---

## Testing Checklist

### Phase 1
- [ ] Token read from file when keychain blocked
- [ ] File not found handled gracefully
- [ ] Invalid JSON in file handled gracefully
- [ ] Correct JSON structure parsed correctly

### Phase 2
- [ ] Environment variable takes priority
- [ ] Empty env var ignored
- [ ] Works with valid token value

### Phase 3
- [ ] Preflight detects accessible item
- [ ] Preflight detects missing item
- [ ] Preflight detects interaction required
- [ ] Fallbacks used when interaction required

### Phase 4
- [ ] Token cached after successful read
- [ ] Cached token used on subsequent reads
- [ ] Cache cleared on 401 error
- [ ] Cache cleared on explicit invalidation

### Phase 5
- [ ] All diagnostic fields populated
- [ ] Copy diagnostics works
- [ ] UI updates reflect current state

---

## Rollback Plan

Each phase is independent and can be reverted:

- **Phase 1**: Remove file reading code, revert `getAccessToken()`
- **Phase 2**: Remove environment variable check
- **Phase 3**: Remove LAContext import and preflight code
- **Phase 4**: Remove app cache keychain operations
- **Phase 5**: Remove debug view and diagnostics struct
