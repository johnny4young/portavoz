import CryptoKit
import Foundation

/// Disposable real-app transport for the canonical public Web fixture.
///
/// macOS 15 local-network privacy can place a user-owned permission sheet over
/// an unattended XCUITest host when a launch-agent-owned Python process opens
/// even a loopback listener. The package integration lane keeps that real HTTP
/// server. XCUITest instead installs this protocol only for `-use-temp-store`
/// composition, preserving URLSession, receipt, parser, and presentation
/// behavior without opening a socket or automating a privacy decision.
final class UITestAskWebFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let environmentKey = "PORTAVOZ_UI_WEB_FIXTURE_PAYLOAD"
    static let fixtureBaseURL = URL(string: "http://127.0.0.1:54321")!

    private static let canonicalFixtureSHA256 =
        "97a560b3049bd0d2e0b41fc2e8f7664272f7d20fcf4771b6ec7940295822fd26"
    private static let maximumEncodedPayloadBytes = 12_000

    private var loadingTask: Task<Void, Never>?
    private var loadingClient: LoadingClient?

    // URLProtocol requires an overridable class method.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        guard request.httpMethod == "GET",
              let url = request.url,
              url.scheme == fixtureBaseURL.scheme,
              url.host == fixtureBaseURL.host,
              url.port == fixtureBaseURL.port,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false),
              !components.percentEncodedPath.contains("%")
        else { return false }
        return true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest ?? task.originalRequest else {
            return false
        }
        return canInit(with: request)
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let fixture = Self.fixture(
                environment: ProcessInfo.processInfo.environment)
        else {
            fail(with: URLError(.cannotParseResponse))
            return
        }
        guard let route = fixture.routes[url.path] else {
            publishNotFound(for: url)
            return
        }

        let loadingClient = LoadingClient(owner: self)
        self.loadingClient = loadingClient
        let task = Task {
            do {
                if route.delayMilliseconds > 0 {
                    try await Task.sleep(
                        for: .milliseconds(route.delayMilliseconds))
                }
                try Task.checkCancellation()
                loadingClient.publish(route, for: url)
            } catch is CancellationError {
                return
            } catch {
                loadingClient.fail(with: error)
            }
        }
        loadingTask = task
    }

    override func stopLoading() {
        loadingClient?.invalidate()
        loadingClient = nil
        loadingTask?.cancel()
        loadingTask = nil
    }

    static func install(
        into configuration: URLSessionConfiguration,
        environment: [String: String]
    ) -> Bool {
        guard fixture(environment: environment) != nil else { return false }
        let existing = configuration.protocolClasses ?? []
        if !existing.contains(where: { $0 == self }) {
            configuration.protocolClasses = [self] + existing
        }
        return true
    }

    static func fixture(environment: [String: String]) -> Fixture? {
        guard let encoded = environment[environmentKey],
              !encoded.isEmpty,
              encoded.utf8.count <= maximumEncodedPayloadBytes,
              let data = Data(base64Encoded: encoded),
              Self.sha256(data) == canonicalFixtureSHA256,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.schemaVersion == 1,
              document.generation == "public-local-v1",
              document.kind == "apuntador-local-web-fixture",
              document.contentSource == "public-synthetic-only",
              document.bindHost == "127.0.0.1",
              document.routes.count == 14
        else { return nil }

        var routes: [String: Route] = [:]
        for route in document.routes {
            guard route.path.first == "/",
                  routes.updateValue(route, forKey: route.path) == nil
            else { return nil }
        }
        return Fixture(routes: routes)
    }

    private func publish(_ route: Route, for url: URL) {
        if route.behavior == .disconnect {
            fail(with: URLError(.networkConnectionLost))
            return
        }
        guard let status = route.status else {
            fail(with: URLError(.cannotParseResponse))
            return
        }

        let body = Data(route.body.utf8)
        var headers = Self.headers(for: route, body: body)
        if route.behavior == .redirect, let location = route.location {
            headers["Location"] = location
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers)
        else {
            fail(with: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed)

        if route.behavior == .partial {
            client?.urlProtocol(self, didLoad: body.prefix(max(1, body.count / 2)))
            fail(with: URLError(.networkConnectionLost))
            return
        }
        if !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func publishNotFound(for url: URL) {
        let body = Data("not found".utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Cache-Control": "no-store",
                "Content-Length": String(body.count),
                "Content-Type": "text/plain; charset=utf-8",
                "X-Portavoz-Fixture-Freshness": "notApplicable",
                "X-Portavoz-Fixture-Trust": "untrusted"
            ])
        else {
            fail(with: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(with error: any Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    private static func headers(for route: Route, body: Data) -> [String: String] {
        var headers = [
            "Cache-Control": "no-store",
            "Content-Length": String(body.count),
            "Content-Type": "text/html; charset=utf-8",
            "ETag": "\"\(sha256(body))\"",
            "X-Portavoz-Fixture-Freshness": route.freshness,
            "X-Portavoz-Fixture-Trust": route.trust
        ]
        if let publishedAt = route.publishedAt {
            headers["X-Portavoz-Fixture-Published-At"] = publishedAt
        }
        if route.behavior == .error {
            headers["Retry-After"] = "1"
        }
        return headers
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class LoadingClient: @unchecked Sendable {
        private let lock = NSLock()
        private weak var owner: UITestAskWebFixtureURLProtocol?

        init(owner: UITestAskWebFixtureURLProtocol) {
            self.owner = owner
        }

        func publish(_ route: Route, for url: URL) {
            currentOwner()?.publish(route, for: url)
        }

        func fail(with error: any Error) {
            currentOwner()?.fail(with: error)
        }

        func invalidate() {
            lock.withLock { owner = nil }
        }

        private func currentOwner() -> UITestAskWebFixtureURLProtocol? {
            lock.withLock { owner }
        }
    }
}

extension UITestAskWebFixtureURLProtocol {
    struct Fixture: Sendable {
        let routes: [String: Route]
    }

    struct Document: Decodable, Sendable {
        let schemaVersion: Int
        let generation: String
        let kind: String
        let contentSource: String
        let bindHost: String
        let routes: [Route]
    }

    struct Route: Decodable, Sendable {
        let behavior: Behavior
        let body: String
        let delayMilliseconds: Int
        let freshness: String
        let location: String?
        let path: String
        let publishedAt: String?
        let status: Int?
        let trust: String
    }

    enum Behavior: String, Decodable, Sendable {
        case document
        case redirect
        case slow
        case partial
        case error
        case hostile
        case disconnect
    }
}
