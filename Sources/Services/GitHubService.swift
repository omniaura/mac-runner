import Foundation

final class GitHubService: Sendable {
    private let session = URLSession.shared

    func validateAccess(repo: String, token: String) async throws {
        let url = URL(string: "https://api.github.com/repos/\(repo)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GitHubError.invalidRepoOrToken
        }
    }

    func getRegistrationToken(repo: String, token: String) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/\(repo)/actions/runners/registration-token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 else {
            throw GitHubError.failedToGetRegistrationToken
        }

        struct RegistrationTokenResponse: Codable {
            let token: String
        }

        let decoded = try JSONDecoder().decode(RegistrationTokenResponse.self, from: data)
        return decoded.token
    }

    func unregisterRunner(repo: String, token: String, runnerId: UUID) async throws {
        // First, get runner ID from GitHub API
        // Then delete it
        // Implementation depends on how we track GitHub runner IDs
        throw GitHubError.notImplemented
    }
}

enum GitHubError: LocalizedError {
    case invalidRepoOrToken
    case failedToGetRegistrationToken
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .invalidRepoOrToken:
            return "Invalid repository or GitHub token. Check your token has 'repo' scope."
        case .failedToGetRegistrationToken:
            return "Failed to get registration token from GitHub"
        case .notImplemented:
            return "Feature not yet implemented"
        }
    }
}
