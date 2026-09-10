import ApplicationKit
import Foundation
import XCTest

extension ArchitectureDependencyTests {
    func testResourceWorkloadTelemetryRemainsContentFreeAndOutsideAudioCallbacks() throws {
        let contract = try Self.contents(
            of: "Sources/PortavozCore/ResourceWorkload.swift")
        guard let descriptorStart = contract.range(
            of: "public struct ResourceWorkloadDescriptor"),
            let spanStart = contract.range(
                of: "public struct ResourceWorkloadSpan",
                range: descriptorStart.upperBound..<contract.endIndex)
        else {
            return XCTFail("Resource workload descriptor boundary is missing")
        }
        let descriptor = contract[
            descriptorStart.lowerBound..<spanStart.lowerBound]
        for forbidden in [
            "String", "URL", "MeetingID", "Transcript", "modelID", "path", "Error",
        ] {
            XCTAssertFalse(
                descriptor.contains(forbidden),
                "Workload descriptors must not admit content field \(forbidden)")
        }

        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppResourceWorkloadTelemetry.swift")
        for forbidden in [
            "MeetingID", "TranscriptSegment", "URL", "localizedDescription",
            "modelID", "relativePath", "Logger(",
        ] {
            XCTAssertFalse(
                adapter.contains(forbidden),
                "Platform telemetry must not record \(forbidden)")
        }
        XCTAssertTrue(adapter.contains("workloadClass.rawValue"))
        XCTAssertTrue(adapter.contains("kind.rawValue"))
        XCTAssertTrue(adapter.contains("operation.rawValue"))
        XCTAssertTrue(adapter.contains("outcome.rawValue"))
        XCTAssertFalse(adapter.contains("span.id, privacy:"))

        let audioCallbackInstrumentation = try Self.sourceMatches(
            under: "Sources/AudioCaptureKit",
            pattern: #"ResourceWorkload(?:Telemetry|Descriptor|Event|Span)"#)
        XCTAssertTrue(
            audioCallbackInstrumentation.isEmpty,
            "Measurement must never enter capture callbacks: \(audioCallbackInstrumentation)")

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")
        XCTAssertTrue(architecture.contains(
            "Resource measurement preserves those owners"))
        XCTAssertTrue(decisions.contains("## D148"))
        XCTAssertTrue(appSpec.contains(
            "### Resource workload measurement (D148)"))
    }

    func testProactiveMeetingAssistIsOptInSourceClosedAndBounded() throws {
        let policy = try Self.contents(
            of: "Sources/IntelligenceKit/ProactiveMeetingAssist.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/RecordingProactiveAssistModel.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let controllerState = try Self.contents(
            of: "Sources/portavoz-app/RecordingControllerState.swift")
        let detection = try Self.contents(
            of: "Sources/portavoz-app/RecordingController+CompanionDetection.swift")
        let toolbar = try Self.contents(
            of: "Sources/portavoz-app/RecordingToolbar.swift")
        let liveAssist = try Self.contents(
            of: "Sources/portavoz-app/RecordingLiveAssist.swift")
        let stressGate = try Self.contents(
            of: "scripts/run-recording-reliability-stress.sh")
        let releaseGate = try Self.contents(
            of: "scripts/run-release-reliability-gates.sh")

        for required in [
            "public static let maximumSourceRows = 64",
            "public static let maximumVisibleSuggestions = 3",
            "public static let maximumSourceDuration: TimeInterval = recentWindow",
            "public static let maximumTimelineOffset: TimeInterval = 1_000_000_000",
            "public static let minimumEmissionInterval: TimeInterval = 180",
            "case openObjective = \"open-objective\"",
            "case talkBalance = \"talk-balance\"",
            "Set(boundedClosed.map(\\.id)).count == boundedClosed.count",
            "boundedClosed.allSatisfy({ $0.meetingID == meetingID })",
            "mutableTail.meetingID == meetingID",
            "isValidSourceRow(mutableTail)",
            "!boundedClosed.contains(where: { $0.id == mutableTail.id })",
            "!TranscriptSegmentOrder.canonicalOrder(mutableTail, newest)",
        ] {
            XCTAssertTrue(
                policy.contains(required),
                "Bounded proactive policy is missing \(required)")
        }
        for forbidden in ["FoundationModels", "URLSession", "Task {", "AsyncStream"] {
            XCTAssertFalse(
                policy.contains(forbidden),
                "Proactive admission must remain source-closed and synchronous")
        }
        XCTAssertEqual(
            policy.components(separatedBy: "public init(").count - 1,
            1,
            "Only user-authored objective input may be publicly constructed; policy output authority stays internal")

        for required in [
            "private(set) var isEnabled = false",
            "private(set) var isPaused = false",
            "private var emittedSignals: Set<ProactiveAssistSignalKey> = []",
            "func setPaused(",
            "func reset()",
        ] {
            XCTAssertTrue(model.contains(required))
        }
        XCTAssertFalse(model.contains("Task {"))
        XCTAssertGreaterThanOrEqual(
            controller.components(
                separatedBy: "proactiveAssist.reset()").count - 1,
            3,
            "Start, Stop, and next-session lifecycle paths must clear proactive state")
        XCTAssertTrue(detection.contains("observeProactiveAssist()"))
        XCTAssertTrue(controllerState.contains(
            "func observeProactiveAssist() {\n        guard phase == .recording else { return }"))
        for gate in [stressGate, releaseGate] {
            XCTAssertTrue(gate.contains("ProactiveMeetingAssistPolicyTests"))
            XCTAssertTrue(gate.contains("RecordingProactiveAssistModelTests"))
        }

        for identifier in [
            "recording-proactive-assist",
            "recording-proactive-pause",
        ] {
            XCTAssertTrue(toolbar.contains(identifier))
        }
        for identifier in [
            "recording-proactive-panel",
            "recording-proactive-status",
            "recording-proactive-suggestion-",
            "recording-proactive-dismiss-",
            "recording-proactive-source-",
        ] {
            XCTAssertTrue(liveAssist.contains(identifier))
        }

        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let intelligenceSpec = try Self.contents(
            of: "docs/specs/04-intelligence.md")
        let appSpec = try Self.contents(
            of: "docs/specs/06-app-macos.md")
        let qualitySpec = try Self.contents(
            of: "docs/specs/08-quality.md")
        XCTAssertTrue(architecture.contains(
            "Bounded source-closed proactive meeting assistance"))
        XCTAssertTrue(decisions.contains("## D390"))
        XCTAssertTrue(intelligenceSpec.contains(
            "### Bounded source-closed proactive assistance (D390)"))
        XCTAssertTrue(appSpec.contains(
            "### Recording-scoped proactive assistance (D390)"))
        XCTAssertTrue(qualitySpec.contains(
            "### Bounded proactive assistance qualification (D390)"))
    }

    func testPlatformSecurityImplementationHasOneOuterOwner() throws {
        let securityImports = try Self.imports(under: "Sources")
            .filter { $0.module == "Security" }
            .map(\.file)
            .sorted()
        XCTAssertEqual(
            securityImports,
            [
                "IntegrationsKit/CloudKitMeetingSyncPlatform.swift",
                "PlatformKit/KeychainSecretStore.swift",
            ])

        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))
        XCTAssertEqual(
            try XCTUnwrap(targets["PlatformKit"]).dependencies,
            ["PortavozCore"])
        for target in ["portavoz-app", "portavoz-cli", "PortavozTests"] {
            XCTAssertTrue(try XCTUnwrap(targets[target]).dependencies.contains("PlatformKit"))
        }

        let directConsumers = try Self.sourceMatches(
            under: "Sources",
            pattern: #"\bKeychainSecretStore\s*\("#)
        XCTAssertEqual(
            directConsumers.sorted(),
            ["portavoz-app/AppServices.swift", "portavoz-cli/CLIComposition.swift"])
    }

    func testOnboardingPermissionsUsePlatformAdapters() throws {
        let onboarding = try Self.contents(
            of: "Sources/portavoz-app/OnboardingView.swift")
        let services = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Permissions.swift")
        let startRuntime = try Self.contents(
            of: "Sources/portavoz-app/AppServices+StartRecording.swift")
        let platform = try Self.contents(
            of: "Sources/PlatformKit/MicrophonePermissionClient.swift")

        XCTAssertFalse(onboarding.contains("AVCaptureDevice"))
        XCTAssertFalse(onboarding.contains("CalendarAttendeeSource"))
        XCTAssertTrue(onboarding.contains("services.requestMicrophonePermission()"))
        XCTAssertTrue(onboarding.contains("services.requestOnboardingCalendarAccess()"))
        XCTAssertTrue(services.contains("microphonePermissions.request()"))
        XCTAssertTrue(services.contains("microphonePermissions.authorizeIfNeeded()"))
        let recordingAuthorization = try XCTUnwrap(startRuntime.range(
            of: "services.authorizeMicrophoneForRecording()"))
        let microphoneConstruction = try XCTUnwrap(startRuntime.range(
            of: "let microphone = MicrophoneSource("))
        XCTAssertLessThan(
            recordingAuthorization.lowerBound,
            microphoneConstruction.lowerBound)
        XCTAssertTrue(platform.contains("AVCaptureDevice.authorizationStatus"))
        XCTAssertTrue(platform.contains("AVCaptureDevice.requestAccess"))
    }

    func testAppMeetingLifecycleWritesEnterThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\b(?:services\.)?store\.(?:delete|restore|purge)\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App MeetingStore lifecycle writes must enter through ApplicationKit: \(violations)")
    }

    func testAppSummaryRegenerationEntersThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"services\.store\.latestSummary\s*\(|services\.configuredSummaryProvider\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App summary regeneration must enter through ApplicationKit: \(violations)")
    }

    func testAppAudioImportEntersThroughApplicationKit() throws {
        let definitions = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"\bfunc\s+importMeeting\s*\("#)

        XCTAssertEqual(
            definitions,
            ["AppServices+ImportMeeting.swift"],
            "Audio import orchestration must not return to AppServices or a view")
    }

    func testAppMeetingRefineEntersThroughApplicationKit() throws {
        let violations = try Self.sourceMatches(
            under: "Sources/portavoz-app",
            pattern: #"services\.store\.(?:applyRefinedCast|replaceCast|replaceCompanionCards)\s*\("#)

        XCTAssertTrue(
            violations.isEmpty,
            "App refine mutations must enter through ApplicationKit: \(violations)")
    }

    func testAppRecordingStopEntersThroughApplicationKit() throws {
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")

        XCTAssertTrue(controller.contains("services.stopRecording.execute"))
        XCTAssertFalse(controller.contains("services.store.installCapturedSnapshot"))
        XCTAssertFalse(controller.contains(
            "PostCaptureProcessingCoordinator.initialDiarizationRequest"))
    }

    func testAppRecordingStartEntersThroughApplicationKit() throws {
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+StartRecording.swift")

        XCTAssertTrue(controller.contains("services.startRecording.execute"))
        XCTAssertTrue(adapter.contains("var startRecording: StartRecording"))
        XCTAssertFalse(
            adapter.contains("try await services.loadEnginesIfNeeded()"),
            "Recording start must never wait for model preparation")
        XCTAssertTrue(adapter.contains("LiveTranscriptionAttacher("))
        XCTAssertTrue(adapter.contains("services.acquireResidentLiveSpeechRuntime()"))
        XCTAssertTrue(adapter.contains("services.acquireLiveSpeechRuntime()"))
        XCTAssertTrue(adapter.contains("voiceProcessing: false"))
        XCTAssertFalse(adapter.contains("aecEnabled"))
        XCTAssertTrue(controller.contains("receiveLiveTranscription("))
        XCTAssertFalse(controller.contains("services.store.beginRecording"))
        XCTAssertFalse(controller.contains("MicrophoneSource("))
        XCTAssertFalse(controller.contains("RecordingSession("))
        XCTAssertFalse(controller.contains("makeSystemTapSource"))

        let microphone = try Self.contents(
            of: "Sources/AudioCaptureKit/MicrophoneSource.swift")
        XCTAssertTrue(microphone.contains(
            "voiceProcessing: Bool = false"))
    }

    func testAppIntentsStaySDKOnlySoMetadataExtractionCannotBreak() throws {
        let intents = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppIntents.swift")
        let appDelegate = try Self.contents(
            of: "Sources/portavoz-app/PortavozAppDelegate.swift")
        let contentView = try Self.contents(
            of: "Sources/portavoz-app/ContentView.swift")
        let recordingView = try Self.contents(
            of: "Sources/portavoz-app/RecordingView.swift")
        let entityAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+AutomationEntities.swift")
        let entityLoader = try Self.contents(
            of: "Sources/ApplicationKit/LoadAutomationEntities.swift")
        let entityStorage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+AutomationEntities.swift")
        let entityFixture = try Self.contents(
            of: "Sources/portavoz-app/AppServices+AutomationEntityUITestFixture.swift")
        let appLaunch = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
        let extractor = try Self.contents(
            of: "scripts/build-appintents-metadata.sh")
        let packager = try Self.contents(of: "scripts/make-app.sh")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        // The release pipeline compiles this ONE file standalone to extract
        // App Intents metadata (D139). An import of any project module would
        // break that compile — at release time, not at test time — so the
        // SDK-only diet is enforced here.
        let allowedImports: Set<String> = [
            "AppIntents", "AppKit", "CoreSpotlight", "Foundation",
        ]
        // Tokenize rather than prefix-match: an indented `import` (inside
        // #if) must not slip through, and a trailing comment or a kind
        // import (`import struct Foundation.URL`) must not mis-parse.
        let importKinds: Set<String> = [
            "typealias", "struct", "class", "enum", "protocol", "let", "var", "func"
        ]
        let imports: [String] = intents.split(separator: "\n").compactMap { rawLine in
            var tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            while let first = tokens.first, first.hasPrefix("@") {
                tokens.removeFirst()
            }
            guard tokens.first == "import" else { return nil }
            tokens.removeFirst()
            if let kind = tokens.first, importKinds.contains(kind) {
                tokens.removeFirst()
            }
            guard let spec = tokens.first else { return nil }
            return spec.split(separator: ".").first.map(String.init)
        }
        XCTAssertFalse(
            imports.isEmpty,
            "the import scan must see the intents file's imports; an empty parse means the parser rotted, not that the diet holds")
        for module in imports {
            XCTAssertTrue(
                allowedImports.contains(module),
                "PortavozAppIntents.swift must stay SDK-only; found: \(module)")
        }
        // The extractor uses the SHIPPING module name, and the packager
        // fails the build rather than shipping silently without intents.
        XCTAssertTrue(extractor.contains("-module-name portavoz_app"))
        for action in [
            "OpenCommitmentIntent",
            "OpenMeetingIntent",
            "ShowPersonCommitmentsIntent",
            "StartRecordingIntent",
            "StopRecordingIntent",
        ] {
            XCTAssertTrue(extractor.contains("\"\(action)\""))
        }
        for entity in [
            "PortavozCommitmentEntity",
            "PortavozMeetingEntity",
            "PortavozPersonEntity",
        ] {
            XCTAssertTrue(extractor.contains("\"\(entity)\""))
            XCTAssertTrue(intents.contains("struct \(entity): AppEntity"))
        }
        for query in [
            "PortavozCommitmentEntityQuery",
            "PortavozMeetingEntityQuery",
            "PortavozPersonEntityQuery",
        ] {
            XCTAssertTrue(extractor.contains("\"\(query)\""))
            XCTAssertTrue(intents.contains("struct \(query): EntityStringQuery"))
        }
        XCTAssertTrue(packager.contains("scripts/build-appintents-metadata.sh"))
        XCTAssertFalse(
            intents.contains("NSWorkspace.shared.open"),
            "the intent must route inside its owning process, not ask LaunchServices to choose a URL handler")
        XCTAssertTrue(intents.contains(
            "PortavozAppIntentBridge.requestStartRecording()"))
        XCTAssertTrue(intents.contains(
            "PortavozAppIntentBridge.requestStopRecording()"))
        XCTAssertTrue(appDelegate.contains(
            "PortavozAppIntentBridge.consumeStartRecordingRequest()"))
        XCTAssertTrue(appDelegate.contains(
            "PortavozAppIntentBridge.consumeStopRecordingRequest("))
        XCTAssertTrue(appDelegate.contains(
            "PortavozAppIntentBridge.consumeNavigationRequest()"))
        XCTAssertTrue(intents.contains("@AppDependency(default:"))
        XCTAssertTrue(intents.contains("import CoreSpotlight"))
        XCTAssertEqual(
            intents.components(separatedBy:
                "var attributeSet: CSSearchableItemAttributeSet").count - 1,
            3)
        XCTAssertTrue(entityAdapter.contains("AppDependencyManager.shared.add"))
        XCTAssertTrue(entityAdapter.contains("LoadAutomationEntities(catalog: store)"))
        XCTAssertTrue(appLaunch.contains("services.installAutomationEntityCatalog()"))
        XCTAssertTrue(entityLoader.contains("maximumResultCount: Int { 50 }"))
        XCTAssertTrue(entityLoader.contains(
            "maximumQueryCharacterCount: Int { 120 }"))
        XCTAssertTrue(entityStorage.contains("maximumAutomationEntityCount = 50"))
        XCTAssertTrue(entityStorage.contains("LIKE :pattern ESCAPE '\\\\'"))
        XCTAssertFalse(intents.contains("CSSearchableIndex"))
        XCTAssertFalse(entityAdapter.contains("CSSearchableIndex"))
        XCTAssertTrue(entityFixture.contains("arguments.contains(\"-use-temp-store\")"))
        XCTAssertTrue(entityFixture.contains("AppAutomationEntityCatalog(store: store)"))
        XCTAssertTrue(entityFixture.contains(
            "PortavozAppEntityOpenAction.openMeeting("))
        XCTAssertTrue(entityFixture.contains(
            "PortavozAppEntityOpenAction.showPersonCommitments("))
        XCTAssertTrue(entityFixture.contains(
            "PortavozAppEntityOpenAction.openCommitment("))
        XCTAssertFalse(
            entityFixture.contains(".perform()"),
            "AppDependency is initialized only inside a system-owned intent perform flow")
        XCTAssertEqual(
            intents.components(separatedBy: "extension PortavozMeetingEntity: IndexedEntity")
                .count - 1,
            1)
        XCTAssertTrue(intents.contains("struct OpenMeetingIntent: OpenIntent"))
        XCTAssertTrue(intents.contains(
            "struct ShowPersonCommitmentsIntent: OpenIntent"))
        XCTAssertTrue(intents.contains("struct OpenCommitmentIntent: OpenIntent"))
        XCTAssertTrue(contentView.contains("case library"))
        XCTAssertTrue(contentView.contains("case person(PersonID)"))
        XCTAssertTrue(contentView.contains("case commitment(CommitmentID)"))
        XCTAssertTrue(contentView.contains("case recordingRecovery"))
        XCTAssertTrue(appDelegate.contains(
            "services.pendingRoute = .recordingRecovery"))
        XCTAssertTrue(recordingView.contains("guard startsAutomatically else { return }"))
        XCTAssertEqual(
            intents.components(separatedBy:
                "static let supportedModes: IntentModes = [.foreground(.immediate)]")
                .count - 1,
            2,
            "Start and Stop must use Tahoe's immediate foreground mode")
        XCTAssertEqual(
            intents.components(separatedBy: "static var openAppWhenRun: Bool { true }")
                .count - 1,
            2,
            "Start and Stop must preserve the pre-Tahoe foreground contract")
        XCTAssertFalse(
            intents.contains("AppShortcutsProvider"),
            "macOS publishes the action only; an App Shortcut duplicates it in the picker")
        XCTAssertFalse(
            appDelegate.contains("updateAppShortcutParameters()"),
            "macOS has no App Shortcut representation to refresh")
        XCTAssertTrue(extractor.contains("must not publish unsupported App Shortcuts"))
        XCTAssertTrue(decisions.contains("## D139"))
        XCTAssertTrue(decisions.contains("## D141"))
        XCTAssertTrue(decisions.contains("## D324"))
        XCTAssertTrue(decisions.contains("## D325"))
        XCTAssertTrue(decisions.contains("## D326"))
    }

    func testLocalVoiceEnrollmentEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ManageLocalVoiceAndModels.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LocalVoiceIdentity.swift")
        let settings = try Self.contents(of: "Sources/portavoz-app/SettingsView.swift")
            + Self.contents(of: "Sources/portavoz-app/SettingsVoiceSection.swift")
        let onboarding = try Self.contents(of: "Sources/portavoz-app/OnboardingView.swift")

        XCTAssertTrue(workflow.contains("case recordAndEnroll("))
        XCTAssertTrue(workflow.contains("case enrollSample("))
        XCTAssertTrue(workflow.contains("LocalVoiceSampleCapturing"))
        XCTAssertTrue(workflow.contains("LocalVoiceSampleIdentityExtracting"))
        XCTAssertTrue(adapter.contains("ManageLocalVoiceIdentity("))
        XCTAssertTrue(adapter.contains("MicrophoneSource("))
        XCTAssertTrue(adapter.contains("voiceProcessing: mode == .echoCancelled"))
        XCTAssertTrue(adapter.contains("ContinuousClock()"))
        XCTAssertEqual(
            adapter.components(separatedBy: "await microphone.stop()").count - 1,
            2)
        XCTAssertTrue(adapter.contains("services.acquireDiarizationRuntime()"))
        XCTAssertTrue(adapter.contains("services.finishDiarizationRuntime("))
        XCTAssertTrue(adapter.contains("services.makeDiarizer("))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(adapter.contains(#"arguments.contains("-use-temp-store")"#))
        XCTAssertTrue(settings.contains("services.recordAndEnrollLocalVoice("))
        XCTAssertTrue(settings.contains("services.deleteLocalVoiceIdentity()"))
        XCTAssertFalse(settings.contains("try? await services.deleteLocalVoiceIdentity()"))
        XCTAssertTrue(settings.contains("settings-voice-enroll"))
        XCTAssertTrue(onboarding.contains("services.enrollLocalVoice(from:"))
        XCTAssertTrue(onboarding.contains("services.recordAndEnrollLocalVoice("))
        XCTAssertTrue(onboarding.contains("LocalVoiceSample.minimumEnrollmentDuration"))
        XCTAssertTrue(onboarding.contains("onboarding-voice-enroll"))
        for presentation in [settings, onboarding] {
            XCTAssertFalse(presentation.contains("MicrophoneSource("))
            XCTAssertFalse(presentation.contains("extractVoiceprint("))
            XCTAssertFalse(presentation.contains("services.voiceprintStore"))
            XCTAssertFalse(presentation.contains(
                "services.acquireDiarizationRuntime()"))
            XCTAssertFalse(presentation.contains("import AudioCaptureKit"))
            XCTAssertFalse(presentation.contains("import DiarizationKit"))
        }
    }

    func testAppLaunchRecoveryEntersThroughApplicationKitBeforeWorkerResume() throws {
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/RecordingRecoveryCoordinator.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+RecoverInterruptedMeetings.swift")
        let launch = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")

        XCTAssertTrue(coordinator.contains("services.recoverInterruptedMeetings.execute"))
        XCTAssertTrue(adapter.contains("CaptureFileRecovery"))
        XCTAssertFalse(coordinator.contains("recoverExpiredProcessingJobs"))
        XCTAssertFalse(coordinator.contains("installRecoveredCaptureAssets"))
        XCTAssertFalse(coordinator.contains("installCapturedSnapshot"))
        XCTAssertFalse(coordinator.contains("markMeetingNeedsAttention"))
        XCTAssertFalse(coordinator.contains("CaptureFileRecovery"))
        let recovery = try XCTUnwrap(launch.range(of:
            "RecordingRecoveryCoordinator.runIfNeeded"))
        let worker = try XCTUnwrap(launch.range(of:
            "PostCaptureProcessingCoordinator.resumeAfterRecovery"))
        let recommendation = try XCTUnwrap(launch.range(of:
            "services.configureInitialSummaryProviderIfNeeded"))
        XCTAssertLessThan(recovery.lowerBound, worker.lowerBound)
        XCTAssertLessThan(worker.lowerBound, recommendation.lowerBound)
    }

    func testLocalSummaryProviderDiscoveryEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/LocalSummaryProviders.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LocalSummaryProviders.swift")
        let settings = try Self.contents(of: "Sources/portavoz-app/SettingsView.swift")
        let onboarding = try Self.contents(of: "Sources/portavoz-app/OnboardingView.swift")

        XCTAssertTrue(workflow.contains("struct DiscoverLocalSummaryProviders"))
        XCTAssertTrue(workflow.contains("struct ConfigureInitialSummaryProvider"))
        XCTAssertTrue(workflow.contains("enum LocalSummaryProviderPolicy"))
        XCTAssertTrue(workflow.contains("enum LocalSummaryRecommendationReason"))
        XCTAssertTrue(workflow.contains("func saveInitialSummaryProviderSelection"))
        for concrete in [
            "OllamaService", "UserDefaults", "ProcessInfo", "NSHomeDirectory",
        ] {
            XCTAssertFalse(workflow.contains(concrete), concrete)
            XCTAssertTrue(adapter.contains(concrete), concrete)
        }
        XCTAssertFalse(workflow.contains("FoundationModelsCapability"))
        XCTAssertTrue(adapter.contains("foundationModelsCapability.isAvailable"))
        XCTAssertTrue(adapter.contains("contains(\"-use-temp-store\")"))
        XCTAssertTrue(adapter.contains("ollama: .unavailable"))
        XCTAssertTrue(adapter.contains("@MainActor"))
        XCTAssertTrue(adapter.contains("struct AppSummaryProviderSelectionStore"))
        for presentation in [settings, onboarding] {
            XCTAssertTrue(presentation.contains("discoverLocalSummaryProviders"))
            XCTAssertFalse(presentation.contains("HardwareRecommender"))
            XCTAssertFalse(presentation.contains("currentHardwareProfile"))
            XCTAssertFalse(presentation.contains("InitialSummaryEnginePolicy"))
            XCTAssertFalse(presentation.contains("OllamaService"))
        }
    }

    func testSettingsResourcesEnterThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/SettingsResources.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+SettingsResources.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SettingsView.swift")
        let voiceSettings = try Self.contents(
            of: "Sources/portavoz-app/SettingsVoiceSection.swift")
        let audio = try Self.contents(
            of: "Sources/portavoz-app/AudioSection.swift")
        let voices = try Self.contents(
            of: "Sources/portavoz-app/RememberedVoicesSection.swift")
        let localVoiceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LocalVoiceIdentity.swift")
        let voiceprintStore = try Self.contents(
            of: "Sources/DiarizationKit/VoiceprintStore.swift")
        let voiceGallery = try Self.contents(
            of: "Sources/DiarizationKit/VoiceGallery.swift")

        for useCase in [
            "struct LoadAudioInputOptions",
            "struct ManageRecordingStorage",
            "struct ManageRememberedVoices",
        ] {
            XCTAssertTrue(workflow.contains(useCase), useCase)
        }
        for concreteImport in [
            "import AudioCaptureKit", "import DiarizationKit", "import StorageKit",
        ] {
            XCTAssertFalse(workflow.contains(concreteImport), concreteImport)
        }
        for concrete in [
            "AudioDeviceCatalog", "RecordingsLocation", "VoiceGallery",
        ] {
            XCTAssertTrue(adapter.contains(concrete), concrete)
        }
        XCTAssertTrue(adapter.contains("AsyncStream<RecordingStorageProgress>"))
        XCTAssertTrue(settings.contains("services.updateRecordingStorage"))
        XCTAssertFalse(settings.contains("RecordingsLocation"))
        XCTAssertFalse(settings.contains("Task.detached"))
        XCTAssertFalse(settings.contains("import StorageKit"))
        XCTAssertTrue(audio.contains("services.audioInputOptions()"))
        XCTAssertFalse(audio.contains("AudioDeviceCatalog"))
        XCTAssertFalse(audio.contains("import AudioCaptureKit"))
        XCTAssertTrue(voices.contains("services.rememberedVoiceSummaries()"))
        XCTAssertTrue(voices.contains("services.removeRememberedVoice"))
        XCTAssertTrue(voices.contains("services.removeAllRememberedVoices"))
        XCTAssertTrue(voices.contains("settings-remembered-voices-error"))
        XCTAssertTrue(voices.contains("settings-remembered-voices-retry"))
        XCTAssertFalse(voices.contains("services.voiceGallery"))
        XCTAssertFalse(voices.contains("import DiarizationKit"))
        XCTAssertFalse(voices.contains("try?"))
        XCTAssertTrue(settings.contains("SettingsVoiceSection()"))
        XCTAssertTrue(voiceSettings.contains("await loadStatus()"))
        XCTAssertTrue(voiceSettings.contains("settings-voice-storage-retry"))
        XCTAssertTrue(voiceSettings.contains("settings-voice-storage-reset"))
        XCTAssertFalse(voiceSettings.contains("enrollmentDate = try?"))
        XCTAssertTrue(voiceGallery.contains("var all = try readWithoutLock()"))
        XCTAssertTrue(voiceGallery.contains("let remaining = try readWithoutLock().filter"))
        XCTAssertFalse(voiceGallery.contains("try? voices()"))
        XCTAssertFalse(voiceGallery.contains("combined!"))
        XCTAssertTrue(voiceprintStore.contains("guard allowCreation else"))
        XCTAssertTrue(voiceprintStore.contains("VoiceprintError.missingKey"))
        XCTAssertTrue(voiceprintStore.contains("_ = try decodeVoiceprint(using: key)"))
        XCTAssertFalse(voiceprintStore.contains("combined!"))
        XCTAssertTrue(adapter.contains("simulateUnavailable: usesTemporaryStore"))
        XCTAssertTrue(localVoiceAdapter.contains("simulateUnavailable: usesTemporaryStore"))
    }

    func testAppPostCaptureExecutionEntersThroughApplicationKit() throws {
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppPostCaptureProcessingCapabilities.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessPostCaptureJobs.swift")

        XCTAssertTrue(coordinator.contains("services.processPostCaptureJobs.execute"))
        XCTAssertTrue(coordinator.contains("processPostCaptureJobs.nextScheduledDate"))
        for bypass in [
            "claimNextProcessingJob", "heartbeatProcessingJob",
            "suspendProcessingJob",
            "completeTranscriptionJob", "completeDiarizationJob",
            "completeSummaryJob", "failProcessingJob",
            "cancelProcessingJob", "nextScheduledProcessingDate"
        ] {
            XCTAssertFalse(
                coordinator.contains(bypass),
                "Post-capture product policy bypasses ApplicationKit through \(bypass)")
        }

        for ownedPolicy in [
            "claimPostCaptureJob", "heartbeatPostCaptureJob",
            "suspendPostCaptureJob",
            "processTranscription", "processDiarization", "processSummary",
            "SummaryOperationFingerprint.compute", "retryDate",
            "cancelPostCaptureJob", "failPostCaptureJob"
        ] {
            XCTAssertTrue(
                workflow.contains(ownedPolicy),
                "Application workflow is missing \(ownedPolicy)")
        }
        for concreteDependency in [
            "RecordingsLocation", "FileManager", "UserDefaults",
            "PostMeetingShortcut", "OSSignposter", "AppServices"
        ] {
            XCTAssertFalse(
                workflow.contains(concreteDependency),
                "Application workflow contains concrete app dependency \(concreteDependency)")
        }
        for adapterDependency in [
            "RecordingsLocation", "FileManager", "acquireLiveSpeechRuntime",
            "acquireDiarizationRuntime", "PostMeetingShortcut.runIfConfigured"
        ] {
            XCTAssertTrue(adapter.contains(adapterDependency))
        }
    }

    func testPostCaptureContractsStaySeparateFromWorkflowPolicy() throws {
        let contracts = try Self.contents(
            of: "Sources/ApplicationKit/PostCaptureProcessingContracts.swift")
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessPostCaptureJobs.swift")

        for contract in [
            "public protocol PostCaptureProcessingStore",
            "public protocol PostCaptureAudioProcessing",
            "public protocol PostCaptureSummaryConfiguration",
            "public protocol PostCaptureCompletionActions",
            "public struct PostCaptureSummaryProviderSelection",
            "public struct ProcessPostCaptureJobsRequest",
            "public struct ProcessPostCaptureJobsResult"
        ] {
            XCTAssertTrue(contracts.contains(contract))
            XCTAssertFalse(workflow.contains(contract))
        }
        for policy in [
            "public struct ProcessPostCaptureJobs: ApplicationUseCase",
            "processTranscription", "processDiarization", "processSummary",
            "preserveFailure", "heartbeatTask"
        ] {
            XCTAssertTrue(workflow.contains(policy))
            XCTAssertFalse(contracts.contains(policy))
        }
    }

    func testDurableWorkOwnershipMatchesItsRecoveryGranularity() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessPostCaptureJobs.swift")
        let jobs = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+ProcessingJobs.swift")
        let semantic = try Self.contents(
            of: "Sources/portavoz-app/SemanticCorpusIndexingSupervisor.swift")
        let semanticWorkflow = try Self.contents(
            of: "Sources/ApplicationKit/ProcessSemanticCorpusMaintenance.swift")
        let semanticStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+DerivedMaintenance.swift")
        let sync = try Self.contents(
            of: "Sources/IntegrationsKit/CloudMeetingSyncCoordinator.swift")
        let backup = try Self.contents(
            of: "Sources/ApplicationKit/ExportLibraryMarkdownBackup.swift")
        let backupStore = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+LibraryMarkdownBackup.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let storageSpec = try Self.contents(of: "docs/specs/05-storage.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")

        XCTAssertTrue(workflow.contains("suspendPostCaptureJob"))
        XCTAssertTrue(workflow.contains("return (.suspended, true, nil)"))
        XCTAssertTrue(workflow.contains("if execution.shouldStop { break }"))
        XCTAssertTrue(jobs.contains("suspendProcessingJob"))
        XCTAssertTrue(jobs.contains("record.attempt -= 1"))
        XCTAssertTrue(semanticWorkflow.contains("return .paused"))
        XCTAssertTrue(semanticWorkflow.contains("heartbeatTask"))
        XCTAssertTrue(semanticStore.contains("suspendSemanticCorpusMaintenance"))
        XCTAssertTrue(semantic.contains("Task.sleep"))
        XCTAssertTrue(sync.contains(".paused(processedCount:"))
        XCTAssertTrue(backup.contains("return .suspended"))
        XCTAssertTrue(backupStore.contains(".owner.lock"))
        XCTAssertTrue(backupStore.contains("portavoBSDFileLock"))
        for replaySafeOwner in [sync, backup, backupStore] {
            XCTAssertFalse(replaySafeOwner.contains("heartbeat"))
            XCTAssertFalse(replaySafeOwner.contains("Timer"))
            XCTAssertFalse(replaySafeOwner.contains("Task.sleep"))
        }
        XCTAssertTrue(architecture.contains(
            "Intentional suspension explicitly returns"))
        XCTAssertTrue(decisions.contains("## D190"))
        XCTAssertTrue(storageSpec.contains("Intentional suspension"))
        XCTAssertTrue(appSpec.contains("Intentional workflow cancellation"))
    }

    func testProcessingJobSchedulingOwnsDurableWakeAndLeaseRecovery() throws {
        let scheduling = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+ProcessingJobScheduling.swift")
        let jobs = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+ProcessingJobs.swift")

        for wakePolicy in [
            "public func nextScheduledProcessingDate",
            "SELECT MIN(wakeAt)",
            "SELECT notBefore AS wakeAt",
            "SELECT leaseExpiresAt AS wakeAt"
        ] {
            XCTAssertTrue(scheduling.contains(wakePolicy))
        }
        for recoveryPolicy in [
            "static func recoverExpiredProcessingJobs",
            "processing.lease.expired",
            "processing.lease.exhausted"
        ] {
            XCTAssertTrue(scheduling.contains(recoveryPolicy))
        }
        XCTAssertTrue(jobs.contains(
            "try Self.recoverExpiredProcessingJobs(at: timestamp, in: db)"))
        XCTAssertFalse(scheduling.contains("Timer"))
        XCTAssertFalse(scheduling.contains("Task.sleep"))
    }

    func testAppMeetingBundleImportEntersThroughApplicationKit() throws {
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Bundle.swift")

        XCTAssertTrue(adapter.contains("importMeetingBundleUseCase.execute"))
        XCTAssertTrue(adapter.contains("MeetingBundle.decode"))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(adapter.contains("store.save(bundle.meeting)"))
        XCTAssertFalse(adapter.contains("store.saveSummary"))
        XCTAssertFalse(adapter.contains("store.save(bundle.contextItems)"))
        XCTAssertFalse(adapter.contains("store.save(bundle.companionCards"))
    }

    func testAppMeetingBundleExportEntersThroughApplicationKit() throws {
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator+Documents.swift")
        let scene = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailScene.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Bundle.swift")

        XCTAssertTrue(coordinator.contains("sceneActions.exportBundle"))
        XCTAssertFalse(view.contains("services.exportMeetingBundle"))
        XCTAssertTrue(scene.contains("services.exportMeetingBundle"))
        XCTAssertFalse(view.contains("let bundle = MeetingBundle("))
        XCTAssertFalse(view.contains("MeetingBundle.AudioAttachment"))
        XCTAssertFalse(view.contains("Data(contentsOf:"))
        XCTAssertTrue(adapter.contains("exportMeetingBundleUseCase.execute"))
        XCTAssertTrue(adapter.contains("MeetingBundle("))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(adapter.contains("store.contextItems(for:"))
        XCTAssertFalse(adapter.contains("store.companionCards(for:"))
    }

    func testMeetingVoiceMemoryEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/ManageMeetingVoiceMemory.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingVoiceMemory.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator.swift")
            + Self.contents(
                of: "Sources/portavoz-app/MeetingDetailCoordinator+Identity.swift")

        XCTAssertTrue(workflow.contains("struct ManageMeetingVoiceMemory"))
        XCTAssertTrue(workflow.contains("VoiceMatcher.matches("))
        XCTAssertTrue(workflow.contains("case remember(meetingID: MeetingID"))
        XCTAssertTrue(adapter.contains("ManageMeetingVoiceMemory("))
        XCTAssertTrue(adapter.contains("services.acquireDiarizationRuntime()"))
        XCTAssertTrue(adapter.contains("services.finishDiarizationRuntime("))
        XCTAssertTrue(adapter.contains("services.makeDiarizer("))
        XCTAssertTrue(adapter.contains("RecordingsLocation.shared.resolve"))
        XCTAssertTrue(adapter.contains("gallery.remember(voice)"))
        XCTAssertTrue(coordinator.contains("model.send(.loadVoiceSuggestions)"))
        XCTAssertTrue(coordinator.contains("model.send(.rememberVoice("))
        XCTAssertFalse(view.contains("suggestFromVoicesIfUseful"))
        XCTAssertFalse(view.contains("services.meetingDetailVoiceSuggestions("))
        XCTAssertFalse(view.contains("services.rememberMeetingDetailVoice("))
        for bypass in [
            "VoiceMatcher.matches(", "PyannoteDiarizer.loadRecommended",
            "acquireDiarizationRuntime", "ModelStore()",
            "services.voiceGallery", "extractVoiceprints(",
        ] {
            XCTAssertFalse(view.contains(bypass), bypass)
        }
        XCTAssertFalse(view.contains("import DiarizationKit"))
        XCTAssertFalse(view.contains("import ModelStoreKit"))
    }

    func testMeetingNameSuggestionsEnterThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/SuggestMeetingSpeakerNames.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingNames.swift")
        let model = try Self.meetingDetailModelContents()
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator+Identity.swift")

        XCTAssertTrue(workflow.contains("struct SuggestMeetingSpeakerNames"))
        XCTAssertTrue(workflow.contains("func proposeNames("))
        XCTAssertTrue(workflow.contains("static func verified("))
        XCTAssertTrue(workflow.contains("enum MeetingNameSuggestionEvidence"))
        XCTAssertTrue(workflow.contains("struct MeetingNameProposal"))
        XCTAssertTrue(workflow.contains("PersonNameEvidenceMatcher.contains"))
        XCTAssertFalse(workflow.contains("proposal.evidence"))
        XCTAssertTrue(adapter.contains("CalendarAttendeeSource().attendees("))
        XCTAssertTrue(adapter.contains("SpeakerNamer().suggestNames("))
        XCTAssertTrue(adapter.contains("MeetingNameProposal(label:"))
        XCTAssertTrue(model.contains("case loadNameSuggestions"))
        XCTAssertTrue(model.contains("state.nameSuggestions"))
        XCTAssertTrue(coordinator.contains("model.send(.loadNameSuggestions)"))
        XCTAssertTrue(view.contains("model.state.nameSuggestions"))
        for bypass in [
            "CalendarAttendeeSource", "SpeakerNamer", "NameSuggestionFilter",
            "@State private var nameSuggestions", "@State private var suggestingNames",
        ] {
            XCTAssertFalse(view.contains(bypass), bypass)
        }
    }

    func testMeetingReviewMetadataSuggestionsEnterThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/SuggestMeetingReviewMetadata.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingReviewMetadata.swift")
        let model = try Self.meetingDetailModelContents()
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator.swift")

        XCTAssertTrue(workflow.contains("struct SuggestMeetingReviewMetadata"))
        XCTAssertTrue(workflow.contains("MeetingReviewMetadataGenerating"))
        XCTAssertTrue(workflow.contains("func suggestedRecipe("))
        XCTAssertTrue(workflow.contains("func suggestedMeetingTitle("))
        XCTAssertTrue(workflow.contains("func suggestedChapterTitles("))
        XCTAssertTrue(workflow.contains("try Task.checkCancellation()"))
        XCTAssertFalse(workflow.contains("import FoundationModels"))
        XCTAssertFalse(workflow.contains("FoundationModelSummaryProvider"))
        XCTAssertTrue(adapter.contains("foundationModelsCapability.isAvailable"))
        XCTAssertTrue(adapter.contains(#"arguments.contains("-seed-scale")"#))
        for concreteGenerator in [
            "ChapterTitler", "TitleSuggester", "MeetingTypeDetector",
        ] {
            XCTAssertTrue(adapter.contains(concreteGenerator), concreteGenerator)
            XCTAssertFalse(view.contains(concreteGenerator), concreteGenerator)
        }
        XCTAssertTrue(model.contains("case loadMetadataSuggestions"))
        XCTAssertTrue(model.contains("MeetingDetailMetadataSuggestionState"))
        XCTAssertTrue(model.contains("private var requestID"))
        XCTAssertTrue(model.contains("didCompleteTitleSuggestion"))
        XCTAssertTrue(model.contains("didCompleteRecipeSuggestion"))
        XCTAssertTrue(coordinator.contains("model.send(.loadMetadataSuggestions)"))
        XCTAssertTrue(view.contains("model.state.chapterTitles"))
        XCTAssertTrue(view.contains("model.state.suggestedTitle"))
        XCTAssertTrue(view.contains("model.state.suggestedRecipe"))
        XCTAssertFalse(view.contains("ProcessInfo.processInfo"))
        XCTAssertFalse(view.contains("FoundationModelSummaryProvider"))
        XCTAssertFalse(view.contains("suggestTitleIfUseful"))
        XCTAssertFalse(view.contains("suggestRecipeIfUseful"))
        XCTAssertFalse(view.contains("titleChaptersIfNeeded"))
    }

    func testMeetingDetailAudioCoordinationEntersThroughApplicationKit() throws {
        let workflow = try Self.contents(
            of: "Sources/ApplicationKit/MeetingAudioWorkflows.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingAudio.swift")
        let model = try Self.meetingDetailModelContents()
        let view = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailView.swift")
        let playerBar = try Self.contents(
            of: "Sources/portavoz-app/MeetingPlayerBar.swift")
        let playerSection = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailPlayerSection.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator.swift")
        let transcript = try Self.contents(
            of: "Sources/portavoz-app/TranscriptSegmentsView.swift")

        for useCase in [
            "PrepareMeetingPlayback", "CompressMeetingAudio", "ExportMeetingAudioClip",
        ] {
            XCTAssertTrue(workflow.contains("struct \(useCase)"), useCase)
            XCTAssertTrue(adapter.contains("\(useCase)("), useCase)
        }
        XCTAssertTrue(workflow.contains("MeetingAudioChannelResolving"))
        XCTAssertTrue(workflow.contains("Waveform.generateCancellable"))
        XCTAssertFalse(workflow.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(workflow.contains("PlaybackRanges.complement"))
        XCTAssertTrue(adapter.contains("RecordingsLocation.shared"))
        XCTAssertTrue(adapter.contains("MeetingAudioLayout.channelFile"))
        XCTAssertTrue(model.contains("case loadPlayback"))
        XCTAssertTrue(model.contains("case compressAudio"))
        XCTAssertTrue(model.contains("case exportAudioClip"))
        XCTAssertTrue(view.contains(".task(id: playbackTaskID)"))
        XCTAssertTrue(coordinator.contains("model.send(.loadPlayback)"))
        XCTAssertTrue(coordinator.contains("model.send(.compressAudio)"))
        XCTAssertTrue(view.contains("MeetingDetailPlayerSection("))
        XCTAssertTrue(playerBar.contains("await exportClip(range, url)"))

        let presentationSources = [view, playerSection, playerBar, transcript]
        for source in presentationSources {
            XCTAssertFalse(source.contains("import AudioPlaybackKit"))
        }
        for bypass in [
            "RecordingsLocation", "MeetingAudioLayout", "MeetingPlayer.make",
            "Waveform.generate", "AudioTranscoder", "AudioClipExporter",
            "PlaybackRanges.complement",
        ] {
            XCTAssertFalse(view.contains(bypass), bypass)
            XCTAssertFalse(playerBar.contains(bypass), bypass)
        }
    }

    func testLibraryFeatureOwnsStateAndActionsOutsideSwiftUI() throws {
        let model = try Self.contents(
            of: "Sources/portavoz-app/LibraryModel.swift")
        let view = try Self.contents(
            of: "Sources/portavoz-app/LibraryView.swift")
        let trash = try Self.contents(
            of: "Sources/portavoz-app/TrashSection.swift")
        let content = try Self.contents(
            of: "Sources/portavoz-app/ContentView.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Library.swift")
        let readModels = try Self.contents(
            of: "Sources/ApplicationKit/LibraryReadModels.swift")
        let observation = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+LibraryObservation.swift")

        for filename in ["LibraryNavigationControls.swift", "HomeView.swift"] {
            let presentation = try Self.contents(of: "Sources/portavoz-app/\(filename)")
            for capability in ["AppServices", "MeetingStore", ".task", "@State"] {
                XCTAssertFalse(presentation.contains(capability), "\(filename): \(capability)")
            }
        }
        // Home renders the same Library snapshot the sidebar observes and
        // sends the same actions; it owns no store, observation, or state.
        XCTAssertTrue(content.contains("HomeView("))
        XCTAssertTrue(view.contains("LibraryNavigationControls("))

        XCTAssertTrue(model.contains("@MainActor\n@Observable\nfinal class LibraryModel"))
        XCTAssertTrue(model.contains("struct State"))
        XCTAssertTrue(model.contains("enum Action"))
        XCTAssertTrue(model.contains("enum Effect"))
        XCTAssertTrue(model.contains("private(set) var state = State()"))
        XCTAssertTrue(view.contains("model.send(.observeLibrary)"))
        XCTAssertTrue(view.contains("model.send(.observeSearch)"))
        XCTAssertTrue(content.contains("@State private var libraryModel: LibraryModel"))
        XCTAssertTrue(adapter.contains("defer { requestSearchReconciliation() }"))
        XCTAssertTrue(adapter.contains("makeApplicationLibraryStream("))
        XCTAssertTrue(readModels.contains("public enum LibraryUpdate"))
        XCTAssertTrue(observation.contains("func observeLibraryMeetings()"))
        XCTAssertTrue(observation.contains("func observeLibraryOpenItems("))
        XCTAssertTrue(observation.contains("func observeLibraryTrash()"))
        // Segment regions are column-scoped so a semantic backfill, which
        // writes only embedding columns, cannot re-fire either projection.
        XCTAssertTrue(observation.contains(
            "Table(\"meeting\"), Table(\"speaker\"), Self.librarySegmentRegion"))
        XCTAssertTrue(observation.contains("Self.searchSegmentRegion"))
        XCTAssertTrue(observation.contains("Self.searchCorrectedTextRegion"))
        XCTAssertTrue(observation.contains("Self.searchStructuralTextRegion"))
        XCTAssertTrue(observation.contains(
            "Table(\"transcriptCorrectionSearchState\")"))
        XCTAssertFalse(
            observation.contains("Table(\"segment\")"),
            "a whole-table segment region re-fetches the library on every embedding batch")
        XCTAssertTrue(observation.contains(
            "regions: [Table(\"meeting\"), Table(\"summary\"), Table(\"actionItem\")]"))
        XCTAssertTrue(observation.contains("region: Table(\"meeting\")"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("services.meetingLifecycle"))
        XCTAssertFalse(view.contains("services.libraryVersion +="))
        XCTAssertFalse(view.contains("invalidationVersion"))
        XCTAssertFalse(view.contains("@State private var meetings"))
        XCTAssertFalse(model.contains("import StorageKit"))
        XCTAssertFalse(view.contains("import StorageKit"))
        XCTAssertFalse(trash.contains("import StorageKit"))
        XCTAssertFalse(model.contains("reloadVersion"))
        XCTAssertFalse(model.contains("newestReloadVersion"))
        XCTAssertFalse(content.contains("invalidationVersion: services.libraryVersion"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertFalse(trash.contains("@Environment(AppServices.self)"))
        XCTAssertFalse(trash.contains("services."))
    }

    func testGRDBObservationLifetimeBelongsToTheConsumerIterator() throws {
        let adapter = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+Observation.swift")
        let library = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+LibraryObservation.swift")

        for required in [
            "AsyncThrowingStream(unfolding:",
            "ObservedStreamIterator(values.makeAsyncIterator())",
            "Iterator: AsyncIteratorProtocol & GRDBSendableMetatype",
            "private let lock = NSLock()",
            "guard var iterator = takeIterator()",
            "restore(iterator)",
        ] {
            XCTAssertTrue(
                adapter.contains(required),
                "consumer-owned GRDB adapter is missing \(required)")
        }
        for forbidden in [
            "Task {",
            "continuation.onTermination",
            "for try await value in values",
        ] {
            XCTAssertFalse(
                adapter.contains(forbidden),
                "GRDB observations must not regain forwarding bridge \(forbidden)")
        }
        XCTAssertFalse(
            library.contains("func observedStream"),
            "the shared lifetime adapter must not return to a feature file")
    }

    func testResidentMenuBarUsesOneScopedReadOwner() throws {
        let readModels = try Self.contents(
            of: "Sources/ApplicationKit/MenuBarReadModels.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/MenuBarModel.swift")
        let adapter = try Self.contents(of: "Sources/portavoz-app/AppServices+MenuBar.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/MenuBarView.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/PortavozApp.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MenuBarObservation.swift")

        XCTAssertTrue(readModels.contains("public enum MenuBarUpdate"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("private(set) var state = State()"))
        XCTAssertTrue(model.contains("failedSections"))
        XCTAssertTrue(adapter.contains("store.observeMenuBarMeetings(limit: 3)"))
        XCTAssertTrue(adapter.contains("store.observeLibraryOpenItems(limit: 200)"))
        XCTAssertTrue(view.contains("@State private var model: MenuBarModel"))
        XCTAssertTrue(view.contains(".task { await model.observe() }"))
        XCTAssertTrue(app.contains("MenuBarContent(model: services.makeMenuBarModel())"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("CalendarAttendeeSource"))
        XCTAssertFalse(view.contains("import StorageKit"))
        XCTAssertFalse(view.contains("import IntegrationsKit"))
        XCTAssertTrue(storage.contains("region: Table(\"meeting\")"))
        XCTAssertTrue(storage.contains(".limit(max(0, limit))"))
        XCTAssertFalse(storage.contains("Table(\"segment\")"))
        XCTAssertFalse(storage.contains("Table(\"speaker\")"))
    }

    func testWholeLibraryMarkdownBackupUsesOneApplicationWorkflow() throws {
        let useCase = try Self.contents(
            of: "Sources/ApplicationKit/ExportLibraryMarkdownBackup.swift")
        let execution = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupExecution.swift")
        let recoveryUseCase = try Self.contents(
            of: "Sources/ApplicationKit/RecoverLibraryMarkdownBackup.swift")
        let recoveryValidation = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupRecoveryValidation.swift")
        let filesContract = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupFiles.swift")
        let sourceContract = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupSource.swift")
        let recoveryContract = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupRecovery.swift")
        let reconciliation = try Self.contents(
            of: "Sources/ApplicationKit/ReconcileBackupPublication.swift")
        let destinationContract = try Self.contents(
            of: "Sources/ApplicationKit/LibraryMarkdownBackupDestination.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+LibraryMarkdownBackup.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LibraryMarkdownBackup.swift")
        let recoveryAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppLibraryMarkdownBackupRecoveryStore.swift")
        let model = try Self.contents(
            of: "Sources/portavoz-app/LibraryMarkdownBackupModel.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/BackupSection.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let app = try Self.contents(
            of: "Sources/portavoz-app/AppLaunchModel.swift")
        let resourceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ResourceGovernor.swift")
        let bookmark = try Self.contents(
            of: "Sources/PlatformKit/PersistentFileBookmark.swift")
        let architecture = try Self.contents(of: "docs/ARCHITECTURE.md")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")
        let appSpec = try Self.contents(of: "docs/specs/06-app-macos.md")

        XCTAssertTrue(useCase.contains("actor ExportLibraryMarkdownBackup"))
        XCTAssertTrue(filesContract.contains(
            "protocol LibraryMarkdownBackupDocuments"))
        XCTAssertTrue(filesContract.contains(
            "protocol LibraryMarkdownBackupFiles"))
        XCTAssertTrue(filesContract.contains("func evidence("))
        XCTAssertTrue(sourceContract.contains(
            "protocol LibraryMarkdownBackupSourceSession"))
        XCTAssertTrue(sourceContract.contains(
            "extension MeetingStore: LibraryMarkdownBackupStore"))
        XCTAssertTrue(execution.contains("LibraryMarkdownBackupFailureStage"))
        XCTAssertTrue(recoveryUseCase.contains(
            "actor RecoverLibraryMarkdownBackup"))
        XCTAssertTrue(recoveryUseCase.contains(
            "struct RecoverLibraryMarkdownBackupRequest"))
        XCTAssertTrue(recoveryValidation.contains(
            "enum LibraryMarkdownBackupRecoveryValidation"))
        XCTAssertTrue(destinationContract.contains(
            "protocol LibraryMarkdownBackupDestinationAccess"))
        XCTAssertTrue(recoveryContract.contains(
            "protocol LibraryMarkdownBackupRecoveryStore"))
        XCTAssertTrue(recoveryContract.contains("func operationIDs()"))
        XCTAssertTrue(recoveryContract.contains("pendingPublication"))
        XCTAssertTrue(recoveryContract.contains("completedPublications"))
        XCTAssertTrue(recoveryContract.contains(
            "LibraryMarkdownBackupRecoveryFailure"))
        XCTAssertTrue(recoveryContract.contains(
            "case recordFailure(LibraryMarkdownBackupRecoveryFailure)"))
        XCTAssertTrue(recoveryContract.contains(
            "LibraryMarkdownBackupSourceCursor"))
        XCTAssertTrue(recoveryContract.contains(
            "case checkpointSource(LibraryMarkdownBackupSourceCursor)"))
        XCTAssertTrue(recoveryContract.contains(
            "sourceCursor: LibraryMarkdownBackupSourceCursor?"))
        XCTAssertTrue(reconciliation.contains(
            "struct ReconcileBackupPublication: ApplicationUseCase"))
        XCTAssertTrue(reconciliation.contains("files.evidence("))
        XCTAssertTrue(reconciliation.contains(".clearReservation"))
        XCTAssertTrue(reconciliation.contains(".complete(pending)"))
        XCTAssertTrue(reconciliation.contains("repairCheckpointIfNeeded"))
        XCTAssertTrue(sourceContract.contains(
            "func checkpoint() async throws"))
        XCTAssertTrue(sourceContract.contains(
            "protocol LibraryMarkdownBackupRecoverySourceStore"))
        XCTAssertTrue(sourceContract.contains(
            "func adoptLibraryMarkdownBackupSource("))
        XCTAssertTrue(sourceContract.contains(
            "preserving operationIDs: Set<UUID>"))
        XCTAssertTrue(sourceContract.contains("func abandon() async"))
        XCTAssertTrue(useCase.contains(
            "pendingRecoveryCheckpoint"))
        XCTAssertTrue(useCase.contains(
            ".checkpointSource(cursor)"))
        XCTAssertTrue(useCase.contains(".recordFailure(recoveryFailure)"))
        XCTAssertTrue(useCase.contains("try await recoveryStore.apply("))
        XCTAssertTrue(useCase.contains("destinationLease.close()"))
        XCTAssertTrue(useCase.contains("maintenanceGate.disposition"))
        XCTAssertTrue(useCase.contains("workloadClass: .maintenance"))
        XCTAssertTrue(useCase.contains("kind: .mediaExport"))
        XCTAssertTrue(useCase.contains("shouldProceed(at: .admission)"))
        XCTAssertTrue(useCase.contains("shouldProceed(at: .checkpoint)"))
        XCTAssertTrue(useCase.contains("private var activeRun"))
        XCTAssertTrue(useCase.contains("restoreRecoveredRun("))
        XCTAssertTrue(useCase.contains("await source.abandon()"))
        XCTAssertTrue(useCase.contains("existingMarkdownFileNames"))
        XCTAssertTrue(useCase.contains("case .nameCollision:"))
        XCTAssertTrue(storage.contains("database.backup("))
        XCTAssertTrue(storage.contains("pagesPerStep: pagesPerStep"))
        XCTAssertTrue(storage.contains("database.read"))
        XCTAssertTrue(storage.contains(
            "private var cursor: MeetingMarkdownBackupStageCursor?"))
        XCTAssertTrue(storage.contains(
            "Column(\"startedAt\") < currentCursor.startedAt"))
        XCTAssertTrue(storage.contains(
            "Column(\"id\") > currentCursor.recordID"))
        XCTAssertTrue(storage.contains(
            "adoptLibraryMarkdownBackupStage("))
        XCTAssertTrue(storage.contains("configuration.readonly = true"))
        XCTAssertTrue(storage.contains(
            "try validateLibraryMarkdownBackupRegularFile("))
        XCTAssertTrue(storage.contains(
            "MeetingMarkdownBackupStageError.invalidCursor"))
        XCTAssertTrue(storage.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(storage.contains("values.isExcludedFromBackup = true"))
        XCTAssertTrue(storage.contains(".workspace-coordinator.lock"))
        XCTAssertTrue(storage.contains(".owner.lock"))
        XCTAssertTrue(storage.contains("portavoBSDFileLock"))
        XCTAssertTrue(storage.contains("O_NOFOLLOW"))
        XCTAssertTrue(storage.contains(
            "UUID(uuidString: workspace.lastPathComponent)"))
        XCTAssertTrue(storage.contains(
            "stageID.uuidString.lowercased() == workspace.lastPathComponent"))
        XCTAssertTrue(storage.contains(
            "cleanupAbandonedLibraryMarkdownBackupStages"))
        XCTAssertTrue(storage.contains("removesWorkspaceOnDeinit"))
        XCTAssertTrue(storage.contains("public func abandon()"))
        XCTAssertTrue(storage.contains(
            "preserving operationIDs: Set<UUID> = []"))
        XCTAssertTrue(storage.contains("generalSummarySnapshot"))
        XCTAssertTrue(adapter.contains("MeetingExporter.markdown"))
        XCTAssertTrue(adapter.contains("AppBackupDestinationAccess"))
        XCTAssertTrue(adapter.contains("PersistentFileBookmark().resolve"))
        XCTAssertTrue(adapter.contains(
            "AppLibraryMarkdownBackupRecoveryStore"))
        XCTAssertTrue(adapter.contains("RecoverLibraryMarkdownBackup("))
        XCTAssertTrue(adapter.contains("ReconcileBackupPublication("))
        XCTAssertTrue(adapter.contains("moveItem(at: temporary, to: destination)"))
        XCTAssertTrue(adapter.contains("Darwin.openat("))
        XCTAssertTrue(adapter.contains("O_NOFOLLOW"))
        XCTAssertTrue(adapter.contains("O_NONBLOCK"))
        XCTAssertTrue(adapter.contains("Darwin.fstat("))
        XCTAssertTrue(adapter.contains("var hasher = SHA256()"))
        XCTAssertFalse(adapter.contains("[.atomic, .withoutOverwriting]"))
        XCTAssertTrue(bookmark.contains(".withoutImplicitSecurityScope"))
        XCTAssertFalse(bookmark.contains("startAccessingSecurityScopedResource"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("private var pendingDirectory: URL?"))
        XCTAssertTrue(model.contains("func recoverAtLaunch()"))
        XCTAssertTrue(model.contains("recoverLibraryMarkdownBackup"))
        XCTAssertTrue(model.contains("hasPendingLaunchRecovery"))
        XCTAssertTrue(model.contains("func maintenanceMayResume()"))
        XCTAssertTrue(services.contains("let libraryMarkdownBackup: LibraryMarkdownBackupModel"))
        XCTAssertTrue(adapter.contains("cleanupOnLaunch: !usesTemporaryStore"))
        XCTAssertTrue(app.contains(
            "libraryMarkdownBackup.recoverAtLaunch()"))
        XCTAssertTrue(resourceAdapter.contains(
            "libraryMarkdownBackup.maintenanceMayResume()"))
        XCTAssertTrue(recoveryAdapter.contains(
            "private static let metadataFormatVersion = 2"))
        XCTAssertTrue(recoveryAdapter.contains(
            "private static let recordFormatVersion = 1"))
        XCTAssertTrue(recoveryAdapter.contains("options: .atomic"))
        XCTAssertTrue(recoveryAdapter.contains(
            "fileManager.moveItem("))
        XCTAssertTrue(recoveryAdapter.contains(
            "nextSequenceByOperation"))
        XCTAssertTrue(recoveryAdapter.contains(
            "nextFailureSequenceByOperation"))
        XCTAssertTrue(recoveryAdapter.contains(
            "guard cursor == current || Self.isAfter(cursor, current)"))
        XCTAssertTrue(recoveryAdapter.contains(
            "guard try !itemExists(pendingURL(operationID: operationID))"))
        XCTAssertTrue(recoveryAdapter.contains("func operationIDs()"))
        XCTAssertTrue(recoveryAdapter.contains(
            "operationID.uuidString.lowercased() == name"))
        XCTAssertTrue(recoveryAdapter.contains(
            "== publication.meetingID.rawValue.uuidString"))
        XCTAssertTrue(recoveryAdapter.contains(".posixPermissions: 0o600"))
        XCTAssertTrue(recoveryAdapter.contains(
            "values.isExcludedFromBackup = true"))
        XCTAssertTrue(view.contains("services.libraryMarkdownBackup"))
        XCTAssertTrue(view.contains("NSOpenPanel"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("MeetingExporter"))
        XCTAssertFalse(view.contains("Data(markdown"))
        XCTAssertFalse(view.contains("import IntegrationsKit"))
        XCTAssertFalse(view.contains("import StorageKit"))
        XCTAssertTrue(architecture.contains(
            "bounded pending-publication reconciliation operation"))
        XCTAssertTrue(decisions.contains("## D187"))
        XCTAssertTrue(decisions.contains("## D188"))
        XCTAssertTrue(decisions.contains("## D189"))
        XCTAssertTrue(appSpec.contains(
            "### Capture-safe staged whole-library backup (D180–D189)"))
    }

    func testFirstRunLedgerAndBriefStayBehindApplicationOwners() throws {
        let firstRun = try Self.contents(
            of: "Sources/ApplicationKit/FirstRunExperience.swift")
        let firstRunPolicy = try Self.contents(
            of: "Sources/ApplicationKit/FirstRunOnboarding.swift")
        let ledger = try Self.contents(
            of: "Sources/ApplicationKit/LocalDataLedger.swift")
        let brief = try Self.contents(
            of: "Sources/ApplicationKit/PrepareMeetingBrief.swift")
        let content = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let onboarding = try Self.contents(of: "Sources/portavoz-app/OnboardingView.swift")
        let settings = try Self.contents(
            of: "Sources/portavoz-app/SettingsCategories.swift")
        let briefView = try Self.contents(
            of: "Sources/portavoz-app/MeetingBriefView.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let firstRunAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+FirstRun.swift")
        let ledgerAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+LocalDataLedger.swift")
        let briefAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingBrief.swift")

        XCTAssertTrue(firstRun.contains("struct ResolveFirstRunExperience: ApplicationUseCase"))
        XCTAssertTrue(firstRunPolicy.contains("enum FirstRunOnboardingPolicy"))
        XCTAssertTrue(ledger.contains("struct LoadLocalDataLedger: ApplicationUseCase"))
        XCTAssertTrue(brief.contains("struct PrepareMeetingBrief: ApplicationUseCase"))
        for contract in [firstRun, firstRunPolicy, ledger, brief] {
            XCTAssertFalse(contract.contains("import StorageKit"))
            XCTAssertFalse(contract.contains("import GRDB"))
        }
        XCTAssertTrue(services.contains("let firstRun: FirstRunModel"))
        XCTAssertTrue(services.contains("let localDataLedger: LocalDataLedgerModel"))
        XCTAssertTrue(services.contains("let meetingBriefUseCase: PrepareMeetingBrief"))
        XCTAssertTrue(firstRunAdapter.contains("store.liveMeetingCount()"))
        XCTAssertTrue(ledgerAdapter.contains("store.liveMeetingCount()"))
        XCTAssertTrue(briefAdapter.contains("AppMeetingBriefLibraryReader"))
        XCTAssertTrue(briefAdapter.contains("AppOnDeviceMeetingBriefSynthesizer"))
        XCTAssertFalse(content.contains("services.store"))
        XCTAssertFalse(content.contains("UserDefaults"))
        XCTAssertFalse(content.contains("decideOnboarding"))
        XCTAssertFalse(onboarding.contains("UserDefaults"))
        XCTAssertFalse(settings.contains("services.store"))
        XCTAssertFalse(settings.contains("directorySize"))
        XCTAssertFalse(settings.contains("VoiceGallery"))
        XCTAssertFalse(settings.contains("RecordingsLocation"))
        XCTAssertFalse(settings.contains("import AudioCaptureKit"))
        XCTAssertFalse(settings.contains("import DiarizationKit"))
        XCTAssertFalse(settings.contains("import StorageKit"))
        XCTAssertFalse(briefView.contains("MeetingStore"))
        XCTAssertFalse(briefView.contains("AskMeetings"))
        XCTAssertFalse(briefView.contains("BriefSynthesizer"))
        XCTAssertFalse(briefView.contains("import IntelligenceKit"))
        XCTAssertFalse(briefView.contains("import StorageKit"))
    }

    func testMeetingReviewPoliciesStayInsideApplicationKit() throws {
        let policies = [
            "ChapterExtractor", "PlaybackRanges", "SummarySections", "VoiceHue",
        ]
        for policy in policies {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/ApplicationKit/\(policy).swift").path),
                "\(policy) must remain an inward ApplicationKit policy")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/IntegrationsKit/\(policy).swift").path),
                "\(policy) must not return to the outbound integration layer")
        }

        for consumer in [
            "InsightsView.swift", "MeetingDetailView.swift", "PVDesign.swift", "RecordingView.swift",
        ] {
            XCTAssertTrue(
                try Self.contents(of: "Sources/portavoz-app/\(consumer)")
                    .contains("import ApplicationKit"),
                "\(consumer) must consume meeting-review policy through ApplicationKit")
        }
    }

    func testInsightsReadPoliciesStayInsideApplicationKit() throws {
        let policies = [
            "InsightsScope", "LibraryStats", "InsightsFindings",
        ]
        for policy in policies {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/ApplicationKit/\(policy).swift").path),
                "\(policy) must remain an inward ApplicationKit policy")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/IntegrationsKit/\(policy).swift").path),
                "\(policy) must not return to the outbound integration layer")
        }

        let insights = try Self.contents(of: "Sources/portavoz-app/InsightsView.swift")
        XCTAssertTrue(insights.contains("import ApplicationKit"))
        XCTAssertFalse(
            insights.contains("import IntegrationsKit"),
            "InsightsView must not regain a broad outbound dependency for local read policy")
    }

    func testInsightsUsesOneScopedReadModelWithoutGlobalInvalidation() throws {
        let readModels = try Self.contents(
            of: "Sources/ApplicationKit/InsightsReadModels.swift")
        let model = try Self.contents(of: "Sources/portavoz-app/InsightsModel.swift")
        let adapter = try Self.contents(of: "Sources/portavoz-app/AppServices+Insights.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/InsightsView.swift")
        let content = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+InsightsObservation.swift")

        XCTAssertTrue(readModels.contains("struct InsightsReadModel"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("InsightsReadModel.compute"))
        XCTAssertTrue(adapter.contains("store.observeInsightsMeetings()"))
        XCTAssertTrue(adapter.contains("store.observeInsightsFacts()"))
        XCTAssertTrue(adapter.contains("store.observeInsightsVoiceBalance()"))
        XCTAssertTrue(adapter.contains("store.observeInsightsFindingInputs"))
        XCTAssertTrue(content.contains("@State private var insightsModel: InsightsModel"))
        XCTAssertTrue(view.contains("let model: InsightsModel"))
        XCTAssertFalse(view.contains("libraryVersion"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("import StorageKit"))
        for table in ["meeting", "speaker", "segment", "summary", "actionItem"] {
            XCTAssertTrue(storage.contains("Table(\"\(table)\")"))
        }
    }

    func testMeetingPreparationPoliciesStayInsideInwardLayers() throws {
        for policy in ["BriefRelevance", "ReminderPolicy", "MirrorStats"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/ApplicationKit/\(policy).swift").path),
                "\(policy) must remain an inward ApplicationKit policy")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: Self.repoRoot
                    .appendingPathComponent("Sources/IntegrationsKit/\(policy).swift").path),
                "\(policy) must not return to the outbound integration layer")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("Sources/PortavozCore/UpcomingEvent.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("Sources/ApplicationKit/UpcomingEvent.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repoRoot
            .appendingPathComponent("Sources/IntegrationsKit/UpcomingEvent.swift").path))

        let calendar = try Self.contents(
            of: "Sources/IntegrationsKit/CalendarAttendeeSource.swift")
        XCTAssertTrue(calendar.contains("import EventKit"))
        XCTAssertTrue(calendar.contains("import PortavozCore"))
        XCTAssertFalse(calendar.contains("struct UpcomingEvent"))

        for consumer in ["MeetingBriefView.swift", "MeetingReminder.swift", "MirrorCard.swift"] {
            XCTAssertTrue(
                try Self.contents(of: "Sources/portavoz-app/\(consumer)")
                    .contains("import ApplicationKit"),
                "\(consumer) must consume product policy through ApplicationKit")
        }

        for eventOnlyConsumer in [
            "ContentView.swift", "LibraryModel.swift", "LibraryView.swift", "RecordingView.swift",
        ] {
            XCTAssertFalse(
                try Self.contents(of: "Sources/portavoz-app/\(eventOnlyConsumer)")
                    .contains("import IntegrationsKit"),
                "\(eventOnlyConsumer) must not depend on the EventKit adapter for a Core value")
        }
    }

    func testMeetingDetailUsesScopedReadModelWithoutGlobalReload() throws {
        let readModels = try Self.contents(
            of: "Sources/ApplicationKit/MeetingDetailReadModels.swift")
        let model = try Self.meetingDetailModelContents()
        let adapter = try Self.contents(of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let reminderAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+CommitmentReminders.swift")
        let voiceAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+MeetingVoiceMemory.swift")
        let content = try Self.contents(of: "Sources/portavoz-app/ContentView.swift")
        let scene = try Self.contents(of: "Sources/portavoz-app/MeetingDetailScene.swift")
        let presentation = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailPresentation.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingDetailObservation.swift")
        let schema = try Self.contents(of: "Sources/StorageKit/Schema.swift")
        let orderingMigration = try Self.contents(
            of: "Sources/StorageKit/Schema+MeetingDetailOrdering.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(readModels.contains("struct MeetingReviewReadModel"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("struct MeetingDetailReviewAccumulator"))
        XCTAssertTrue(model.contains("func beginObservation() -> UUID"))
        XCTAssertTrue(model.contains("MeetingReviewReadModel("))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewCore"))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewSummary"))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewCompanionCards"))
        XCTAssertTrue(content.contains("MeetingDetailScene("))
        XCTAssertFalse(content.contains("MeetingDetailView("))
        XCTAssertTrue(content.contains(".id(id)"))
        XCTAssertTrue(scene.contains("@State private var model: MeetingDetailModel"))
        XCTAssertTrue(scene.contains("services.makeMeetingDetailModel(meetingID)"))
        XCTAssertTrue(scene.contains("MeetingDetailView("))
        XCTAssertTrue(view.contains("let model: MeetingDetailModel"))
        XCTAssertTrue(view.contains(".task { await model.observe() }"))
        XCTAssertFalse(view.contains("AppServices"))
        XCTAssertFalse(view.contains("services."))
        XCTAssertEqual(
            presentation.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("import ") },
            ["import Foundation"])
        for forbidden in [
            "AppLanguage",
            "AppServices",
            "Locale.current",
            "MeetingStore",
            "TimeZone.current",
            "@State",
            "@Environment",
        ] {
            XCTAssertFalse(presentation.contains(forbidden), forbidden)
        }
        XCTAssertFalse(view.contains("ReloadID"))
        XCTAssertFalse(view.contains("services.store.detail"))
        XCTAssertFalse(view.contains("services.store.mostRecentSummary"))
        XCTAssertFalse(view.contains("services.store.companionCards(for:"))
        XCTAssertFalse(view.contains("libraryVersion: services.libraryVersion"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("services.libraryVersion"))
        XCTAssertFalse(view.contains("services.meetingLifecycle"))
        XCTAssertTrue(storage.contains(
            #".order(Column("startTime"), Column("id"))"#))
        XCTAssertTrue(schema.contains("public static let version = 51"))
        XCTAssertTrue(schema.contains("registerMeetingDetailOrderingMigration"))
        XCTAssertTrue(orderingMigration.contains("registerMigration(\"v49\")"))
        XCTAssertTrue(orderingMigration.contains(
            "ON segment(meetingID, startTime, id)"))
        XCTAssertTrue(orderingMigration.contains("WHERE deletedAt IS NULL"))
        XCTAssertTrue(decisions.contains("## D455"))
        XCTAssertTrue(voiceAdapter.contains("Task.detached(priority: .utility)"))
        XCTAssertTrue(voiceAdapter.contains(#"arguments.contains("-use-temp-store")"#))
        XCTAssertTrue(model.contains("enum Action"))
        XCTAssertTrue(model.contains("case renameMeeting"))
        XCTAssertTrue(model.contains("case renameSpeaker"))
        XCTAssertTrue(model.contains("case findCanonicalPeople"))
        XCTAssertTrue(model.contains("case linkCanonicalPerson"))
        XCTAssertTrue(model.contains("case setActionItem"))
        XCTAssertTrue(model.contains("case removeCompanionCard"))
        XCTAssertTrue(model.contains("enum CommitmentAction"))
        XCTAssertTrue(model.contains("case commitment(CommitmentAction)"))
        XCTAssertTrue(model.contains("case deleteMeeting"))
        XCTAssertTrue(model.contains("case prepareDocument"))
        XCTAssertTrue(model.contains("case publishGist"))
        XCTAssertTrue(model.contains("case loadVoiceSuggestions"))
        XCTAssertTrue(model.contains("case rememberVoice"))
        XCTAssertFalse(model.contains("Unexpected Meeting Detail"))
        XCTAssertTrue(adapter.contains("renameMeetingDetailMeeting"))
        XCTAssertTrue(adapter.contains("renameMeetingDetailSpeaker"))
        XCTAssertTrue(adapter.contains("FindCanonicalPeople(store: store)"))
        XCTAssertTrue(adapter.contains("LinkObservedSpeaker(store: store)"))
        XCTAssertTrue(adapter.contains("setMeetingDetailActionItem"))
        XCTAssertTrue(adapter.contains("deleteMeetingDetailCompanionCard"))
        XCTAssertTrue(reminderAdapter.contains("ManageMeetingCommitmentInbox("))
        XCTAssertTrue(reminderAdapter.contains("AppMeetingCommitmentReviewRepository"))
        XCTAssertTrue(adapter.contains("deleteMeetingDetail"))
        XCTAssertTrue(adapter.contains("requestMeetingDetailSearchReindex"))
        XCTAssertTrue(storage.contains(
            "Table(\"transcriptCorrection\"), Table(\"transcriptCorrectionTarget\")"))
        XCTAssertTrue(storage.contains(
            "Table(\"transcriptCorrectionPayload\"), Table(\"transcriptCorrectionPart\")"))
        XCTAssertTrue(storage.contains("Table(\"summaryClaim\")"))
        XCTAssertTrue(storage.contains("Table(\"summaryClaimSegment\")"))
        XCTAssertTrue(storage.contains("Table(\"companionCard\")"))
        XCTAssertTrue(storage.contains("Table(\"companionCardEvidence\")"))
        XCTAssertTrue(storage.contains("Table(\"companionCardEvidenceSegment\")"))
    }

    func testMeetingDetailSectionsReceiveOnlyExplicitValuesAndActions() throws {
        let scene = try Self.contents(of: "Sources/portavoz-app/MeetingDetailScene.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let flow = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailFlowState.swift")
        let actions = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailActionSection.swift")
        let header = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailHeaderSection.swift")
        let generatedDocument = try Self.contents(
            of: "Sources/portavoz-app/MeetingGeneratedDocumentSection.swift")
        let commitments = try Self.contents(
            of: "Sources/portavoz-app/MeetingCommitmentInboxSection.swift")
        let trust = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailTrustSection.swift")
        let transcript = try Self.contents(
            of: "Sources/portavoz-app/MeetingTranscriptSection.swift")
        let player = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailPlayerSection.swift")
        let notes = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailNotesSection.swift")
        let refineReview = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailRefineReviewSheet.swift")
        let rail = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailRailSection.swift")
        let focusedTranscript = try Self.contents(
            of: "Sources/portavoz-app/FocusedTranscriptView.swift")
        let documentPresentation = try Self.contents(
            of: "Sources/ApplicationKit/MeetingGeneratedDocumentPresentation.swift")
        let transcriptContent = try Self.contents(
            of: "Sources/ApplicationKit/MeetingTranscriptContent.swift")

        XCTAssertTrue(view.contains("MeetingDetailHeaderSection("))
        XCTAssertTrue(view.contains("MeetingGeneratedDocumentSection("))
        XCTAssertTrue(view.contains("MeetingCommitmentInboxSection("))
        XCTAssertTrue(view.contains("MeetingDetailActionSection("))
        XCTAssertTrue(view.contains("MeetingDetailRailSection("))
        XCTAssertTrue(view.contains("MeetingTranscriptSection("))
        XCTAssertTrue(view.contains("MeetingDetailPlayerSection("))
        XCTAssertTrue(view.contains("MeetingDetailNotesSection("))
        XCTAssertTrue(rail.contains("MeetingDetailTrustSection("))
        XCTAssertTrue(rail.contains("MeetingTranscriptChaptersSection("))
        XCTAssertFalse(view.contains("private func header("))
        XCTAssertFalse(view.contains("private func speakersRow("))
        XCTAssertFalse(view.contains("private func summarySection("))
        XCTAssertFalse(view.contains("private var transcriptHeader"))
        XCTAssertFalse(view.contains("private func transcriptArea("))
        XCTAssertFalse(view.contains("private func transcriptLines("))
        XCTAssertFalse(view.contains("private func chaptersSection("))
        XCTAssertFalse(view.contains("private var playerDock"))
        XCTAssertFalse(view.contains("private var compressRow"))
        XCTAssertFalse(view.contains("private var companionCardsSection"))

        for (name, source) in [
            ("actions", actions),
            ("header", header),
            ("generated document", generatedDocument),
            ("commitments", commitments),
            ("trust", trust),
            ("transcript", transcript),
            ("player", player),
            ("rail", rail),
            ("notes", notes),
            ("refine review", refineReview)
        ] {
            XCTAssertTrue(source.contains("Values"), name)
            XCTAssertTrue(source.contains("Actions"), name)
            XCTAssertTrue(
                source.contains(".accessibilityElement(children: .contain)"),
                "\(name) must preserve nested interaction identifiers")
            for forbidden in [
                "AppServices", "MeetingDetailModel", "MeetingStore",
                "MeetingDetailCoordinator", "UserDefaults.standard", "@Environment",
                "services.", "model."
            ] {
                XCTAssertFalse(source.contains(forbidden), "\(name): \(forbidden)")
            }
        }
        XCTAssertFalse(header.contains("@State"))
        XCTAssertTrue(generatedDocument.contains("@State private var tabSelection"))
        XCTAssertFalse(generatedDocument.contains("SummarySections.parse"))
        XCTAssertFalse(generatedDocument.contains("CustomRecipeStore"))
        XCTAssertTrue(generatedDocument.contains("MeetingEvidenceSources("))
        XCTAssertTrue(commitments.contains("struct MeetingCommitmentInboxValues"))
        XCTAssertTrue(commitments.contains("struct MeetingCommitmentInboxActions"))
        XCTAssertTrue(commitments.contains("MeetingEvidenceSources("))
        XCTAssertTrue(trust.contains("@State private var retryingProcessing"))
        XCTAssertTrue(transcript.contains("struct MeetingTranscriptValues"))
        XCTAssertTrue(transcript.contains("struct MeetingTranscriptActions"))
        XCTAssertTrue(transcript.contains("MeetingTranscriptContent"))
        XCTAssertTrue(transcript.contains("presentCorrection:"))
        XCTAssertFalse(transcript.contains("@State private var correctionRow"))
        XCTAssertFalse(transcript.contains(".sheet(item: $correctionRow)"))
        XCTAssertFalse(transcript.contains("ChapterExtractor"))
        XCTAssertTrue(player.contains("struct MeetingDetailPlayerValues"))
        XCTAssertTrue(player.contains("struct MeetingDetailPlayerActions"))
        XCTAssertTrue(player.contains("MeetingPlayerBar("))
        XCTAssertFalse(player.contains("@State"))
        XCTAssertTrue(notes.contains("struct MeetingDetailNotesValues"))
        XCTAssertTrue(notes.contains("struct MeetingDetailNotesActions"))
        XCTAssertTrue(refineReview.contains("struct MeetingDetailRefineReviewActions"))
        XCTAssertTrue(actions.contains("struct MeetingDetailActionValues"))
        XCTAssertTrue(actions.contains("struct MeetingDetailActionActions"))
        XCTAssertFalse(actions.contains("@State"))
        XCTAssertTrue(rail.contains("struct MeetingDetailRailValues"))
        XCTAssertTrue(rail.contains("struct MeetingDetailRailActions"))
        XCTAssertTrue(rail.contains("MeetingDetailCompanionSection("))
        XCTAssertTrue(rail.contains("let hasHealth: Bool"))
        XCTAssertFalse(rail.contains("segments.contains"))
        XCTAssertFalse(rail.contains("@State"))

        XCTAssertTrue(scene.contains("@State private var flow = MeetingDetailFlowState()"))
        XCTAssertTrue(scene.contains("@AppStorage(\"mirrorAfterMeeting\")"))
        XCTAssertTrue(scene.contains("flow: flow"))
        XCTAssertTrue(scene.contains("closeDetail: {"))
        XCTAssertTrue(scene.contains("showInsights: {"))
        XCTAssertTrue(scene.contains("disableMirrorAfterMeeting: {"))
        XCTAssertTrue(flow.contains("@Observable"))
        XCTAssertTrue(flow.contains("enum SheetRoute"))
        XCTAssertTrue(flow.contains("TranscriptCorrectionTarget"))
        XCTAssertTrue(flow.contains("presentTranscriptCorrection("))
        XCTAssertTrue(flow.contains("enum DialogRoute"))
        XCTAssertTrue(flow.contains("enum AlertRoute"))
        for legacyState in [
            "@State private var renamingSpeaker",
            "@State private var exportDocument",
            "@State private var showGistConfirm",
            "@State private var showingRecap",
            "@State private var summarySetupIssue",
            "@State private var editingTitle",
            "@State private var showingNewStructure",
            "@State private var choosingPerson",
        ] {
            XCTAssertFalse(view.contains(legacyState), legacyState)
        }
        for forbidden in [
            "AppServices", "MeetingDetailModel", "MeetingStore",
            "UserDefaults.standard", "@Environment", "services.", "model."
        ] {
            XCTAssertFalse(flow.contains(forbidden), "flow: \(forbidden)")
        }

        XCTAssertEqual(
            transcriptContent.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("import ") },
            ["import Foundation", "import PortavozCore"])
        XCTAssertTrue(transcriptContent.contains("sourceSegmentIDs"))
        XCTAssertTrue(transcriptContent.contains("rowID(at:"))
        XCTAssertTrue(transcriptContent.contains("activeRowID(at:"))
        XCTAssertTrue(transcriptContent.contains("rightmostRowEnding("))
        for forbidden in [
            "import SwiftUI", "AppServices", "MeetingDetailModel", "MeetingStore",
            "UserDefaults", "@State", "@Environment",
        ] {
            XCTAssertFalse(transcriptContent.contains(forbidden), forbidden)
        }
        XCTAssertTrue(focusedTranscript.contains("struct FocusedTranscriptView<"))
        XCTAssertTrue(focusedTranscript.contains("Accessory: View"))
        XCTAssertTrue(focusedTranscript.contains("accessory(segment, isActive)"))
        XCTAssertTrue(focusedTranscript.contains("TranscriptFollowOwnershipPolicy"))
        XCTAssertFalse(focusedTranscript.contains("import PortavozCore"))

        XCTAssertEqual(
            documentPresentation.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("import ") },
            ["import Foundation"])
        XCTAssertTrue(documentPresentation.contains("sourceOrdinal"))
        XCTAssertTrue(documentPresentation.contains("hasTypedCommitments"))
        for forbidden in [
            "SwiftUI", "L10n", "AppServices", "MeetingStore", "@State", "@Environment",
        ] {
            XCTAssertFalse(documentPresentation.contains(forbidden), forbidden)
        }
    }

    func testCompactReviewActivationUsesOwnedRevealAndExactPostconditions() throws {
        let support = try Self.contents(
            of: "Tests/PortavozUITests/UITestSupport.swift")
        let transcript = try Self.contents(
            of: "Sources/portavoz-app/TranscriptSegmentsView.swift")
        let recording = try Self.contents(
            of: "Sources/portavoz-app/RecordingView.swift")
        let objectives = try Self.contents(
            of: "Sources/portavoz-app/RecordingLiveAssist.swift")
        let uiTests = try Self.contents(
            of: "Tests/PortavozUITests/MeetingDetailUITests.swift")
        let interviewUITest = try Self.contents(
            of: "Tests/PortavozUITests/InterviewAssistUITests.swift")
        let askServices = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Ask.swift")
        let askUITest = try Self.contents(
            of: "Tests/PortavozUITests/LibraryUITests.swift")
        let decisions = try Self.contents(of: "docs/DECISIONS.md")

        XCTAssertTrue(transcript.contains(
            "scrollAccessibilityIdentifier: \"detail-transcript-scroll\""))
        XCTAssertTrue(transcript.contains(
            ".accessibilityIdentifier(\"detail-transcript-scroll\")"))
        XCTAssertGreaterThanOrEqual(
            uiTests.components(
                separatedBy: "correct.revealVertically(in: transcriptScroll").count - 1,
            2,
            "text and structural correction must reveal their exact target")
        XCTAssertTrue(support.contains("func revealVertically("))
        XCTAssertTrue(support.contains("viewportFrame.contains(controlFrame)"))
        XCTAssertTrue(support.contains("private func waitForStableContainedFrame("))
        XCTAssertTrue(support.contains("maximumStep: CGFloat = 48"))
        XCTAssertTrue(support.contains("let geometryChanged = waitForUITestCondition("))
        XCTAssertTrue(support.contains("let rawViewportFrame = viewportElement.frame"))
        XCTAssertTrue(support.contains("updatedViewportFrame != rawViewportFrame"))
        XCTAssertFalse(support.contains("updatedViewportFrame != viewportFrame"))
        XCTAssertTrue(support.contains("pollInterval: 0.02"))
        XCTAssertTrue(support.contains("above anchorElement: XCUIElement"))
        XCTAssertTrue(support.contains(
            "maxScrolls: max(0, maxScrolls - attempt - 1)"))
        XCTAssertTrue(support.contains("if !geometryChanged { continue }"))
        XCTAssertFalse(support.contains("guard targetMoved else { return false }"))
        XCTAssertEqual(
            support.components(
                separatedBy: "if viewportFrame.contains(frame),").count - 1,
            2,
            "geometric containment alone must not terminate before hittability")
        XCTAssertTrue(support.contains(
            "let inwardDelta = viewportFrame.midY - controlFrame.midY"))
        XCTAssertTrue(support.contains(
            "deltaY = min(max(inwardDelta, -maximumStep), maximumStep)"))
        XCTAssertFalse(support.contains(
            "if viewportFrame.contains(frame) {\n"
                + "                return waitForStableContainedFrame("))
        XCTAssertFalse(uiTests.contains("private extension XCUIElement"))
        XCTAssertFalse(uiTests.contains("deltaY: CGFloat = -48"))
        XCTAssertFalse(uiTests.contains("waitForVisibleStableFrame"))
        XCTAssertTrue(support.contains("for _ in 0..<maxScrolls"))
        XCTAssertFalse(support.contains("Task.sleep"))
        XCTAssertFalse(uiTests.contains("sleep("))

        XCTAssertTrue(objectives.contains(
            ".accessibilityElement(children: .contain)\n"
                + "        .accessibilityLabel(objective.text)\n"
                + "        .accessibilityIdentifier(\n"
                + "            \"recording-objective-text-\\(objective.id.uuidString)\")\n"
                + "        .id(objective.id)"))
        // Objective reveal behavior belongs to the real-app single/batched
        // arrival journeys, not an assertion freezing the predicate's spelling.
        XCTAssertTrue(recording.contains("RecordingAssistPanel(controller: controller)"))
        XCTAssertFalse(
            recording.contains(".frame(maxHeight: 260)"),
            "the assist area must grow with the window, not sit at a pinned height")

        let objectiveSubmit = try XCTUnwrap(interviewUITest.range(
            of: "objective.typeKey(.return, modifierFlags: [])"))
        let objectiveAdmission = try XCTUnwrap(interviewUITest.range(
            of: "objectiveCount.waitForLabelOrValue(expectedObjectiveCount, timeout: 5)"))
        let admissionFailure = try XCTUnwrap(interviewUITest.range(
            of: "objective admission must publish before proving its saved row"))
        let savedObjective = try XCTUnwrap(interviewUITest.range(
            of: "identifier BEGINSWITH %@ AND label == %@"))
        let objectiveExistence = try XCTUnwrap(interviewUITest.range(
            of: "savedObjective.waitForExistenceFast(timeout: 5)"))
        let zeroGestureContainment = try XCTUnwrap(interviewUITest.range(
            of: "maxScrolls: 0"))
        XCTAssertLessThan(objectiveSubmit.lowerBound, objectiveAdmission.lowerBound)
        XCTAssertLessThan(objectiveAdmission.lowerBound, admissionFailure.lowerBound)
        XCTAssertLessThan(admissionFailure.lowerBound, savedObjective.lowerBound)
        XCTAssertLessThan(savedObjective.lowerBound, objectiveExistence.lowerBound)
        XCTAssertLessThan(objectiveExistence.lowerBound, zeroGestureContainment.lowerBound)
        XCTAssertFalse(interviewUITest.contains("add.click()"))
        XCTAssertTrue(askUITest.contains(
            "app.control(withIdentifier: \"recording-objective-add\").click()"))
        XCTAssertFalse(interviewUITest.contains(
            "objectiveCount.revealVertically(in: assist)"))
        XCTAssertFalse(interviewUITest.contains("above: objectiveCount"))
        XCTAssertFalse(interviewUITest.contains("missingTargetDeltaY"))
        XCTAssertFalse(interviewUITest.contains("private extension XCUIElement"))
        XCTAssertFalse(interviewUITest.contains("waitForStableContainedFrame("))
        XCTAssertFalse(interviewUITest.contains("max(distance, 120)"))
        XCTAssertFalse(interviewUITest.contains(
            "scroll.scroll(byDeltaX: 0, deltaY: -240)"))
        XCTAssertTrue(interviewUITest.contains(
            "answerAction.revealVertically(in: assist)"))

        let commitmentExistence = try XCTUnwrap(uiTests.range(
            of: "review.waitForExistenceFast(timeout: 5)"))
        let commitmentActivation = try XCTUnwrap(uiTests.range(
            of: "review.click()"))
        let commitmentPostcondition = try XCTUnwrap(uiTests.range(
            of: "app.control(withIdentifier: \"commitment-editor\")"
                + ".waitForExistenceFast(timeout: 5)"))
        XCTAssertLessThan(
            commitmentExistence.lowerBound,
            commitmentActivation.lowerBound)
        XCTAssertLessThan(
            commitmentActivation.lowerBound,
            commitmentPostcondition.lowerBound)
        XCTAssertFalse(uiTests.contains(
            "review.revealVertically(in: artifacts)"))

        XCTAssertTrue(askServices.contains(
            "-simulate-ask-progressive-handshake"))
        XCTAssertFalse(askServices.contains(
            "Task.sleep(for: .milliseconds(500))"))
        XCTAssertFalse(askServices.contains(
            "Task.sleep(for: .milliseconds(350))"))
        XCTAssertGreaterThanOrEqual(
            askUITest.components(
                separatedBy: "continueFeatureUITestHandshake(").count - 1,
            3,
            "Ask must explicitly release Notes, evidence, and partial-answer phases")
        XCTAssertFalse(askServices.contains("Task.sleep(for: .milliseconds(700))"))
        for key in ["PORTAVOZ_UI_TEST_ASK_NOTES_READY_PATH",
                    "PORTAVOZ_UI_TEST_ASK_NOTES_CONTINUE_PATH"] {
            XCTAssertTrue(askServices.contains(key))
            XCTAssertTrue(askUITest.contains(key))
        }
        XCTAssertTrue(askUITest.contains(
            "waitForFeatureUITestHandshakeRelease("))
        XCTAssertTrue(decisions.contains("## D409"))
        XCTAssertTrue(decisions.contains("## D414"))
        XCTAssertTrue(decisions.contains("## D415"))
        XCTAssertTrue(decisions.contains("## D416"))
        XCTAssertTrue(decisions.contains("## D426"))
    }

    func testMeetingDetailCompositionKeepsEffectsOutOfPresentationChildren() throws {
        let view = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let artifacts = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailArtifactsSection.swift")
        let flowHost = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailFlowHost.swift")
        let playbackNavigation = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailPlaybackNavigation.swift")
        let scene = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailScene.swift")
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator.swift")
        let identityCoordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator+Identity.swift")
        let documentCoordinator = try Self.contents(
            of: "Sources/portavoz-app/MeetingDetailCoordinator+Documents.swift")

        XCTAssertTrue(view.contains("MeetingDetailFlowHost("))
        XCTAssertTrue(view.contains("MeetingDetailPlaybackNavigation()"))
        XCTAssertTrue(view.contains("MeetingDetailArtifactsSection"))
        XCTAssertTrue(artifacts.contains(
            ".frame(minHeight: 180, idealHeight: 240, maxHeight: 240)"))
        XCTAssertTrue(view.contains(".layoutPriority(1)"))
        XCTAssertTrue(flowHost.contains("MeetingDetailRefineReviewSheet("))
        XCTAssertTrue(flowHost.contains("TranscriptCorrectionEditor("))
        XCTAssertTrue(flowHost.contains("TranscriptStructuralCorrectionEditor("))
        for obsoletePresentation in [
            "private func notesHeader(", "private func notesContent(",
            "private func refineReviewSheet(", "private func sheetContent(",
            "private var dialogButtons", "private var alertButtons"
        ] {
            XCTAssertFalse(view.contains(obsoletePresentation), obsoletePresentation)
        }
        XCTAssertFalse(view.contains("model.send("))
        XCTAssertFalse(view.contains("@Binding"))
        XCTAssertFalse(view.contains("@AppStorage"))
        XCTAssertFalse(view.contains("CustomRecipeStore"))
        XCTAssertFalse(view.contains("route ="))
        XCTAssertLessThanOrEqual(
            view.components(separatedBy: .newlines).count,
            500,
            "Meeting Detail must remain a compact composition surface")

        XCTAssertTrue(flowHost.contains("struct MeetingDetailFlowValues"))
        XCTAssertTrue(flowHost.contains("struct MeetingDetailFlowActions"))
        XCTAssertTrue(flowHost.contains("MeetingDetailFlowState"))
        XCTAssertTrue(flowHost.contains("let copyText:"))
        XCTAssertTrue(flowHost.contains("let openURL:"))
        XCTAssertFalse(flowHost.contains("import AppKit"))
        XCTAssertFalse(flowHost.contains("NSPasteboard"))
        XCTAssertFalse(flowHost.contains("NSWorkspace"))
        XCTAssertTrue(playbackNavigation.contains("@Observable"))
        XCTAssertTrue(playbackNavigation.contains("MeetingTranscriptNavigationState"))
        XCTAssertTrue(view.contains("deliverPendingMeetingSeekIfPossible()"))
        XCTAssertTrue(view.contains("if didApply"))
        XCTAssertTrue(view.contains("sceneActions.acknowledgePendingSeek(request.id)"))
        XCTAssertTrue(scene.contains("services.pendingMeetingSeek?.id == requestID"))
        XCTAssertFalse(scene.contains("consumePendingSeek:"))
        for source in [flowHost, playbackNavigation] {
            for forbidden in [
                "AppServices", "MeetingDetailModel", "MeetingStore",
                "MeetingDetailCoordinator", "model.", "services.", "store."
            ] {
                XCTAssertFalse(source.contains(forbidden), forbidden)
            }
        }

        let coordinatorSources = coordinator + identityCoordinator + documentCoordinator
        XCTAssertTrue(coordinatorSources.contains("model.send("))
        XCTAssertTrue(coordinatorSources.contains("MeetingDetailModel"))
        XCTAssertFalse(coordinatorSources.contains("import SwiftUI"))
        for forbidden in [
            "AppServices", "MeetingStore", "StorageKit", "DiarizationKit",
            "AudioCaptureKit", "services.", "store."
        ] {
            XCTAssertFalse(coordinatorSources.contains(forbidden), forbidden)
        }
    }
}
