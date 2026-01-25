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
            return "OAuth token not found in credentials."
        case .invalidAPIKeyFormat:
            return "Invalid API key format."
        case .accessDenied:
            return "Keychain access denied. Configure a manual API key in Settings."
        }
    }

    /// Whether this error can be resolved by manual API key entry
    var canUseManualKey: Bool {
        switch self {
        case .notFound, .invalidData, .tokenNotFound, .accessDenied:
            return true
        case .keychainError, .invalidAPIKeyFormat:
            return false
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

    // Token cache to reduce keychain access frequency
    private var cachedToken: String?
    private var tokenCacheTime: Date?
    private let tokenCacheTTL: TimeInterval = 300 // 5 minutes

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

    /// Attempts to get an access token, checking manual API key first, then Claude Code OAuth
    func getAccessToken() throws -> String {
        // 1. If keychain access was previously denied, don't try ANY keychain access
        if lastAccessDenied {
            throw CredentialError.accessDenied
        }

        // 2. Try manual API key first - if user configured one, use it
        do {
            return try getManualAPIKey()
        } catch let error as CredentialError {
            if error.isAccessDenied {
                lastAccessDenied = true
                throw error
            }
            // For notFound or other errors, continue to try OAuth
        } catch {
            // Other errors, continue to try OAuth
        }

        // 3. Check OAuth token cache
        if let cached = cachedToken,
           let cacheTime = tokenCacheTime,
           Date().timeIntervalSince(cacheTime) < tokenCacheTTL {
            return cached
        }

        // 4. Try OAuth token from keychain
        do {
            let token = try getClaudeCodeToken()
            // Cache the result
            cachedToken = token
            tokenCacheTime = Date()
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
        tokenCacheTime = nil
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
            // errSecAuthFailed (-25293): Authentication failed (user denied)
            // errSecInteractionNotAllowed (-25308): User interaction not allowed
            // errSecUserCanceled (-128): User canceled the operation
            if status == errSecAuthFailed ||
               status == errSecInteractionNotAllowed ||
               status == errSecUserCanceled {
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

        // Clear access denied state - user now has a valid credential
        lastAccessDenied = false
    }

    /// Retrieves the manual API key from keychain
    func getManualAPIKey() throws -> String {
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
            if status == errSecAuthFailed ||
               status == errSecInteractionNotAllowed ||
               status == errSecUserCanceled {
                throw CredentialError.accessDenied
            }
            throw CredentialError.keychainError(status)
        }

        guard let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw CredentialError.invalidData
        }

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
    }

    /// Checks if a manual API key is configured
    func hasManualAPIKey() -> Bool {
        return (try? getManualAPIKey()) != nil
    }
}
