import ApplicationKit
import Foundation
import XCTest

final class ArchitectureDependencyTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testPackageExposesOnlyImplementedKitBoundaries() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let targets = try TargetManifestParser.declarations(in: manifest)

        for name in ["ContextFeedKit", "SyncKit"] {
            XCTAssertNil(
                targets[name],
                "Speculative package target \(name) must not return without a vertical use case")
            XCTAssertFalse(
                manifest.contains(#".library(name: "\#(name)""#),
                "Speculative package product \(name) must not return without a vertical use case")
        }
    }

    func testApplicationKitManifestBoundaryAdmitsOnlyExtractedCapabilities() throws {
        let manifest = try Self.contents(of: "Package.swift")
        let targets = try TargetManifestParser.declarations(in: manifest)
        let application = try XCTUnwrap(targets["ApplicationKit"])

        XCTAssertEqual(
            application.dependencies,
            [
                "DiarizationKit", "IntelligenceKit", "PortavozCore", "StorageKit",
                "TranscriptionKit",
            ])
        XCTAssertTrue(try XCTUnwrap(targets["portavoz-app"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(try XCTUnwrap(targets["portavoz-cli"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(try XCTUnwrap(targets["PortavozTests"]).dependencies.contains(
            "ApplicationKit"))
        XCTAssertTrue(manifest.contains(
            #".library(name: "ApplicationKit", targets: ["ApplicationKit"])"#))
        XCTAssertTrue(try Self.contents(of: "project.yml").contains("- ApplicationKit"))
    }

    func testCapabilityTargetsNeverDependBackOnApplicationKit() throws {
        let targets = try TargetManifestParser.declarations(
            in: Self.contents(of: "Package.swift"))
        let allowedConsumers = Set([
            "ApplicationKit", "portavoz-app", "portavoz-cli", "PortavozTests",
        ])
        let violations = targets.values
            .filter { !allowedConsumers.contains($0.name) }
            .filter { $0.dependencies.contains("ApplicationKit") }
            .map(\.name)
            .sorted()

        XCTAssertTrue(
            violations.isEmpty,
            "Capability targets must not depend on ApplicationKit: \(violations)")
    }

    func testCoreForbiddenImportsRemainAtDocumentedBaseline() throws {
        let forbidden = Set([
            "AppKit", "SwiftUI", "GRDB", "Security", "Network", "FoundationNetworking",
        ])
        let actual = try Self.imports(under: "Sources/PortavozCore")
            .filter { forbidden.contains($0.module) }
            .reduce(into: [String: [String]]()) { result, item in
                result[item.module, default: []].append(item.file)
            }
            .mapValues { $0.sorted() }

        // SecretStore is existing debt scheduled for a platform adapter. The
        // allowlist prevents that exception from spreading during extraction.
        XCTAssertEqual(actual, ["Security": ["SecretStore.swift"]])
    }

    func testCompanionBYOKEgressCannotBypassTheGateway() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let byok = try Self.contents(of: "Sources/IntelligenceKit/BYOK.swift")
        let companion = try Self.contents(of: "Sources/IntelligenceKit/Companion.swift")
        let provenance = try Self.contents(
            of: "Sources/IntelligenceKit/CompanionGenerationProvenance.swift")
        let recording = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")
        let refresh = try Self.contents(of: "Sources/portavoz-app/CompanionRefresh.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")

        XCTAssertTrue(core.contains("public protocol DataEgressGateway"))
        XCTAssertFalse(core.contains("URLSession.shared"))
        XCTAssertTrue(adapter.contains("try Self.validate(networkRequest"))
        XCTAssertTrue(adapter.contains("delegate: DataEgressRedirectBlocker()"))
        XCTAssertTrue(byok.contains("private let gateway: any DataEgressGateway"))
        XCTAssertTrue(byok.contains("gateway.perform(networkRequest, metadata: metadata)"))
        let clientStart = try XCTUnwrap(
            byok.range(of: "public struct CompanionBYOKClient"))
        let settingsStart = try XCTUnwrap(byok.range(
            of: "public enum BYOKSettings",
            range: clientStart.upperBound..<byok.endIndex))
        let companionClient = byok[clientStart.lowerBound..<settingsStart.lowerBound]
        XCTAssertFalse(companionClient.contains("URLSession"))
        XCTAssertFalse(companionClient.contains("data(for:"))
        XCTAssertTrue(companion.contains("completeCompanionQuestion"))
        XCTAssertFalse(companion.contains("byok.complete("))
        XCTAssertFalse(companion.contains("OpenAICompatibleSummaryClient("))
        XCTAssertFalse(companion.contains("session.data(for:"))
        XCTAssertFalse(provenance.contains("session.data(for:"))
        XCTAssertTrue(provenance.contains(
            "egressConsentSource: DataEgressConsentSource = .explicitCompanionClient"))
        XCTAssertTrue(services.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        XCTAssertTrue(recording.contains("services?.dataEgressGateway"))
        XCTAssertTrue(recording.contains("gateway: gateway"))
        XCTAssertTrue(refresh.contains("gateway: any DataEgressGateway"))
        XCTAssertTrue(refresh.contains("gateway: gateway"))
        for source in [recording, refresh] {
            XCTAssertTrue(source.contains(
                "egressConsentSource: .companionBYOKSettings"))
            XCTAssertFalse(source.contains("URLSession.shared"))
            XCTAssertFalse(source.contains("data(for:"))
        }
    }

    func testOpenAICompatibleSummaryEgressCannotBypassTheGateway() throws {
        let byok = try Self.contents(of: "Sources/IntelligenceKit/BYOK.swift")
        let provider = try Self.contents(
            of: "Sources/IntelligenceKit/OpenAICompatibleSummaryProvider.swift")
        let ollama = try Self.contents(of: "Sources/IntelligenceKit/OllamaService.swift")
        let regeneration = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Application.swift")
        let processing = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        let cli = try Self.contents(of: "Sources/portavoz-cli/CLISummarize.swift")

        XCTAssertTrue(byok.contains("public struct OpenAICompatibleSummaryClient"))
        XCTAssertTrue(byok.contains("private let gateway: any DataEgressGateway"))
        let summaryStart = try XCTUnwrap(
            byok.range(of: "public struct OpenAICompatibleSummaryClient"))
        let companionStart = try XCTUnwrap(byok.range(
            of: "struct CompanionDataEgressContext",
            range: summaryStart.upperBound..<byok.endIndex))
        let summaryClient = byok[summaryStart.lowerBound..<companionStart.lowerBound]
        XCTAssertTrue(summaryClient.contains("gateway.perform(networkRequest, metadata: metadata)"))
        XCTAssertFalse(summaryClient.contains("URLSession"))
        XCTAssertFalse(summaryClient.contains("data(for:"))
        XCTAssertTrue(provider.contains("client.completeSummary("))
        XCTAssertFalse(provider.contains("URLSession"))
        XCTAssertFalse(provider.contains("data(for:"))
        XCTAssertTrue(ollama.contains("gateway: any DataEgressGateway"))

        XCTAssertTrue(regeneration.contains("gateway: gateway"))
        XCTAssertTrue(regeneration.contains("consentSource: .summaryEngineSettings"))
        XCTAssertTrue(processing.contains("gateway: dataEgressGateway"))
        XCTAssertTrue(processing.contains("consentSource: .summaryEngineSettings"))
        XCTAssertTrue(cli.contains(
            "URLSessionDataEgressGateway(receiptRecorder: receiptStore)"))
        let cliMeetingSave = try XCTUnwrap(cli.range(
            of: "try await receiptStore.save(record)"))
        let cliRemoteSummary = try XCTUnwrap(cli.range(
            of: "let draft = try await provider.summarize(request)"))
        XCTAssertLessThan(cliMeetingSave.lowerBound, cliRemoteSummary.lowerBound)
        XCTAssertFalse(cli.contains("URLSession.shared"))
        XCTAssertFalse(cli.contains("data(for:"))
    }

    func testExplicitPublishingEgressCannotBypassTheGateway() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let gist = try Self.contents(of: "Sources/IntegrationsKit/GistPublisher.swift")
        let issues = try Self.contents(of: "Sources/IntegrationsKit/IssueExporters.swift")
        let detail = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let cliExport = try Self.contents(of: "Sources/portavoz-cli/CLIExport.swift")
        let cliIssues = try Self.contents(of: "Sources/portavoz-cli/CLIIssues.swift")

        for operation in ["publishGitHubGist", "createGitHubIssue", "createLinearIssue"] {
            XCTAssertTrue(core.contains(operation))
            XCTAssertTrue(adapter.contains("case .\(operation):"))
        }
        for publisher in [gist, issues] {
            XCTAssertTrue(publisher.contains("private let gateway: any DataEgressGateway"))
            XCTAssertTrue(publisher.contains("gateway.perform("))
            XCTAssertFalse(publisher.contains("URLSession"))
            XCTAssertFalse(publisher.contains("data(for:"))
        }
        XCTAssertTrue(detail.contains("gateway: services.dataEgressGateway"))
        XCTAssertTrue(detail.contains("meetingID: detail.meeting.id"))
        XCTAssertTrue(cliExport.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        XCTAssertTrue(cliExport.contains("meetingID: meetingID"))
        XCTAssertTrue(cliIssues.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))
        XCTAssertTrue(cliIssues.contains("meetingID: meetingID"))
    }

    func testMeetingContentEgressPersistsReceiptBeforeTransport() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/DataEgress.swift")
        let adapter = try Self.contents(
            of: "Sources/IntegrationsKit/URLSessionDataEgressGateway.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+PrivacyReceipt.swift")
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")

        XCTAssertTrue(core.contains("public protocol DataEgressEventRecorder"))
        XCTAssertTrue(core.contains("public struct PrivacyReceipt"))
        let validation = try XCTUnwrap(adapter.range(of: "try Self.validate(networkRequest"))
        let receipt = try XCTUnwrap(adapter.range(of: "recordDataEgressEvent"))
        let transport = try XCTUnwrap(adapter.range(of: "let (data, response) = try await session.data("))
        XCTAssertLessThan(validation.lowerBound, receipt.lowerBound)
        XCTAssertLessThan(receipt.lowerBound, transport.lowerBound)
        XCTAssertTrue(storage.contains("extension MeetingStore: DataEgressEventRecorder"))
        XCTAssertTrue(storage.contains("guard let meetingID = event.meetingID"))
        XCTAssertTrue(services.contains(
            "URLSessionDataEgressGateway(receiptRecorder: store)"))

        let forbiddenReceiptFields = [
            "transcript", "prompt", "markdown", "question", "answer", "actionItemText",
        ]
        let eventStart = try XCTUnwrap(core.range(of: "public struct DataEgressEvent"))
        let recorderStart = try XCTUnwrap(core.range(
            of: "public protocol DataEgressEventRecorder",
            range: eventStart.upperBound..<core.endIndex))
        let eventSource = core[eventStart.lowerBound..<recorderStart.lowerBound]
        for field in forbiddenReceiptFields {
            XCTAssertFalse(eventSource.contains("public let \(field)"), field)
        }
    }

    func testApplicationKitImportsStayInsideTheApprovedLayer() throws {
        let allowed = Set([
            "Foundation", "PortavozCore", "TranscriptionKit", "DiarizationKit",
            "IntelligenceKit", "StorageKit",
        ])
        let violations = try Self.imports(under: "Sources/ApplicationKit")
            .filter { !allowed.contains($0.module) }
            .map { "\($0.file): \($0.module)" }
            .sorted()
        let platformSymbols = try Self.sourceMatches(
            under: "Sources/ApplicationKit",
            pattern: #"\b(?:FileManager|UserDefaults|URLSession)\b"#)

        XCTAssertTrue(
            violations.isEmpty,
            "ApplicationKit imported presentation/platform/database APIs: \(violations)")
        XCTAssertTrue(
            platformSymbols.isEmpty,
            "ApplicationKit used a platform adapter directly: \(platformSymbols)")
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
        XCTAssertTrue(adapter.contains("services?.prepareRecordingEnginesInBackground()"))
        XCTAssertTrue(controller.contains("if commit.liveTranscriptionAvailable"))
        XCTAssertFalse(controller.contains("services.store.beginRecording"))
        XCTAssertFalse(controller.contains("MicrophoneSource("))
        XCTAssertFalse(controller.contains("RecordingSession("))
        XCTAssertFalse(controller.contains("makeSystemTapSource"))
    }

    func testRecordingLifecycleFailuresStayTypedUntilPresentation() throws {
        let core = try Self.contents(of: "Sources/PortavozCore/FailureCategory.swift")
        let start = try Self.contents(of: "Sources/ApplicationKit/StartRecording.swift")
        let stop = try Self.contents(of: "Sources/ApplicationKit/StopRecording.swift")
        let controller = try Self.contents(
            of: "Sources/portavoz-app/RecordingController.swift")

        for category in [
            "critical", "recoverable", "degradable", "external", "destructive",
        ] {
            XCTAssertTrue(core.contains("case \(category)"))
        }
        XCTAssertTrue(core.contains("public protocol CodedFailure"))
        XCTAssertTrue(start.contains("public enum StartRecordingFailure"))
        XCTAssertTrue(stop.contains("public enum StopRecordingFailure"))
        XCTAssertFalse(start.contains("error.localizedDescription"))
        XCTAssertFalse(stop.contains("error.localizedDescription"))
        XCTAssertFalse(start.contains("message: String"))
        XCTAssertFalse(stop.contains("processingFailed(message:"))
        XCTAssertTrue(controller.contains("presentStartFailure(failure)"))
        XCTAssertTrue(controller.contains("presentStopFailure(failure"))
        XCTAssertTrue(controller.contains("L10n.text("))
    }

    func testSpeechModelReadinessIsScopedToTheWorkflowCapability() throws {
        let services = try Self.contents(of: "Sources/portavoz-app/AppServices.swift")
        let readiness = services
        let refine = try Self.contents(
            of: "Sources/portavoz-app/AppServices+RefineMeeting.swift")
        let importAdapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+ImportMeeting.swift")
        let recovery = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureTranscriptionProcessor.swift")

        let refinePrepareStart = try XCTUnwrap(refine.range(of: "func prepare("))
        let refineTranscribeStart = try XCTUnwrap(refine.range(
            of: "func transcribe(", range: refinePrepareStart.upperBound..<refine.endIndex))
        let refinePreparation = refine[
            refinePrepareStart.lowerBound..<refineTranscribeStart.lowerBound]
        XCTAssertTrue(refinePreparation.contains("loadWhisperIfNeeded"))
        XCTAssertFalse(
            refinePreparation.contains("loadEnginesIfNeeded"),
            "Refine readiness requires Whisper only; diarization remains degradable")
        XCTAssertTrue(refine.contains("services.loadDiarizerIfNeeded()"))

        let transcriberStart = try XCTUnwrap(readiness.range(
            of: "func loadTranscriberIfNeeded()"))
        let diarizerStart = try XCTUnwrap(readiness.range(
            of: "func loadDiarizerIfNeeded()", range: transcriberStart.upperBound..<readiness.endIndex))
        let broadLoaderStart = try XCTUnwrap(readiness.range(
            of: "func loadEnginesIfNeeded()", range: diarizerStart.upperBound..<readiness.endIndex))
        let transcriberLoader = readiness[
            transcriberStart.lowerBound..<diarizerStart.lowerBound]
        let diarizerLoader = readiness[
            diarizerStart.lowerBound..<broadLoaderStart.lowerBound]
        XCTAssertTrue(transcriberLoader.contains("ParakeetEngine.loadRecommended"))
        XCTAssertFalse(transcriberLoader.contains("PyannoteDiarizer"))
        XCTAssertTrue(diarizerLoader.contains("PyannoteDiarizer.loadRecommended"))
        XCTAssertFalse(diarizerLoader.contains("ParakeetEngine"))
        XCTAssertTrue(services.contains("transcriberLoadTask"))
        XCTAssertTrue(services.contains("diarizerLoadTask"))

        XCTAssertTrue(importAdapter.contains("services.loadDiarizerIfNeeded()"))
        XCTAssertFalse(importAdapter.contains("services.loadEnginesIfNeeded()"))
        XCTAssertTrue(recovery.contains("services.loadTranscriberIfNeeded()"))
        XCTAssertFalse(recovery.contains("services.loadEnginesIfNeeded()"))
    }

    func testSettingsWhisperDownloadUsesAppScopedVerifiedPreparation() throws {
        let settings = try Self.contents(of: "Sources/portavoz-app/SettingsView.swift")
        let models = try Self.contents(
            of: "Sources/portavoz-app/AppServices+WhisperModels.swift")
        let engine = try Self.contents(of: "Sources/TranscriptionKit/WhisperEngine.swift")

        XCTAssertTrue(settings.contains("services.prepareWhisperVariant(variant.id)"))
        XCTAssertFalse(settings.contains("ModelStore()"))
        XCTAssertTrue(models.contains("whisperBackgroundPreparation"))
        XCTAssertTrue(models.contains("whisperPreparedModel = prepared"))
        XCTAssertTrue(models.contains("finishWhisperPreparation(active)"))
        XCTAssertTrue(engine.contains("public struct PreparedModel"))
        XCTAssertTrue(engine.contains("return try await loadPrepared(prepared)"))
    }

    func testAppLaunchRecoveryEntersThroughApplicationKitBeforeWorkerResume() throws {
        let coordinator = try Self.contents(
            of: "Sources/portavoz-app/RecordingRecoveryCoordinator.swift")
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+RecoverInterruptedMeetings.swift")
        let launch = try Self.contents(of: "Sources/portavoz-app/PortavozApp.swift")

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
            "appServices.configureInitialSummaryEngineIfNeeded"))
        XCTAssertLessThan(recovery.lowerBound, worker.lowerBound)
        XCTAssertLessThan(worker.lowerBound, recommendation.lowerBound)
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
        let adapter = try Self.contents(
            of: "Sources/portavoz-app/AppServices+Bundle.swift")

        XCTAssertTrue(view.contains("services.exportMeetingBundle"))
        XCTAssertFalse(view.contains("let bundle = MeetingBundle("))
        XCTAssertFalse(view.contains("MeetingBundle.AudioAttachment"))
        XCTAssertFalse(view.contains("Data(contentsOf:"))
        XCTAssertTrue(adapter.contains("exportMeetingBundleUseCase.execute"))
        XCTAssertTrue(adapter.contains("MeetingBundle("))
        XCTAssertTrue(adapter.contains("Task.detached(priority: .utility)"))
        XCTAssertFalse(adapter.contains("store.contextItems(for:"))
        XCTAssertFalse(adapter.contains("store.companionCards(for:"))
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

        XCTAssertTrue(model.contains("@MainActor\n@Observable\nfinal class LibraryModel"))
        XCTAssertTrue(model.contains("struct State"))
        XCTAssertTrue(model.contains("enum Action"))
        XCTAssertTrue(model.contains("enum Effect"))
        XCTAssertTrue(model.contains("private(set) var state = State()"))
        XCTAssertTrue(view.contains("model.send(.observeLibrary)"))
        XCTAssertTrue(view.contains("model.send(.observeSearch)"))
        XCTAssertTrue(content.contains("@State private var libraryModel: LibraryModel"))
        XCTAssertTrue(adapter.contains("defer { libraryVersion += 1 }"))
        XCTAssertTrue(adapter.contains("makeApplicationLibraryStream("))
        XCTAssertTrue(readModels.contains("public enum LibraryUpdate"))
        XCTAssertTrue(observation.contains("func observeLibraryMeetings()"))
        XCTAssertTrue(observation.contains("func observeLibraryOpenItems("))
        XCTAssertTrue(observation.contains("func observeLibraryTrash()"))
        XCTAssertTrue(observation.contains(
            "regions: [Table(\"meeting\"), Table(\"speaker\"), Table(\"segment\")]"))
        XCTAssertTrue(observation.contains(
            "regions: [Table(\"meeting\"), Table(\"summary\"), Table(\"actionItem\")]"))
        XCTAssertTrue(observation.contains("region: Table(\"meeting\")"))
        XCTAssertTrue(observation.contains("regions: [Table(\"meeting\"), Table(\"segment\")]"))
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
        let model = try Self.contents(of: "Sources/portavoz-app/MeetingDetailModel.swift")
        let adapter = try Self.contents(of: "Sources/portavoz-app/AppServices+MeetingDetail.swift")
        let view = try Self.contents(of: "Sources/portavoz-app/MeetingDetailView.swift")
        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+MeetingDetailObservation.swift")

        XCTAssertTrue(readModels.contains("struct MeetingReviewReadModel"))
        XCTAssertFalse(readModels.contains("import StorageKit"))
        XCTAssertFalse(readModels.contains("import GRDB"))
        XCTAssertTrue(model.contains("@Observable"))
        XCTAssertTrue(model.contains("MeetingReviewReadModel("))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewCore"))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewSummary"))
        XCTAssertTrue(adapter.contains("store.observeMeetingReviewCompanionCards"))
        XCTAssertTrue(view.contains("@State private var model: MeetingDetailModel"))
        XCTAssertTrue(view.contains(".task { await model.observe() }"))
        XCTAssertFalse(view.contains("ReloadID"))
        XCTAssertFalse(view.contains("services.store.detail"))
        XCTAssertFalse(view.contains("services.store.mostRecentSummary"))
        XCTAssertFalse(view.contains("services.store.companionCards(for:"))
        XCTAssertFalse(view.contains("libraryVersion: services.libraryVersion"))
        XCTAssertFalse(view.contains("services.store"))
        XCTAssertFalse(view.contains("services.libraryVersion"))
        XCTAssertFalse(view.contains("services.meetingLifecycle"))
        XCTAssertTrue(model.contains("enum Action"))
        XCTAssertTrue(model.contains("case renameMeeting"))
        XCTAssertTrue(model.contains("case renameSpeaker"))
        XCTAssertTrue(model.contains("case setActionItem"))
        XCTAssertTrue(model.contains("case removeCompanionCard"))
        XCTAssertTrue(model.contains("case deleteMeeting"))
        XCTAssertTrue(adapter.contains("renameMeetingDetailMeeting"))
        XCTAssertTrue(adapter.contains("renameMeetingDetailSpeaker"))
        XCTAssertTrue(adapter.contains("setMeetingDetailActionItem"))
        XCTAssertTrue(adapter.contains("deleteMeetingDetailCompanionCard"))
        XCTAssertTrue(adapter.contains("deleteMeetingDetail"))
        XCTAssertTrue(adapter.contains("requestMeetingDetailSearchReindex"))
        XCTAssertTrue(storage.contains(
            "regions: [Table(\"meeting\"), Table(\"speaker\"), Table(\"segment\")]"))
        XCTAssertTrue(storage.contains(
            "regions: [Table(\"meeting\"), Table(\"summary\"), Table(\"actionItem\")]"))
        XCTAssertTrue(storage.contains(
            "regions: [Table(\"meeting\"), Table(\"companionCard\")]"))
    }

    func testDistributionNotarizesTheExtractedAppBeforeTheDMG() throws {
        let builder = try Self.contents(of: "scripts/make-dmg.sh")
        let verifier = try Self.contents(of: "scripts/verify-distribution.sh")

        let archive = try XCTUnwrap(builder.range(of: "ditto -c -k --sequesterRsrc"))
        let appSubmission = try XCTUnwrap(builder.range(
            of: "notarytool submit \"$APP_ARCHIVE\"", range: archive.upperBound..<builder.endIndex))
        let appStaple = try XCTUnwrap(builder.range(
            of: "stapler staple dist/Portavoz.app",
            range: appSubmission.upperBound..<builder.endIndex))
        let package = try XCTUnwrap(builder.range(
            of: "cp -a dist/Portavoz.app \"$STAGE/\"",
            range: appStaple.upperBound..<builder.endIndex))
        let imageSubmission = try XCTUnwrap(builder.range(
            of: "notarytool submit \"$DMG\"", range: package.upperBound..<builder.endIndex))
        let imageStaple = try XCTUnwrap(builder.range(
            of: "stapler staple \"$DMG\"",
            range: imageSubmission.upperBound..<builder.endIndex))
        XCTAssertNotNil(builder.range(
            of: "scripts/verify-distribution.sh \"$DMG\"",
            range: imageStaple.upperBound..<builder.endIndex))

        XCTAssertTrue(verifier.contains("cp -a \"$MOUNT/Portavoz.app\" \"$APP_COPY\""))
        XCTAssertTrue(verifier.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(verifier.contains("stapler validate \"$APP_COPY\""))
        XCTAssertTrue(verifier.contains("spctl -a -vvv -t exec \"$APP_COPY\""))
    }

    func testSupportDiagnosticsRemainRedactedLocalEvidence() throws {
        let exporter = try Self.contents(
            of: "Sources/ApplicationKit/ExportSupportDiagnostics.swift")
        for forbidden in [
            "title:", "segments:", "transcriptText", "summaryMarkdown", "actionItem",
            "companionCard", "configJSON", "metricsJSON", "errorMessage",
            "audioDirectory", "destinationURL", "apiKey"
        ] {
            XCTAssertFalse(exporter.contains(forbidden), "Exporter contains \(forbidden)")
        }
        XCTAssertTrue(exporter.contains("meeting.referenceDigest.prefix(12)"))
        XCTAssertTrue(exporter.contains("job.inputFingerprintDigest"))
        XCTAssertTrue(exporter.contains("run.inputFingerprintDigest"))

        let storage = try Self.contents(
            of: "Sources/StorageKit/MeetingStore+SupportDiagnostics.swift")
        XCTAssertTrue(storage.contains("supportDigest(meetingID.rawValue.uuidString)"))
        XCTAssertTrue(storage.contains("supportDigest(job.inputFingerprint)"))
        XCTAssertTrue(storage.contains("supportDigest(run.inputFingerprint)"))
        XCTAssertFalse(storage.contains("errorMessage:"))
        XCTAssertFalse(storage.contains("configJSON:"))
        XCTAssertFalse(storage.contains("metricsJSON:"))

        let settings = try Self.contents(
            of: "Sources/portavoz-app/SupportDiagnosticsSection.swift")
        XCTAssertTrue(settings.contains("NSSavePanel"))
        XCTAssertFalse(settings.contains("URLSession"))
        XCTAssertFalse(settings.contains("DataEgressGateway"))

        let worker = try Self.contents(
            of: "Sources/portavoz-app/PostCaptureProcessingCoordinator.swift")
        guard let intervalStart = worker.range(
            of: "let interval = signposter.beginInterval"),
            let heartbeatStart = worker.range(
                of: "private static func heartbeatTask",
                range: intervalStart.upperBound..<worker.endIndex)
        else {
            return XCTFail("Durable-processing signpost boundary is missing")
        }
        let signpostedExecution = worker[intervalStart.lowerBound..<heartbeatStart.lowerBound]
        XCTAssertTrue(signpostedExecution.contains("job.kind.rawValue"))
        XCTAssertTrue(signpostedExecution.contains("job.attempt"))
        XCTAssertFalse(signpostedExecution.contains("job.id"))
        XCTAssertFalse(signpostedExecution.contains("job.meetingID"))
        XCTAssertFalse(signpostedExecution.contains("localizedDescription"))
    }

    func testApplicationUseCaseProvidesOneAsyncBoundary() async throws {
        let result = try await CharacterCount().execute("Portavoz")
        let callableResult = try await CharacterCount()("local first")

        XCTAssertEqual(result, 8)
        XCTAssertEqual(callableResult, 11)
    }
}

private extension ArchitectureDependencyTests {
    struct SourceImport {
        let file: String
        let module: String
    }

    struct CharacterCount: ApplicationUseCase {
        func execute(_ request: String) async throws -> Int { request.count }
    }

    static func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    static func imports(under relativeDirectory: String) throws -> [SourceImport] {
        let root = repoRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let files = enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        let regex = try NSRegularExpression(
            pattern: #"(?m)^\s*(?:@preconcurrency\s+)?import\s+([A-Za-z0-9_]+)"#)
        return try files.flatMap { file -> [SourceImport] in
            let source = try String(
                contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            return regex.matches(in: source, range: range).compactMap { match in
                guard let moduleRange = Range(match.range(at: 1), in: source) else { return nil }
                return SourceImport(file: file, module: String(source[moduleRange]))
            }
        }
    }

    static func sourceMatches(
        under relativeDirectory: String,
        pattern: String
    ) throws -> [String] {
        let root = repoRoot.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let regex = try NSRegularExpression(pattern: pattern)
        return try enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .sorted()
            .compactMap { file in
                let source = try String(
                    contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                return regex.firstMatch(in: source, range: range) == nil ? nil : file
            }
    }
}

private struct TargetDeclaration {
    let name: String
    let dependencies: Set<String>
}

private enum TargetManifestParser {
    static func declarations(in manifest: String) throws -> [String: TargetDeclaration] {
        let regex = try NSRegularExpression(
            pattern: #"\.(?:target|executableTarget|testTarget)\s*\("#)
        let fullRange = NSRange(manifest.startIndex..., in: manifest)
        return try regex.matches(in: manifest, range: fullRange).reduce(into: [:]) {
            result, match in
            guard let markerRange = Range(match.range, in: manifest),
                let open = manifest[markerRange].lastIndex(of: "(")
            else { return }
            let openIndex = manifest.index(markerRange.lowerBound, offsetBy:
                manifest[markerRange].distance(from: manifest[markerRange].startIndex, to: open))
            guard let closeIndex = closingDelimiter(
                in: manifest, from: openIndex, open: "(", close: ")")
            else { throw ParseError.unbalancedTarget }
            let block = String(manifest[markerRange.lowerBound...closeIndex])
            guard let declaration = try declaration(from: block) else { return }
            result[declaration.name] = declaration
        }
    }

    private static func declaration(from block: String) throws -> TargetDeclaration? {
        let nameRegex = try NSRegularExpression(pattern: #"\bname\s*:\s*\"([^\"]+)\""#)
        let fullRange = NSRange(block.startIndex..., in: block)
        guard let match = nameRegex.firstMatch(in: block, range: fullRange),
            let nameRange = Range(match.range(at: 1), in: block)
        else { return nil }
        let name = String(block[nameRange])
        guard let labelRange = block.range(of: "dependencies:") else {
            return TargetDeclaration(name: name, dependencies: [])
        }
        guard let open = block[labelRange.upperBound...].firstIndex(of: "[") else {
            throw ParseError.missingDependencyArray
        }
        guard let close = closingDelimiter(in: block, from: open, open: "[", close: "]") else {
            throw ParseError.unbalancedDependencies
        }
        let dependencySource = String(block[open...close])
        let stringRegex = try NSRegularExpression(pattern: #"\"([^\"]+)\""#)
        let dependencyRange = NSRange(dependencySource.startIndex..., in: dependencySource)
        let dependencies = Set(stringRegex.matches(
            in: dependencySource, range: dependencyRange).compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: dependencySource) else { return nil }
                return String(dependencySource[range])
            })
        return TargetDeclaration(name: name, dependencies: dependencies)
    }

    private static func closingDelimiter(
        in source: String,
        from start: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        var depth = 0
        var state = LexicalState.code
        var index = start
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let nextCharacter = next < source.endIndex ? source[next] : nil
            switch state {
            case .code:
                if character == "/", nextCharacter == "/" { state = .lineComment }
                else if character == "/", nextCharacter == "*" { state = .blockComment }
                else if character == "\"" { state = .string }
                else if character == open { depth += 1 }
                else if character == close {
                    depth -= 1
                    if depth == 0 { return index }
                }
            case .string:
                if character == "\\" { index = next }
                else if character == "\"" { state = .code }
            case .lineComment:
                if character == "\n" { state = .code }
            case .blockComment:
                if character == "*", nextCharacter == "/" {
                    state = .code
                    index = next
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private enum LexicalState {
        case code
        case string
        case lineComment
        case blockComment
    }

    private enum ParseError: Error {
        case unbalancedTarget
        case missingDependencyArray
        case unbalancedDependencies
    }
}
