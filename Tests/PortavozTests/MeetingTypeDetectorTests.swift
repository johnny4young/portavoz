import Foundation
import PortavozCore
import XCTest

@testable import IntelligenceKit

final class RecipeCatalogTests: XCTestCase {
    func testEveryRecipeResolvesByIDAndIsUnique() {
        XCTAssertEqual(Recipe.all.count, 5)
        XCTAssertEqual(Set(Recipe.all.map(\.id)).count, 5)
        for recipe in Recipe.all {
            XCTAssertEqual(Recipe.byID(recipe.id)?.displayName, recipe.displayName)
            XCTAssertFalse(recipe.sections.isEmpty)
        }
        XCTAssertNil(Recipe.byID("nope"))
    }

    func testExcerptCapsLengthAndLeadsWithSpeakerCount() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let meeting = MeetingID()
        let long = String(repeating: "palabra ", count: 80)
        let segments = (0..<40).map { index in
            TranscriptSegment(
                meetingID: meeting, channel: .system, text: long,
                startTime: TimeInterval(index), endTime: TimeInterval(index) + 1, isFinal: true)
        }
        let excerpt = MeetingTypeDetector.excerpt(segments: segments, speakerCount: 3)
        XCTAssertTrue(excerpt.hasPrefix("Speakers: 3"))
        XCTAssertLessThan(excerpt.count, 2600, "capped well under the 3B's window")
    }
}

/// Real-model acceptance test (M13b criterion: the suggested Recipe is
/// right for ≥3 meeting types). Needs PORTAVOZ_MODEL_TESTS=1 + macOS 26.
final class MeetingTypeDetectorIntegrationTests: XCTestCase {
    private func segments(_ lines: [String]) -> [TranscriptSegment] {
        let meeting = MeetingID()
        return lines.enumerated().map { index, text in
            TranscriptSegment(
                meetingID: meeting, channel: .system, text: text,
                startTime: TimeInterval(index * 6), endTime: TimeInterval(index * 6 + 5),
                isFinal: true)
        }
    }

    func testClassifiesThreeTypesAndLeavesGeneralAlone() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PORTAVOZ_MODEL_TESTS"] == "1",
            "set PORTAVOZ_MODEL_TESTS=1 to run")
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }

        let standup = segments([
            "Ayer terminé la migración de la base de datos y cerré el ticket 142.",
            "Hoy me toca el endpoint de reportes, no tengo bloqueos.",
            "Yo ayer estuve con el bug del login, hoy sigo con eso.",
            "Estoy bloqueado esperando el acceso al ambiente de staging.",
            "Yo terminé el diseño, hoy empiezo la implementación del onboarding.",
        ])
        let planning = segments([
            "El objetivo del trimestre es lanzar la versión de iOS.",
            "Para el alcance: entra la grabadora presencial, queda fuera el sync.",
            "El riesgo principal son los tiempos de revisión del App Store.",
            "Próximos pasos: Ana arma el backlog y Luis valida el presupuesto.",
            "Acordamos revisar el plan cada dos semanas.",
        ])
        let interview = segments([
            "Cuéntame de tu experiencia con sistemas distribuidos.",
            "Trabajé cinco años en infraestructura, sobre todo en colas de mensajes.",
            "¿Cómo manejarías un incidente de latencia en producción?",
            "Primero miraría las métricas de p99 y los despliegues recientes.",
            "¿Tienes preguntas para nosotros sobre el equipo o el rol?",
        ])
        let general = segments([
            "El bug está en el loop de reintentos, mira la línea cuarenta.",
            "Sí, el timeout se dispara antes de que responda el servidor.",
            "Probemos subiendo el límite y agregando un log ahí.",
            "Listo, lo pruebo y te cuento en el canal.",
            "Dale, también revisa el test que quedó en rojo.",
        ])

        let detectedStandup = await MeetingTypeDetector.detect(segments: standup, speakerCount: 5)
        XCTAssertEqual(detectedStandup?.id, "standup")

        let detectedPlanning = await MeetingTypeDetector.detect(segments: planning, speakerCount: 3)
        XCTAssertEqual(detectedPlanning?.id, "planning")

        let detectedInterview = await MeetingTypeDetector.detect(
            segments: interview, speakerCount: 2)
        XCTAssertEqual(detectedInterview?.id, "interview")

        let detectedGeneral = await MeetingTypeDetector.detect(segments: general, speakerCount: 2)
        XCTAssertNil(detectedGeneral, "a debugging chat must not get a typed recipe")
    }
}
