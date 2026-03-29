import Foundation

/// HTTP client for communicating with the agent-memory backend.
///
/// Sends transcribed text to the `/message` endpoint and returns the agent's reply.
/// All network calls are performed with `URLSession.shared` (foreground transfers).
/// Offline resilience (queueing, retry) is handled at a higher level by `MessageQueue`.
///
/// Usage:
/// ```swift
/// let client = NetworkClient()
/// let reply = try await client.send(text: "What's on my calendar today?")
/// ```
final class NetworkClient {

    // MARK: - Init

    private let baseURL: URL
    private let authToken: String
    private let session: URLSession

    init(
        baseURL: URL = LuxConfig.baseURL,
        authToken: String = LuxConfig.authToken,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.session = session
    }

    // MARK: - Public API

    /// POST transcribed text to the agent-memory `/message` endpoint.
    ///
    /// - Parameter text: The user's transcribed message.
    /// - Returns: The agent's reply string.
    /// - Throws: `NetworkClientError` on HTTP or decoding failure, or URLSession errors
    ///   on connectivity problems.
    func send(text: String) async throws -> String {
        let url = baseURL.appendingPathComponent("message")

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(MessageRequest(text: text))

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NetworkClientError.requestFailed(0, "Non-HTTP response")
        }

        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "no body"
            throw NetworkClientError.requestFailed(http.statusCode, detail)
        }

        do {
            return try JSONDecoder().decode(MessageResponse.self, from: data).reply
        } catch {
            throw NetworkClientError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Codable Shapes

    private struct MessageRequest: Encodable {
        let text: String
    }

    private struct MessageResponse: Decodable {
        let reply: String
    }

    // MARK: - Errors

    enum NetworkClientError: LocalizedError {
        case requestFailed(Int, String)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let code, let detail):
                return "Request failed (\(code)): \(detail)"
            case .decodingFailed(let detail):
                return "Failed to decode agent reply: \(detail)"
            }
        }
    }
}
