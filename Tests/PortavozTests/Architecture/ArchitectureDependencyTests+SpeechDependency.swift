import Foundation
import XCTest

extension ArchitectureDependencyTests {
    func testFluidAudioRequirementAndResolutionStayAtReviewedVersion() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let requirement = try NSRegularExpression(pattern:
            #"\.package\(\s*url:\s*"https://github\.com/FluidInference/FluidAudio\.git",\s*exact:\s*"0\.15\.6"\s*\)"#)
        XCTAssertEqual(requirement.numberOfMatches(
            in: manifest, range: NSRange(manifest.startIndex..., in: manifest)), 1,
            "The speech engine must require an explicitly reviewed exact release, not a patch range")

        let resolved = try Self.jsonObject(at: "Package.resolved")
        let pins = try XCTUnwrap(resolved["pins"] as? [[String: Any]])
        let fluidPins = pins.filter { ($0["identity"] as? String) == "fluidaudio" }
        XCTAssertEqual(fluidPins.count, 1)
        let pin = try XCTUnwrap(fluidPins.first)
        XCTAssertEqual(pin["kind"] as? String, "remoteSourceControl")
        XCTAssertEqual(pin["location"] as? String, "https://github.com/FluidInference/FluidAudio.git")
        let state = try XCTUnwrap(pin["state"] as? [String: Any])
        XCTAssertEqual(state["version"] as? String, "0.15.6")
        XCTAssertEqual(state["revision"] as? String, "4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b")
    }

    private static let fluidAudioImportPattern =
        #"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?FluidAudio\b"#

    func testFluidAudioBoundaryRecognizesSwiftImportForms() throws {
        let regex = try NSRegularExpression(pattern: Self.fluidAudioImportPattern)
        for source in [
            "import FluidAudio", "@preconcurrency import FluidAudio",
            "public import FluidAudio", "internal import FluidAudio",
            "@_implementationOnly import FluidAudio", "import struct FluidAudio.ASRConfig",
            "private import class FluidAudio.DiarizerManager",
            "import\nFluidAudio",
        ] {
            XCTAssertNotNil(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), source)
        }
        let unrelated = "import FluidAudioTestSupport"
        XCTAssertNil(regex.firstMatch(in: unrelated, range: NSRange(unrelated.startIndex..., in: unrelated)))
    }

    func testFluidAudioImportsRemainInExistingCapabilityAdapters() throws {
        let imports = try Self.sourceMatches(
            under: "Sources", pattern: Self.fluidAudioImportPattern)
        XCTAssertEqual(imports, [
            "DiarizationKit/DiarizationEvaluation.swift",
            "DiarizationKit/PyannoteDiarizer.swift",
            "TranscriptionKit/NemotronLatin1120Engine.swift",
            "TranscriptionKit/ParakeetEngine.swift",
            "TranscriptionKit/ParakeetSegmentMapper.swift",
        ])
        let targets = try TargetManifestParser.declarations(in: Self.contents(of: "Package.swift"))
        let consumers = targets.values.filter { $0.dependencies.contains("FluidAudio") }.map(\.name).sorted()
        XCTAssertEqual(consumers, ["DiarizationKit", "TranscriptionKit"])
    }
}
