import Foundation
import XCTest

final class EnglishSourceTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testPublicSourceProseIsEnglishOutsideSpanishResourcesAndFixtures() throws {
        let relativeFiles = try Self.filesToScan()
        var failures: [String] = []
        for relative in relativeFiles {
            let url = Self.repoRoot.appendingPathComponent(relative)
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where Self.looksSpanish(line) {
                if Self.isAllowedSpanishFixture(relative, line: line) { continue }
                failures.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(failures.isEmpty, "Spanish prose outside approved resources/fixtures:\n" + failures.joined(separator: "\n"))
    }

    private static func filesToScan() throws -> [String] {
        var files = ["README.md", "CLAUDE.md", "Makefile", "Package.swift", "project.yml", ".swiftlint.yml"]
        let scannedSuffixes = [".swift", ".sh", ".py", ".yml", ".yaml", ".md", ".rb", ".entitlements"]
        for root in ["scripts", "Sources", ".github", "packaging"] {
            let rootURL = repoRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(atPath: rootURL.path) else { continue }
            for case let item as String in enumerator {
                guard scannedSuffixes.contains(where: item.hasSuffix) else { continue }
                let relative = root + "/" + item
                guard !relative.contains("Resources/Localization/") else { continue }
                files.append(relative)
            }
        }
        return files
    }

    private static func looksSpanish(_ line: String) -> Bool {
        if line.range(of: #"[¿¡áéíóúñÁÉÍÓÚÑ]"#, options: .regularExpression) != nil {
            return true
        }
        let needles = [
            " Ajustes", " grabación", " reunión", " hablante", " resumen", " transcripción",
            " micrófono", " carpeta", " presupuesto", " Listo", " Elige", " modelo(s)",
            " te preguntaron", " Texto de UI", " línea", "Pausar", "Reproducir"
        ]
        return needles.contains { line.contains($0) }
    }

    private static func isAllowedSpanishFixture(_ relative: String, line: String) -> Bool {
        if relative == "Sources/portavoz-app/SettingsView.swift", line.contains("Español") {
            return true
        }
        if relative == "Sources/portavoz-app/MeetingDetailView.swift", line.contains("Español") {
            return true
        }
        if relative == "Sources/portavoz-app/AppServices.swift" {
            return line.contains("Revisemos el presupuesto")
                || line.contains("El equipo revisó")
                || line.contains("Se revisará")
        }
        if relative == "Sources/IntelligenceKit/Companion.swift" {
            return line.contains("qué") || line.contains("cómo") || line.contains("¿")
                || line.contains("quién") || line.contains("cuál") || line.contains("cuánto")
                || line.contains("ana maría") || line.contains("podrías")
        }
        if relative == "Sources/IntelligenceKit/PromptFactory.swift", line.contains("Spanish (español)") {
            return true
        }
        if relative == "Sources/IntelligenceKit/SummaryFingerprint.swift", line.contains("José") {
            return true
        }
        if relative == "Sources/portavoz-cli/CLIAsk.swift", line.contains("qué") {
            return true
        }
        return false
    }
}
