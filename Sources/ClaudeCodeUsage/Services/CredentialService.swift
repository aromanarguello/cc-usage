import Foundation
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

actor CredentialService {
    private let serviceName = "Claude Code-credentials"
    private let manualKeyService = "ClaudeCodeUsage-apiKey"
    private let manualKeyAccount = "anthropic-api-key"
    private let accessDeniedKey = "keychainAccessDenied"

    // Token cache - cached until invalidated (on 401) or app restart
    private var cachedToken: String?

    // Manual API key cache - cached until invalidated or app restart
    private var cachedManualKey: String?

    // Track if keychain access was denied (persisted to UserDefaults)
    private var lastAccessDenied: Bool {
        get { UserDefaults.standard.bool(forKey: accessDeniedKey) }
        set { UserDefaults.standard.set(newValue, forKey: accessDeniedKey) }
    }

    /// Returns true if the last keychain access attempt was denied
    func wasAccessDenied() -> Bool {
        return lastAccessDenied
    }

    /// Clears the access denied state (for retry button)
    func clearAccessDeniedState() {
        lastAccessDenied = false
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

    /// Attempts to get an OAuth access token from Claude Code CLI credentials
    func getAccessToken() throws -> String {
        // 1. If keychain access was previously denied, don't try keychain access
        if lastAccessDenied {
            throw CredentialError.accessDenied
        }

        // 2. Check OAuth token cache (cached until 401 or app restart)
        if let cached = cachedToken {
            return cached
        }

        // 3. Try OAuth token from keychain
        do {
            let token = try getClaudeCodeToken()
            // Cache the result
            cachedToken = token
            return token
        } catch let error as CredentialError {
            // Track access denied state
            if error.isAccessDenied {
                lastAccessDenied = true
            }
            throw error
        }
    }

    /// Invalidates the token cache, forcing a fresh keychain read on next access
    func invalidateCache() {
        cachedToken = nil
        cachedManualKey = nil
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
        lastAccessDenied = false
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
}
