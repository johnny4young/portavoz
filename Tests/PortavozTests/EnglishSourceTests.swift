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

    func testDocumentationProseIsEnglish() throws {
        let root = Self.repoRoot.appendingPathComponent("docs")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            return XCTFail("Unable to enumerate docs/")
        }
        let files = enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".md") }
            .sorted()
        var failures: [String] = []
        for item in files {
            let url = root.appendingPathComponent(item)
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
            var insideFence = false
            for (index, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    insideFence.toggle()
                    continue
                }
                guard !insideFence else { continue }
                let prose = Self.documentationProse(in: line)
                if Self.looksLikeSpanishDocumentation(prose) {
                    failures.append("docs/\(item):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "Spanish explanatory prose under docs/. Quote intentional localized literals:\n"
                + failures.joined(separator: "\n"))
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

    /// Removes code and quoted literals before applying the docs-language
    /// policy. Localized UI labels and bilingual fixtures are allowed only
    /// when they are clearly represented as literals rather than prose.
    private static func documentationProse(in line: String) -> String {
        var result = line
        let literalPatterns = [
            #"`[^`]*`"#,
            #"\"[^\"]*\""#,
            #"“[^”]*”"#,
            #"«[^»]*»"#,
            #"\]\([^)]*\)"#,
        ]
        for pattern in literalPatterns {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    private static func looksLikeSpanishDocumentation(_ line: String) -> Bool {
        if line.range(of: #"[¿¡áéíóúñÁÉÍÓÚÑ]"#, options: .regularExpression) != nil {
            return true
        }
        let pattern = #"(?i)\b(el|la|los|las|una|para|con|sin|que|del|estado|actual|siguiente|fase|hecho|pendiente|implementado|captura|usuario|archivo|carpeta|modelo|prueba|objetivo|interfaz|calidad|versión|fecha)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(line.startIndex..., in: line)
        return regex.numberOfMatches(in: line, range: range) >= 3
    }

    private static func isAllowedSpanishFixture(_ relative: String, line: String) -> Bool {
        if relative == "Sources/IntelligenceKit/SummaryOutputAdmission.swift" {
            // This exact line is a bilingual stop-word lexicon used as data by
            // evidence admission; all explanatory source prose remains English.
            return line.contains("acordo") && line.contains("reunión")
        }
        if relative == "Sources/portavoz-app/SettingsView.swift", line.contains("Español") {
            return true
        }
        if relative == "Sources/portavoz-app/SettingsView+Intelligence.swift",
            line.contains("Español") {
            // Native language name shown in the transcription-language pin.
            return true
        }
        if relative == "Sources/portavoz-app/MeetingDetailView.swift", line.contains("Español") {
            return true
        }
        if relative == "Sources/portavoz-app/AppServices+Showcase.swift" {
            // The -seed-showcase library is deliberately Spanish fictional
            // prose: the bilingual transcript is what the screenshot shows.
            return true
        }
        if relative == "Sources/portavoz-app/AppServices+ScaleBenchmark.swift" {
            // Disposable mixed-language content used only by the measured
            // large-detail fixture and its UI screenshot.
            return true
        }
        if relative == "Sources/portavoz-app/AppServices+UITestFixtures.swift" {
            // The deterministic Meeting Detail fixture deliberately carries
            // Spanish transcript, summary, and Companion evidence.
            return line.contains("Revisemos el presupuesto")
                || line.contains("El equipo revisó")
                || line.contains("Se revisará")
                || line.contains("Cerremos con los próximos")
                || line.contains("¿Cuándo es el rollout")
                || line.contains("te encargas del presupuesto")
                // Recipe-history UI fixture: a newer Standup snapshot must
                // remain visible instead of reverting to the General one.
                || line.contains("resumen de standup sigue visible")
                || line.contains("presupuesto de transcripción ya fue revisado")
        }
        if relative == "Sources/portavoz-app/AppServices+Ask.swift" {
            // The disposable Ask adapter returns deterministic Spanish seed
            // data so both locales verify answer content without a model.
            return line.contains("El presupuesto se revisó")
        }
        if relative == "Sources/portavoz-app/BenchMode.swift" {
            // Synthetic Spanish meeting fed to the --mlx-smoke in-app check.
            return line.contains("Revisemos el presupuesto")
                || line.contains("dólares")
                || line.contains("migración")
        }
        if relative == "Sources/portavoz-cli/CLIBenchFTS.swift" {
            // Synthetic Spanish corpus + queries for the T4 FTS benchmark.
            return line.contains("presupuesto") || line.contains("qué acordamos")
                || line.contains("integración") || line.contains("diarización")
                || line.contains("reunión")
        }
        if relative == "Sources/portavoz-cli/CLIBenchScale.swift" {
            // Synthetic bilingual corpus and queries for the Band 4 scale
            // matrix; this is data, not public explanatory prose.
            return true
        }
        if relative == "Sources/IntelligenceKit/Companion.swift" {
            return line.contains("qué") || line.contains("cómo") || line.contains("¿")
                || line.contains("quién") || line.contains("cuál") || line.contains("cuánto")
                || line.contains("ana maría") || line.contains("podrías")
        }
        if relative == "Sources/ApplicationKit/MirrorStats.swift" {
            // The post-meeting mirror synthesis is bilingual and lives in a
            // pure module (no L10n): both languages are inlined by design.
            return line.contains("habitual") || line.contains("balance de habla")
                || line.contains("pregunta")
        }
        if relative == "Sources/IntelligenceKit/PromptFactory.swift", line.contains("Spanish (español)") {
            return true
        }
        if relative == "Sources/IntelligenceKit/SummaryFingerprint.swift", line.contains("José") {
            return true
        }
        if relative == "Sources/TranscriptionKit/VocabularyPrompt.swift",
            line.contains("En esta reunión hablamos de ") {
            return true
        }
        if relative == "Sources/IntelligenceKit/TitleSuggester.swift",
            line.contains("resumen sobre el presupuesto") {
            // Intentional Spanish few-shot example: titles must come out in
            // the summary's language, so the prompt shows both languages.
            return true
        }
        if relative == "Sources/IntelligenceKit/ChapterTitler.swift",
            line.contains("presupuesto de transcripción") {
            // Intentional Spanish few-shot: chapter titles must come out in
            // the transcript's language, so the prompt shows both.
            return true
        }
        if relative == "Sources/portavoz-cli/CLIAsk.swift", line.contains("qué") {
            return true
        }
        return false
    }
}
