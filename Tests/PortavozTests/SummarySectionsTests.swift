import XCTest

@testable import ApplicationKit

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
        XCTAssertEqual(parsed.sections[0].bulletLines, [
            "- La beta sale el lunes.",
            "- Congelar el scope del sprint 15.",
            "▸ El fix queda verificado."
        ])
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

    func testGeneratedDocumentShowsCanonicalCommitmentsOnlyThroughTypedControls() {
        let english = MeetingGeneratedDocumentPresentation(markdown: """
            The team approved the rollout.

            ## Decisions
            - Ship on Friday.

            ## Action Items
            - Ana will prepare the release.

            ## Open Questions
            - Who owns support?
            """, hasTypedCommitments: true)
        let spanish = MeetingGeneratedDocumentPresentation(markdown: """
            El equipo aprobó el despliegue.

            ## Decisiones
            - Publicar el viernes.

            ## Pendientes
            - Ana preparará el release.

            ## Preguntas abiertas
            - ¿Quién atiende soporte?
            """, hasTypedCommitments: true)

        XCTAssertEqual(english.sections.map(\.heading), ["Decisions", "Open Questions"])
        XCTAssertEqual(english.sections.map(\.sourceOrdinal), [0, 2])
        XCTAssertEqual(english.canonicalCommitmentSectionCount, 1)
        XCTAssertEqual(spanish.sections.map(\.heading), ["Decisiones", "Preguntas abiertas"])
        XCTAssertEqual(spanish.sections.map(\.sourceOrdinal), [0, 2])
        XCTAssertEqual(spanish.canonicalCommitmentSectionCount, 1)
    }

    func testGeneratedDocumentKeepsRecipeSectionsThatAreNotCanonicalAppendices() {
        let presentation = MeetingGeneratedDocumentPresentation(markdown: """
            ## Next Steps
            - Validate the migration.

            ## Tareas pendientes
            - Review the custom plan.
            """, hasTypedCommitments: true)

        XCTAssertEqual(presentation.overviewMarkdown, "")
        XCTAssertEqual(
            presentation.sections.map(\.heading),
            ["Next Steps", "Tareas pendientes"])
        XCTAssertEqual(presentation.canonicalCommitmentSectionCount, 0)
    }

    func testGeneratedDocumentPreservesCanonicalLookingSectionWithoutTypedCommitments() {
        let presentation = MeetingGeneratedDocumentPresentation(
            markdown: """
                ## Action Items
                - Legacy content that has no typed task.
                """,
            hasTypedCommitments: false)

        XCTAssertEqual(presentation.sections.map(\.heading), ["Action Items"])
        XCTAssertEqual(presentation.canonicalCommitmentSectionCount, 0)
    }
}
