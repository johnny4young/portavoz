import Foundation

struct ApuntadorWebFixtureDescriptor {
    let baseURL: URL

    static func loadFromRunnerEnvironment() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        guard let descriptorPath = environment[
            "PORTAVOZ_UI_WEB_FIXTURE_DESCRIPTOR"],
            !descriptorPath.isEmpty
        else { throw FixtureError.missingDescriptor }

        let descriptorURL = URL(fileURLWithPath: descriptorPath)
        let data = try Data(
            contentsOf: descriptorURL,
            options: .mappedIfSafe)
        guard data.count <= 4_096 else {
            throw FixtureError.invalidDescriptor
        }
        let descriptor = try JSONDecoder().decode(
            Descriptor.self,
            from: data)
        guard descriptor.schemaVersion == 1,
              descriptor.generation == "public-local-v1",
              descriptor.fixtureChecksum == canonicalFixtureChecksum,
              descriptor.processID > 0,
              let baseURL = URL(string: descriptor.baseURL),
              baseURL.scheme == "http",
              baseURL.host == "127.0.0.1",
              baseURL.port != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil
        else { throw FixtureError.invalidDescriptor }
        return Self(baseURL: baseURL)
    }
}

private extension ApuntadorWebFixtureDescriptor {
    static let canonicalFixtureChecksum =
        "97a560b3049bd0d2e0b41fc2e8f7664272f7d20fcf4771b6ec7940295822fd26"

    struct Descriptor: Decodable {
        let schemaVersion: Int
        let generation: String
        let fixtureChecksum: String
        let baseURL: String
        let processID: Int
    }

    enum FixtureError: Error {
        case missingDescriptor
        case invalidDescriptor
    }
}
