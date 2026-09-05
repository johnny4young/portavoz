import Foundation
import PortavozCore

/// `-seed-showcase` (with `-use-temp-store`): seeds a small FICTIONAL
/// library rich enough for public screenshots — never real user data. The
/// XCUITest seed (`-seed-demo`) stays untouched: tests depend on its exact
/// strings, while this one is free to look good.
extension AppServices {
    // Showcase copy is fictional-universe prose, deliberately Spanish
    // (the bilingual transcript is a differentiator worth showing).
    // swiftlint:disable function_body_length
    func seedShowcaseIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seed-showcase") else { return }
        defer { markUITestSeedReady() }
        guard ((try? await store.meetings()) ?? []).isEmpty else { return }

        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_783_695_600)  // Jul 10, 2026, 10:00 -05:00
        let audioDirectory = Self.prepareSeedAudio()

        // Background meetings so the library looks lived-in.
        for (title, daysAgo, minutes) in [
            ("2026-07-09 Sync semanal QVTL", 1.0, 31),
            ("2026-07-08 1:1 con Marta", 2.0, 28),
            ("2026-07-07 Retro sprint 14", 3.0, 47),
            ("2026-07-04 Kickoff Aurora Suite", 6.0, 55)
        ] {
            let started = base.addingTimeInterval(-daysAgo * day)
            try? await store.save(Meeting(
                title: title,
                startedAt: started,
                endedAt: started.addingTimeInterval(TimeInterval(minutes * 60)),
                language: "es"))
        }

        // The hero meeting: full cast, transcript, co-authored summary.
        let meeting = Meeting(
            title: "2026-07-10 Sprint Demo · Zephyr",
            startedAt: base,
            endedAt: base.addingTimeInterval(42 * 60),
            language: "es",
            audioDirectory: audioDirectory)
        try? await store.save(meeting)

        let me = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        var marta = Speaker(meetingID: meeting.id, label: "S1")
        marta.displayName = "Marta"
        var ilarion = Speaker(meetingID: meeting.id, label: "S2")
        ilarion.displayName = "Ilarion"
        let s3 = Speaker(meetingID: meeting.id, label: "S3")
        try? await store.save([me, marta, ilarion, s3])

        func line(
            _ speaker: Speaker, _ text: String, _ minute: Double, seconds: Double = 14
        ) -> TranscriptSegment {
            TranscriptSegment(
                meetingID: meeting.id, speakerID: speaker.id,
                channel: speaker.isMe ? .microphone : .system,
                text: text, startTime: minute * 60, endTime: minute * 60 + seconds,
                isFinal: true)
        }
        // Fictional transcript prose reads better unwrapped.
        // swiftlint:disable line_length
        try? await store.save([
            // Keep one system turn and one microphone turn inside the short
            // synthetic audio fixture. Later rows remain minutes apart so the
            // public detail still demonstrates chapters.
            line(marta, "Arranquemos con el estado de Zephyr: el cluster de pruebas ya corre la build 214 y el pipeline quedó verde anoche.", 0, seconds: 2.5),
            line(me, "Perfecto. ¿Cerramos entonces el bug del device-ID duplicado en QVTL?", 0.0417, seconds: 2.5),
            line(ilarion, "Sí, era el cache del provisioning. El fix está en main y lo verificamos contra los 40 dispositivos del lab.", 1.4),
            line(marta, "Queda pendiente migrar los dashboards de Kepler antes del viernes — eso bloquea la demo con el cliente.", 2.3),
            line(me, "Lo tomo yo. También quiero que revisemos el presupuesto de transcripción del Q3.", 3.0, seconds: 10),
            line(ilarion, "On that note — the English docs for Aurora Suite are ready for review, I shared the draft this morning.", 3.8),
            line(marta, "Genial. Propongo congelar el scope del sprint 15 hoy: Zephyr beta, dashboards Kepler y las docs de Aurora.", 4.6),
            line(s3, "Desde infraestructura sin novedades: el failover de la región secundaria pasó el drill sin downtime.", 5.5),
            line(me, "Entonces decidido: beta de Zephyr sale el lunes y Marta lidera la demo con el cliente.", 6.3, seconds: 9)
        ])
        // swiftlint:enable line_length

        _ = try? await store.saveSummary(SummaryDraft(
            meetingID: meeting.id, recipeID: Recipe.general.id, language: "es",
            markdown: """
                La demo del sprint validó la build 214 de Zephyr sobre el cluster \
                de pruebas y cerró el bug del device-ID duplicado en QVTL \
                (cache del provisioning, verificado contra 40 dispositivos).

                ## Decisiones
                - La beta de Zephyr sale el lunes; Marta lidera la demo con el cliente.
                - ▸ Congelar el scope del sprint 15: Zephyr beta, dashboards Kepler y docs de Aurora Suite.
                - El fix del device-ID queda verificado y cerrado.

                ## Preguntas abiertas
                - ¿El presupuesto de transcripción del Q3 cubre el crecimiento del lab?
                """,
            actionItems: [
                ActionItem(text: "Migrar los dashboards de Kepler antes del viernes", ownerSpeakerID: me.id),
                ActionItem(text: "Review the Aurora Suite English docs draft", ownerSpeakerID: marta.id),
                ActionItem(text: "Preparar la demo del cliente para el lunes", ownerSpeakerID: marta.id)
            ]))
        try? await store.save([
            ContextItem(
                meetingID: meeting.id, kind: .note,
                content: "congelar scope sprint 15", timestamp: 280)
        ])
        try? await store.recordDataEgressEvent(DataEgressEvent(
            meetingID: meeting.id,
            operation: .summaryGeneration,
            destinationScope: .localDevice,
            destinationHost: "localhost",
            dataClassification: .meetingSummaryMaterial,
            consentSource: .summaryEngineSettings,
            providerID: "localhost",
            modelID: "showcase-local-summary",
            attemptedAt: base.addingTimeInterval(7 * 60)))
        requestSearchReconciliation()
    }
    // swiftlint:enable function_body_length
}

