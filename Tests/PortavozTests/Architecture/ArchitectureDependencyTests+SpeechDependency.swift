import Foundation
import XCTest

extension ArchitectureDependencyTests {
    /// D516/D559: immutable reviewed source plus exact subsystem selection.
    /// Parsing the manifest cannot itself qualify models, UI or resource usage.
    static func requiredFluidAudioRevision() throws -> String {
        let manifest = try contents(of: "Package.swift")
        XCTAssertTrue(manifest.hasPrefix("// swift-tools-version:6.2\n"),
            "Swift 6.2 traits are required to exclude unused TTS resources and NeMo")
        let requirement = try NSRegularExpression(pattern:
            #"\.package\(\s*url:\s*"https://github\.com/johnny4young/FluidAudio\.git",\s*revision:\s*"([0-9a-f]{40})",\s*traits:\s*\["Diarizer"\]\s*\)"#)
        let matches = requirement.matches(
            in: manifest, range: NSRange(manifest.startIndex..., in: manifest))
        XCTAssertEqual(matches.count, 1,
            "Require exactly the reviewed immutable fork and Diarizer-only traits, never a rolling branch/default TTS")
        let match = try XCTUnwrap(matches.first)
        return String(manifest[try XCTUnwrap(Range(match.range(at: 1), in: manifest))])
    }

    func testFluidAudioRequirementAndResolutionStayAtReviewedVersion() throws {
        let requiredRevision = try Self.requiredFluidAudioRevision()
        XCTAssertEqual(requiredRevision, "24922d65f33ca70fdc041e36598df7ef51786274",
            "A new speech SDK source requires explicit review rather than only changing the manifest")
        let resolved = try Self.jsonObject(at: "Package.resolved")
        let pins = try XCTUnwrap(resolved["pins"] as? [[String: Any]])
        let fluidPins = pins.filter { ($0["identity"] as? String) == "fluidaudio" }
        XCTAssertEqual(fluidPins.count, 1)
        let pin = try XCTUnwrap(fluidPins.first)
        XCTAssertEqual(pin["kind"] as? String, "remoteSourceControl")
        XCTAssertEqual(pin["location"] as? String, "https://github.com/johnny4young/FluidAudio.git")
        let state = try XCTUnwrap(pin["state"] as? [String: Any])
        XCTAssertNil(state["version"])
        XCTAssertNil(state["branch"])
        XCTAssertEqual(state["revision"] as? String, requiredRevision,
            "The resolved dependency must equal the full reviewed SHA")
    }

    /// Statement-anchored: attributes and access modifiers may precede `import`,
    /// but nothing else on the line may. Paired with `codeOnly: true` scanning,
    /// prose or a quoted pattern can never register as an import.
    static let fluidAudioImportPattern =
        #"(?m)^[^\S\n]*(?:@[A-Za-z_][A-Za-z0-9_]*[^\S\n]+)*"#
        + #"(?:(?:public|package|internal|fileprivate|private)[^\S\n]+)?"#
        + #"import[^\S\n]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[^\S\n]+)?FluidAudio\b"#

    /// A re-export would let vendor types reach every file that imports the kit
    /// without adding an import the inventory above can see.
    static let fluidAudioReExportPattern =
        #"(?m)^[^\S\n]*(?:(?:@_exported[^\S\n]+(?:(?:public|package)[^\S\n]+)?import)"#
        + #"|(?:(?:public|package|open)[^\S\n]+import))"#
        + #"[^\S\n]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[^\S\n]+)?FluidAudio\b"#

    static let fluidAudioTypealiasExportPattern =
        #"(?m)^[^\S\n]*(?:public|package|open)[^\S\n]+typealias[^\S\n]+[A-Za-z0-9_]+[^\S\n]*=[^\S\n]*FluidAudio\."#

    func testFluidAudioBoundaryRecognizesSwiftImportForms() throws {
        let regex = try NSRegularExpression(pattern: Self.fluidAudioImportPattern)
        func matches(_ source: String) -> Bool {
            let code = SwiftSourceScanner.codeOnly(source)
            return regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }
        for source in [
            "import FluidAudio", "@preconcurrency import FluidAudio",
            "public import FluidAudio", "internal import FluidAudio",
            "@_implementationOnly import FluidAudio", "import struct FluidAudio.ASRConfig",
            "private import class FluidAudio.DiarizerManager",
            "import Foundation\n@preconcurrency import FluidAudio\n",
        ] {
            XCTAssertTrue(matches(source), source)
        }
        // The regressions the inventory actually depends on not seeing: an import
        // that is only mentioned, and a module whose name merely starts the same.
        for source in [
            "// import FluidAudio",
            "/// Prose that says: import FluidAudio, as an example.",
            "/* import FluidAudio */",
            "let pattern = \"import FluidAudio\"",
            "let block = \"\"\"\nimport FluidAudio\n\"\"\"",
            "let raw = #\"import FluidAudio\"#",
            "import FluidAudioTestSupport",
            "let alias = FluidAudio.ASRConfig.self",
        ] {
            XCTAssertFalse(matches(source), source)
        }
    }

    func testFluidAudioBoundaryRecognizesReExportForms() throws {
        let reExport = try NSRegularExpression(pattern: Self.fluidAudioReExportPattern)
        let typealiasExport = try NSRegularExpression(pattern: Self.fluidAudioTypealiasExportPattern)
        func matches(_ regex: NSRegularExpression, _ source: String) -> Bool {
            let code = SwiftSourceScanner.codeOnly(source)
            return regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        }
        for source in [
            "@_exported import FluidAudio", "@_exported public import FluidAudio",
            "public import FluidAudio", "package import FluidAudio",
            "public import struct FluidAudio.ASRConfig",
        ] {
            XCTAssertTrue(matches(reExport, source), source)
        }
        for source in ["import FluidAudio", "internal import FluidAudio", "// public import FluidAudio"] {
            XCTAssertFalse(matches(reExport, source), source)
        }
        XCTAssertTrue(matches(typealiasExport, "public typealias ASRConfig = FluidAudio.ASRConfig"))
        XCTAssertFalse(matches(typealiasExport, "private typealias ASRConfig = FluidAudio.ASRConfig"))
    }

    func testFluidAudioImportsRemainInExistingCapabilityAdapters() throws {
        let imports = try Self.sourceMatches(
            under: "Sources", pattern: Self.fluidAudioImportPattern, codeOnly: true)
        XCTAssertEqual(imports, [
            "DiarizationKit/DiarizationEvaluation.swift",
            "DiarizationKit/PyannoteDiarizer.swift",
            "TranscriptionKit/NemotronLatin1120Engine.swift",
            "TranscriptionKit/ParakeetEngine.swift",
            "TranscriptionKit/ParakeetSegmentMapper.swift",
            "TranscriptionKit/SileroVoiceActivityDetector.swift",
        ])
        let targets = try TargetManifestParser.declarations(in: Self.contents(of: "Package.swift"))
        let consumers = targets.values.filter { $0.dependencies.contains("FluidAudio") }.map(\.name).sorted()
        XCTAssertEqual(consumers, ["DiarizationKit", "TranscriptionKit"])
    }

    /// ARCHITECTURE.md states the boundary without qualifying it by directory,
    /// so the inventory covers the test tree too.
    func testFluidAudioImportsInTestsStayInTheEngineSuites() throws {
        let imports = try Self.sourceMatches(
            under: "Tests", pattern: Self.fluidAudioImportPattern, codeOnly: true)
        XCTAssertEqual(imports, [
            "PortavozTests/DictationModelBaselineTests.swift",
            "PortavozTests/DictationVendorProbe.swift",
            "PortavozTests/DictationVendorProbeTests.swift",
            "PortavozTests/NemotronLatin1120Tests.swift",
            "PortavozTests/ParakeetLanguageConfigurationTests.swift",
            "PortavozTests/SileroVoiceActivityDetectorTests.swift",
            "PortavozTests/TranscriptionTests.swift",
        ])
    }

    func testFluidAudioIsNeverReExportedFromPortavozModules() throws {
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources", pattern: Self.fluidAudioReExportPattern, codeOnly: true),
            [],
            "A re-exported import would spread vendor types past the reviewed adapters")
        XCTAssertEqual(
            try Self.sourceMatches(
                under: "Sources", pattern: Self.fluidAudioTypealiasExportPattern, codeOnly: true),
            [],
            "A public typealias onto a vendor type is a re-export by another name")
    }
}
