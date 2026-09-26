import XCTest

/// UI smoke tests (M11 tooling). These launch the real app under XCUITest so
/// we verify the UI renders without driving the screen by hand. Run with
/// `make test-ui`. The app honors `-use-temp-store` so a test run never
/// touches the real library.
final class LibraryUITests: PortavozUITestCase {
    @MainActor
    func testDatabaseLaunchFailureOffersSafeRecovery() throws {
        let scratch = try UITestStorage.makeDirectory()
        let recoveryRoot = scratch.appendingPathComponent("copies", isDirectory: true)
        let databaseURL = scratch.appendingPathComponent("failed.sqlite")
        let diagnosticsURL = scratch.appendingPathComponent("launch-diagnostics.json")
        try FileManager.default.createDirectory(
            at: recoveryRoot,
            withIntermediateDirectories: true)

        let app = try XCUIApplication.portavoz()
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
            title.waitForExistenceFast(timeout: 15),
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
        XCTAssertTrue(copyStatus.waitForExistenceFast(timeout: 15))
        let expectedCopyStatus = UITestLocale.environmentLocale == "es"
            ? "Copia de recuperación guardada"
            : "Recovery copy saved"
        XCTAssertTrue(
            copyStatus.waitForLabelOrValue(expectedCopyStatus, timeout: 15))
        let destinationArtifacts = try FileManager.default.contentsOfDirectory(
            at: recoveryRoot,
            includingPropertiesForKeys: nil)
        let leakedStages = destinationArtifacts.filter {
            $0.lastPathComponent.hasPrefix(".portavoz-recovery-")
        }
        XCTAssertTrue(
            leakedStages.isEmpty,
            "recovery publication must not leak a hidden stage: \(leakedStages)")
        let copies = destinationArtifacts.filter { artifact in
            guard !artifact.lastPathComponent.hasPrefix(".") else { return false }
            let values = try? artifact.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }
        XCTAssertEqual(
            copies.count,
            1,
            "one activation must publish one visible recovery directory: \(copies)")
        let recoveryCopy = try XCTUnwrap(copies.first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryCopy.appendingPathComponent("portavoz.sqlite").path))
        XCTAssertEqual(try Data(contentsOf: databaseURL), originalDatabase)

        app.buttons["launch-recovery-export-diagnostics"].click()
        let diagnosticsStatus = app.control(
            withIdentifier: "launch-recovery-diagnostics-status")
        XCTAssertTrue(diagnosticsStatus.waitForExistenceFast(timeout: 15))
        let expectedDiagnosticsStatus = UITestLocale.environmentLocale == "es"
            ? "Diagnósticos de inicio guardados"
            : "Launch diagnostics saved"
        XCTAssertTrue(
            diagnosticsStatus.waitForLabelOrValue(
                expectedDiagnosticsStatus,
                timeout: 15))
        let diagnostics = try String(contentsOf: diagnosticsURL, encoding: .utf8)
        XCTAssertFalse(diagnostics.contains(databaseURL.path))
        XCTAssertFalse(diagnostics.contains(databaseURL.lastPathComponent))
        XCTAssertTrue(diagnostics.contains(#""filePresent" : true"#))

        app.buttons["launch-recovery-retry"].click()
        XCTAssertTrue(
            title.waitForExistenceFast(timeout: 15),
            "a repeated failure must return to the bounded recovery state")
        XCTAssertFalse(app.buttons["library-new-recording-button"].exists)
        try app.requireDisposableMainWindowOnZeroScreen()
        attachScreenshot(of: app, named: "database-launch-recovery")
    }

    @MainActor
    func testUpcomingMeetingBriefShowsRelatedEvidenceAndOpenCommitment() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true, seedBrief: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let upcoming = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-upcoming-'"))
            .firstMatch
        XCTAssertTrue(upcoming.waitForExistenceFast(timeout: 10))
        upcoming.click()

        XCTAssertTrue(app.control(withIdentifier: "brief-title").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.staticTexts["Presupuesto rollout"].exists)
        let related = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'brief-related-'"))
            .firstMatch
        XCTAssertTrue(
            related.waitForExistenceFast(timeout: 10),
            "the brief must surface the related seeded meeting")
        XCTAssertTrue(app.staticTexts["Test meeting"].exists)
        let commitment = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'brief-open-'"))
            .firstMatch
        XCTAssertTrue(commitment.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.staticTexts["Prepare the rollout"].exists)
        XCTAssertTrue(app.buttons["brief-record-button"].exists)
        attachScreenshot(of: app, named: "meeting-preparation-brief")
    }

