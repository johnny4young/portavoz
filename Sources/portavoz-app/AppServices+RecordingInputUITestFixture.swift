import ApplicationKit
import Foundation
import PortavozCore

/// A file handshake holds the real storage call at its application boundary.
/// Only disposable composition can select it; normal recording has no timer.
struct RecordingInputUITestFixture: RecordingInputStore {
    private let store: any RecordingInputStore
    private let entered: String
    private let release: String

    init?(
        store: any RecordingInputStore,
        usesTemporaryStore: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard usesTemporaryStore,
              let entered = environment["PORTAVOZ_UI_TEST_INPUT_ENTERED_PATH"],
              let release = environment["PORTAVOZ_UI_TEST_INPUT_CONTINUE_PATH"],
              !entered.isEmpty, !release.isEmpty, entered != release else { return nil }
        self.store = store
        self.entered = entered
        self.release = release
    }

    func persistRecordingInput(
        _ items: [ContextItem], removing removedIDs: [UUID], for meetingID: MeetingID
    ) async throws {
        guard FileManager.default.createFile(atPath: entered, contents: Data()) else {
            throw HandshakeFailure.signal
        }
        for _ in 0..<600 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: release) {
                try await store.persistRecordingInput(items, removing: removedIDs, for: meetingID)
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HandshakeFailure.timeout
    }

    private enum HandshakeFailure: Error { case signal, timeout }
}
