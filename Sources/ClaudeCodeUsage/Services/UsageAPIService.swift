import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case networkError(Error)
    case decodingError(Error)
    case serverError(Int, String?)

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .unauthorized:
            return "Token expired. Run `claude` in terminal to refresh."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .serverError(let code, let message):
            return "Server error \(code): \(message ?? "Unknown")"
        }
    }
}

actor UsageAPIService {
    private let baseURL = "https://api.anthropic.com/api/oauth/usage"
    private let credentialService: CredentialService
    private var hasAttemptedRefresh = false

    init(credentialService: CredentialService) {
        self.credentialService = credentialService
    }

    func fetchUsage(allowPrompt: Bool = false) async throws -> UsageData {
        do {
            return try await performFetch(allowPrompt: allowPrompt)
        } catch APIError.unauthorized {
            // Invalidate cached credentials - they're no longer valid
            await credentialService.invalidateCache()

            // Try to refresh token by spawning CLI, then retry once
            guard !hasAttemptedRefresh else {
                hasAttemptedRefresh = false
                throw APIError.unauthorized
            }
            hasAttemptedRefresh = true
            defer { hasAttemptedRefresh = false }
            if await triggerTokenRefresh() {
                // Small delay to let keychain update
                try? await Task.sleep(for: .milliseconds(500))
                return try await performFetch(allowPrompt: allowPrompt)
            }
            throw APIError.unauthorized
        }
    }

    private func performFetch(allowPrompt: Bool = false) async throws -> UsageData {
        let accessToken = try await credentialService.getAccessToken(allowPrompt: allowPrompt)

        guard let url = URL(string: baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) : (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200:
            hasAttemptedRefresh = false  // Reset on success
        case 401:
            throw APIError.unauthorized
        default:
            let message = String(data: data, encoding: .utf8)
            throw APIError.serverError(httpResponse.statusCode, message)
        }

        let decoder = JSONDecoder()
        // API returns dates with fractional seconds: 2026-01-23T05:59:59.532731+00:00
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = formatter.date(from: dateString) {
                return date
            }
            // Fallback for dates without fractional seconds
            let basicFormatter = ISO8601DateFormatter()
            basicFormatter.formatOptions = [.withInternetDateTime]
            if let date = basicFormatter.date(from: dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }

        do {
            let apiResponse = try decoder.decode(UsageAPIResponse.self, from: data)
            return apiResponse.toUsageData()
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Fetches raw JSON response for debugging/discovery
    func fetchRawResponse() async throws -> String {
        let accessToken = try await credentialService.getAccessToken()

        guard let url = URL(string: baseURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.serverError((response as? HTTPURLResponse)?.statusCode ?? 0, nil)
        }

        // Pretty print JSON
        if let json = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            return prettyString
        }

        return String(data: data, encoding: .utf8) ?? "Unable to decode response"
    }

    /// Spawns the Claude CLI to trigger its internal token refresh mechanism
    private func triggerTokenRefresh() async -> Bool {
        // Find claude binary - try common locations
        let possiblePaths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]

        let claudePath = possiblePaths.first { FileManager.default.fileExists(atPath: $0) }

        guard let path = claudePath else {
            return false
        }

        do {
            let (_, exitCode) = try await runProcessAsync(
                executablePath: path,
                arguments: ["--version"],
                timeout: Duration.seconds(10)
            )
            return exitCode == 0
        } catch {
            return false
        }
    }
}