    @MainActor
    func testLibraryRendersRecordButtonAndActionChips() throws {
        let app = try XCUIApplication.portavoz()
        app.launchArguments += ["-AppleInterfaceStyle", "Light"]
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(record.frame),
                      "welcome content must not inflate the split view beyond the window")
        if let locale = UITestLocale.environmentLocale {
            XCTAssertEqual(record.label, locale == "es" ? "Nueva grabación" : "New recording")
        }
        let title = app.staticTexts["home-title"]
        XCTAssertTrue(title.waitForExistenceFast(timeout: 5))
        if let locale = UITestLocale.environmentLocale {
            XCTAssertEqual(renderedText(of: title), locale == "es" ? "Hoy" : "Today")
        }
        XCTAssertTrue(app.buttons["home-record"].isHittable)
        XCTAssertTrue(app.buttons["home-ask"].isHittable)
        XCTAssertTrue(
            app.control(withIdentifier: "library-record-menu").exists,
            "Import lives behind the record button's menu, not in the navigation")
        let navigation = [
            "library-home-button", "library-ask-button",
            "library-insights-button", "library-commitment-radar-button"
        ].map { app.buttons[$0] }
        for button in navigation {
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThan(button.frame.width, 180, "navigation must retain full-width labels")
        }
        for (previous, next) in zip(navigation, navigation.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.frame.maxY, next.frame.minY,
                                     "navigation targets must not overlap")
        }
        attachScreenshot(of: app, named: "home-today-light")

        app.buttons["home-ask"].click()
        XCTAssertTrue(app.control(withIdentifier: "ask-question-field").waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.buttons["library-ask-button"].isSelected)
        XCTAssertFalse(app.buttons["library-insights-button"].isSelected)
    }

    @MainActor
    func testPrivacyChipOpensTheActivityLogInYourData() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }
        XCTAssertTrue(app.waitForSeededLibraryToSettle())

        func openActivity() {
            let chip = app.buttons["library-privacy-chip"]
            XCTAssertTrue(chip.waitForExistenceFast(timeout: 10))
            XCTAssertTrue(chip.waitForStableFrame(timeout: 10))
            chip.click()
            XCTAssertTrue(
                app.control(withIdentifier: "library-privacy-note").waitForExistenceFast(timeout: 5),
                "the chip must open its short privacy note")
            let seeActivity = app.buttons["library-privacy-activity"]
            XCTAssertTrue(seeActivity.waitForHittable(timeout: 5))
            seeActivity.click()
            XCTAssertTrue(
                app.control(withIdentifier: "settings-ledger-audio").waitForExistenceFast(timeout: 10),
                "See activity must land on Your data, where the activity log lives")
            XCTAssertTrue(app.buttons["settings-category-data"].isSelected)
            XCTAssertTrue(
                app.finishTextFieldEditing(identifier: "settings-search-field", timeout: 5),
                "the deep link must release native search editing before sidebar navigation")
            XCTAssertEqual(app.textFields["settings-search-field"].value as? String, "")
        }

        // A fresh Settings window.
        openActivity()
        // A window previously showing another pane. On a small display the
        // Settings window covers the main window, so bring the main window
        // forward (⌘`) before reaching for the chip; Settings stays open.
        XCTAssertTrue(app.openSettingsCategory(
            "settings-category-general", revealing: "settings-category-list"))
        XCTAssertTrue(app.buttons["settings-category-general"].isSelected)
        typeKey("`", modifierFlags: .command, in: app)
        XCTAssertTrue(
            app.buttons["library-privacy-chip"].waitForHittable(timeout: 10),
            "the main window must be in front before the chip is used again")
        openActivity()
    }

    @MainActor
    func testRecordingStartFailureOffersTypedRecovery() throws {
        let app = try XCUIApplication.portavoz(simulateRecordingStartFailure: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        XCTAssertTrue(
            app.control(withIdentifier: "recording-failure").waitForExistenceFast(timeout: 10),
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
    func testCaptureFailureSurvivesStopAndRelaunchWithPlayablePrefix() throws {
        let directory = try UITestStorage.makeDirectory()
        let app = try XCUIApplication.portavoz()
        app.launchEnvironment["PORTAVOZ_UI_TEST_DATABASE_PATH"] = directory.appendingPathComponent("library.sqlite").path
        app.launchEnvironment["PORTAVOZ_AUDIO_ROOT"] = directory.appendingPathComponent("audio").path
        app.launchArguments.append("-simulate-capture-prefix-failure")
        app.launchPortavoz()
        defer { app.terminate() }
        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        record.click()
        XCTAssertTrue(app.control(withIdentifier: "recording-microphone-capture-failure")
            .waitForExistenceFast(timeout: 10))
        let stop = app.buttons["recording-stop"]
        XCTAssertTrue(stop.waitForExistenceFast(timeout: 5))
        stop.click()
        XCTAssertTrue(app.control(withIdentifier: "detail-capture-failure-microphone")
            .waitForExistenceFast(timeout: 15))
        app.terminate()
        app.launchArguments.removeAll { $0 == "-simulate-capture-prefix-failure" }
        app.launchPortavoz()
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(meeting.waitForExistenceFast(timeout: 15))
        meeting.click()
        XCTAssertTrue(app.control(withIdentifier: "detail-capture-report").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.control(withIdentifier: "detail-capture-failure-microphone").exists)
        XCTAssertFalse(app.control(withIdentifier: "detail-capture-failure-system").exists)
        XCTAssertTrue(app.control(withIdentifier: "player-play-pause").waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.control(withIdentifier: "player-play-pause").isEnabled)
        attachScreenshot(of: app, named: "capture-prefix-relaunch")
    }

    @MainActor
    func testRecordingWarnsWhenRemoteAudioCallbacksStop() throws {
        let app = try XCUIApplication.portavoz(simulateSystemCaptureStall: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        let warning = app.control(withIdentifier: "recording-system-capture-health")
        XCTAssertTrue(
            warning.waitForExistenceFast(timeout: 10),
            "callback death must become visible while microphone capture continues")
        let stop = app.buttons["recording-stop-after-remote-outage"]
        XCTAssertTrue(
            stop.waitForExistenceFast(timeout: 5),
            "a prolonged outage must make Stop explicit without ending capture automatically")
        let expected = isSpanish
            ? "El audio remoto no está disponible desde hace dos minutos. Si la llamada terminó, detén esta grabación."
            : "Remote audio has been unavailable for two minutes. If the call ended, stop this recording."
        XCTAssertTrue(app.staticTexts[expected].exists)
        attachScreenshot(of: app, named: "recording-remote-audio-recovery")

        stop.click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-failure").waitForExistenceFast(timeout: 10),
            "Stop must leave active capture and surface the fixture's explicit no-audio outcome")
        XCTAssertFalse(stop.exists, "Stop must not remain actionable after capture closes")
        let reference = app.control(withIdentifier: "recording-failure-reference")
        XCTAssertTrue(reference.waitForExistenceFast(timeout: 3))
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
    func testRecordingWarnsWhenIncomingAudioClips() throws {
        let app = try XCUIApplication.portavoz(simulateSystemAudioClipping: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        let warning = app.control(withIdentifier: "recording-system-audio-clipping")
        XCTAssertTrue(
            warning.waitForExistenceFast(timeout: 10),
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
    func testColdRecordingStartsLiveCaptionsWhenModelBecomesReady() throws {
        let app = try XCUIApplication.portavoz(simulateLiveTranscriptionAttach: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        XCTAssertTrue(
            app.waitForLiveTranscriptionAttachPreparing(),
            "the fixture must enter the model-preparing state")
        let preparing = app.control(withIdentifier: "recording-transcript-deferred")
        XCTAssertTrue(preparing.waitForExistenceFast(timeout: 20))
        XCTAssertTrue(
            app.control(withIdentifier: "recording-apuntador-state").exists,
            "the assist panel must always say what Apuntador is doing")
        let preparingPrefix = isSpanish
            ? "Grabando. Los subtítulos empiezan"
            : "Recording. Captions start"
        XCTAssertTrue(
            renderedText(of: preparing).contains(preparingPrefix),
            "expected localized preparing copy, saw: \(renderedText(of: preparing))")
        XCTAssertTrue(
            app.continueLiveTranscriptionAttachFixture(),
            "the fixture must release the model-ready transition")
        XCTAssertTrue(
            app.staticTexts["Live captions are available now."].waitForExistenceFast(
                timeout: 8))
        XCTAssertFalse(preparing.exists)
        // "Catch me up" is a standing recording control on EVERY platform:
        // tapping answers honestly when the on-device model is unavailable,
        // so presence is deterministic even where generation is not.
        XCTAssertTrue(
            app.control(withIdentifier: "recording-catch-up")
                .waitForExistenceFast(timeout: 5),
            "the recording bar must offer the catch-up action")
        attachScreenshot(of: app, named: "recording-live-transcript-hot-attach")
    }

    @MainActor
    func testLiveTranscriptYieldsFollowWhileReadingHistory() throws {
        let app = try XCUIApplication.portavoz(simulateLiveTranscriptBrowsing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        record.click()

        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the fixture must publish a stable 18-row reading frontier")
        let transcript = app.control(withIdentifier: "recording-live-transcript")
        XCTAssertTrue(transcript.waitForExistenceFast(timeout: 8))
        XCTAssertTrue(
            app.staticTexts["History row 18 remains readable during live updates."]
                .waitForExistenceFast(timeout: 8))

        let jumpToLive = app.buttons["recording-jump-to-live"]
        // Hosted runners occasionally coalesce the first synthetic wheel
        // event. Retry the same user gesture until SwiftUI reports reader
        // ownership instead of turning one dropped event into a false failure.
        for _ in 0..<4 where !jumpToLive.exists {
            transcript.scroll(byDeltaX: 0, deltaY: 8)
        }
        XCTAssertTrue(
            jumpToLive.waitForExistenceFast(timeout: 5),
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
        XCTAssertTrue(jumpToLive.waitForDisappearance(timeout: 5))
        XCTAssertTrue(newestRow.waitForHittable(timeout: 5))
    }

    /// One live-assist journey covers objectives, proactive source disclosure,
    /// pause/resume, the next-question action, and measured talk balance.
    @MainActor
    func testRecordingOffersObjectivesNextQuestionAndTalkBalance() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            simulateSequoiaCapabilities: true,
            simulateLiveTranscriptBrowsing: true,
            simulateLiveApuntador: true,
            simulateProactiveAssist: true)
        app.launchEnvironment["PORTAVOZ_UI_TEST_DEFAULTS"] =
            #"{"companionEnabled":true}"#
        app.launchArguments.append("-seed-live-summary-ui")
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
        let isSpanish = record.label == "Nueva grabación"
        record.click()

        XCTAssertTrue(
            app.waitForLiveTranscriptFrontier(),
            "the live-assist assertions require closed captions")
        let expectedQuestion = UITestLocale.environmentLocale == "es"
            ? "¿Puedes explicar por qué el despliegue pasó al viernes?"
            : "Could you explain why the rollout moved to Friday?"
        XCTAssertTrue(
            app.staticTexts[expectedQuestion].waitForExistenceFast(timeout: 10),
            "the real bundled detector must surface the frozen bilingual question")
        let questionOnlyStatus = UITestLocale.environmentLocale == "es"
            ? "pregunta detectada"
            : "question detected"
        XCTAssertTrue(
            app.staticTexts[questionOnlyStatus].waitForExistenceFast(timeout: 5),
            "without an answer engine Sequoia must show an honest question-only card")
        let transcript = app.control(withIdentifier: "recording-live-transcript")
        XCTAssertTrue(transcript.waitForExistenceFast(timeout: 8))
        app.openAssistTab("summary")
        let liveSummary = app.control(withIdentifier: "recording-live-summary")
        XCTAssertTrue(
            liveSummary.waitForExistenceFast(timeout: 8),
            "Sequoia must render the deterministic rolling-summary checkpoint")
        let expectedLiveHighlights = UITestLocale.environmentLocale == "es"
            ? "Puntos clave en vivo"
            : "Live highlights"
        XCTAssertTrue(
            app.staticTexts[expectedLiveHighlights].waitForExistenceFast(timeout: 5),
            "the model-free checkpoint must disclose its extractive live highlights")

        app.openAssistTab("objectives")
        let panel = app.control(withIdentifier: "recording-objectives-panel")
        XCTAssertTrue(
            panel.waitForExistenceFast(timeout: 8),
            "the recording surface must offer the objectives panel")
        let field = app.control(withIdentifier: "recording-objective-field")
        XCTAssertTrue(field.waitForExistenceFast(timeout: 5))
        field.click()
        typeText("Cerrar el presupuesto del trimestre", in: app)
        app.control(withIdentifier: "recording-objective-add").click()
        XCTAssertTrue(
            app.staticTexts["Cerrar el presupuesto del trimestre"]
                .waitForExistenceFast(timeout: 5),
            "an added objective must appear in the checklist")

        XCTAssertTrue(app.control(withIdentifier: "recording-translation-picker").exists)
        XCTAssertTrue(
            app.control(withIdentifier: "recording-talk-balance")
                .waitForExistenceFast(timeout: 8),
            "closed captions must surface the talk-balance cue")
        XCTAssertFalse(
            app.control(withIdentifier: "recording-assist-tab-proactive").exists,
            "proactive help must be off until this recording explicitly opts in")

        XCTAssertTrue(
            app.recordingMoreItem("recording-next-question").exists,
            "the More menu must offer the next-question action")
        XCTAssertTrue(app.control(withIdentifier: "recording-hud").exists)
        app.recordingMoreItem("recording-proactive-assist").click()
        XCTAssertEqual(
            app.dismissRecordingMorePanel(bundleIdentifier: keyboardReceiverBundleIdentifier), .admitted)

        // Suggestions only becomes a tab once this recording opts in.
        app.openAssistTab("proactive")
        let proactivePanel = app.control(withIdentifier: "recording-proactive-panel")
        XCTAssertTrue(proactivePanel.waitForExistenceFast(timeout: 5))
        let objectiveSuggestion = app.control(
            withIdentifier: "recording-proactive-suggestion-open-objective")
        XCTAssertTrue(
            objectiveSuggestion.waitForExistenceFast(timeout: 5),
            "an open objective after sufficient finalized conversation must produce one inert card")
        XCTAssertTrue(app.staticTexts["Cerrar el presupuesto del trimestre"].exists)
        let expectedSource = isSpanish
            ? "Fuente: tu objetivo abierto + 16 turnos cerrados · 00:40–05:45"
            : "Source: your open objective + 16 closed turns · 00:40–05:45"
        XCTAssertTrue(
            app.staticTexts[expectedSource].exists,
            "the suggestion must disclose its exact objective and bounded caption window")

        let pause = app.control(withIdentifier: "recording-proactive-pause")
        XCTAssertTrue(pause.exists)
        let proactiveStatus = app.control(
            withIdentifier: "recording-proactive-status")
        pause.click()
        let paused = isSpanish ? "En pausa" : "Paused"
        XCTAssertTrue(proactiveStatus.waitForLabelOrValue(paused, timeout: 3))
        XCTAssertTrue(objectiveSuggestion.exists, "pause must preserve visible evidence")
        pause.click()
        let running = isSpanish ? "Observando señales locales" : "Watching local signals"
        XCTAssertTrue(proactiveStatus.waitForLabelOrValue(running, timeout: 3))

        // One panel open for both flips: the switch stays put while the
        // suggestions panel below it disappears and returns.
        // Each flip goes through the helper: a slower host can close the
        // panel between the two clicks, and the helper reopens it.
        app.recordingMoreItem("recording-proactive-assist").click()
        XCTAssertTrue(proactivePanel.waitForDisappearance(timeout: 3))
        app.recordingMoreItem("recording-proactive-assist").click()
        XCTAssertTrue(proactivePanel.waitForExistenceFast(timeout: 3))
        // The panel may stay open: the last assertion reads the suggestions
        // panel underneath, and teardown terminates the app.
        XCTAssertFalse(
            objectiveSuggestion.exists,
            "re-enabling the same recording must not repeat an emitted evidence signal")
    }

    @MainActor
    func testLiveTranslationUsesADistinctLabeledRail() throws {
        let app = try XCUIApplication.portavoz(simulateLiveTranscriptBrowsing: true)
        app.launchArguments.append("-seed-live-translation-ui")
        app.launchPortavoz()
        defer { app.terminate() }

        let record = app.buttons["library-new-recording-button"]
        XCTAssertTrue(record.waitForExistenceFast(timeout: 15))
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
            translation.waitForExistenceFast(timeout: 10),
            "a translated row must expose its own labeled visual boundary")
        let targetLanguageLabel =
            isSpanish ? "Traducción al inglés" : "English translation"
        XCTAssertEqual(
            translation.label, targetLanguageLabel,
            "the translation mark must name its language for assistive technology")
        attachScreenshot(of: app, named: "recording-live-translation-rail")
    }

    @MainActor
    func testActiveRecordingRemainsReachableAfterBrowsingTheLibrary() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            simulateLiveTranscriptBrowsing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        let homeRecord = app.buttons["home-record"]
        XCTAssertTrue(homeRecord.waitForStableFrame(timeout: 5))
        homeRecord.click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-live-transcript")
                .waitForExistenceFast(timeout: 8))

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
                .waitForExistenceFast(timeout: 10),
            "the historical meeting must replace the live route before returning")

        let returnToRecording = app.buttons["library-return-to-recording"]
        XCTAssertTrue(
            returnToRecording.waitForExistenceFast(timeout: 5),
            "an active capture must remain reachable from every library route")
        returnToRecording.click()
        XCTAssertTrue(
            app.control(withIdentifier: "recording-stop").waitForExistenceFast(timeout: 8))
        XCTAssertTrue(app.control(withIdentifier: "recording-elapsed-time").exists)
        attachScreenshot(of: app, named: "recording-return-to-live")
    }

    @MainActor
    func testSeededMeetingsGroupByRecency() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true)
        app.launchPortavoz()
        defer { app.terminate() }

        // The seeded meeting appears under a time-bucket section header, not
        // one flat "Meetings" list (design system timeline).
        XCTAssertTrue(
            app.staticTexts["Test meeting"].firstMatch.waitForExistenceFast(timeout: 15),
            "the seeded meeting must appear in the grouped library")
        // Its timestamp (Nov 2023) is old, so it lands under "Earlier".
        XCTAssertTrue(
            app.staticTexts["Earlier"].exists || app.staticTexts["Antes"].exists,
            "an old meeting must sit under the Earlier bucket")

        attachScreenshot(of: app, named: "band-2o-library-voice-mix")

        // Search crosses the SwiftUI binding, feature-model debounce, and
        // real FTS projection before publishing a new Library snapshot.
        let search = app.textFields["library-search-field"]
        XCTAssertTrue(search.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(app.finishTextFieldEditing(identifier: "library-search-field", timeout: 5))
        // Prove the row is already visible before focusing search: the click can
        // raise a native completion surface over the sidebar, which says
        // nothing about the launch fast path under test.
        let visibleMeeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(
            visibleMeeting.waitForHittable(timeout: 5),
            "exercise the already-visible launch fast path")
        search.click()
        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        // A normal key after launch readiness must not keep editing the search.
        // This tests actual responder ownership without private focus attributes
        // or requiring a particular native suggestion popover to appear.
        typeKey("x", modifierFlags: [], in: app)
        guard search.waitForValue("", timeout: 5) else {
            XCTFail("seed readiness must finish editing even when the meeting was already hittable")
            return
        }
        search.click()
        typeText("viernes", in: app)
        XCTAssertTrue(search.waitForValue("viernes", timeout: 5))
        // Commit native editing without accepting an AutoFill suggestion over
        // the real FTS hit; retain the exact query and destination assertions.
        typeKey(.tab, modifierFlags: [], in: app)
        XCTAssertTrue(search.waitForValue("viernes", timeout: 5))
        let hit = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-search-hit-'"))
            .firstMatch
        XCTAssertTrue(
            hit.waitForExistenceFast(timeout: 10),
            "the feature model must publish the seeded transcript search hit")
        XCTAssertTrue(
            hit.label.contains("Test meeting · 00:03"),
            "the search result must expose the meeting and exact hit timestamp")
        XCTAssertTrue(hit.waitForHittable(timeout: 5))
        hit.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
        attachScreenshot(of: app, named: "band-4c-fast-local-search")
    }

    @MainActor
    func testAskConversationAnswersAndSeeksToExactCitation() throws {
        let webFixture = try ApuntadorWebFixtureDescriptor
            .loadFromRunnerEnvironment()
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            simulateSequoiaCapabilities: true,
            includeWebFixture: true)
        app.configureFeatureUITestHandshake(
            argument: "-simulate-ask-progressive-handshake",
            name: "ask-empty",
            readyEnvironmentKey: "PORTAVOZ_UI_TEST_ASK_EMPTY_READY_PATH",
            continueEnvironmentKey:
                "PORTAVOZ_UI_TEST_ASK_EMPTY_CONTINUE_PATH")
        app.configureFeatureUITestHandshake(
            argument: "-simulate-ask-progressive-handshake",
            name: "ask-evidence",
            readyEnvironmentKey: "PORTAVOZ_UI_TEST_ASK_EVIDENCE_READY_PATH",
            continueEnvironmentKey:
                "PORTAVOZ_UI_TEST_ASK_EVIDENCE_CONTINUE_PATH")
        app.configureFeatureUITestHandshake(
            argument: "-simulate-ask-progressive-handshake",
            name: "ask-notes",
            readyEnvironmentKey: "PORTAVOZ_UI_TEST_ASK_NOTES_READY_PATH",
            continueEnvironmentKey:
                "PORTAVOZ_UI_TEST_ASK_NOTES_CONTINUE_PATH")
        app.configureFeatureUITestHandshake(
            argument: "-simulate-ask-progressive-handshake",
            name: "ask-answer",
            readyEnvironmentKey: "PORTAVOZ_UI_TEST_ASK_ANSWER_READY_PATH",
            continueEnvironmentKey:
                "PORTAVOZ_UI_TEST_ASK_ANSWER_CONTINUE_PATH")
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()
        let field = app.textFields["ask-question-field"]
        XCTAssertTrue(field.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-source-status-library"]
                .waitForExistenceFast(timeout: 5))
        let webSource = app.descendants(matching: .any)["ask-source-web"]
        XCTAssertTrue(webSource.waitForExistenceFast(timeout: 5))
        webSource.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-source-status-web"]
                .waitForExistenceFast(timeout: 5),
            "Web must disclose its direct-source boundary")
        let webQuestion = UITestLocale.environmentLocale == "es"
            ? "¿Cuándo se lanza Costa?"
            : "When does Harbor launch?"
        let webPath = UITestLocale.environmentLocale == "es"
            ? "/source/fresh-es"
            : "/source/fresh-en"
        field.click()
        typeText(webQuestion, in: app)
        XCTAssertTrue(field.waitForValue(webQuestion, timeout: 5))
        let webSourceField = app.textFields["ask-web-source-field"]
        XCTAssertTrue(webSourceField.waitForExistenceFast(timeout: 5))
        webSourceField.click()
        let webURL = try XCTUnwrap(
            URL(string: webPath, relativeTo: webFixture.baseURL)?.absoluteURL)
        typeText(webURL.absoluteString, in: app)
        XCTAssertTrue(webSourceField.waitForValue(webURL.absoluteString, timeout: 5))
        let consent = app.checkBoxes["ask-web-consent"]
        XCTAssertTrue(consent.waitForEnabled(timeout: 5))
        XCTAssertFalse(
            app.buttons["ask-submit"].isEnabled,
            "Web must remain blocked before one-request consent")
        consent.click()
        XCTAssertTrue(app.buttons["ask-submit"].waitForEnabled(timeout: 5))
        app.buttons["ask-submit"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-pending-source-web"]
                .waitForExistenceFast(timeout: 5))
        let webAnswer = UITestLocale.environmentLocale == "es"
            ? "Costa se lanza el 18 de septiembre a las 10:00 UTC [1]."
            : "Harbor launches September 14 at 09:00 UTC [1]."
        XCTAssertTrue(
            app.staticTexts[webAnswer].waitForExistenceFast(timeout: 10),
            "the real app must answer from the deterministic loopback page")
        let webCitation = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-web-citation-' "
                + "AND NOT identifier ENDSWITH '-freshness'"))
            .firstMatch
        XCTAssertTrue(webCitation.waitForExistenceFast(timeout: 5))
        let freshness = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-web-citation-' "
                + "AND identifier ENDSWITH '-freshness'"))
            .firstMatch
        XCTAssertTrue(
            freshness.waitForExistenceFast(timeout: 5),
            "the citation must disclose its observed source date and freshness")
        let freshnessText = renderedText(of: freshness)
        let expectedFreshness = UITestLocale.environmentLocale == "es"
            ? "Fuente reciente"
            : "Fresh source"
        XCTAssertTrue(freshnessText.contains(expectedFreshness), freshnessText)
        XCTAssertTrue(freshnessText.contains("2026"), freshnessText)
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-exchange-source-web"]
                .waitForExistenceFast(timeout: 5))
        XCTAssertFalse(
            consent.isSelected,
            "one-request Web consent must be consumed after submission")
        attachScreenshot(of: app, named: "ask-consented-cited-web-answer")

        let notesSource = app.descendants(matching: .any)["ask-source-notes"]
        XCTAssertTrue(notesSource.waitForExistenceFast(timeout: 5))
        notesSource.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-source-status-notes"]
                .waitForExistenceFast(timeout: 5),
            "Notes must disclose the raw-local-note-only boundary")
        field.click()
        typeText("budget Q3", in: app)
        XCTAssertTrue(field.waitForValue("budget Q3", timeout: 5))
        app.buttons["ask-submit"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-pending-source-notes"]
                .waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            app.waitForFeatureUITestHandshakeReady(
                readyEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_NOTES_READY_PATH"),
            "Notes generation must remain pending until its evidence is inspected")
        let pendingNote = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'ask-pending-note-citation-'"))
            .firstMatch
        XCTAssertTrue(
            pendingNote.waitForExistenceFast(timeout: 10),
            "the exact raw note must appear before local generation finishes")
        let expectedAuthor = UITestLocale.environmentLocale == "es" ? "Tú" : "You"
        let pendingNoteLabel = pendingNote.label
        XCTAssertTrue(pendingNoteLabel.contains(expectedAuthor), pendingNoteLabel)
        XCTAssertTrue(pendingNoteLabel.contains("Test meeting · 00:12"), pendingNoteLabel)
        XCTAssertFalse(app.staticTexts["Debes revisar el budget Q3."].exists)
        XCTAssertTrue(
            app.continueFeatureUITestHandshake(
                readyEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_NOTES_READY_PATH",
                continueEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_NOTES_CONTINUE_PATH"),
            "the Notes fixture must release generation only after evidence assertions")
        XCTAssertTrue(
            app.staticTexts["Debes revisar el budget Q3."]
                .waitForExistenceFast(timeout: 10),
            "the seeded real app must answer through the typed Notes lane")
        let noteCitation = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-note-citation-'"))
            .firstMatch
        XCTAssertTrue(noteCitation.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(noteCitation.label.contains(expectedAuthor), noteCitation.label)
        XCTAssertTrue(noteCitation.label.contains("Test meeting · 00:12"), noteCitation.label)
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-exchange-source-notes"]
                .waitForExistenceFast(timeout: 5))

        let meetingSource = app.descendants(matching: .any)["ask-source-meeting"]
        XCTAssertTrue(meetingSource.waitForExistenceFast(timeout: 5))
        meetingSource.click()
        let meetingPicker = app.descendants(matching: .any)[
            "ask-source-meeting-picker"]
        XCTAssertTrue(meetingPicker.waitForExistenceFast(timeout: 10))
        meetingPicker.click()
        let meetingOption = app.menuItems.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'ask-source-meeting-option-'"))
            .firstMatch
        XCTAssertTrue(
            meetingOption.waitForExistenceFast(timeout: 5),
            "the exact seeded meeting must be exposed as an identified menu item")
        meetingOption.click()
        field.click()
        typeText("sinresultado", in: app)
        XCTAssertTrue(field.waitForValue("sinresultado", timeout: 5))
        XCTAssertTrue(app.buttons["ask-submit"].isEnabled)
        app.buttons["ask-submit"].click()
        XCTAssertTrue(
            app.waitForFeatureUITestHandshakeReady(
                readyEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_EMPTY_READY_PATH"),
            "the empty retrieval must remain cancellable until replacement")
        let pendingQuestion = app.descendants(matching: .any)[
            "ask-pending-question"]
        XCTAssertTrue(pendingQuestion.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-pending-source-meeting"]
                .waitForExistenceFast(timeout: 5))

        field.click()
        typeText("viernes", in: app)
        XCTAssertTrue(field.waitForValue("viernes", timeout: 5))
        app.buttons["ask-submit"].click()
        XCTAssertTrue(
            app.waitForFeatureUITestHandshakeRelease(
                readyEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_EMPTY_READY_PATH"),
            "replacement must cancel and clean the preceding retrieval")
        XCTAssertTrue(
            pendingQuestion.waitForLabelOrValue("viernes", timeout: 5),
            "a new Ask submission must replace pending work")

        let progressiveEvidence = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-pending-citation-'"))
            .firstMatch
        XCTAssertTrue(
            progressiveEvidence.waitForExistenceFast(timeout: 10),
            "exact evidence must appear before local answer generation finishes")
        XCTAssertTrue(progressiveEvidence.label.contains("Test meeting · 00:03"))
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-progress-refining"]
                .waitForExistenceFast(timeout: 5),
            "Ask must distinguish lexical evidence from semantic refinement")
        attachScreenshot(of: app, named: "ask-progressive-evidence")
        XCTAssertTrue(
            app.continueFeatureUITestHandshake(
                readyEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_EVIDENCE_READY_PATH",
                continueEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_EVIDENCE_CONTINUE_PATH"),
            "the deterministic fixture must release lexical evidence exactly once")

        XCTAssertTrue(
            app.descendants(matching: .any)["ask-progress-generating"]
                .waitForExistenceFast(timeout: 5),
            "Ask must expose answer generation after the evidence set is fenced")
        let pendingAnswer = app.staticTexts["ask-pending-answer"]
        XCTAssertTrue(
            pendingAnswer.waitForExistenceFast(timeout: 5),
            "the local answer must become readable before generation completes")
        XCTAssertTrue(renderedText(of: pendingAnswer).contains("presupuesto"))
        XCTAssertTrue(
            app.continueFeatureUITestHandshake(
                readyEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_ANSWER_READY_PATH",
                continueEnvironmentKey:
                    "PORTAVOZ_UI_TEST_ASK_ANSWER_CONTINUE_PATH"),
            "the deterministic fixture must release the partial answer exactly once")
        XCTAssertTrue(
            app.staticTexts["El presupuesto se revisó y el rollout quedó para el viernes."]
                .waitForExistenceFast(timeout: 10),
            "manual Ask must publish the seeded local answer even when Apple Foundation Models are unavailable")
        XCTAssertFalse(
            app.descendants(matching: .any)["ask-generation-unavailable"].exists,
            "the explicit manual Ask route must not be gated by Sequoia capabilities")
        let citation = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-citation-'"))
            .firstMatch
        XCTAssertTrue(citation.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(citation.label.contains("Test meeting · 00:03"))
        XCTAssertTrue(
            app.descendants(matching: .any)["ask-exchange-source-meeting"]
                .waitForExistenceFast(timeout: 5))
        attachScreenshot(of: app, named: "band-6c5-full-ask-answer")

        citation.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactPersonCommitmentsAndEvidence() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedAskMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()

        let memorySurface = app.descendants(matching: .any)[
            "ask-surface-person-commitments"]
        XCTAssertTrue(memorySurface.waitForExistenceFast(timeout: 10))
        memorySurface.click()

        let title = app.descendants(matching: .any)["ask-memory-title"]
        XCTAssertTrue(title.waitForExistenceFast(timeout: 5))
        XCTAssertEqual(
            renderedText(of: title),
            UITestLocale.environmentLocale == "es"
                ? "Compromisos actuales"
                : "Current commitments")

        let person = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-memory-person-'"))
            .firstMatch
        XCTAssertTrue(person.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(person.label.contains("Ana"))
        person.click()

        let selected = app.descendants(matching: .any)[
            "ask-memory-selected-person"]
        XCTAssertTrue(selected.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: selected).contains("Ana"))
        app.buttons["ask-memory-load"].click()

        let commitment = app.descendants(matching: .any)[
            "ask-memory-commitment-B5D10000-0000-4000-8000-000000000005"]
        XCTAssertTrue(commitment.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(app.staticTexts["Prepare the rollout"].exists)
        let evidence = app.buttons[
            "ask-memory-evidence-B5D10000-0000-4000-8000-000000000005-0"]
        XCTAssertTrue(evidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(evidence.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "ask-confirmed-person-commitments")

        evidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactCommitmentBlockersAndEvidence() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedAskMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()
        let memorySurface = app.descendants(matching: .any)[
            "ask-surface-person-commitments"]
        XCTAssertTrue(memorySurface.waitForExistenceFast(timeout: 10))
        memorySurface.click()

        let person = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-memory-person-'"))
            .firstMatch
        XCTAssertTrue(person.waitForExistenceFast(timeout: 10))
        person.click()
        app.buttons["ask-memory-load"].click()

        let loadBlockers = app.buttons[
            "ask-memory-blockers-load-B5D10000-0000-4000-8000-000000000005"]
        XCTAssertTrue(loadBlockers.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(loadBlockers.label.contains("Prepare the rollout"))
        loadBlockers.click()

        let blocker = app.descendants(matching: .any)[
            "ask-memory-blocker-B5D50000-0000-4000-8000-000000000007"]
        XCTAssertTrue(blocker.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(renderedText(of: blocker).contains(
            "La revisión de seguridad debe aprobarse antes del rollout."))
        let blockedCommitment = app.descendants(matching: .any)[
            "ask-memory-blocker-commitment-B5D50000-0000-4000-8000-000000000007"]
        XCTAssertTrue(blockedCommitment.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: blockedCommitment).contains(
            "Prepare the rollout"))

        let primaryEvidence = app.buttons[
            "ask-memory-blocker-evidence-B5D50000-0000-4000-8000-000000000007-0"]
        let commitmentEvidence = app.buttons[
            "ask-memory-blocker-evidence-B5D50000-0000-4000-8000-000000000007-1"]
        XCTAssertTrue(primaryEvidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(primaryEvidence.label.contains("Security review · 00:04"))
        XCTAssertTrue(commitmentEvidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(commitmentEvidence.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "ask-confirmed-commitment-blockers")

        primaryEvidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:04", timeout: 10))
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactTopicDecisionsAndEvidence() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedAskTopicMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()

        let topicSurface = app.descendants(matching: .any)[
            "ask-surface-topic-decisions"]
        XCTAssertTrue(topicSurface.waitForExistenceFast(timeout: 10))
        topicSurface.click()

        let title = app.descendants(matching: .any)["ask-topic-title"]
        XCTAssertTrue(title.waitForExistenceFast(timeout: 5))
        XCTAssertEqual(
            renderedText(of: title),
            UITestLocale.environmentLocale == "es"
                ? "Memoria del tema"
                : "Topic memory")

        let topic = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-option-'"))
            .firstMatch
        XCTAssertTrue(topic.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(topic.label.contains("model rollout"))
        topic.click()

        let selected = app.descendants(matching: .any)["ask-topic-selected"]
        XCTAssertTrue(selected.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: selected).contains("model rollout"))
        app.buttons["ask-topic-load"].click()

        let decision = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-decision-'"))
            .firstMatch
        XCTAssertTrue(decision.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            renderedText(of: decision).contains(
                "El rollout del modelo queda para el viernes."))
        let evidence = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-evidence-'"))
            .firstMatch
        XCTAssertTrue(evidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(evidence.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "ask-confirmed-topic-decisions")

        evidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactTopicFirstDiscussionAndEvidence() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedAskTopicMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()

        let topicSurface = app.descendants(matching: .any)[
            "ask-surface-topic-decisions"]
        XCTAssertTrue(topicSurface.waitForExistenceFast(timeout: 10))
        topicSurface.click()

        let topic = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-option-'"))
            .firstMatch
        XCTAssertTrue(topic.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(topic.label.contains("model rollout"))
        topic.click()

        let firstDiscussionJob = app.descendants(matching: .any)[
            "ask-topic-job-first-discussion"]
        XCTAssertTrue(firstDiscussionJob.waitForExistenceFast(timeout: 5))
        firstDiscussionJob.click()
        app.buttons["ask-topic-load"].click()

        let discussion = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'ask-topic-first-discussion-' "
                    + "AND NOT identifier BEGINSWITH "
                    + "'ask-topic-first-discussion-evidence-'"))
            .firstMatch
        XCTAssertTrue(discussion.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(renderedText(of: discussion).contains("Test meeting"))
        let evidence = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'ask-topic-first-discussion-evidence-'"))
            .firstMatch
        XCTAssertTrue(evidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(evidence.label.contains("Test meeting · 00:03"))
        attachScreenshot(of: app, named: "ask-confirmed-topic-first-discussion")

        evidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactTopicDecisionConflictsAndEvidence() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedAskTopicMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()

        let topicSurface = app.descendants(matching: .any)[
            "ask-surface-topic-decisions"]
        XCTAssertTrue(topicSurface.waitForExistenceFast(timeout: 10))
        topicSurface.click()

        let topic = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-option-'"))
            .firstMatch
        XCTAssertTrue(topic.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(topic.label.contains("model rollout"))
        topic.click()

        let conflictJob = app.descendants(matching: .any)[
            "ask-topic-job-decision-conflicts"]
        XCTAssertTrue(conflictJob.waitForExistenceFast(timeout: 5))
        conflictJob.click()
        app.buttons["ask-topic-load"].click()

        let conflict = app.descendants(matching: .any)[
            "ask-topic-conflict-B5D40000-0000-4000-8000-000000000005"]
        XCTAssertTrue(conflict.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(
            renderedText(of: conflict).contains(
                "El rollout del modelo queda para el viernes."))
        let replaced = app.descendants(matching: .any)[
            "ask-topic-conflict-replaced-B5D40000-0000-4000-8000-000000000005"]
        XCTAssertTrue(replaced.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(
            renderedText(of: replaced).contains(
                "El rollout del modelo quedaba para el jueves."))
        let currentEvidence = app.buttons[
            "ask-topic-conflict-evidence-B5D40000-0000-4000-8000-000000000005-0"]
        let replacedEvidence = app.buttons[
            "ask-topic-conflict-evidence-B5D40000-0000-4000-8000-000000000005-1"]
        XCTAssertTrue(currentEvidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(replacedEvidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(currentEvidence.label.contains("Test meeting · 00:03"))
        XCTAssertTrue(replacedEvidence.label.contains("Planning baseline · 00:04"))
        attachScreenshot(of: app, named: "ask-confirmed-topic-decision-conflicts")

        currentEvidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
    }

    @MainActor
    func testAskConfirmedMemoryLoadsExactTopicChangesSinceMeetingAndEvidence() throws {
        let app = try XCUIApplication.portavoz(
            seedDemo: true,
            seedAskTopicMemory: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(app.waitForSeededLibraryToSettle())
        app.buttons["library-ask-button"].click()

        let topicSurface = app.descendants(matching: .any)[
            "ask-surface-topic-decisions"]
        XCTAssertTrue(topicSurface.waitForExistenceFast(timeout: 10))
        topicSurface.click()

        let topic = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'ask-topic-option-'"))
            .firstMatch
        XCTAssertTrue(topic.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(topic.label.contains("model rollout"))
        topic.click()

        let changesSinceJob = app.descendants(matching: .any)[
            "ask-topic-job-changes-since"]
        XCTAssertTrue(changesSinceJob.waitForExistenceFast(timeout: 5))
        changesSinceJob.click()

        let anchorSearch = app.textFields["ask-topic-anchor-search"]
        XCTAssertTrue(anchorSearch.waitForExistenceFast(timeout: 5))
        anchorSearch.click()
        typeText("Planning", in: app)
        XCTAssertTrue(anchorSearch.waitForValue("Planning", timeout: 5))

        let anchor = app.buttons[
            "ask-topic-anchor-option-B5D40000-0000-4000-8000-000000000003"]
        XCTAssertTrue(anchor.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(anchor.label.contains("Planning baseline"))
        anchor.click()

        let selectedAnchor = app.descendants(matching: .any)[
            "ask-topic-anchor-selected"]
        XCTAssertTrue(selectedAnchor.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: selectedAnchor).contains(
            "Planning baseline"))
        let load = app.buttons["ask-topic-load"]
        XCTAssertTrue(load.isEnabled)
        load.click()

        let change = app.descendants(matching: .any)[
            "ask-topic-change-since-B5D40000-0000-4000-8000-000000000005"]
        XCTAssertTrue(change.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(renderedText(of: change).contains(
            "El rollout del modelo queda para el viernes."))
        let replaced = app.descendants(matching: .any)[
            "ask-topic-change-since-replaced-"
                + "B5D40000-0000-4000-8000-000000000005"]
        XCTAssertTrue(replaced.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: replaced).contains(
            "El rollout del modelo quedaba para el jueves."))
        let anchorSummary = app.descendants(matching: .any)[
            "ask-topic-change-since-anchor"]
        XCTAssertTrue(anchorSummary.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(renderedText(of: anchorSummary).contains(
            "Planning baseline"))

        let currentEvidence = app.buttons[
            "ask-topic-change-since-evidence-"
                + "B5D40000-0000-4000-8000-000000000005-0"]
        let replacedEvidence = app.buttons[
            "ask-topic-change-since-evidence-"
                + "B5D40000-0000-4000-8000-000000000005-1"]
        XCTAssertTrue(currentEvidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(replacedEvidence.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(currentEvidence.label.contains("Test meeting · 00:03"))
        XCTAssertTrue(replacedEvidence.label.contains(
            "Planning baseline · 00:04"))
        attachScreenshot(of: app, named: "ask-confirmed-topic-changes-since")

        currentEvidence.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
    }

    @MainActor
    func testCommandPaletteSearchAnswerAndCitationSurviveNoStaleState() throws {
        let app = try XCUIApplication.portavoz(seedDemo: true)
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
            app.control(withIdentifier: "player-current-time").waitForExistenceFast(timeout: 10))
        typeKey("k", modifierFlags: .command, in: app)
        let field = app.textFields["palette-query-field"]
        XCTAssertTrue(field.waitForExistenceFast(timeout: 10))
        let source = app.descendants(matching: .any)["palette-source-library"]
        XCTAssertTrue(source.waitForExistenceFast(timeout: 5))
        let expectedSource = UITestLocale.environmentLocale == "es"
            ? "Fuente de la respuesta: Biblioteca"
            : "Answer source: Library"
        XCTAssertTrue(source.waitForLabelOrValue(expectedSource, timeout: 5))
        XCTAssertTrue(field.isHittable, "the palette must stay above the main window")
        field.click()
        typeText("viernes", in: app)
        XCTAssertTrue(field.waitForValue("viernes", timeout: 5))
        XCTAssertTrue(
            app.buttons["palette-hit-0"].waitForExistenceFast(timeout: 10),
            "the palette must publish instant local FTS results")
        typeKey(.return, modifierFlags: [], in: app)
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
            app.staticTexts["palette-answer"].waitForExistenceFast(timeout: 20),
            "Enter must use the same full Ask workflow")
        XCTAssertTrue(app.buttons["palette-copy-answer"].exists)
        let citation = app.buttons["palette-citation-0"]
        XCTAssertTrue(citation.exists)
        XCTAssertTrue(citation.label.contains("Test meeting · 00:03"))
        let paletteWindow = app.windows["command-palette-window"]
        XCTAssertTrue(
            paletteWindow.waitForExistenceFast(timeout: 5),
            "the palette window must remain visible while showing its answer")
        attachElementScreenshot(of: paletteWindow, named: "band-6c5-command-palette-answer")

        citation.click()
        let currentTime = app.staticTexts["player-current-time"]
        XCTAssertTrue(currentTime.waitForExistenceFast(timeout: 10))
        XCTAssertTrue(currentTime.waitForValue("0:03", timeout: 10))
    }

    @MainActor
    func testLaunchRecoversInterruptedStagingAudio() throws {
        let app = try XCUIApplication.portavoz(seedRecovery: true)
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
            app.control(withIdentifier: "player-play-pause").waitForExistenceFast(timeout: 10),
            "the recovered CAF must be playable without loading an ML model")
        XCTAssertTrue(
            app.control(withIdentifier: "detail-refine").exists,
            "the recovered meeting must retain its explicit transcript recovery action")
    }

    @MainActor
    func testLaunchResumesDurablePostCaptureProcessing() throws {
        let app = try XCUIApplication.portavoz(seedProcessing: true)
        app.launchPortavoz()
        defer { app.terminate() }

        XCTAssertTrue(
            app.staticTexts["Durable processing recovery"]
                .firstMatch.waitForExistenceFast(timeout: 15),
            "the durable processing fixture must remain discoverable while work resumes")
        let meeting = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'library-meeting-'"))
            .firstMatch
        XCTAssertTrue(meeting.waitForExistenceFast(timeout: 5))
        XCTAssertTrue(meeting.waitForHittable(timeout: 10))
        meeting.click()

        XCTAssertTrue(
            app.staticTexts["El procesamiento durable conserva este texto."]
                .waitForExistenceFast(timeout: 10),
            "diarization completion must atomically preserve the original transcript")
        XCTAssertTrue(
            app.staticTexts["Durable processing finished."]
                .waitForExistenceFast(timeout: 15),
            "the resumed worker must publish its dependent summary and refresh the detail")
        attachScreenshot(of: app, named: "durable-post-capture-recovery")
    }
}
