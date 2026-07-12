import XCTest

@testable import IntegrationsKit

final class SummarySectionsTests: XCTestCase {
    func testSplitsIntroAndSectionsWithBulletCounts() {
        let markdown = """
        La demo validó la build 214 y cerró el bug del device-ID.

        ## Decisiones
        - La beta sale el lunes.
        - Congelar el scope del sprint 15.
        ▸ El fix queda verificado.

        ## Preguntas abiertas
        - ¿El presupuesto del Q3 cubre el crecimiento?
        """
        let parsed = SummarySections.parse(markdown)

        XCTAssertTrue(parsed.intro.contains("build 214"))
        XCTAssertEqual(parsed.sections.count, 2)
        XCTAssertEqual(parsed.sections[0].heading, "Decisiones")
        XCTAssertEqual(parsed.sections[0].bulletCount, 3)  // -, -, ▸
        XCTAssertEqual(parsed.sections[1].heading, "Preguntas abiertas")
        XCTAssertEqual(parsed.sections[1].bulletCount, 1)
        XCTAssertTrue(parsed.sections[1].body.contains("presupuesto"))
    }

    func testDropsH1TitleAndHandlesNoSections() {
        let parsed = SummarySections.parse("# Meeting title\n\nJust a flat summary, no headers.")
        XCTAssertEqual(parsed.sections.count, 0)
        XCTAssertEqual(parsed.intro, "Just a flat summary, no headers.")
    }

    func testEmptyMarkdown() {
        let parsed = SummarySections.parse("")
        XCTAssertTrue(parsed.intro.isEmpty)
        XCTAssertTrue(parsed.sections.isEmpty)
    }
}
