import Foundation

/// Build-time configuration for the Lux iOS app.
///
/// For local development: update `defaultBaseURL` and `authToken` directly.
/// For distribution: consider migrating `authToken` to Keychain.
///
/// The auth token must match the `AGENT_MEMORY_AUTH_TOKEN` environment variable
/// set on the agent-memory backend server.
enum LuxConfig {

    // MARK: - Backend

    /// Base URL of the agent-memory backend.
    ///
    /// Override by setting `LUX_BASE_URL` in the scheme's environment variables
    /// (Product > Scheme > Edit Scheme > Run > Environment Variables), or change
    /// `defaultBaseURL` below for a permanent build-time override.
    static var baseURL: URL {
        if let raw = ProcessInfo.processInfo.environment["LUX_BASE_URL"],
           let url = URL(string: raw) {
            return url
        }
        return defaultBaseURL
    }

    /// Change this constant to point the app at a different server.
    static let defaultBaseURL = URL(string: "https://lux.mynerd.place")!

    // MARK: - Auth

    /// Bearer token sent in the `Authorization` header with every request.
    ///
    /// Set `LUX_AUTH_TOKEN` in the scheme's environment variables for development,
    /// or replace the empty-string fallback below with your token.
    ///
    /// TODO: migrate to Keychain before any wider distribution.
    static var authToken: String {
        ProcessInfo.processInfo.environment["LUX_AUTH_TOKEN"] ?? ""
    }
}
