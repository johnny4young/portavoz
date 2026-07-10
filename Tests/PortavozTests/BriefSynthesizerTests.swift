import Foundation
import PortavozCore
import XCTest

@testable import IntelligenceKit

/// The deterministic gate behind "What to know" citations: the model's
/// output never decides what survives — grounding does. (Class-level
/// availability: the Point type appears in helper signatures; on older
/// macOS the whole class is skipped by the runtime.)
@available(macOS 26.0, *)
final class BriefSynthesizerTests: XCTestCase {
    private let passages = [
        "El equipo decidió migrar de Keycloak a Zephyr antes del cierre del trimestre.",
        "Marta quedó de revisar el PR de la función Lambda de QVTL.",
    ]

    private func point(_ text: String, _ index: Int) -> BriefSynthesizer.Point {
        BriefSynthesizer.Point(text: text, passageIndex: index)
    }

    func testGroundedBulletsSurviveWithTheirCitation() {
        let kept = BriefSynthesizer.sanitize(
            [
                point("La migración a Zephyr se decidió para este trimestre.", 1),
                point("Marta debe revisar el PR de Lambda.", 2),
            ],
            passages: passages)
        XCTAssertEqual(kept.count, 2)
        XCTAssertEqual(kept[0].passageIndex, 1)
    }

    func testFillerWithoutLiteralEvidenceIsDropped() {
        // The field complaint: "the meeting will be brief, lasting only 10
        // minutes" — cites a passage but shares no content word with it.
        let kept = BriefSynthesizer.sanitize(
            [point("The meeting will be brief, lasting ten minutes.", 1)],
            passages: passages)
        XCTAssertTrue(kept.isEmpty)
    }

    func testInvalidIndexTooShortAndDuplicatesAreDropped() {
        let kept = BriefSynthesizer.sanitize(
            [
                point("La migración a Zephyr quedó decidida.", 3),  // índice inválido
                point("Corto.", 1),  // muy corto
                point("Marta debe revisar el PR de Lambda.", 2),
                point("marta debe revisar el pr de lambda.", 2),  // duplicado
            ],
            passages: passages)
        XCTAssertEqual(kept.count, 1)
    }

    func testGroundingIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(
            BriefSynthesizer.grounded(
                "La MIGRACION quedó lista.", in: "hablamos de la migración pendiente"))
        XCTAssertFalse(BriefSynthesizer.grounded("Nada que ver aquí.", in: passages[0]))
    }
}
