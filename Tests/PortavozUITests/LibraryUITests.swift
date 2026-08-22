import XCTest

/// UI smoke tests (M11 tooling). These launch the real app under XCUITest so
/// we verify the UI renders without driving the screen by hand. Run with
/// `make test-ui`. The app honors `-use-temp-store` so a test run never
/// touches the real library.
final class LibraryUITests: PortavozUITestCase {
    @MainActor
    func testDatabaseLaunchFailureOffersSafeRecovery() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "portavoz-launch-recovery-uitest-\(UUID().uuidString)",
                isDirectory: true)
        let recoveryRoot = scratch.appendingPathComponent("copies", isDirectory: true)
        let databaseURL = scratch.appendingPathComponent("failed.sqlite")
        let diagnosticsURL = scratch.appendingPathComponent("launch-diagnostics.json")
        try FileManager.default.createDirectory(
            at: recoveryRoot,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let app = XCUIApplication.portavoz()
        app.launchArguments.append("-simulate-database-open-failure")
        app.launchEnvironment["PORTAVOZ_UI_TEST_DATABASE_PATH"] = databaseURL.path
        app.launchEnvironment["PORTAVOZ_UI_TEST_DATABASE_RECOVERY_DIRECTORY"] =
            recoveryRoot.path
        app.launchEnvironment["PORTAVOZ_UI_TEST_LAUNCH_DIAGNOSTICS_PATH"] =
            diagnosticsURL.path
        app.launchPortavoz()
        defer { app.terminate() }

        let title = app.staticTexts["launch-recovery-title"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 15),
            "a database-open failure must render recovery instead of terminating")
        let expectedTitle = UITestLocale.environmentLocale == "es"
            ? "No se pudo abrir tu biblioteca"
            : "Your library couldn't be opened"
        XCTAssertEqual(renderedText(of: title), expectedTitle)
        XCTAssertFalse(app.buttons["library-new-recording-button"].exists)
        XCTAssertTrue(app.control(withIdentifier: "launch-recovery-file-evidence").exists)
        XCTAssertTrue(app.buttons["launch-recovery-retry"].exists)

        let originalDatabase = try Data(contentsOf: databaseURL)
        app.buttons["launch-recovery-save-copy"].click()
        let copyStatus = app.control(withIdentifier: "launch-recovery-copy-status")
        XCTAssertTrue(copyStatus.waitForExistence(timeout: 15))
        let expectedCopyStatus = UITestLocale.environmentLocale == "es"
            ? "Copia de recuperación guardada"
            : "Recovery copy saved"
        let copyFinished = expectation(
            for: NSPredicate(
                format: "label == %@ OR value == %@",
                expectedCopyStatus,
                expectedCopyStatus),
            evaluatedWith: copyStatus)
        wait(for: [copyFinished], timeout: 15)
        let copies = try FileManager.default.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: copies[0].appendingPathComponent("portavoz.sqlite").path))
        XCTAssertEqual(try Data(contentsOf: databaseURL), originalDatabase)

        app.buttons["launch-recovery-export-diagnostics"].click()
        let diagnosticsStatus = app.control(
            withIdentifier: "launch-recovery-diagnostics-status")
        XCTAssertTrue(diagnosticsStatus.waitForExistence(timeout: 15))
        let expectedDiagnosticsStatus = UITestLocale.environmentLocale == "es"
            ? "Diagnósticos de inicio guardados"
            : "Launch diagnostics saved"
        let diagnosticsFinished = expectation(
            for: NSPredicate(
                format: "label == %@ OR value == %@",
                expectedDiagnosticsStatus,
                expectedDiagnosticsStatus),
            evaluatedWith: diagnosticsStatus)
        wait(for: [diagnosticsFinished], timeout: 15)
        let diagnostics = try String(contentsOf: diagnosticsURL, encoding: .utf8)
        XCTAssertFalse(diagnostics.contains(databaseURL.path))
        XCTAssertFalse(diagnostics.contains(databaseURL.lastPathComponent))
        XCTAssertTrue(diagnostics.contains(#""filePresent" : true"#))

        app.buttons["launch-recovery-retry"].click()
        XCTAssertTrue(
            title.waitForExistence(timeout: 15),
            "a repeated failure must return to the bounded recovery state")
        XCTAssertFalse(app.buttons["library-new-recording-button"].exists)
        attachScreenshot(of: app, named: "database-launch-recovery")
    }

    @MainActor
    private func renderedText(of element: XCUIElement) -> String {
        guard let value = element.value as? String, !value.isEmpty else {
            return element.label
        }
        return value
    }

    @MainActor
    func testUpcomingMeetingBriefShowsRelatedEvidenceAndOpenCommitment() {
        let app = XCUIApplication.portavoz(seedDemo: true, seedBrief: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let upcoming = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-upcoming-'"))
            .firstMatch
        XCTAssertTrue(upcoming.waitForExistence(timeout: 10))
        upcoming.click()

        XCTAssertTrue(app.control(withIdentifier: "brief-title").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        let related = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'brief-related-'"))
            .firstMatch
        XCTAssertTrue(
            related.waitForExistence(timeout: 10),
            "the brief must surface the related seeded meeting")
        XCTAssertTrue(app.staticTexts["Test meeting"].exists)
        let commitment = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'brief-open-'"))
            .firstMatch
        XCTAssertTrue(commitment.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Prepare the rollout"].exists)
        XCTAssertTrue(app.buttons["brief-record-button"].exists)
        attachScreenshot(of: app, named: "meeting-preparation-brief")
    }

    @MainActor
    func testLibraryRendersRecordButtonAndActionChips() {
        let app = XCUIApplication.portavoz()
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(
            record.waitForExistence(timeout: 15),
            "the library window must render its primary action on launch")

        if let locale = UITestLocale.environmentLocale {
            XCTAssertEqual(record.label, locale == "es" ? "Nueva grabación" : "New recording")
        }

        // The design-system action chips replace the old full-width buttons.
        XCTAssertTrue(app.buttons["library-import-audio-button"].exists)
        XCTAssertTrue(app.buttons["library-ask-button"].exists)
        XCTAssertTrue(app.buttons["library-insights-button"].exists)
        XCTAssertTrue(app.buttons["library-commitment-radar-button"].exists)
    }

    @MainActor
    func testRecordingStartFailureOffersTypedRecovery() {
        let app = XCUIApplication.portavoz(simulateRecordingStartFailure: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        XCTAssertTrue(
            app.control(withIdentifier: "recording-failure").waitForExistence(timeout: 10),
            "a deterministic start failure must become an actionable error state")
        let expected = isSpanish
            ? "Portavoz no pudo preparar los dispositivos de grabación. Revisa los permisos y vuelve a intentarlo."
            : "Portavoz could not prepare the recording devices. Check permissions and try again."
        XCTAssertTrue(app.staticTexts[expected].exists)
        XCTAssertTrue(app.control(withIdentifier: "recording-retry").exists)
        XCTAssertTrue(app.control(withIdentifier: "recording-back").exists)

        // ContentUnavailableView can expose SwiftUI children as `.other` even
        // when the underlying controls retain their stable identifiers.
        let reference = app.control(withIdentifier: "recording-failure-reference")
        XCTAssertTrue(reference.exists)
        let expectedReference = isSpanish
            ? "Referencia del error: recording.start.preparation.unavailable"
            : "Error reference: recording.start.preparation.unavailable"
        XCTAssertTrue(app.staticTexts[expectedReference].exists)
        attachScreenshot(of: app, named: "band-3j-typed-recording-failure")
    }

    @MainActor
    func testRecordingWarnsWhenRemoteAudioCallbacksStop() {
        let app = XCUIApplication.portavoz(simulateSystemCaptureStall: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        let warning = app.control(withIdentifier: "recording-system-capture-health")
        XCTAssertTrue(
            warning.waitForExistence(timeout: 10),
            "callback death must become visible while microphone capture continues")
        let stop = app.buttons["recording-stop-after-remote-outage"]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 5),
            "a prolonged outage must make Stop explicit without ending capture automatically")
        let expected = isSpanish
            ? "El audio remoto no está disponible desde hace dos minutos. Si la llamada terminó, detén esta grabación."
            : "Remote audio has been unavailable for two minutes. If the call ended, stop this recording."
        XCTAssertTrue(app.staticTexts[expected].exists)
        attachScreenshot(of: app, named: "recording-remote-audio-recovery")

        stop.click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-failure").waitForExistence(timeout: 10),
            "Stop must leave active capture and surface the fixture's explicit no-audio outcome")
        XCTAssertFalse(stop.exists, "Stop must not remain actionable after capture closes")
        let reference = app.control(withIdentifier: "recording-failure-reference")
        XCTAssertTrue(reference.waitForExistence(timeout: 3))
        let expectedFailure = isSpanish
            ? "No se capturó audio. Revisa los permisos de micrófono y grabación de audio del sistema de Portavoz."
            : "No audio was captured. Check Portavoz microphone and system audio recording permissions."
        XCTAssertTrue(app.staticTexts[expectedFailure].exists)
        let expectedReference = isSpanish
            ? "Referencia del error: recording.stop.no-audio"
            : "Error reference: recording.stop.no-audio"
        XCTAssertTrue(
            app.staticTexts[expectedReference].exists,
            "the empty fixture must use the guarded no-audio result")
        XCTAssertTrue(app.control(withIdentifier: "recording-retry").exists)
        attachScreenshot(of: app, named: "recording-remote-audio-stop-recovery")
    }

    @MainActor
    func testRecordingWarnsWhenIncomingAudioClips() {
        let app = XCUIApplication.portavoz(simulateSystemAudioClipping: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        let warning = app.control(withIdentifier: "recording-system-audio-clipping")
        XCTAssertTrue(
            warning.waitForExistence(timeout: 10),
            "sustained incoming full-scale audio must expose its transcript-quality risk")
        let expected = isSpanish
            ? "El audio de los demás se está saturando — la transcripción puede ser menos precisa."
            : "The other participants' audio is clipping — transcript accuracy may be lower."
        XCTAssertTrue(app.staticTexts[expected].exists)
        attachScreenshot(of: app, named: "recording-system-audio-clipping")

        let dismiss = app.buttons["recording-system-audio-clipping-dismiss"]
        XCTAssertTrue(dismiss.exists)
        dismiss.click()
        XCTAssertFalse(warning.exists)
    }

    @MainActor
    func testColdRecordingStartsLiveCaptionsWhenModelBecomesReady() {
        let app = XCUIApplication.portavoz(simulateLiveTranscriptionAttach: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        XCTAssertTrue(
            app.waitForLiveTranscriptionAttachPreparing(),
            "the fixture must enter the model-preparing state")
        let preparing = app.control(withIdentifier: "recording-transcript-deferred")
        XCTAssertTrue(preparing.waitForExistence(timeout: 20))
        let preparingPrefix = isSpanish
            ? "El audio sigue guardándose correctamente."
            : "Audio is safe."
        XCTAssertTrue(
            preparing.label.contains(preparingPrefix),
            "expected localized preparing copy, saw: \(preparing.label)")
        XCTAssertTrue(
            app.continueLiveTranscriptionAttachFixture(),
            "the fixture must release the model-ready transition")
        XCTAssertTrue(
            app.staticTexts["Live captions are available now."].waitForExistence(
                timeout: 8))
        XCTAssertFalse(preparing.exists)
        // "Catch me up" is a standing recording control on EVERY platform:
        // tapping answers honestly when the on-device model is unavailable,
        // so presence is deterministic even where generation is not.
        XCTAssertTrue(
            app.control(withIdentifier: "recording-catch-up")
                .waitForExistence(timeout: 5),
            "the recording bar must offer the catch-up action")
        attachScreenshot(of: app, named: "recording-live-transcript-hot-attach")
    }

    @MainActor
    func testLiveTranscriptYieldsFollowWhileReadingHistory() {
        let app = XCUIApplication.portavoz(simulateLiveTranscriptBrowsing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the fixture must publish a stable 18-row reading frontier")
        let transcript = app.control(withIdentifier: "recording-live-transcript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["History row 18 remains readable during live updates."]
                .waitForExistence(timeout: 8))

        let jumpToLive = app.buttons["recording-jump-to-live"]
        // Hosted runners occasionally coalesce the first synthetic wheel
        // event. Retry the same user gesture until SwiftUI reports reader
        // ownership instead of turning one dropped event into a false failure.
        for _ in 0..<4 where !jumpToLive.exists {
            transcript.scroll(byDeltaX: 0, deltaY: 8)
        }
        XCTAssertTrue(
            jumpToLive.waitForExistence(timeout: 5),
            "manual history browsing must pause automatic follow")
        let earlierRow = app.staticTexts[
            "History row 02 remains readable during live updates."
        ]
        // A runner's wheel acceleration and window height change how far one
        // synthetic scroll travels. Keep scrolling in the same user direction
        // until the same deterministic history row is actually in view.
        for _ in 0..<12 where !earlierRow.isHittable {
            transcript.scroll(byDeltaX: 0, deltaY: 8)
        }
        XCTAssertTrue(
            earlierRow.isHittable,
            "the user must be able to reach an earlier closed row")
        let readerOwnedY = earlierRow.frame.midY

        XCTAssertTrue(
            app.resumeLiveTranscriptFixture(),
            "the fixture must resume only after the reader owns the viewport")
        XCTAssertTrue(
            app.waitForLiveTranscriptFixtureToFinish(),
            "the fixture must publish the six incoming rows")
        XCTAssertTrue(
            jumpToLive.exists,
            "new live captions must not steal scroll ownership from the reader")
        XCTAssertTrue(
            earlierRow.isHittable,
            "incoming rows must keep the earlier row in the viewport")
        XCTAssertEqual(
            earlierRow.frame.midY,
            readerOwnedY,
            accuracy: 1,
            "incoming rows must not reposition the reader-owned history")
        let newestRow = app.staticTexts[
            "History row 24 remains readable during live updates."
        ]
        attachScreenshot(of: app, named: "recording-live-transcript-history-paused")

        jumpToLive.click()
        let resumed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: jumpToLive)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed)
        let latestVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: newestRow)
        XCTAssertEqual(XCTWaiter.wait(for: [latestVisible], timeout: 5), .completed)
    }

    /// The live assist surface (APUN-003/004): objectives with manual
    /// check-off, the next-question action, and the talk-balance cue that
    /// appears once closed captions exist.
    @MainActor
    func testRecordingOffersObjectivesNextQuestionAndTalkBalance() {
        let app = XCUIApplication.portavoz(simulateLiveTranscriptBrowsing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        record.click()

        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the live-assist assertions require closed captions")
        let transcript = app.control(withIdentifier: "recording-live-transcript")
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))

        let panel = app.control(withIdentifier: "recording-objectives-panel")
        XCTAssertTrue(
            panel.waitForExistence(timeout: 8),
            "the recording surface must offer the objectives panel")
        let field = app.control(withIdentifier: "recording-objective-field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        app.typeText("Cerrar el presupuesto del trimestre")
        app.control(withIdentifier: "recording-objective-add").click()
        XCTAssertTrue(
            app.staticTexts["Cerrar el presupuesto del trimestre"]
                .waitForExistence(timeout: 5),
            "an added objective must appear in the checklist")

        XCTAssertTrue(
            app.control(withIdentifier: "recording-next-question").exists,
            "the bar must offer the next-question action")
        XCTAssertTrue(app.control(withIdentifier: "recording-translation-picker").exists)
        XCTAssertTrue(app.control(withIdentifier: "recording-hud").exists)
        XCTAssertTrue(
            app.control(withIdentifier: "recording-talk-balance")
                .waitForExistence(timeout: 8),
            "closed captions must surface the talk-balance cue")
    }

    @MainActor
    func testLiveTranslationUsesADistinctLabeledRail() {
        let app = XCUIApplication.portavoz(simulateLiveTranscriptBrowsing: true)
        app.launchArguments.append("-seed-live-translation-ui")
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the translated-rail assertion requires a stable caption frontier")
        let translation = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH 'recording-live-translation-'"))
            .firstMatch
        XCTAssertTrue(
            translation.waitForExistence(timeout: 10),
            "a translated row must expose its own labeled visual boundary")
        let targetLanguageLabel =
            isSpanish ? "Traducción al inglés" : "English translation"
        XCTAssertTrue(
            app.staticTexts[targetLanguageLabel].exists,
            "translated copy must visibly say which language it represents")
        attachScreenshot(of: app, named: "recording-live-translation-rail")
    }

    @MainActor
    func testActiveRecordingRemainsReachableAfterBrowsingTheLibrary() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-new-recording-button"].click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-live-transcript")
                .waitForExistence(timeout: 8))

        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(app.prepareForInteraction())
        XCTAssertTrue(
            meeting.waitForStableFrame(timeout: 10),
            "the historical meeting must have a stable hit target")
        meeting.click()
        XCTAssertTrue(
            app.control(withIdentifier: "detail-transcript-title")
                .waitForExistence(timeout: 10),
            "the historical meeting must replace the live route before returning")

        let returnToRecording = app.buttons["library-return-to-recording"]
        XCTAssertTrue(
            returnToRecording.waitForExistence(timeout: 5),
            "an active capture must remain reachable from every library route")
        returnToRecording.click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-stop").waitForExistence(timeout: 8))
        XCTAssertTrue(app.control(withIdentifier: "recording-elapsed-time").exists)
        attachScreenshot(of: app, named: "recording-return-to-live")
    }

    @MainActor
    func testSeededMeetingsGroupByRecency() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        // The seeded meeting appears under a time-bucket section header, not
        // one flat "Meetings" list (design system timeline).
        XCTAssertTrue(
            app.staticTexts["Test meeting"].firstMatch.waitForExistence(timeout: 15),
            "the seeded meeting must appear in the grouped library")
        // Its timestamp (Nov 2023) is old, so it lands under "Earlier".
        XCTAssertTrue(
            app.staticTexts["Earlier"].exists || app.staticTexts["Antes"].exists,
            "an old meeting must sit under the Earlier bucket")

        attachScreenshot(of: app, named: "band-2o-library-voice-mix")

        // Search crosses the SwiftUI binding, feature-model debounce, and
        // real FTS projection before publishing a new Library snapshot.
        let search = app.textFields["library-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("viernes")
        let hit = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-search-hit-'"))
            .firstMatch
        XCTAssertTrue(
            hit.waitForExistence(timeout: 10),
            "the feature model must publish the seeded transcript search hit")
        XCTAssertTrue(
            hit.label.contains("Test meeting · 00:03"),
            "the search result must expose the meeting and exact hit timestamp")
        hit.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 10))
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 10)
        attachScreenshot(of: app, named: "band-4c-fast-local-search")
    }

    @MainActor
    func testAskConversationAnswersAndSeeksToExactCitation() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()
        let field = app.textFields["ask-question-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("viernes")
        app.buttons["ask-submit"].click()

        let progressiveEvidence = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-pending-citation-'"))
            .firstMatch
        XCTAssertTrue(
            progressiveEvidence.waitForExistence(timeout: 10),
            "exact evidence must appear before local answer generation finishes")
        XCTAssertTrue(progressiveEvidence.label.contains("Test meeting · 00:03"))
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-progress-refining"]
                .waitForExistence(timeout: 5),
            "Ask must distinguish lexical evidence from semantic refinement")
        attachScreenshot(of: app, named: "ask-progressive-evidence")

        XCTAssertTrue(
            app.descendants(matching: .any)["ask-progress-generating"]
                .waitForExistence(timeout: 5),
            "Ask must expose answer generation after the evidence set is fenced")
        XCTAssertTrue(
            app.staticTexts["El presupuesto se revisó y el rollout quedó para el viernes."]
                .waitForExistence(timeout: 10),
            "the full Ask model must publish the seeded local answer")
        let citation = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-citation-'"))
            .firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 5))
        XCTAssertTrue(citation.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "band-6c5-full-ask-answer")

        citation.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 10))
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 10)
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactPersonCommitmentsAndEvidence() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedAskMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()

        let memorySurface = app.descendants(matching: .any)[
            "ask-surface-person-commitments"]
        XCTAssertTrue(memorySurface.waitForExistence(timeout: 10))
        memorySurface.click()

        let title = app.descendants(matching: .any)["ask-memory-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(
            renderedText(of: title),
            UITestLocale.environmentLocale == "es"
                ? "Compromisos actuales"
                : "Current commitments")

        let person = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-memory-person-'"))
            .firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 10))
        XCTAssertTrue(person.label.contains("Ana"))
        person.click()

        let selected = app.descendants(matching: .any)[
            "ask-memory-selected-person"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertTrue(renderedText(of: selected).contains("Ana"))
        app.buttons["ask-memory-load"].click()

        let commitment = app.descendants(matching: .any)[
            "ask-memory-commitment-B5D10000-0000-4000-8000-000000000005"]
        XCTAssertTrue(commitment.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Prepare the rollout"].exists)
        let evidence = app.buttons[
            "ask-memory-evidence-B5D10000-0000-4000-8000-000000000005-0"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        XCTAssertTrue(evidence.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "ask-confirmed-person-commitments")

        evidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 10))
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 10)
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactTopicDecisionsAndEvidence() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedAskTopicMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()

        let topicSurface = app.descendants(matching: .any)[
            "ask-surface-topic-decisions"]
        XCTAssertTrue(topicSurface.waitForExistence(timeout: 10))
        topicSurface.click()

        let title = app.descendants(matching: .any)["ask-topic-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(
            renderedText(of: title),
            UITestLocale.environmentLocale == "es"
                ? "Memoria del tema"
                : "Topic memory")

        let topic = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-option-'"))
            .firstMatch
        XCTAssertTrue(topic.waitForExistence(timeout: 10))
        XCTAssertTrue(topic.label.contains("model rollout"))
        topic.click()

        let selected = app.descendants(matching: .any)["ask-topic-selected"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertTrue(renderedText(of: selected).contains("model rollout"))
        app.buttons["ask-topic-load"].click()

        let decision = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-decision-'"))
            .firstMatch
        XCTAssertTrue(decision.waitForExistence(timeout: 10))
        XCTAssertTrue(
            renderedText(of: decision).contains(
                "El rollout del modelo queda para el viernes."))
        let evidence = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-evidence-'"))
            .firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        XCTAssertTrue(evidence.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "ask-confirmed-topic-decisions")

        evidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 10))
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 10)
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactTopicFirstDiscussionAndEvidence() {
        let app = XCUIApplication.portavoz(
            seedDemo: true,
            seedAskTopicMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()

        let topicSurface = app.descendants(matching: .any)[
            "ask-surface-topic-decisions"]
        XCTAssertTrue(topicSurface.waitForExistence(timeout: 10))
        topicSurface.click()

        let topic = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-option-'"))
            .firstMatch
        XCTAssertTrue(topic.waitForExistence(timeout: 10))
        XCTAssertTrue(topic.label.contains("model rollout"))
        topic.click()

        let firstDiscussionJob = app.descendants(matching: .any)[
            "ask-topic-job-first-discussion"]
        XCTAssertTrue(firstDiscussionJob.waitForExistence(timeout: 5))
        firstDiscussionJob.click()
        app.buttons["ask-topic-load"].click()

        let discussion = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'ask-topic-first-discussion-' "
                    + "AND NOT identifier BEGINSWITH "
                    + "'ask-topic-first-discussion-evidence-'"))
            .firstMatch
        XCTAssertTrue(discussion.waitForExistence(timeout: 10))
        XCTAssertTrue(renderedText(of: discussion).contains("Test meeting"))
        let evidence = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'ask-topic-first-discussion-evidence-'"))
            .firstMatch
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        XCTAssertTrue(evidence.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "ask-confirmed-topic-first-discussion")

        evidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 10))
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 10)
    }

    @MainActor
    func testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState() {
        let app = XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        // Keep the citation destination open before invoking the resident
        // palette. Reassigning the same route does not reconstruct SwiftUI,
        // so this proves the navigation request reaches a mounted detail.
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        meeting.click()
        XCTAssertTrue(
            app.control(withIdentifier: "player-current-time").waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields["palette-query-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("viernes")
        XCTAssertTrue(
            app.buttons["palette-hit-0"].waitForExistence(timeout: 10),
            "the palette must publish instant local FTS results")
        field.typeKey(.return, modifierFlags: [])
        // `palette-answer` renders only from `state.answer`, which nothing but
        // `submit()` sets — so its presence *is* the proof that Enter ran the
        // full Ask workflow rather than reusing the instant FTS hits.
        //
        // Deliberately not asserting the answer's words. Those come from
        // `RAGAnswerer`, an on-device Foundation Models session: when the model
        // is unavailable or throttled the workflow honestly falls back to
        // "Closest passages from your meetings:" with the same citations.
        // Pinning the generated sentence made this gate fail about half the
        // time for a reason that was never a regression.
        XCTAssertTrue(
            app.staticTexts["palette-answer"].waitForExistence(timeout: 20),
            "Enter must use the same full Ask workflow")
        XCTAssertTrue(app.buttons["palette-copy-answer"].exists)
        let citation = app.buttons["palette-citation-0"]
        XCTAssertTrue(citation.exists)
        XCTAssertTrue(citation.label.contains("Test meeting · 00:03"))
        let paletteWindow = app.windows["command-palette-window"]
        XCTAssertTrue(
            paletteWindow.waitForExistence(timeout: 5),
            "the palette window must remain visible while showing its answer")
        attachElementScreenshot(of: paletteWindow, named: "band-6c5-command-palette-answer")

        citation.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistence(timeout: 10))
        let seeked = expectation(
            for: NSPredicate(format: "value == '0:03'"),
            evaluatedWith: currentTime)
        wait(for: [seeked], timeout: 10)
    }

    @MainActor
    func testLaunchRecoversInterruptedStagingAudio() {
        let app = XCUIApplication.portavoz(seedRecovery: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.waitForSeededLibraryToSettle(timeout: 30),
            "launch recovery must complete before the recovered meeting is selected")
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(meeting.exists, "launch recovery must return interrupted audio")
        meeting.click()
        XCTAssertTrue(
            app.control(withIdentifier: "player-play-pause").waitForExistence(timeout: 10),
            "the recovered CAF must be playable without loading an ML model")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-refine").exists,
            "the recovered meeting must retain its explicit transcript recovery action")
    }

    @MainActor
    func testLaunchResumesDurablePostCaptureProcessing() {
        let app = XCUIApplication.portavoz(seedProcessing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.staticTexts["Durable processing recovery"]
                .firstMatch.waitForExistence(timeout: 15),
            "the durable processing fixture must remain discoverable while work resumes")
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(meeting.waitForExistence(timeout: 5))
        let settled = expectation(
            for: NSPredicate(format: "isHittable == true"), evaluatedWith: meeting)
        wait(for: [settled], timeout: 10)
        meeting.click()

        XCTAssertTrue(
            app.staticTexts["El procesamiento durable conserva este texto."]
                .waitForExistence(timeout: 10),
            "diarization completion must atomically preserve the original transcript")
        XCTAssertTrue(
            app.staticTexts["Durable processing finished."]
                .waitForExistence(timeout: 15),
            "the resumed worker must publish its dependent summary and refresh the detail")
        attachScreenshot(of: app, named: "durable-post-capture-recovery")
    }
}