/// Fictional bilingual runtime data shared by the disposable public showcase.
/// Keeping it beside the showcase seeder prevents localized fixture prose from
/// leaking across production-facing source files.
enum PublicShowcaseFixture {
    static let speakerEvidence = "Nora confirmó el failover."

    static let liveTranscriptLines = [
        "Quiero confirmar el alcance de la beta antes de cerrar el sprint.",
        "La build 214 ya está estable en el cluster de pruebas.",
        "¿El fix del device-ID quedó verificado con todo el laboratorio?",
        "Sí, pasó contra los cuarenta dispositivos sin nuevos duplicados.",
        "Entonces podemos cerrar ese riesgo para la demo del lunes.",
        "Todavía falta mover los dashboards de Kepler al workspace final.",
        "Yo puedo encargarme de la migración esta tarde.",
        "Perfecto, Marta revisará los permisos cuando termines.",
        "También debemos validar el presupuesto de transcripción del Q3.",
        "Finanzas compartió una proyección actualizada esta mañana.",
        "La proyección cubre el crecimiento esperado del laboratorio.",
        "Queda pendiente documentar el margen para nuevos idiomas.",
        "Voy a añadir esa nota al checklist de lanzamiento.",
        "Las English docs de Aurora ya están listas para review.",
        "Ilarion enviará el enlace al equipo después de la llamada.",
        "Con eso podemos congelar el scope del sprint quince.",
        "Zephyr beta, dashboards Kepler y docs de Aurora quedan dentro.",
        "El rediseño del onboarding pasa al siguiente sprint.",
        "¿Tenemos algún bloqueo adicional para la demo del cliente?",
        "No, el failover también completó el drill sin downtime.",
        "La beta de Zephyr queda programada para el lunes.",
        "Yo enviaré el checklist final después de esta llamada.",
        "Marta revisará los dashboards de Kepler antes del viernes.",
        "Perfecto, cerramos con responsables y fechas claras."
    ]

    static func translation(for source: String) -> String {
        switch source {
        case "La beta de Zephyr queda programada para el lunes.":
            "The Zephyr beta remains scheduled for Monday."
        case "Yo enviaré el checklist final después de esta llamada.":
            "I will send the final checklist after this call."
        case "Marta revisará los dashboards de Kepler antes del viernes.":
            "Marta will review the Kepler dashboards before Friday."
        case "Perfecto, cerramos con responsables y fechas claras.":
            "Perfect, we are closing with clear owners and dates."
        default:
            "The team confirms the next step and its owner."
        }
    }
}
