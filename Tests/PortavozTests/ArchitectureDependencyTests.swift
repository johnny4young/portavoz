import ApplicationKit
import Foundation
import XCTest

final class ArchitectureDependencyTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testApplicationKitManifestBoundaryAdmitsOnlyExtractedCapabilities() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let targets = try TargetManifestParser.declarations(in: manifest)
        let application = try XCTUnwrap(targets["ApplicationKit"])

        XCTAssertEqual(
            application.dependencies,
            [
                "DiarizationKit", "IntelligenceKit", "PortavozCore", "StorageKit",
                "TranscriptionKit",
            ])
        XCTAssertTrue(try XCTUnwrap(targets["portavoz-app"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(try XCTUnwrap(targets["portavoz-cli"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(try XCTUnwrap(targets["PortavozTests"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(manifest.contains(
            #".library(name: "ApplicationKit", targets: ["ApplicationKit"])"#))
        XCTAssertTrue(try Self.contents(of: "project.yml").contains("- ApplicationKit"))
    }

    func testCapabilityTargetsNeverDependBackOnApplicationKit() throws {
        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))
        let allowedConsumers = Set([
            "ApplicationKit", "portavoz-app", "portavoz-cli", "PortavozTests",
        ])
        let violations = targets.values
            .filter { !allowedConsumers.contains($0.name) }
            .filter { $0.dependencies.contains("ApplicationKit") }
            .map(\.name)
            .sorted()

        XCTAssertTrue(
            violations.isEmpty,
            "Capability targets must not depend on ApplicationKit: \(violations)")
    }

    func testCoreForbiddenImportsRemainAtDocumentedBaseline() throws {
        let forbidden = Set([
            "AppKit", "SwiftUI", "GRDB", "Security", "Network", "FoundationNetworking",
        ])
        let actual = try Self.imports(under: "Sources/PortavozCore")
            .filter { forbidden.contains($0.module) }
            .reduce(into: [String: [String]]()) { result, item in
                result[item.module, default: []].append(item.file)
            }
            .mapValues { $0.sorted() }

        // SecretStore is existing debt scheduled for a platform adapter. The
        // allowlist prevents that exception from spreading during extraction.
        XCTAssertEqual(actual, ["Security": ["SecretStore.swift"]])
    }

    func testApplicationKitImportsStayInsideTheApprovedLayer() throws {
        let allowed = Set([
            "Foundation", "PortavozCore", "ModelStoreKit", "AudioCaptureKit",
            "TranscriptionKit", "DiarizationKit", "IntelligenceKit", "StorageKit",
            "AudioPlaybackKit", "IntegrationsKit",
        ])
        let violations = try Self.imports(under: "Sources/ApplicationKit")
            .filter { !allowed.contains($0.module) }
            .map { "\($0.file): \($0.module)" }
            .sorted()
        let platformSymbols = try Self.sourceMatches(
            under: "Sources/ApplicationKit",
            pattern: #"\b(?:FileManager|UserDefaults|URLSession)\b"#)

        XCTAssertTrue(
            violations.isEmpty,
            "ApplicationKit imported presentation/platform/database APIs: \(violations)")
        XCTAssertTrue(
            platformSymbols.isEmpty,
            "ApplicationKit used a platform adapter directly: \(platformSymbols)")
    }

    func testAppMeetingLifecycleWritesEnterThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\b(?:services\.)?store\.(?:delete|restore|purge)\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App MeetingStore lifecycle writes must enter through ApplicationKit: \(violations)")
    }

    func testAppSummaryRegenerationEntersThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"services\.store\.latestSummary\s*\(|services\.configuredSummaryProvider\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App summary regeneration must enter through ApplicationKit: \(violations)")
    }

    func testAppAudioImportEntersThroughApplicationKit() throws {
        let definitions = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\bfunc\s+importMeeting\s*\("#)

        XCTAssertEqual(
            definitions,
            ["AppServices+ImportMeeting.swift"],
            "Audio import orchestration must not return to AppServices or a view")
    }

    func testAppMeetingRefineEntersThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"services\.store\.(?:applyRefinedCast|replaceCast|replaceCompanionCards)\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App refine mutations must enter through ApplicationKit: \(violations)")
    }

    func testApplicationUseCaseProvidesOneAsyncBoundary() async throws {
        let result = try await CharacterCount().execute("Portavoz")
        let callableResult = try await CharacterCount()("local first")

        XCTAssertEqual(result, 8)
        XCTAssertEqual(callableResult, 11)
    }
}

private extension ArchitectureDependencyTests {
    struct SourceImport {
        let file: String
        let module: String
    }

    struct CharacterCount: ApplicationUseCase {
        func execute(_ request: String) async throws -> Int { request.count }
    }

    static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    static func imports(under relativeDirectory: String) throws -> [SourceImport] {
        let root = repoRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let files = enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        let regex = try NSRegularExpression(
            pattern: #"(?m)^\s*(?:@preconcurrency\s+)?import\s+([A-Za-z0-9_]+)"#)
        return try files.flatMap { file -> [SourceImport] in
            let source = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            return regex.matches(in: source, range: range).compactMap { match in
                guard let moduleRange = Range(match.range(at: 1), in: source) else { return nil }
                return SourceImport(file: file, module: String(source[moduleRange]))
            }
        }
    }

    static func sourceMatches(
        under relativeDirectory: String,
        pattern: String
    ) throws -> [String] {
        let root = repoRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let regex = try NSRegularExpression(pattern: pattern)
        return try enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .compactMap { file in
                let source = try String(
                    contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                return regex.firstMatch(in: source, range: range) == nil ? nil : file
            }
    }
}

private struct TargetDeclaration {
    let name: String
    let dependencies: Set<String>
}

private enum TargetManifestParser {
    static func declarations(in manifest: String) throws -> [String: TargetDeclaration] {
        let regex = try NSRegularExpression(
            pattern: #"\.(?:target|executableTarget|testTarget)\s*\("#)
        let fullRange = NSRange(manifest.startIndex..., in: manifest)
        return try regex.matches(in: manifest, range: fullRange).reduce(into: [:]) {
            result, match in
            guard let markerRange = Range(match.range, in: manifest),
                let open = manifest[markerRange].lastIndex(of: "(")
            else { return }
            let openIndex = manifest.index(markerRange.lowerBound, offsetBy:
                manifest[markerRange].distance(from: manifest[markerRange].startIndex, to: open))
            guard let closeIndex = closingDelimiter(
                in: manifest, from: openIndex, open: "(", close: ")")
            else { throw ParseError.unbalancedTarget }
            let block = String(manifest[markerRange.lowerBound...closeIndex])
            guard let declaration = try declaration(from: block) else { return }
            result[declaration.name] = declaration
        }
    }

    private static func declaration(from block: String) throws -> TargetDeclaration? {
        let nameRegex = try NSRegularExpression(pattern: #"\bname\s*:\s*\"([^\"]+)\""#)
        let fullRange = NSRange(block.startIndex..., in: block)
        guard let match = nameRegex.firstMatch(in: block, range: fullRange),
            let nameRange = Range(match.range(at: 1), in: block)
        else { return nil }
        let name = String(block[nameRange])
        guard let labelRange = block.range(of: "dependencies:") else {
            return TargetDeclaration(name: name, dependencies: [])
        }
        guard let open = block[labelRange.upperBound...].firstIndex(of: "[") else {
            throw ParseError.missingDependencyArray
        }
        guard let close = closingDelimiter(in: block, from: open, open: "[", close: "]") else {
            throw ParseError.unbalancedDependencies
        }
        let dependencySource = String(block[open...close])
        let stringRegex = try NSRegularExpression(pattern: #"\"([^\"]+)\""#)
        let dependencyRange = NSRange(dependencySource.startIndex..., in: dependencySource)
        let dependencies = Set(stringRegex.matches(
            in: dependencySource, range: dependencyRange).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: dependencySource) else { return nil }
                return String(dependencySource[range])
            })
        return TargetDeclaration(name: name, dependencies: dependencies)
    }

    private static func closingDelimiter(
        in source: String,
        from start: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 0
        var state = LexicalState.code
        var index = start
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let nextCharacter = next < source.endIndex ? source[next] : nil
            switch state {
            case .code:
                if character == "/", nextCharacter == "/" { state = .lineComment }
                else if character == "/", nextCharacter == "*" { state = .blockComment }
                else if character == "\"" { state = .string }
                else if character == open { depth += 1 }
                else if character == close {
                    depth -= 1
                    if depth == 0 { return index }
                }
            case .string:
                if character == "\\" { index = next }
                else if character == "\"" { state = .code }
            case .lineComment:
                if character == "\n" { state = .code }
            case .blockComment:
                if character == "*", nextCharacter == "/" {
                    state = .code
                    index = next
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private enum LexicalState {
        case code
        case string
        case lineComment
        case blockComment
    }

    private enum ParseError: Error {
        case unbalancedTarget
        case missingDependencyArray
        case unbalancedDependencies
    }
}
