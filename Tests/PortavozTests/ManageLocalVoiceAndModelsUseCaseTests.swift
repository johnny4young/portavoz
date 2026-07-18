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

    func testRecordedVoiceEnrollmentOwnsCaptureExtractionPersistenceAndProgress() async throws {
        let identity = VoiceIdentityStoreFake()
        let capture = VoiceSampleCaptureFake(sample: LocalVoiceSample(
            samples: [0.1, 0.2, 0.3, 0.4],
            sampleRate: 1))
        let extractor = VoiceSampleExtractorFake()
        let progress = VoiceEnrollmentProgressRecorder()
        let useCase = ManageLocalVoiceIdentity(
            sampleCapture: capture,
            identities: identity,
            sampleExtractor: extractor)

        guard case .enrolled(let voiceprint) = try await useCase.execute(
            .recordAndEnroll(seconds: 12, mode: .echoCancelled) { event in
                await progress.append(event)
            }) else { return XCTFail("expected enrolled identity") }

        XCTAssertEqual(voiceprint.embedding, [0.5, 0.5])
        let requests = await capture.requests
        let extracted = await extractor.samples
        let stored = await identity.stored
        let events = await progress.events
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.seconds, 12)
        XCTAssertEqual(requests.first?.mode, .echoCancelled)
        XCTAssertEqual(extracted.first?.sampleRate, 1)
        XCTAssertEqual(stored?.embedding, [0.5, 0.5])
        XCTAssertEqual(events, [
            .capturing(secondsRemaining: 12),
            .capturing(secondsRemaining: 6),
            .extracting,
            .persisting
        ])
    }

    func testCapturedSampleEnrollmentBypassesMicrophone() async throws {
        let capture = VoiceSampleCaptureFake(sample: LocalVoiceSample(
            samples: [9, 9, 9, 9],
            sampleRate: 1))
        let extractor = VoiceSampleExtractorFake()
        let useCase = ManageLocalVoiceIdentity(
            sampleCapture: capture,
            identities: VoiceIdentityStoreFake(),
            sampleExtractor: extractor)

        _ = try await useCase.execute(.enrollSample(LocalVoiceSample(
            samples: [0.25, 0.25, 0.25, 0.25],
            sampleRate: 1)))

        let requests = await capture.requests
        let extracted = await extractor.samples
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(extracted.map(\.sampleRate), [1])
    }

    func testRecordedEnrollmentRejectsInvalidDurationBeforeCapture() async {
        let capture = VoiceSampleCaptureFake(sample: LocalVoiceSample(
            samples: [0.1, 0.1, 0.1, 0.1],
            sampleRate: 1))
        let useCase = ManageLocalVoiceIdentity(
            sampleCapture: capture,
            identities: VoiceIdentityStoreFake(),
            sampleExtractor: VoiceSampleExtractorFake())

        do {
            _ = try await useCase.execute(.recordAndEnroll(
                seconds: 0,
                mode: .raw))
            XCTFail("expected invalid duration")
        } catch let error as ManageLocalVoiceIdentityError {
            XCTAssertEqual(error, .invalidCaptureDuration)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let requests = await capture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSampleEnrollmentRejectsInvalidAudioBeforeExtractionOrWrite() async {
        let identity = VoiceIdentityStoreFake()
        let extractor = VoiceSampleExtractorFake()
        let useCase = ManageLocalVoiceIdentity(
            sampleCapture: VoiceSampleCaptureFake(sample: LocalVoiceSample(
                samples: [0.1, 0.1, 0.1, 0.1],
                sampleRate: 1)),
            identities: identity,
            sampleExtractor: extractor)

        let invalidSamples = [
            LocalVoiceSample(samples: [], sampleRate: 16_000),
            LocalVoiceSample(samples: [0.1, 0.2], sampleRate: 1),
            LocalVoiceSample(samples: [0.1, .nan, 0.2, 0.3], sampleRate: 1),
            LocalVoiceSample(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: .infinity)
        ]
        for sample in invalidSamples {
            do {
                _ = try await useCase.execute(.enrollSample(sample))
                XCTFail("expected invalid sample")
            } catch let error as ManageLocalVoiceIdentityError {
                XCTAssertEqual(error, .invalidSample)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
        let extracted = await extractor.samples
        let stored = await identity.stored
        XCTAssertTrue(extracted.isEmpty)
        XCTAssertNil(stored)
    }

    func testCaptureFailureDoesNotExtractOrPersistIdentity() async {
        let identity = VoiceIdentityStoreFake()
        let extractor = VoiceSampleExtractorFake()
        let useCase = ManageLocalVoiceIdentity(
            sampleCapture: VoiceSampleCaptureFake(
                sample: LocalVoiceSample(samples: [0.1, 0.1, 0.1, 0.1], sampleRate: 1),
                failure: .capture),
            identities: identity,
            sampleExtractor: extractor)

        do {
            _ = try await useCase.execute(.recordAndEnroll(seconds: 12, mode: .raw))
            XCTFail("expected capture failure")
        } catch let error as VoiceEnrollmentFailure {
            XCTAssertEqual(error, .capture)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let extracted = await extractor.samples
        let stored = await identity.stored
        XCTAssertTrue(extracted.isEmpty)
        XCTAssertNil(stored)
    }

    func testExtractionFailureDoesNotPersistIdentity() async {
        let identity = VoiceIdentityStoreFake()
        let useCase = ManageLocalVoiceIdentity(
            sampleCapture: VoiceSampleCaptureFake(sample: LocalVoiceSample(
                samples: [0.1, 0.1, 0.1, 0.1],
                sampleRate: 1)),
            identities: identity,
            sampleExtractor: VoiceSampleExtractorFake(failure: .extract))

        do {
            _ = try await useCase.execute(.recordAndEnroll(seconds: 12, mode: .raw))
            XCTFail("expected extraction failure")
        } catch let error as VoiceEnrollmentFailure {
            XCTAssertEqual(error, .extract)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let stored = await identity.stored
        XCTAssertNil(stored)
    }

    func testDeletePropagatesStoreFailureWithoutInventingSuccess() async {
        let existing = Voiceprint(
            embedding: [0.1, 0.9],
            createdAt: Date(timeIntervalSince1970: 42))
        let identity = VoiceIdentityStoreFake(stored: existing, deleteFailure: .store)
        let useCase = ManageLocalVoiceIdentity(
            sampleCapture: VoiceSampleCaptureFake(sample: LocalVoiceSample(
                samples: [0.1, 0.1, 0.1, 0.1],
                sampleRate: 1)),
            identities: identity,
            sampleExtractor: VoiceSampleExtractorFake())

        do {
            _ = try await useCase.execute(.delete)
            XCTFail("expected store failure")
        } catch let error as VoiceEnrollmentFailure {
            XCTAssertEqual(error, .store)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let stored = await identity.stored
        XCTAssertEqual(stored?.embedding, existing.embedding)
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
    private let deleteFailure: VoiceEnrollmentFailure?

    init(
        stored: Voiceprint? = nil,
        deleteFailure: VoiceEnrollmentFailure? = nil
    ) {
        self.stored = stored
        self.deleteFailure = deleteFailure
    }

    func loadVoiceIdentity() -> Voiceprint? { stored }
    func saveVoiceIdentity(_ voiceprint: Voiceprint) { stored = voiceprint }
    func deleteVoiceIdentity() throws {
        if let deleteFailure { throw deleteFailure }
        stored = nil
    }
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

private actor VoiceSampleCaptureFake: LocalVoiceSampleCapturing {
    struct Request: Sendable {
        let seconds: Int
        let mode: LocalVoiceCaptureMode
    }

    let sample: LocalVoiceSample
    let failure: VoiceEnrollmentFailure?
    private(set) var requests: [Request] = []

    init(sample: LocalVoiceSample, failure: VoiceEnrollmentFailure? = nil) {
        self.sample = sample
        self.failure = failure
    }

    func captureVoiceSample(
        seconds: Int,
        mode: LocalVoiceCaptureMode,
        progress: @escaping LocalVoiceEnrollmentProgressHandler
    ) async throws -> LocalVoiceSample {
        requests.append(Request(seconds: seconds, mode: mode))
        if let failure { throw failure }
        await progress(.capturing(secondsRemaining: seconds / 2))
        return sample
    }
}

private actor VoiceSampleExtractorFake: LocalVoiceSampleIdentityExtracting {
    let failure: VoiceEnrollmentFailure?
    private(set) var samples: [LocalVoiceSample] = []

    init(failure: VoiceEnrollmentFailure? = nil) {
        self.failure = failure
    }

    func extractVoiceIdentity(from sample: LocalVoiceSample) throws -> Voiceprint {
        samples.append(sample)
        if let failure { throw failure }
        return Voiceprint(
            embedding: [0.5, 0.5],
            createdAt: Date(timeIntervalSince1970: 60))
    }
}

private enum VoiceEnrollmentFailure: Error, Equatable {
    case capture
    case extract
    case store
}

private actor VoiceEnrollmentProgressRecorder {
    private(set) var events: [LocalVoiceEnrollmentProgress] = []
    func append(_ event: LocalVoiceEnrollmentProgress) { events.append(event) }
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
