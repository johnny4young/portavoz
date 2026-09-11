import ApplicationKit

extension AppServices {
    var recordingInputWriter: PersistRecordingInput {
        if let fixture = RecordingInputUITestFixture(store: store, usesTemporaryStore: usesTemporaryMeetingStore) {
            return PersistRecordingInput(store: fixture)
        }
        return PersistRecordingInput(store: store)
    }
}
