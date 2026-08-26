import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit
import XCTest
@testable import portavoz_app

final class ProductionSyncQualificationTests: XCTestCase {
    func testConfigurationRequiresDisposableShellAndExactArguments() throws {
        let arguments = validArguments()
        let configuration = try XCTUnwrap(
            ProductionSyncQualificationConfiguration.requested(
                arguments: arguments,
                environment: validEnvironment()))

        XCTAssertEqual(configuration.role, "a")
        XCTAssertEqual(configuration.stage, "prepare-existing")
        XCTAssertEqual(configuration.timeoutSeconds, 300)
        XCTAssertEqual(configuration.manifestURL.lastPathComponent, "run.json")

        XCTAssertThrowsError(
            try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments.filter { $0 != "-use-temp-store" }))
        XCTAssertThrowsError(
            try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments + ["--production-sync-role", "b"]))
        XCTAssertThrowsError(
            try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments + ["-use-temp-store"]))
        XCTAssertThrowsError(
            try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments + ["-seed-demo"]))
        XCTAssertThrowsError(
            try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments + ["-reset-app-language"]))
        XCTAssertThrowsError(
            try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments.map {
                    $0 == "prepare-existing" ? "../../private" : $0
                }))
        XCTAssertThrowsError(
            try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments,
                environment: validEnvironment().merging([
                    "PORTAVOZ_RESET_APP_LANGUAGE": "1"
                ]) { _, new in new }))
        XCTAssertThrowsError(
            try ProductionSyncQualificationConfiguration.requested(
                arguments: arguments,
                environment: [
                    "PORTAVOZ_UI_TEST_DATABASE_PATH":
                        "/private/tmp/portavoz-sync/app-shell/b/\(UUID()).sqlite"
                ]))
    }

    func testTrackedContractIsFiniteBilingualAndMatchesPublicCorpus() throws {
        let data = try Data(contentsOf: contractURL())
        let contract = try JSONDecoder().decode(
            ProductionSyncQualificationContract.self,
            from: data)

        try contract.validate()
        XCTAssertEqual(contract.roles, ["a", "b"])
        XCTAssertEqual(contract.corpus.languages, ["en", "es"])
        XCTAssertEqual(
            contract.corpus.sha256,
            ProductionSyncQualificationCorpus.sha256)
        XCTAssertEqual(
            ProductionSyncQualificationDigest.hex(data),
            ProductionSyncQualificationContract.frozenSHA256)
        XCTAssertEqual(contract.stages.count, 27)
        XCTAssertEqual(
            try contract.stage(role: "a", id: "retry-relaunch").roleSequence,
            8)
        XCTAssertEqual(
            try contract.stage(role: "b", id: "await-push").roleSequence,
            6)
        XCTAssertEqual(
            try contract.stage(role: "b", id: "await-push").requires,
            ["b.receive-retry"])
        XCTAssertEqual(
            try contract.stage(role: "a", id: "push-source").requiresLiveStage,
            "b.await-push")
        XCTAssertEqual(
            try contract.stage(role: "a", id: "offline-attempt").externalAction,
            "disable-network")
        XCTAssertEqual(
            try contract.stage(role: "a", id: "observe-account-switch").externalAction,
            "switch-to-secondary-account")
    }

    @MainActor
    func testQualificationLaunchDoesNotConstructOrdinaryAppServices() {
        var constructedServices = false

        let model = AppLaunchModel(
            arguments: validArguments(),
            environment: [:],
            servicesFactory: {
                constructedServices = true
                throw ProductionSyncQualificationError.invalidLifecycle
            })

        XCTAssertFalse(constructedServices)
        XCTAssertNil(model.services)
        guard case .opening = model.phase else {
            return XCTFail("Qualification must retain only the inert app shell")
        }
    }

    func testPublicCorpusRoundTripsThroughPortableSyncAndTombstone() async throws {
        let manifest = try makeManifest()
        let source = try MeetingStore.inMemory()
        let destination = try MeetingStore.inMemory()
        let sourceDevice = try XCTUnwrap(UUID(
            uuidString: "80000000-0000-4000-8000-000000000001"))

        try await ProductionSyncQualificationCorpus.seed(
            manifest: manifest,
            store: source)
        _ = try await source.markMeetingsForInitialSync(after: nil, limit: 10)
        try await replayNewest(
            from: source,
            to: destination,
            sourceDevice: sourceDevice)
        try await assertSeedCorpus(
            manifest: manifest,
            store: destination)

        try await transition(
            to: .editA,
            from: .seed,
            source: source,
            destination: destination,
            sourceDevice: sourceDevice,
            manifest: manifest)

        let remainingTransitions: [(
            ProductionSyncQualificationCorpusState,
            ProductionSyncQualificationCorpusState
        )] = [
            (.editB, .editA),
            (.retry, .editB),
            (.push, .retry)
        ]
        for transition in remainingTransitions {
            try await self.transition(
                to: transition.0,
                from: transition.1,
                source: source,
                destination: destination,
                sourceDevice: sourceDevice,
                manifest: manifest)
        }

        try await ProductionSyncQualificationCorpus.delete(
            manifest: manifest,
            store: source)
        try await replayNewest(
            from: source,
            to: destination,
            sourceDevice: sourceDevice)
        let deleted = try await ProductionSyncQualificationCorpus.facts(
            expecting: .deleted,
            manifest: manifest,
            store: destination)
        XCTAssertEqual(deleted.liveMeetings, 0)
        XCTAssertEqual(deleted.deletedMeetings, 1)
    }

    func testExistingCorpusSeedIsAcknowledgedUntilExplicitAdmission() async throws {
        let store = try MeetingStore.inMemory()
        let manifest = try makeManifest()

        try await ProductionSyncQualificationCorpus.seed(
            manifest: manifest,
            store: store)

        let initiallyPending = try await store.pendingMeetingSyncChanges()
        XCTAssertTrue(initiallyPending.isEmpty)
        let batch = try await store.markMeetingsForInitialSync(
            after: nil,
            limit: 10)
        XCTAssertEqual(batch.processedCount, 1)
        let admittedChanges = try await store.pendingMeetingSyncChanges()
        XCTAssertEqual(admittedChanges.count, 1)
    }

    func testRunScopedDeviceIdentityIsStableAndRoleSeparated() throws {
        let runID = try XCTUnwrap(UUID(
            uuidString: "80000000-0000-4000-8000-000000000099"))

        let first = ProductionSyncQualificationIdentity.deviceID(
            runID: runID,
            role: "a")
        let repeated = ProductionSyncQualificationIdentity.deviceID(
            runID: runID,
            role: "a")
        let otherRole = ProductionSyncQualificationIdentity.deviceID(
            runID: runID,
            role: "b")

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, otherRole)
        XCTAssertEqual(first.uuidString.split(separator: "-")[2].first, "4")
    }

    func testLifecycleReceiptUsesClosedContentFreeVocabulary() {
        let status = CloudMeetingSyncStatus(
            phase: .retrying,
            accountStatus: .temporarilyUnavailable,
            isEnabled: true,
            initialSeedState: .requested,
            progress: CloudMeetingSyncProgress(
                pendingLocalChanges: 1,
                queuedTransfers: 2,
                retryingTransfers: 1,
                failedTransfers: 0),
            nextRetryAt: nil,
            failure: .synchronizationFailed)

        let evidence = ProductionSyncQualificationReceipt.Lifecycle(
            status: status)

        XCTAssertEqual(evidence.phase, "retrying")
        XCTAssertEqual(evidence.accountStatus, "temporarilyUnavailable")
        XCTAssertEqual(evidence.initialSeedState, "requested")
        XCTAssertEqual(evidence.pendingLocalChanges, 1)
        XCTAssertEqual(evidence.queuedTransfers, 2)
        XCTAssertEqual(evidence.retryingTransfers, 1)
        XCTAssertEqual(evidence.failedTransfers, 0)
    }

    func testReceiptUUIDStringsUseTheOwnersLowercaseWireFormat() throws {
        let identifier = try XCTUnwrap(UUID(
            uuidString: "8ABCDEF0-1234-4ABC-8DEF-123456789ABC"))

        XCTAssertEqual(
            ProductionSyncQualificationDigest.uuid(identifier),
            "8abcdef0-1234-4abc-8def-123456789abc")
    }

    func testScratchTreeRejectsSymbolicLinksBeforeOpeningState() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "portavoz-production-sync-\(UUID())",
            isDirectory: true)
        let outside = manager.temporaryDirectory.appendingPathComponent(
            "portavoz-production-sync-outside-\(UUID())",
            isDirectory: true)
        defer {
            try? manager.removeItem(at: root)
            try? manager.removeItem(at: outside)
        }
        try manager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let link = root.appendingPathComponent("payloads")
        try manager.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(
            try ProductionSyncQualificationFile.requireSafeScratchTree(root))
        XCTAssertThrowsError(
            try ProductionSyncQualificationFile.requireRegularFileOrAbsent(link))
    }

    private func replayNewest(
        from source: MeetingStore,
        to destination: MeetingStore,
        sourceDevice: UUID
    ) async throws {
        let changes = try await source.pendingMeetingSyncChanges()
        let change = try XCTUnwrap(changes.first)
        let envelope = try await source.meetingSyncEnvelope(
            for: change,
            sourceDeviceID: sourceDevice)
        let result = try await destination.applyRemoteMeetingSyncEnvelope(
            envelope)
        XCTAssertEqual(result, .applied)
        try await source.acknowledgeMeetingSync(change)
    }

    private func assertSeedCorpus(
        manifest: ProductionSyncQualificationManifest,
        store: MeetingStore
    ) async throws {
        let storedSeed = try await store.detail(
            MeetingID(rawValue: manifest.corpus.meetingID))
        let seededDetail = try XCTUnwrap(storedSeed)
        XCTAssertEqual(
            seededDetail.meeting.title,
            "Portavoz public sync qualification")
        XCTAssertEqual(
            seededDetail.meeting.startedAt,
            Date(timeIntervalSince1970: 1_768_478_400))
        XCTAssertEqual(
            seededDetail.meeting.endedAt,
            Date(timeIntervalSince1970: 1_768_479_000))
        XCTAssertNil(seededDetail.meeting.language)
        XCTAssertNil(seededDetail.meeting.audioDirectory)
        XCTAssertEqual(seededDetail.meeting.retention, .keep)
        XCTAssertEqual(seededDetail.meeting.visibility, "private")
        XCTAssertEqual(seededDetail.meeting.lifecycleState, .ready)
        XCTAssertEqual(seededDetail.meeting.transcriptRevision, 0)
        XCTAssertNil(seededDetail.meeting.lastProcessingError)
        XCTAssertTrue(seededDetail.summaries.isEmpty)
        _ = try await ProductionSyncQualificationCorpus.facts(
            expecting: .seed,
            manifest: manifest,
            store: store)
    }

    private func transition(
        to state: ProductionSyncQualificationCorpusState,
        from priorState: ProductionSyncQualificationCorpusState,
        source: MeetingStore,
        destination: MeetingStore,
        sourceDevice: UUID,
        manifest: ProductionSyncQualificationManifest
    ) async throws {
        try await ProductionSyncQualificationCorpus.update(
            to: state,
            from: priorState,
            manifest: manifest,
            store: source)
        try await replayNewest(
            from: source,
            to: destination,
            sourceDevice: sourceDevice)
        _ = try await ProductionSyncQualificationCorpus.facts(
            expecting: state,
            manifest: manifest,
            store: destination)
    }

    private func validArguments() -> [String] {
        [
            "/private/tmp/Portavoz Sync Qualification.app/Contents/MacOS/portavoz-app",
            "-NSTreatUnknownArgumentsAsOpen",
            "NO",
            "-ApplePersistenceIgnoreState",
            "YES",
            "-use-temp-store",
            "--production-sync-qualification",
            "--production-sync-manifest",
            "/private/tmp/portavoz-sync/run.json",
            "--production-sync-workspace",
            "/private/tmp/portavoz-sync",
            "--production-sync-role",
            "a",
            "--production-sync-stage",
            "prepare-existing",
            "--production-sync-timeout-seconds",
            "300"
        ]
    }

    private func validEnvironment() -> [String: String] {
        [
            "PORTAVOZ_UI_TEST_DATABASE_PATH":
                "/private/tmp/portavoz-sync/app-shell/a/\(UUID()).sqlite"
        ]
    }

    private func makeManifest() throws -> ProductionSyncQualificationManifest {
        try ProductionSyncQualificationManifest(
            schemaVersion: 1,
            kind: "production-sync-qualification-run",
            runID: XCTUnwrap(UUID(
                uuidString: "80000000-0000-4000-8000-000000000010")),
            createdAt: "2026-08-25T12:00:00Z",
            release: .init(
                version: "1.0.0",
                build: "202608250001",
                commit: String(repeating: "a", count: 40)),
            contractSHA256: String(repeating: "b", count: 64),
            executableSHA256: String(repeating: "c", count: 64),
            codeResourcesSHA256: String(repeating: "e", count: 64),
            provisioningProfileSHA256: String(repeating: "f", count: 64),
            runNonce: String(repeating: "d", count: 64),
            corpus: .init(
                sha256: ProductionSyncQualificationCorpus.sha256,
                meetingID: XCTUnwrap(UUID(
                    uuidString: "80000000-0000-4000-8000-000000000011")),
                speakerIDs: [
                    XCTUnwrap(UUID(uuidString: "80000000-0000-4000-8000-000000000012")),
                    XCTUnwrap(UUID(uuidString: "80000000-0000-4000-8000-000000000013"))
                ],
                segmentIDs: [
                    XCTUnwrap(UUID(uuidString: "80000000-0000-4000-8000-000000000014")),
                    XCTUnwrap(UUID(uuidString: "80000000-0000-4000-8000-000000000015"))
                ]))
    }

    private func contractURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evidence/production-sync-qualification.json")
    }
}
