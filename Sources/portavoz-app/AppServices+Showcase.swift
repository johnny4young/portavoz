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
        guard ((try? await store.meetings()) ?? []).isEmpty else { return }

        let day: TimeInterval = 86_400
        let base = Date(timeIntervalSince1970: 1_783_695_600)  // Jul 10, 2026, 10:00 -05:00

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
            language: "es")
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
            line(marta, "Arranquemos con el estado de Zephyr: el cluster de pruebas ya corre la build 214 y el pipeline quedó verde anoche.", 0.2),
            line(me, "Perfecto. ¿Cerramos entonces el bug del device-ID duplicado en QVTL?", 0.9, seconds: 8),
            line(ilarion, "Sí, era el cache del provisioning. El fix está en main y lo verificamos contra los 40 dispositivos del lab.", 1.4),
            line(marta, "Queda pendiente migrar los dashboards de Kepler antes del viernes — eso bloquea la demo con el cliente.", 2.3),
            line(me, "Lo tomo yo. También quiero que revisemos el presupuesto de transcripción del Q3.", 3.0, seconds: 10),
            line(ilarion, "On that note — the English docs for Aurora Suite are ready for review, I shared the draft this morning.", 3.8),
            line(marta, "Genial. Propongo congelar el scope del sprint 15 hoy: Zephyr beta, dashboards Kepler y las docs de Aurora.", 4.6),
            line(s3, "Desde infraestructura sin novedades: el failover de la región secundaria pasó el drill sin downtime.", 5.5),
            line(me, "Entonces decidido: beta de Zephyr sale el lunes y Marta lidera la demo con el cliente.", 6.3, seconds: 9)
        ])
        // swiftlint:enable line_length

        try? await store.saveSummary(SummaryDraft(
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
        requestSpotlightReindex()
    }
    // swiftlint:enable function_body_length
}
