import ApplicationKit
import Foundation
import XCTest

/// Shared root and helpers for the architecture ratchets. Each family of
/// checks lives in its own `ArchitectureDependencyTests+*.swift`.
final class ArchitectureDependencyTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Architecture
        .deletingLastPathComponent()   // PortavozTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
}

extension ArchitectureDependencyTests {
    struct SourceImport {
        let file: String
        let module: String
    }

    struct CharacterCount: ApplicationUseCase {
        func execute(_ request: String) async throws -> Int { request.count }
    }

    static func meetingDetailModelContents() throws -> String {
        try [
            "Sources/portavoz-app/MeetingDetailModel.swift",
            "Sources/portavoz-app/MeetingDetailModel+Actions.swift",
            "Sources/portavoz-app/MeetingDetailReviewAccumulator.swift",
            "Sources/portavoz-app/MeetingDetailMetadataSuggestionState.swift",
            "Sources/portavoz-app/MeetingDetailPerformanceTrace.swift",
        ].map(contents(of:)).joined()
    }

    static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    static func jsonObject(at relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func p95(in object: [String: Any], key: String) throws -> Double {
        let distribution = try XCTUnwrap(object[key] as? [String: Any])
        return try XCTUnwrap(distribution["p95Milliseconds"] as? Double)
    }

    static func p95(
        in object: [String: Any],
        key: String,
        nestedKey: String
    ) throws -> Double {
        let nested = try XCTUnwrap(object[key] as? [String: Any])
        return try p95(in: nested, key: nestedKey)
    }

    static func p95Bytes(in object: [String: Any], key: String) throws -> Int {
        let distribution = try XCTUnwrap(object[key] as? [String: Any])
        return try XCTUnwrap(distribution["p95Bytes"] as? Int)
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

    static func synchronousMainActorXCTestMethods() throws -> [String] {
        let root = repoRoot.appendingPathComponent("Tests/PortavozTests")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        return try enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .flatMap { file -> [String] in
                let source = try String(
                    contentsOf: root.appendingPathComponent(file),
                    encoding: .utf8)
                return synchronousMainActorXCTestMethods(
                    in: source,
                    file: file)
            }
    }

    static func synchronousMainActorXCTestMethods(
        in source: String,
        file: String
    ) -> [String] {
        let declarations = source.replacingOccurrences(
            of: #"(?m)^([\t ]*)@MainActor[\t ]+(?=(?:final[\t ]+)?(?:class|func)\b)"#,
            with: "$1@MainActor\n$1",
            options: .regularExpression)
        let lines = declarations.split(
            separator: "\n",
            omittingEmptySubsequences: false).map(String.init)
        var violations: [String] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            guard lines[lineIndex].trimmingCharacters(in: .whitespaces)
                == "@MainActor"
            else {
                lineIndex += 1
                continue
            }

            var classIndex = lineIndex + 1
            while classIndex < lines.count {
                let trimmed = lines[classIndex]
                    .trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("@") {
                    classIndex += 1
                    continue
                }
                break
            }
            if classIndex < lines.count,
               lines[classIndex].trimmingCharacters(in: .whitespaces)
                .hasPrefix("func test") {
                if let name = synchronousXCTestMethodName(
                    at: classIndex, in: lines, before: lines.count) {
                    violations.append("\(file):\(name)")
                }
                lineIndex = classIndex + 1
                continue
            }
            guard classIndex < lines.count,
                  lines[classIndex].contains("class "),
                  lines[classIndex].contains(": XCTestCase"),
                  let classEnd = lines[(classIndex + 1)...].firstIndex(of: "}")
            else {
                lineIndex += 1
                continue
            }

            var methodIndex = classIndex + 1
            while methodIndex < classEnd {
                let line = lines[methodIndex]
                guard line.hasPrefix("    func test"),
                      !line.hasPrefix("        ")
                else {
                    methodIndex += 1
                    continue
                }

                if let name = synchronousXCTestMethodName(
                    at: methodIndex, in: lines, before: classEnd) {
                    violations.append("\(file):\(name)")
                }
                methodIndex += 1
            }
            lineIndex = classEnd + 1
        }
        return violations
    }

    static func synchronousXCTestMethodName(
        at start: Int,
        in lines: [String],
        before end: Int
    ) -> String? {
        var index = start
        var declaration = lines[index].trimmingCharacters(in: .whitespaces)
        while !declaration.contains("{") && index + 1 < end {
            index += 1
            declaration += "\n" + lines[index]
        }
        guard declaration.range(
            of: #"\basync\b"#,
            options: .regularExpression) == nil else { return nil }
        return String(declaration.dropFirst("func ".count).prefix { $0 != "(" })
    }
}

struct TargetDeclaration {
    let name: String
    let dependencies: Set<String>
}

enum TargetManifestParser {
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
