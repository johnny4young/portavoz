import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

extension AppServices {
    static let meetingSyncDeviceIDKey = "meetingSync.localDeviceID"

    static func makeMeetingSyncModel(
        store: MeetingStore,
        usesTemporaryStore: Bool,
        telemetry: ResourceWorkloadTelemetry,
        captureState: AppResourceCaptureState
    ) -> MeetingSyncModel {
        if usesTemporaryStore {
            return MeetingSyncModel(
                client: UITestMeetingSyncClient(),
                telemetry: telemetry)
        }

        let transportRoot = supportRoot
            .appendingPathComponent("CloudMeetingSync", isDirectory: true)
        let localDeviceID = persistentMeetingSyncDeviceID()
        let maintenanceGate = AppResourceGovernorMaintenanceGate.make(
            captureState: captureState)
        let client = LifecycleMeetingSyncClient(
            transportRoot: transportRoot
        ) {
            let transportStore = try CloudMeetingSyncStateStore(
                rootDirectory: transportRoot)
            return CloudMeetingSyncLifecycle(
                meetingStore: store,
                transportStore: transportStore,
                localDeviceID: localDeviceID,
                platform: CloudKitMeetingSyncPlatform(),
                maintenanceGate: maintenanceGate)
        }
        return MeetingSyncModel(
            client: client,
            telemetry: telemetry)
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
