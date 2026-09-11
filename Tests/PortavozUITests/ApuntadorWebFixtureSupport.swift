import CryptoKit
import Foundation

struct ApuntadorWebFixtureDescriptor {
    let baseURL: URL

    static func loadFromRunnerEnvironment() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        guard let encoded = environment[environmentKey],
              !encoded.isEmpty,
              encoded.utf8.count <= maximumEncodedPayloadBytes,
              let data = Data(base64Encoded: encoded),
              sha256(data) == canonicalFixtureChecksum,
              let manifest = try? JSONDecoder().decode(
                Manifest.self,
                from: data),
              manifest.schemaVersion == 1,
              manifest.generation == "public-local-v1",
              manifest.kind == "apuntador-local-web-fixture",
              manifest.contentSource == "public-synthetic-only",
              manifest.bindHost == "127.0.0.1",
              manifest.routes.count == 14
        else { throw FixtureError.invalidPayload }
        return Self(baseURL: fixtureBaseURL)
    }
}

private extension ApuntadorWebFixtureDescriptor {
    static let environmentKey = "PORTAVOZ_UI_WEB_FIXTURE_PAYLOAD"
    static let maximumEncodedPayloadBytes = 12_000
    static let canonicalFixtureChecksum =
        "97a560b3049bd0d2e0b41fc2e8f7664272f7d20fcf4771b6ec7940295822fd26"
    static let fixtureBaseURL = URL(string: "http://127.0.0.1:54321")!

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    struct Manifest: Decodable {
        let schemaVersion: Int
        let generation: String
        let kind: String
        let contentSource: String
        let bindHost: String
        let routes: [Route]
    }

    struct Route: Decodable {
        let path: String
    }

    enum FixtureError: Error {
        case invalidPayload
    }
}
