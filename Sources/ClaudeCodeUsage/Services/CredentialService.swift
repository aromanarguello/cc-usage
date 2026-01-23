import Foundation
import Security

enum CredentialError: Error, LocalizedError {
    case notFound
    case invalidData
    case keychainError(OSStatus)
    case tokenNotFound
    case invalidAPIKeyFormat

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
        }
    }

    /// Whether this error can be resolved by manual API key entry
    var canUseManualKey: Bool {
        switch self {
        case .notFound, .invalidData, .tokenNotFound:
            return true
        case .keychainError, .invalidAPIKeyFormat:
            return false
        }
    }
}

actor CredentialService {
    private let serviceName = "Claude Code-credentials"
    private let manualKeyService = "ClaudeCodeUsage-apiKey"
    private let manualKeyAccount = "anthropic-api-key"

    /// Attempts to get an access token, trying Claude Code credentials first, then manual API key
    func getAccessToken() throws -> String {
        // First, try to get Claude Code's OAuth token
        do {
            return try getClaudeCodeToken()
        } catch {
            // If that fails, try manual API key as fallback
            if let manualKey = try? getManualAPIKey() {
                return manualKey
            }
            // Re-throw the original error if no manual key
            throw error
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
