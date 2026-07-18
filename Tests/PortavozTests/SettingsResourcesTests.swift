import ApplicationKit
import Foundation
import XCTest

final class SettingsResourcesTests: XCTestCase {
    func testAudioInputsCrossAsCapabilityNeutralOptions() async throws {
        let expected = [
            AudioInputOption(uid: "default-mic", name: "Studio Display Microphone"),
        ]
        let result = try await LoadAudioInputOptions(
            inputs: AudioInputListingFake(options: expected)
        ).execute(())

        XCTAssertEqual(result, expected)
    }

    func testAudioInputFailureRemainsVisibleToTheCaller() async {
        do {
            _ = try await LoadAudioInputOptions(
                inputs: AudioInputListingFake(error: SettingsResourceTestError.failed)
            ).execute(())
            XCTFail("expected the capability failure")
        } catch {
            XCTAssertEqual(error as? SettingsResourceTestError, .failed)
        }
    }

    func testRecordingStorageInspectionDoesNotMigrate() async throws {
        let initial = storageLocation("initial", custom: false)
        let fake = RecordingStorageManagerFake(location: initial)

        let result = try await ManageRecordingStorage(storage: fake).execute(
            ManageRecordingStorageRequest(action: .inspect))

        XCTAssertEqual(result, .location(initial))
        let moves = await fake.moves
        XCTAssertTrue(moves.isEmpty)
    }

    func testRecordingStorageMovePublishesOrderedProgressBeforeResult() async throws {
        let initial = storageLocation("initial", custom: false)
        let updated = storageLocation("updated", custom: true)
        let fake = RecordingStorageManagerFake(
            location: initial,
            movedLocation: updated,
            movedCount: 2,
            progress: [
                RecordingStorageProgress(completed: 1, total: 2),
                RecordingStorageProgress(completed: 2, total: 2),
            ])
        let updates = ProgressRecorder()
        let destination = URL(fileURLWithPath: "/tmp/updated")

        let result = try await ManageRecordingStorage(storage: fake).execute(
            ManageRecordingStorageRequest(
                action: .move(to: destination),
                progress: { await updates.append($0) }))

        XCTAssertEqual(result, .moved(location: updated, recordingCount: 2))
        let recordedUpdates = await updates.values
        XCTAssertEqual(recordedUpdates, [
            RecordingStorageProgress(completed: 1, total: 2),
            RecordingStorageProgress(completed: 2, total: 2),
        ])
        let moves = await fake.moves
        XCTAssertEqual(moves, [destination])
    }

    func testRecordingStorageFailureDoesNotInventAnUpdatedLocation() async {
        let initial = storageLocation("initial", custom: false)
        let fake = RecordingStorageManagerFake(
            location: initial,
            moveError: SettingsResourceTestError.failed)

        do {
            _ = try await ManageRecordingStorage(storage: fake).execute(
                ManageRecordingStorageRequest(
                    action: .move(to: URL(fileURLWithPath: "/tmp/failed"))))
            XCTFail("expected migration failure")
        } catch {
            XCTAssertEqual(error as? SettingsResourceTestError, .failed)
        }
        let location = await fake.location
        XCTAssertEqual(location, initial)
    }

    func testRecordingStorageProgressRejectsNegativeCounts() {
        XCTAssertEqual(
            RecordingStorageProgress(completed: -1, total: -2),
            RecordingStorageProgress(completed: 0, total: 0))
    }

    func testRememberedVoiceListContainsNoBiometricPayload() async throws {
        let summary = RememberedVoiceSummary(
            id: UUID(),
            name: "Ana",
            createdAt: Date(timeIntervalSince1970: 1_000))
        let catalog = RememberedVoiceCatalogFake(voices: [summary])

        let result = try await ManageRememberedVoices(catalog: catalog).execute(.list)

        XCTAssertEqual(result, .voices([summary]))
    }

    func testRememberedVoiceDeletionFailuresAreNotSwallowed() async {
        let catalog = RememberedVoiceCatalogFake(
            voices: [],
            mutationError: SettingsResourceTestError.failed)
        do {
            _ = try await ManageRememberedVoices(catalog: catalog).execute(.remove(UUID()))
            XCTFail("expected remove failure")
        } catch {
            XCTAssertEqual(error as? SettingsResourceTestError, .failed)
        }

        do {
            _ = try await ManageRememberedVoices(catalog: catalog).execute(.removeAll)
            XCTFail("expected remove-all failure")
        } catch {
            XCTAssertEqual(error as? SettingsResourceTestError, .failed)
        }
    }

    private func storageLocation(
        _ name: String,
        custom: Bool
    ) -> RecordingStorageLocation {
        RecordingStorageLocation(
            currentRoot: URL(fileURLWithPath: "/tmp/\(name)"),
            defaultRoot: URL(fileURLWithPath: "/tmp/default"),
            isCustom: custom)
    }
}

private enum SettingsResourceTestError: Error, Equatable {
    case failed
}

private struct AudioInputListingFake: AudioInputListing {
    let options: [AudioInputOption]
    let error: SettingsResourceTestError?

    init(
        options: [AudioInputOption] = [],
        error: SettingsResourceTestError? = nil
    ) {
        self.options = options
        self.error = error
    }

    func audioInputOptions() async throws -> [AudioInputOption] {
        if let error { throw error }
        return options
    }
}

private actor RecordingStorageManagerFake: RecordingStorageManaging {
    private(set) var location: RecordingStorageLocation
    private(set) var moves: [URL?] = []
    let movedLocation: RecordingStorageLocation
    let movedCount: Int
    let progressUpdates: [RecordingStorageProgress]
    let moveError: SettingsResourceTestError?

    init(
        location: RecordingStorageLocation,
        movedLocation: RecordingStorageLocation? = nil,
        movedCount: Int = 0,
        progress: [RecordingStorageProgress] = [],
        moveError: SettingsResourceTestError? = nil
    ) {
        self.location = location
        self.movedLocation = movedLocation ?? location
        self.movedCount = movedCount
        progressUpdates = progress
        self.moveError = moveError
    }

    func recordingStorageLocation() async -> RecordingStorageLocation {
        location
    }

    func migrateRecordingStorage(
        to destination: URL?,
        progress: @escaping RecordingStorageProgressHandler
    ) async throws -> Int {
        moves.append(destination)
        if let moveError { throw moveError }
        for update in progressUpdates {
            await progress(update)
        }
        location = movedLocation
        return movedCount
    }
}

private actor ProgressRecorder {
    private(set) var values: [RecordingStorageProgress] = []

    func append(_ value: RecordingStorageProgress) {
        values.append(value)
    }
}

private actor RememberedVoiceCatalogFake: RememberedVoiceCatalogManaging {
    let voices: [RememberedVoiceSummary]
    let mutationError: SettingsResourceTestError?

    init(
        voices: [RememberedVoiceSummary],
        mutationError: SettingsResourceTestError? = nil
    ) {
        self.voices = voices
        self.mutationError = mutationError
    }

    func rememberedVoiceSummaries() async throws -> [RememberedVoiceSummary] {
        voices
    }

    func removeRememberedVoice(id: UUID) async throws {
        if let mutationError { throw mutationError }
    }

    func removeAllRememberedVoices() async throws {
        if let mutationError { throw mutationError }
    }
}
