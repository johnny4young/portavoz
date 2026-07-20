import CloudKit
import Foundation
import Security

public struct CloudKitMeetingSyncSignedCapabilities: Equatable, Sendable {
    public let containerIdentifiers: [String]
    public let services: [String]
    public let containerEnvironment: String?
    public let pushEnvironment: String?
    public let hasEmbeddedProvisioningProfile: Bool

    public init(
        containerIdentifiers: [String],
        services: [String],
        containerEnvironment: String?,
        pushEnvironment: String?,
        hasEmbeddedProvisioningProfile: Bool
    ) {
        self.containerIdentifiers = containerIdentifiers
        self.services = services
        self.containerEnvironment = containerEnvironment
        self.pushEnvironment = pushEnvironment
        self.hasEmbeddedProvisioningProfile = hasEmbeddedProvisioningProfile
    }
}

public enum CloudKitMeetingSyncCapabilityIssue: String, Equatable, Sendable {
    case missingContainer
    case missingCloudKitService
    case missingContainerEnvironment
    case missingPushEnvironment
    case environmentMismatch
    case missingProvisioningProfile
}

public struct CloudKitMeetingSyncCapabilityReport: Equatable, Sendable {
    public let issues: [CloudKitMeetingSyncCapabilityIssue]

    public init(issues: [CloudKitMeetingSyncCapabilityIssue]) {
        self.issues = issues
    }

    public var isAvailable: Bool { issues.isEmpty }
}

/// Reads only the current code signature and app bundle. It never creates a
/// CKContainer, checks an account, or performs network work.
public enum CloudKitMeetingSyncCapabilityProbe {
    public static let containerIdentifier = "iCloud.app.portavoz.mac"

    public static func evaluate(
        _ capabilities: CloudKitMeetingSyncSignedCapabilities
    ) -> CloudKitMeetingSyncCapabilityReport {
        var issues: [CloudKitMeetingSyncCapabilityIssue] = []
        if !capabilities.containerIdentifiers.contains(containerIdentifier) {
            issues.append(.missingContainer)
        }
        if !capabilities.services.contains("CloudKit") {
            issues.append(.missingCloudKitService)
        }
        if !["Development", "Production"].contains(capabilities.containerEnvironment) {
            issues.append(.missingContainerEnvironment)
        }
        if !["development", "production"].contains(capabilities.pushEnvironment) {
            issues.append(.missingPushEnvironment)
        }
        if let containerEnvironment = capabilities.containerEnvironment,
           let pushEnvironment = capabilities.pushEnvironment,
           ["Development", "Production"].contains(containerEnvironment),
           ["development", "production"].contains(pushEnvironment),
           containerEnvironment.lowercased() != pushEnvironment {
            issues.append(.environmentMismatch)
        }
        if !capabilities.hasEmbeddedProvisioningProfile {
            issues.append(.missingProvisioningProfile)
        }
        return CloudKitMeetingSyncCapabilityReport(issues: issues)
    }

    public static func current(
        bundle: Bundle = .main
    ) -> CloudKitMeetingSyncCapabilityReport {
        evaluate(readSignedCapabilities(bundle: bundle))
    }
}

