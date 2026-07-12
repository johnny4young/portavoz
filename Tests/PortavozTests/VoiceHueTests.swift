import XCTest

@testable import IntegrationsKit

final class VoiceHueTests: XCTestCase {
    func testNamedPersonIsStableAcrossCallsAndCase() {
        let a = VoiceHue.index(name: "Marta", fallbackOrder: 0)
        XCTAssertEqual(a, VoiceHue.index(name: "marta", fallbackOrder: 3))
        XCTAssertEqual(a, VoiceHue.index(name: "  Marta ", fallbackOrder: 99))
    }

    func testUnnamedFallsBackToAppearanceOrder() {
        XCTAssertEqual(VoiceHue.index(name: nil, fallbackOrder: 0), 0)
        XCTAssertEqual(VoiceHue.index(name: nil, fallbackOrder: 7), 1)
        XCTAssertEqual(VoiceHue.index(name: "", fallbackOrder: 2), 2)
        XCTAssertEqual(VoiceHue.index(name: nil, fallbackOrder: -1), 5, "negative order stays in range")
    }

    func testIndexAlwaysInPaletteRange() {
        for name in ["Marta", "Ilarion", "José", "李静", "a", "z"] {
            let index = VoiceHue.index(name: name, fallbackOrder: 0)
            XCTAssertTrue((0..<VoiceHue.paletteSize).contains(index), "\(name) → \(index)")
        }
    }
}
