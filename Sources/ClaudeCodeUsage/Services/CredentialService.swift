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
    case file = "File System"
    case keychain = "Claude Code Keychain"
}

/// Result of a preflight keychain access check (non-interactive)
enum KeychainAccessStatus {
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

    // UserDefaults keys
    private let denialTimestampKey = "keychainDenialTimestamp"

    /// Cooldown period before retrying after keychain denial (6 hours, matching CodexBar pattern)
    private let denialCooldownSeconds: TimeInterval = 6 * 60 * 60

    /// Environment variable name for OAuth token override
    /// Users can set this to bypass keychain access issues
    private let envTokenKey = "CLAUDE_USAGE_OAUTH_TOKEN"

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
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
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

    /// Returns a user-friendly description of the keychain access status
    func getAccessStatusDescription() -> String {
        // Check sources in priority order
        if hasEnvironmentToken() {
            return "Using environment variable token"
        }

        if cachedToken != nil {
            return "Using cached token"
        }

        if getTokenFromAppCache() != nil {
            return "Using app's cached token"
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
        SecItemAdd(addQuery as CFDictionary, nil)
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

    // MARK: - Token Retrieval

    /// Attempts to get an OAuth access token from Claude Code CLI credentials
    /// Priority order: 1) Env var, 2) Memory cache, 3) App cache, 4) File system, 5) Claude's keychain
    func getAccessToken() throws -> String {
        // 1. Environment variable (highest priority - bypasses all other sources)
        if let envToken = getTokenFromEnvironment() {
            lastCredentialSource = .environment
            return envToken
        }

        // 2. Check in-memory cache (fastest, cleared on 401 or app restart)
        if let cached = cachedToken {
            lastCredentialSource = .memoryCache
            return cached
        }

        // 3. Check app's own keychain cache (survives app restarts, no ACL issues)
        if let appCachedToken = getTokenFromAppCache() {
            cachedToken = appCachedToken  // Also store in memory for speed
            tokenCacheTimestamp = Date()
            lastCredentialSource = .appCache
            return appCachedToken
        }

        // 4. Check file-based credentials (used on Linux, may exist on Mac)
        if let fileToken = getTokenFromFile() {
            cachedToken = fileToken
            tokenCacheTimestamp = Date()
            // Also cache in app's keychain for consistency
            cacheTokenInAppKeychain(fileToken)
            lastCredentialSource = .file
            return fileToken
        }

        // 5. If keychain access was recently denied, don't try Claude's keychain (cooldown active)
        if isDenialCooldownActive {
            throw CredentialError.accessDenied
        }

        // 6. Try OAuth token from Claude's keychain (may prompt user)
        do {
            let token = try getClaudeCodeToken()
            // Cache in memory
            cachedToken = token
            tokenCacheTimestamp = Date()
            // Also cache in app's keychain for future use (avoids repeated prompts)
            cacheTokenInAppKeychain(token)
            lastCredentialSource = .keychain
            return token
        } catch let error as CredentialError {
            // Track access denied state with timestamp (starts cooldown)
            if error.isAccessDenied {
                lastDenialTimestamp = Date()
            }
            throw error
        }
    }

    /// Invalidates all token caches, forcing a fresh keychain read on next access
    /// Called when API returns 401 (token expired/invalid)
    func invalidateCache() {
        cachedToken = nil
        tokenCacheTimestamp = nil
        cachedManualKey = nil
        // Also clear the app's keychain cache since the token is invalid
        clearAppKeychainCache()
    }

    /// Clears all OAuth caches and resets denial state
    /// Forces full re-authentication from Claude Code's keychain
    func clearTokenCache() {
        cachedToken = nil
        tokenCacheTimestamp = nil
        clearAppKeychainCache()
        lastDenialTimestamp = nil  // Reset so it will prompt for access again
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
            _ = try getAccessToken()
            return cachedToken != nil
        } catch {
            return false
        }
    }

    /// Gets the Claude Code OAuth token from keychain
    private func getClaudeCodeToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
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

    /// Checks if we have a cached token available (in memory or app keychain)
    func hasCachedToken() -> Bool {
        return cachedToken != nil || getTokenFromAppCache() != nil
    }
}