/// The sole production CKContainer owner. Construction is inert; the first
/// container is created only after the lifecycle proves prior account-scoped
/// consent or receives an explicit Enable action.
public actor CloudKitMeetingSyncPlatform: CloudMeetingSyncPlatform {
    private var container: CKContainer?

    public init() {}

    public func accountIdentity() async throws -> CloudMeetingSyncAccountIdentity {
        let container = try availableContainer()
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw CloudMeetingSyncPlatformError.accountCheckFailed
        }

        switch status {
        case .available:
            do {
                let currentUser = try await container.userRecordID()
                return CloudMeetingSyncAccountIdentity(
                    status: .available,
                    fingerprint: CloudMeetingSyncStateStore.accountFingerprint(
                        forCloudRecordName: currentUser.recordName))
            } catch {
                throw CloudMeetingSyncPlatformError.accountIdentityUnavailable
            }
        case .noAccount:
            return CloudMeetingSyncAccountIdentity(status: .signedOut, fingerprint: nil)
        case .restricted:
            return CloudMeetingSyncAccountIdentity(status: .restricted, fingerprint: nil)
        case .couldNotDetermine, .temporarilyUnavailable:
            return CloudMeetingSyncAccountIdentity(
                status: .temporarilyUnavailable,
                fingerprint: nil)
        @unknown default:
            return CloudMeetingSyncAccountIdentity(status: .unknown, fingerprint: nil)
        }
    }

    public func makeDriver(
        delegate: CloudMeetingSyncEngineDelegate
    ) async throws -> any CloudMeetingSyncEngineDriving {
        let container = try availableContainer()
        do {
            let engine = try await CloudMeetingSyncRuntime.make(
                database: container.privateCloudDatabase,
                delegate: delegate)
            return CloudKitMeetingSyncDriver(engine: engine, delegate: delegate)
        } catch {
            throw CloudMeetingSyncPlatformError.transportCreationFailed
        }
    }
}

/// A bounded manual cycle for the automaticallySync=false engine. Sending
/// first creates the custom zone and publishes already-staged work; fetching
/// then applies remote generations, and the final send publishes any local
/// generation produced by deterministic replay/conflict resolution.
public actor CloudKitMeetingSyncDriver: CloudMeetingSyncEngineDriving {
    private let engine: CKSyncEngine
    private let delegate: CloudMeetingSyncEngineDelegate

    public init(
        engine: CKSyncEngine,
        delegate: CloudMeetingSyncEngineDelegate
    ) {
        self.engine = engine
        self.delegate = delegate
    }

    public func synchronize() async throws {
        do {
            _ = try await delegate.preparePendingChanges(in: engine)
            try await engine.sendChanges()
            try await engine.fetchChanges()
            _ = try await delegate.preparePendingChanges(in: engine)
            try await engine.sendChanges()
        } catch {
            throw CloudMeetingSyncPlatformError.synchronizationFailed
        }
    }

    public func cancel() async {
        await engine.cancelOperations()
    }
}

private extension CloudKitMeetingSyncPlatform {
    func availableContainer() throws -> CKContainer {
        let report = CloudKitMeetingSyncCapabilityProbe.current()
        guard report.isAvailable else {
            throw CloudMeetingSyncPlatformError.capabilityUnavailable
        }
        if let container { return container }
        let created = CKContainer(
            identifier: CloudKitMeetingSyncCapabilityProbe.containerIdentifier)
        container = created
        return created
    }
}

private extension CloudKitMeetingSyncCapabilityProbe {
    static func readSignedCapabilities(
        bundle: Bundle
    ) -> CloudKitMeetingSyncSignedCapabilities {
        let task = SecTaskCreateFromSelf(nil)
        let containers = entitlement(
            "com.apple.developer.icloud-container-identifiers",
            task: task) as? [String] ?? []
        let services = entitlement(
            "com.apple.developer.icloud-services",
            task: task) as? [String] ?? []
        let containerEnvironment = entitlement(
            "com.apple.developer.icloud-container-environment",
            task: task) as? String
        let pushEnvironment = entitlement(
            "com.apple.developer.aps-environment",
            task: task) as? String
        let profile = bundle.bundleURL
            .appendingPathComponent("Contents/embedded.provisionprofile")
        return CloudKitMeetingSyncSignedCapabilities(
            containerIdentifiers: containers,
            services: services,
            containerEnvironment: containerEnvironment,
            pushEnvironment: pushEnvironment,
            hasEmbeddedProvisioningProfile: FileManager.default.fileExists(
                atPath: profile.path))
    }

    static func entitlement(_ key: String, task: SecTask?) -> Any? {
        guard let task,
              let value = SecTaskCopyValueForEntitlement(
                task,
                key as CFString,
                nil)
        else { return nil }
        return value
    }
}
