import Foundation
import KeychainAccess

class TokenStorage {
    static let shared = TokenStorage()

    private let keychain = Keychain(service: "com.omniaura.mac-runner")

    func saveToken(_ token: String, for runnerId: UUID) throws {
        try keychain.set(token, key: "runner-\(runnerId.uuidString)")
    }

    func getToken(for runnerId: UUID) throws -> String {
        guard let token = try keychain.get("runner-\(runnerId.uuidString)") else {
            throw TokenError.notFound
        }
        return token
    }

    func deleteToken(for runnerId: UUID) throws {
        try keychain.remove("runner-\(runnerId.uuidString)")
    }
}

enum TokenError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: return "GitHub token not found in keychain"
        }
    }
}
