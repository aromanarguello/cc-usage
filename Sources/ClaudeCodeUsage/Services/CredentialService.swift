import Foundation
import LocalAuthentication
import Security

enum CredentialError: Error, LocalizedError {
    case notFound
    case invalidData
    case keychainError(OSStatus)
    case tokenNotFound
    case invalidAPIKeyFormat
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Not logged in. Run `claude` in terminal to authenticate."
        case .invalidData:
            return "Invalid credential data format."
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .tokenNotFound:
            return "OAuth token not found. Run `claude` in terminal to authenticate."
        case .invalidAPIKeyFormat:
            return "Invalid API key format."
        case .accessDenied:
            return "Keychain access denied. Click Retry and allow access when prompted."
        }
    }

    /// Whether this error indicates keychain access was denied by the user
    var isAccessDenied: Bool {
        switch self {
        case .accessDenied:
            return true
        default:
            return false
        }
    }
}

/// Tracks where the credential was retrieved from (for debugging)
enum CredentialSource: String {
    case environment = "Environment Variable"
    case memoryCache = "Memory Cache"
    case appCache = "App Keychain Cache"
    case fileCache = "App File Cache"
    case file = "File System"
    case keychain = "Claude Code Keychain"
    case subprocess = "Claude Keychain (subprocess)"
    case setupToken = "Setup Token"
}

/// Result of a preflight keychain access check (non-interactive)
enum KeychainAccessStatus: Equatable {
    case allowed              // Can access without user interaction
    case notFound             // Keychain item doesn't exist
    case interactionRequired  // Will require user to grant access
    case failure(OSStatus)    // Other error occurred
}

