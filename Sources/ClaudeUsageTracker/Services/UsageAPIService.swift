import Foundation

enum APIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case networkError(Error)
    case decodingError(Error)
    case serverError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .unauthorized:
            return "Session expired. Re-login to Claude Code."
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

    init(credentialService: CredentialService) {
        self.credentialService = credentialService
    }

    func fetchUsage() async throws -> UsageData {
        let accessToken = try await credentialService.getAccessToken()

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
            break
        case 401:
            throw APIError.unauthorized
        default:
            let message = String(data: data, encoding: .utf8)
            throw APIError.serverError(httpResponse.statusCode, message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let apiResponse = try decoder.decode(UsageAPIResponse.self, from: data)
            return apiResponse.toUsageData()
        } catch {
            throw APIError.decodingError(error)
        }
    }
}
