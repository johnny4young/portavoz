import ApplicationKit
import DiarizationKit
import Foundation
import XCTest

final class ManageLocalVoiceAndModelsUseCaseTests: XCTestCase {
    func testVoiceEnrollmentAdmitsFileExtractsAndPersistsEmbedding() async throws {
        let identity = VoiceIdentityStoreFake()
        let extractor = VoiceIdentityExtractorFake()
        let useCase = ManageLocalVoiceIdentity(
            files: VoiceInputFilesFake(readable: true),
            identities: identity,
            extractor: extractor)
        let url = URL(fileURLWithPath: "/voice.wav")

        guard case .enrolled(let enrolled) = try await useCase.execute(
            .enroll(fileURL: url))
        else { return XCTFail("expected enrolled identity") }

        XCTAssertEqual(enrolled.embedding, [0.25, 0.75])
        let stored = await identity.stored
        let extractedURLs = await extractor.urls
        XCTAssertEqual(stored?.embedding, enrolled.embedding)
        XCTAssertEqual(extractedURLs, [url])
    }

    func testVoiceStatusAndDeleteNeverReadSourceAudioOrLoadModels() async throws {
        let existing = Voiceprint(
            embedding: [1, 0],
            createdAt: Date(timeIntervalSince1970: 42))
        let identity = VoiceIdentityStoreFake(stored: existing)
        let files = VoiceInputFilesFake(readable: false)
        let extractor = VoiceIdentityExtractorFake()
        let useCase = ManageLocalVoiceIdentity(
            files: files,
            identities: identity,
            extractor: extractor)

        guard case .status(let status) = try await useCase.execute(.status)
        else { return XCTFail("expected status") }
        XCTAssertEqual(status?.embedding, existing.embedding)
        _ = try await useCase.execute(.delete)

        let deleted = await identity.stored
        let fileCallCount = await files.callCount
        let extractedURLs = await extractor.urls
        XCTAssertNil(deleted)
        XCTAssertEqual(fileCallCount, 0)
        XCTAssertTrue(extractedURLs.isEmpty)
    }

    func testVoiceEnrollmentRejectsMissingFileBeforeExtraction() async {
        let extractor = VoiceIdentityExtractorFake()
        let useCase = ManageLocalVoiceIdentity(
            files: VoiceInputFilesFake(readable: false),
            identities: VoiceIdentityStoreFake(),
            extractor: extractor)

        do {
            _ = try await useCase.execute(.enroll(
                fileURL: URL(fileURLWithPath: "/missing.wav")))
            XCTFail("expected missing input")
        } catch let error as AnalyzeAudioFileError {
            XCTAssertEqual(error, .inputFileNotFound("/missing.wav"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let extractedURLs = await extractor.urls
        XCTAssertTrue(extractedURLs.isEmpty)
    }

    func testModelInspectionPreservesCatalogOrderAndVerificationEvidence() async throws {
        let models = LocalModelsFake()
        let useCase = ManageLocalModels(models: models)

        guard case .inspected(let reports) = try await useCase.execute(.init(action: .verify))
        else { return XCTFail("expected reports") }

        XCTAssertEqual(reports.map(\.descriptor.id), ["speech", "speakers"])
        XCTAssertEqual(reports.map(\.verifiedArtifactCount), [2, 0])
        let verifiedIDs = await models.verifiedIDs
        XCTAssertEqual(verifiedIDs, ["speech", "speakers"])
    }

    func testModelDownloadIsSequentialAndPublishesInstalledProgress() async throws {
        let models = LocalModelsFake()
        let progress = ModelProgressRecorder()
        let useCase = ManageLocalModels(models: models)

        guard case .installed(let installed) = try await useCase.execute(.init(
            action: .download
        ) { event in
            await progress.append(event)
        }) else { return XCTFail("expected installed models") }

        XCTAssertEqual(installed.map(\.id), ["speech", "speakers"])
        let installedIDs = await models.installedIDs
        let progressEvents = await progress.events
        XCTAssertEqual(installedIDs, ["speech", "speakers"])
        XCTAssertEqual(progressEvents, [
            .installedModel(name: "Speech"),
            .installedModel(name: "Speakers"),
        ])
    }
}

private actor VoiceInputFilesFake: ApplicationInputFileAccess {
    let readable: Bool
    private(set) var callCount = 0

    init(readable: Bool) { self.readable = readable }

    func isReadableFile(_ url: URL) -> Bool {
        _ = url
        callCount += 1
        return readable
    }
}

private actor VoiceIdentityStoreFake: LocalVoiceIdentityStoring {
    private(set) var stored: Voiceprint?

    init(stored: Voiceprint? = nil) { self.stored = stored }

    func loadVoiceIdentity() -> Voiceprint? { stored }
    func saveVoiceIdentity(_ voiceprint: Voiceprint) { stored = voiceprint }
    func deleteVoiceIdentity() { stored = nil }
}

private actor VoiceIdentityExtractorFake: LocalVoiceIdentityExtracting {
    private(set) var urls: [URL] = []

    func extractVoiceIdentity(from fileURL: URL) -> Voiceprint {
        urls.append(fileURL)
        return Voiceprint(
            embedding: [0.25, 0.75],
            createdAt: Date(timeIntervalSince1970: 50))
    }
}

private actor LocalModelsFake: LocalModelLifecycleManaging {
    nonisolated let catalog = [
        LocalModelDescriptor(
            id: "speech",
            displayName: "Speech",
            revision: "one",
            totalSizeMegabytes: 10,
            artifactCount: 2),
        LocalModelDescriptor(
            id: "speakers",
            displayName: "Speakers",
            revision: "two",
            totalSizeMegabytes: 20,
            artifactCount: 2),
    ]
    private(set) var verifiedIDs: [String] = []
    private(set) var installedIDs: [String] = []

    func verification(for descriptor: LocalModelDescriptor) -> LocalModelVerification {
        verifiedIDs.append(descriptor.id)
        let complete = descriptor.id == "speech"
        return LocalModelVerification(
            descriptor: descriptor,
            directory: URL(fileURLWithPath: "/models/\(descriptor.id)"),
            missing: complete ? [] : ["one", "two"],
            corrupted: [])
    }

    func installAndProveLoadable(
        _ descriptor: LocalModelDescriptor,
        progress: @escaping AudioAnalysisProgressHandler
    ) async throws {
        _ = progress
        installedIDs.append(descriptor.id)
    }
}

private actor ModelProgressRecorder {
    private(set) var events: [AudioAnalysisProgress] = []
    func append(_ event: AudioAnalysisProgress) { events.append(event) }
}