actor CredentialService {
    // Claude Code's keychain credentials
    private let serviceName = "Claude Code-credentials"

    // App's own keychain entries
    private let manualKeyService = "ClaudeCodeUsage-apiKey"
    private let manualKeyAccount = "anthropic-api-key"
    private let oauthCacheService = "ClaudeCodeUsage-oauth"
    private let oauthCacheAccount = "cached-token"
    private let setupTokenService = "ClaudeCodeUsage-setup-token"
    private let setupTokenAccount = "setup-token"

    // UserDefaults keys
    private let denialTimestampKey = "keychainDenialTimestamp"

    /// Cooldown period before retrying after keychain denial (6 hours, matching CodexBar pattern)
    private let denialCooldownSeconds: TimeInterval = 6 * 60 * 60

    /// Environment variable name for OAuth token override
    /// Users can set this to bypass keychain access issues
    private let envTokenKey = "CLAUDE_USAGE_OAUTH_TOKEN"

    // App's file-based cache (fallback when keychain ACL broken)
    private var appCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("claudecodeusage")
    }

    private var fileCachePath: URL {
        appCacheDirectory.appendingPathComponent("oauth-cache.json")
    }

    // In-memory token cache - cleared on 401 or app restart
    private var cachedToken: String?

    // Track when token was last cached (for freshness decisions)
    private var tokenCacheTimestamp: Date?

    // Token cache is considered "warm" if cached within last 6 hours
    private var isTokenCacheWarm: Bool {
        guard let timestamp = tokenCacheTimestamp else { return false }
        return Date().timeIntervalSince(timestamp) < 6 * 60 * 60
    }

    /// Tracks where the last successful credential came from
    private(set) var lastCredentialSource: CredentialSource?

    // Manual API key cache - cached until invalidated or app restart
    private var cachedManualKey: String?

    // Track when keychain access was denied (persisted to UserDefaults)
    private var lastDenialTimestamp: Date? {
        get { UserDefaults.standard.object(forKey: denialTimestampKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: denialTimestampKey) }
    }

    /// Whether the denial cooldown period is still active
    private var isDenialCooldownActive: Bool {
        guard let timestamp = lastDenialTimestamp else { return false }
        return Date().timeIntervalSince(timestamp) < denialCooldownSeconds
    }

    /// Returns true if keychain access was denied and cooldown is still active
    func wasAccessDenied() -> Bool {
        return isDenialCooldownActive
    }

    /// Clears the access denied state (for retry button)
    func clearAccessDeniedState() {
        lastDenialTimestamp = nil
    }

    /// Checks if an OSStatus indicates keychain access was denied by user
    private func isAccessDeniedStatus(_ status: OSStatus) -> Bool {
        // errSecAuthFailed (-25293): Authentication failed (user denied)
        // errSecInteractionNotAllowed (-25308): User interaction not allowed
        // errSecUserCanceled (-128): User canceled the operation
        status == errSecAuthFailed ||
        status == errSecInteractionNotAllowed ||
        status == errSecUserCanceled
    }

    // MARK: - Token Validation

    /// Validates OAuth token format (basic sanity check)
    /// OAuth tokens from Claude typically start with specific prefixes
    private func isValidTokenFormat(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Token should be non-empty and have reasonable length
        // Claude OAuth tokens are typically 100+ characters
        guard !trimmed.isEmpty, trimmed.count >= 20, trimmed.count < 10_000 else {
            return false
        }
        // Should not contain newlines or control characters
        guard !trimmed.contains(where: { $0.isNewline || $0.asciiValue ?? 0 < 32 }) else {
            return false
        }
        return true
    }

    // MARK: - Environment Variable Override

    /// Checks for OAuth token in environment variable (highest priority)
    /// This allows users to bypass keychain access issues entirely
    private func getTokenFromEnvironment() -> String? {
        guard let token = Foundation.ProcessInfo().environment[envTokenKey],
              !token.isEmpty,
              isValidTokenFormat(token) else {
            return nil
        }
        return token
    }

    /// Returns true if an environment variable token is configured
    func hasEnvironmentToken() -> Bool {
        return getTokenFromEnvironment() != nil
    }

    // MARK: - Keychain Preflight Check

    /// Checks if Claude's keychain item can be accessed without user interaction
    /// This is useful for determining UI state before triggering a prompt
    func preflightClaudeKeychainAccess() -> KeychainAccessStatus {
        return preflightClaudeKeychainAccessWithData().status
    }

    /// Applies no-UI attributes to a keychain query to prevent prompts.
    /// Note: LAContext.interactionNotAllowed blocks biometric/passcode prompts but does NOT
    /// block macOS ACL "wants to access key" password dialogs for another app's keychain items.
    /// That's why automatic code paths use the subprocess reader instead of direct SecItemCopyMatching.
    private func applyNoUIAttributes(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }

    /// Checks if Claude's keychain item can be accessed without user interaction,
    /// and returns the token if accessible. This avoids a second keychain call.
    private func preflightClaudeKeychainAccessWithData() -> (status: KeychainAccessStatus, token: String?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        applyNoUIAttributes(to: &query)

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            // Extract token from the data
            if let data = result as? Data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let oauthData = json["claudeAiOauth"] as? [String: Any],
               let accessToken = oauthData["accessToken"] as? String {
                return (.allowed, accessToken)
            }
            return (.allowed, nil)
        case errSecItemNotFound:
            return (.notFound, nil)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return (.interactionRequired, nil)
        default:
            return (.failure(status), nil)
        }
    }

    /// Returns a user-friendly description of the keychain access status
    func getAccessStatusDescription() -> String {
        // Check sources in priority order
        if hasEnvironmentToken() {
            return "Using environment variable token"
        }

        if hasSetupToken() {
            return "Using setup token"
        }

        if cachedToken != nil {
            return "Using cached token"
        }

        if getTokenFromAppCache() != nil {
            return "Using app's cached token"
        }

        if getTokenFromFileCache() != nil {
            return "Using app's file-cached token"
        }

        if hasFileCredentials() {
            return "Using file-based credentials"
        }

        // Check Claude's keychain
        switch preflightClaudeKeychainAccess() {
        case .allowed:
            return "Claude keychain accessible"
        case .notFound:
            return "Not logged in to Claude Code"
        case .interactionRequired:
            return "Keychain access requires permission"
        case .failure(let status):
            return "Keychain error: \(status)"
        }
    }

    // MARK: - App's Keychain Token Cache

    /// Saves a token to the app's own keychain cache
    /// This allows future access without requiring permission to Claude's keychain
    private func cacheTokenInAppKeychain(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        // Delete any existing cached token
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oauthCacheService,
            kSecAttrAccount as String: oauthCacheAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new token
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oauthCacheService,
            kSecAttrAccount as String: oauthCacheAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        #if DEBUG
        if status != errSecSuccess {
            print("[CredentialService] Failed to cache token in app keychain: \(status)")
        }
        #endif
    }

    /// Retrieves token from app's own keychain cache
    private func getTokenFromAppCache() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oauthCacheService,
            kSecAttrAccount as String: oauthCacheAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              isValidTokenFormat(token) else {
            return nil
        }

        return token
    }

    /// Deletes the cached token from app's keychain
    private func clearAppKeychainCache() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oauthCacheService,
            kSecAttrAccount as String: oauthCacheAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

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

    /// Clears the file cache
    private func clearFileCache() {
        try? FileManager.default.removeItem(at: fileCachePath)
    }

    // MARK: - File System Credentials

    /// Path to Claude Code's file-based credentials (used on Linux, may exist on Mac)
    private var fileCredentialsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    /// Attempts to read OAuth token from file system
    /// This is a fallback for users who have file-based credentials (e.g., from Linux)
    private func getTokenFromFile() -> String? {
        let fileURL = fileCredentialsPath

        // Security: Verify file exists and is a regular file (not symlink to sensitive location)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)

            // Security: Limit file size to prevent memory exhaustion (1MB max)
            guard data.count < 1_000_000 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauthData = json["claudeAiOauth"] as? [String: Any],
                  let accessToken = oauthData["accessToken"] as? String else {
                return nil
            }

            // Security: Basic token format validation
            guard isValidTokenFormat(accessToken) else {
                return nil
            }

            return accessToken
        } catch {
            return nil
        }
    }

    /// Returns true if file-based credentials exist
    func hasFileCredentials() -> Bool {
        return FileManager.default.fileExists(atPath: fileCredentialsPath.path)
    }

    // MARK: - Subprocess Keychain Read

    /// Reads Claude Code's OAuth token via the `security` CLI subprocess.
    /// Unlike direct SecItemCopyMatching, the subprocess can be killed on timeout,
    /// preventing the actor from blocking on macOS ACL password dialogs.
    private func getClaudeCodeTokenViaSubprocess() async throws -> String {
        let (output, exitCode) = try await runProcessAsync(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", serviceName, "-w"],
            timeout: .seconds(3)
        )

        guard exitCode == 0, !output.isEmpty else {
            throw CredentialError.notFound
        }

        // Parse JSON — same structure as getClaudeCodeToken()
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthData = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauthData["accessToken"] as? String,
              isValidTokenFormat(accessToken) else {
            throw CredentialError.tokenNotFound
        }
        return accessToken
    }

    // MARK: - Token Retrieval

    /// Attempts to get an OAuth access token from Claude Code CLI credentials
    /// Priority order: 1) Env var, 2) Setup token, 3) Memory cache, 4) App keychain cache,
    ///   5) Claude's keychain via subprocess (automatic, killable on timeout),
    ///   6) Claude's keychain via direct SecItemCopyMatching (user-initiated ONLY),
    ///   7) App file cache, 8) File credentials
    func getAccessToken(allowPrompt: Bool = false) async throws -> String {
        #if DEBUG
        print("[CredentialService] getAccessToken called, allowPrompt: \(allowPrompt)")
        #endif

        // 1. Environment variable (highest priority - bypasses all other sources)
        if let envToken = getTokenFromEnvironment() {
            // Also cache to file so app can recover when env var is removed
            cacheTokenInFile(envToken)
            lastCredentialSource = .environment
            return envToken
        }

        // 2. Setup token (long-lived, stored in app's own keychain - never prompts)
        if let setupToken = getSetupToken() {
            cachedToken = setupToken
            tokenCacheTimestamp = Date()
            lastCredentialSource = .setupToken
            return setupToken
        }

        // 3. Check in-memory cache (fastest, cleared on 401 or app restart)
        if let cached = cachedToken {
            lastCredentialSource = .memoryCache
            return cached
        }

        // 4. Check app's own keychain cache (survives app restarts, no ACL issues)
        if let appCachedToken = getTokenFromAppCache() {
            cachedToken = appCachedToken  // Also store in memory for speed
            tokenCacheTimestamp = Date()
            lastCredentialSource = .appCache
            return appCachedToken
        }

        // 5. Try Claude's keychain via subprocess (safe for automatic refreshes).
        // Unlike direct SecItemCopyMatching, the subprocess can be killed on timeout,
        // so it won't block the actor if macOS shows an ACL password dialog.
        if !isDenialCooldownActive {
            #if DEBUG
            print("[CredentialService] Trying subprocess read of Claude's keychain...")
            #endif
            do {
                let token = try await getClaudeCodeTokenViaSubprocess()
                cachedToken = token
                tokenCacheTimestamp = Date()
                cacheTokenInAppKeychain(token)
                cacheTokenInFile(token)
                lastCredentialSource = .subprocess
                #if DEBUG
                print("[CredentialService] Subprocess read succeeded")
                #endif
                return token
            } catch let error as ProcessError where error.isTimeout {
                // Subprocess timed out — likely an ACL prompt appeared.
                // Set denial cooldown to avoid spawning a doomed subprocess every 60s.
                lastDenialTimestamp = Date()
                #if DEBUG
                print("[CredentialService] Subprocess timed out, entering denial cooldown")
                #endif
            } catch {
                #if DEBUG
                print("[CredentialService] Subprocess failed: \(error)")
                #endif
                // Fall through to other sources
            }
        }

        // 6. Try Claude's keychain directly ONLY when user explicitly initiated the action.
        // SecItemCopyMatching on another app's keychain item can show a macOS ACL password
        // prompt that blocks the entire CredentialService actor, freezing all polling.
        if allowPrompt && !isDenialCooldownActive {
            do {
                let token = try getClaudeCodeToken(allowPrompt: true)
                cachedToken = token
                tokenCacheTimestamp = Date()
                cacheTokenInAppKeychain(token)
                cacheTokenInFile(token)
                lastCredentialSource = .keychain
                return token
            } catch let error as CredentialError {
                if error.isAccessDenied {
                    lastDenialTimestamp = Date()
                }
            } catch {
                // Fall through to file-based fallbacks
            }
        }

        // 7. App file cache (for Linux, or when keychain access denied on macOS)
        if let fileCachedToken = getTokenFromFileCache() {
            cachedToken = fileCachedToken
            tokenCacheTimestamp = Date()
            lastCredentialSource = .fileCache
            return fileCachedToken
        }

        // 8. File-based credentials (used on Linux, may exist on Mac)
        if let fileToken = getTokenFromFile() {
            cachedToken = fileToken
            tokenCacheTimestamp = Date()
            // Also cache in app's keychain for consistency
            cacheTokenInAppKeychain(fileToken)
            cacheTokenInFile(fileToken)
            lastCredentialSource = .file
            return fileToken
        }

        // 8. If we got here with denial cooldown active, throw access denied
        if isDenialCooldownActive {
            throw CredentialError.accessDenied
        }

        // 9. No credentials found anywhere
        throw CredentialError.notFound
    }

    /// Invalidates all token caches, forcing a fresh keychain read on next access
    /// Called when API returns 401 (token expired/invalid)
    func invalidateCache() {
        cachedToken = nil
        tokenCacheTimestamp = nil
        cachedManualKey = nil
        // Also clear the app's keychain and file caches since the token is invalid
        clearAppKeychainCache()
        clearFileCache()
    }

    /// Clears all OAuth caches and resets denial state
    /// Forces full re-authentication from Claude Code's keychain
    func clearTokenCache() {
        cachedToken = nil
        tokenCacheTimestamp = nil
        clearAppKeychainCache()
        clearFileCache()
        lastDenialTimestamp = nil  // Reset so it will prompt for access again
    }

    // MARK: - Account Switch Detection

    /// No-op. Account switches are detected via API 401 responses — when the stale
    /// cached token fails, invalidateCache() clears everything and the subprocess
    /// reader picks up the new token from Claude's keychain on the next refresh.
    func syncWithSourceIfNeeded() async -> Bool {
        return false
    }

    /// Attempts to warm the token cache before sleep
    /// This ensures we have a fresh token in the app's keychain cache
    /// Returns true if cache was warmed successfully
    func warmCacheForSleep() async -> Bool {
        // If we already have a warm cache, no need to refresh
        if isTokenCacheWarm && cachedToken != nil {
            return true
        }

        // Try to get token (will cache if successful)
        do {
            _ = try await getAccessToken()
            return cachedToken != nil
        } catch {
            return false
        }
    }

    /// Gets the Claude Code OAuth token from keychain.
    /// When `allowPrompt` is false, uses no-UI attributes to prevent macOS keychain dialogs.
    /// When true, allows the system to show the keychain access prompt.
    private func getClaudeCodeToken(allowPrompt: Bool = false) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if !allowPrompt {
            applyNoUIAttributes(to: &query)
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw CredentialError.notFound
            }
            if isAccessDeniedStatus(status) {
                throw CredentialError.accessDenied
            }
            throw CredentialError.keychainError(status)
        }

        guard let data = result as? Data else {
            throw CredentialError.invalidData
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.invalidData
        }

        // Navigate to claudeAiOauth.accessToken
        guard let oauthData = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauthData["accessToken"] as? String else {
            throw CredentialError.tokenNotFound
        }

        return accessToken
    }

    // MARK: - Manual API Key Management

    /// Validates API key format (basic check for Anthropic key pattern)
    func validateAPIKeyFormat(_ key: String) -> Bool {
        // Anthropic API keys start with "sk-ant-" and have substantial length
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count > 20
    }

    /// Saves a manual API key to the app's own keychain entry
    func saveManualAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard validateAPIKeyFormat(trimmed) else {
            throw CredentialError.invalidAPIKeyFormat
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw CredentialError.invalidData
        }

        // First, try to delete any existing entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualKeyService,
            kSecAttrAccount as String: manualKeyAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add the new key
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualKeyService,
            kSecAttrAccount as String: manualKeyAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status)
        }

        // Update cache with newly saved key
        cachedManualKey = trimmed

        // Clear access denied state - user now has a valid credential
        lastDenialTimestamp = nil
    }

    /// Retrieves the manual API key from keychain
    func getManualAPIKey() throws -> String {
        // Check cache first (cached until 401 or app restart)
        if let cached = cachedManualKey {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualKeyService,
            kSecAttrAccount as String: manualKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw CredentialError.notFound
            }
            // Detect user denial of keychain access
            if isAccessDeniedStatus(status) {
                throw CredentialError.accessDenied
            }
            throw CredentialError.keychainError(status)
        }

        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw CredentialError.invalidData
        }

        // Cache the result
        cachedManualKey = key

        return key
    }

    /// Deletes the manual API key from keychain
    func deleteManualAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: manualKeyService,
            kSecAttrAccount as String: manualKeyAccount
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychainError(status)
        }

        // Clear the cache
        cachedManualKey = nil
    }

    /// Checks if a manual API key is configured
    func hasManualAPIKey() -> Bool {
        return (try? getManualAPIKey()) != nil
    }

    /// Checks if we have a cached token available (in memory, app keychain, or file cache)
    func hasCachedToken() -> Bool {
        return cachedToken != nil || getTokenFromAppCache() != nil || getTokenFromFileCache() != nil
    }

    /// Returns true if we have a recently cached token that's likely still valid
    /// This is a stronger signal than hasCachedToken() for automatic refresh decisions
    func hasWarmCachedToken() -> Bool {
        return isTokenCacheWarm && cachedToken != nil
    }

    // MARK: - Setup Token (Long-Lived)

    /// Saves a setup token from `claude setup-token` to app's own keychain
    func saveSetupToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidTokenFormat(trimmed) else {
            throw CredentialError.invalidAPIKeyFormat
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw CredentialError.invalidData
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: setupTokenService,
            kSecAttrAccount as String: setupTokenAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: setupTokenService,
            kSecAttrAccount as String: setupTokenAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status)
        }

        cachedToken = trimmed
        tokenCacheTimestamp = Date()
    }

    /// Retrieves setup token from app's own keychain
    func getSetupToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: setupTokenService,
            kSecAttrAccount as String: setupTokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              isValidTokenFormat(token) else {
            return nil
        }
        return token
    }

    /// Removes setup token and reverts to keychain-based flow
    func clearSetupToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: setupTokenService,
            kSecAttrAccount as String: setupTokenAccount
        ]
        SecItemDelete(query as CFDictionary)
        cachedToken = nil
        tokenCacheTimestamp = nil
    }

    /// Returns true if a setup token is configured
    func hasSetupToken() -> Bool {
        return getSetupToken() != nil
    }
}
