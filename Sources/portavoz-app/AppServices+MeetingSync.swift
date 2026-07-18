import Foundation
import IntegrationsKit
import StorageKit

extension AppServices {
    static let meetingSyncDeviceIDKey = "meetingSync.localDeviceID"

    static func makeMeetingSyncModel(
        store: MeetingStore,
        usesTemporaryStore: Bool
    ) -> MeetingSyncModel {
        if usesTemporaryStore {
            return MeetingSyncModel(client: UITestMeetingSyncClient())
        }

        let transportRoot = supportRoot
            .appendingPathComponent("CloudMeetingSync", isDirectory: true)
        let localDeviceID = persistentMeetingSyncDeviceID()
        let client = LifecycleMeetingSyncClient(
            transportRoot: transportRoot
        ) {
            let transportStore = try CloudMeetingSyncStateStore(
                rootDirectory: transportRoot)
            return CloudMeetingSyncLifecycle(
                meetingStore: store,
                transportStore: transportStore,
                localDeviceID: localDeviceID,
                platform: CloudKitMeetingSyncPlatform())
        }
        return MeetingSyncModel(client: client)
    }

    private static func persistentMeetingSyncDeviceID() -> UUID {
        if let raw = UserDefaults.standard.string(forKey: meetingSyncDeviceIDKey),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let created = UUID()
        UserDefaults.standard.set(
            created.uuidString.lowercased(),
            forKey: meetingSyncDeviceIDKey)
        return created
    }
}
