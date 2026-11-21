import XCTest

@testable import ApplicationKit

final class VoiceHueTests: XCTestCase {
    func testNamedPersonIsStableAcrossCallsAndCase() {
        let a = VoiceHue.index(name: "Marta")
        XCTAssertEqual(a, VoiceHue.index(name: "marta"))
        XCTAssertEqual(a, VoiceHue.index(name: "  Marta "))
    }

    func testKnownNamesKeepTheHueTheyAlwaysHad() {
        XCTAssertEqual(
            ["Marta", "Bruno", "Carla", "Ilarion", "Lucia"].map(VoiceHue.index(name:)), [0, 1, 2, 3, 4])
    }

    func testIndexAlwaysInPaletteRange() {
        for name in ["Marta", "Ilarion", "José", "李静", "a", "z"] {
            let index = VoiceHue.index(name: name)
            XCTAssertTrue((0..<VoiceHue.paletteSize).contains(index), "\(name) → \(index)")
        }
    }
}
