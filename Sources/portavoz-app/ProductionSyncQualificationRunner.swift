import AppKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

@MainActor
final class ProductionSyncQualificationSession {
    private struct Outcome {
        let status: CloudMeetingSyncStatus
        let state: ProductionSyncQualificationCorpusState
        let accountFingerprint: String?
        let pushWakes: Int
        let liveStageMarkerSHA256: String?
    }

    private enum PushEvent {
        case registered
        case registrationFailed
        case remoteChange
        case timedOut
    }

    private let configuration: ProductionSyncQualificationConfiguration
    private let contract: ProductionSyncQualificationContract
    private let contractSHA256: String
    private let manifest: ProductionSyncQualificationManifest
    private let stage: ProductionSyncQualificationContract.Stage
    private let meetingStore: MeetingStore
    private let transportStore: CloudMeetingSyncStateStore
    private let lifecycle: CloudMeetingSyncLifecycle
    private let processNonce = UUID()

    init(
        configuration: ProductionSyncQualificationConfiguration,
        bundle: Bundle = .main,
        platform: (any CloudMeetingSyncPlatform)? = nil
    ) throws {
        self.configuration = configuration
        let workspacePath = configuration.workspaceURL.path
        let allowedRoots = [
            FileManager.default.temporaryDirectory.standardizedFileURL.path,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        ]
        guard allowedRoots.contains(where: { root in
            workspacePath.hasPrefix(root + "/")
        }),
              try ProductionSyncQualificationFile.isOwnerOnlyDirectory(
                configuration.workspaceURL)
        else {
            throw ProductionSyncQualificationError.invalidWorkspace
        }
        let (contract, _, digest) = try ProductionSyncQualificationContract.load(
            bundle: bundle)
        self.contract = contract
        contractSHA256 = digest
        manifest = try ProductionSyncQualificationManifest.load(
            from: configuration.manifestURL,
            contract: contract,
            contractSHA256: digest,
            bundle: bundle)
        stage = try contract.stage(
            role: configuration.role,
            id: configuration.stage)
        try ProductionSyncQualificationFile.prepareDirectory(
            configuration.workspaceURL)
        let rolesRoot = configuration.workspaceURL
            .appendingPathComponent("roles", isDirectory: true)
        try ProductionSyncQualificationFile.prepareDirectory(rolesRoot)
        let roleRoot = rolesRoot
            .appendingPathComponent(configuration.role, isDirectory: true)
        try ProductionSyncQualificationFile.prepareDirectory(roleRoot)
        let meetingDatabase = roleRoot.appendingPathComponent("meeting.sqlite")
        for candidate in [
            meetingDatabase,
            URL(fileURLWithPath: meetingDatabase.path + "-shm"),
            URL(fileURLWithPath: meetingDatabase.path + "-wal")
        ] {
            try ProductionSyncQualificationFile.requireRegularFileOrAbsent(
                candidate)
        }
        meetingStore = try MeetingStore(
            databaseURL: meetingDatabase)
        let transportRoot = roleRoot.appendingPathComponent(
            "transport",
            isDirectory: true)
        try ProductionSyncQualificationFile.prepareDirectory(transportRoot)
        try ProductionSyncQualificationFile.requireSafeScratchTree(transportRoot)
        transportStore = try CloudMeetingSyncStateStore(
            rootDirectory: transportRoot)
        lifecycle = CloudMeetingSyncLifecycle(
            meetingStore: meetingStore,
            transportStore: transportStore,
            localDeviceID: ProductionSyncQualificationIdentity.deviceID(
                runID: manifest.runID,
                role: configuration.role),
            platform: platform ?? CloudKitMeetingSyncPlatform())
    }

    func run() async throws {
        try validatePrerequisites()
        let predecessor = try predecessorDigest()
        let outcome = try await executeStage()
        try validateOutcome(outcome)
        let facts = try await ProductionSyncQualificationCorpus.facts(
            expecting: outcome.state,
            manifest: manifest,
            store: meetingStore)
        let accountScope = outcome.accountFingerprint.map {
            ProductionSyncQualificationDigest.scoped(
                namespace: "portavoz-production-sync-account-v1",
                runNonce: manifest.runNonce,
                value: $0)
        }
        let receipt = ProductionSyncQualificationReceipt(
            collectedAt: Self.timestamp(),
            runID: ProductionSyncQualificationDigest.uuid(manifest.runID),
            contractSHA256: contractSHA256,
            release: manifest.release,
            executableSHA256: manifest.executableSHA256,
            codeResourcesSHA256: manifest.codeResourcesSHA256,
            provisioningProfileSHA256: manifest.provisioningProfileSHA256,
            role: configuration.role,
            stage: configuration.stage,
            roleSequence: stage.roleSequence,
            processNonce: ProductionSyncQualificationDigest.uuid(processNonce),
            hostScopeSHA256: try ProductionSyncQualificationHost.scope(
                runNonce: manifest.runNonce),
            accountScopeSHA256: accountScope,
            predecessorSHA256: predecessor,
            liveStageMarkerSHA256: outcome.liveStageMarkerSHA256,
            corpus: .init(
                sha256: manifest.corpus.sha256,
                state: facts.state.rawValue,
                liveMeetings: facts.liveMeetings,
                deletedMeetings: facts.deletedMeetings),
            lifecycle: .init(status: outcome.status),
            pushWakes: outcome.pushWakes,
            os: try ProductionSyncQualificationHost.operatingSystem())
        try ProductionSyncQualificationFile.writeOwnerOnly(
            receipt,
            to: receiptURL,
            maximumBytes: contract.limits.maximumReceiptBytes)
    }

}

private extension ProductionSyncQualificationSession {
    struct StageResult {
        let status: CloudMeetingSyncStatus
        let state: ProductionSyncQualificationCorpusState
        let pushWakes: Int
        let liveStageMarkerSHA256: String?

        init(
            status: CloudMeetingSyncStatus,
            state: ProductionSyncQualificationCorpusState,
            pushWakes: Int = 0,
            liveStageMarkerSHA256: String? = nil
        ) {
            self.status = status
            self.state = state
            self.pushWakes = pushWakes
            self.liveStageMarkerSHA256 = liveStageMarkerSHA256
        }
    }

    var stageKey: String {
        "\(configuration.role).\(configuration.stage)"
    }

    var receiptURL: URL {
        receiptURL(for: stage)
    }

    func liveStageMarkerURL(for stageKey: String) -> URL {
        configuration.workspaceURL
            .appendingPathComponent("live", isDirectory: true)
            .appendingPathComponent(
                stageKey.replacingOccurrences(of: ".", with: "-") + ".json")
    }

    func receiptURL(
        for descriptor: ProductionSyncQualificationContract.Stage
    ) -> URL {
        configuration.workspaceURL
            .appendingPathComponent("receipts", isDirectory: true)
            .appendingPathComponent(descriptor.role, isDirectory: true)
            .appendingPathComponent(
                String(
                    format: "%02d-%@.json",
                    descriptor.roleSequence,
                    descriptor.id))
    }

    func validatePrerequisites() throws {
        let requiredRootKeys: Set<String> = [
            "schemaVersion", "kind", "collectedAt", "runID",
            "contractSHA256", "release", "executableSHA256", "role",
            "codeResourcesSHA256", "provisioningProfileSHA256",
            "stage", "roleSequence", "processNonce", "hostScopeSHA256",
            "accountScopeSHA256", "predecessorSHA256",
            "liveStageMarkerSHA256", "corpus",
            "lifecycle", "pushWakes", "os"
        ]
        for requirement in stage.requires {
            let components = requirement.split(
                separator: ".",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw ProductionSyncQualificationError.invalidContract
            }
            let required = try contract.stage(
                role: String(components[0]),
                id: String(components[1]))
            let url = receiptURL(for: required)
            guard try ProductionSyncQualificationFile.isRegularFile(url),
                  try ProductionSyncQualificationFile.permissions(url) == 0o600,
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty,
                  data.count <= contract.limits.maximumReceiptBytes,
                  let document = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  Set(document.keys) == requiredRootKeys,
                  document["schemaVersion"] as? Int == 1,
                  document["kind"] as? String == "production-sync-stage",
                  document["runID"] as? String
                    == manifest.runID.uuidString.lowercased(),
                  document["contractSHA256"] as? String == contractSHA256,
                  document["executableSHA256"] as? String
                    == manifest.executableSHA256,
                  document["codeResourcesSHA256"] as? String
                    == manifest.codeResourcesSHA256,
                  document["provisioningProfileSHA256"] as? String
                    == manifest.provisioningProfileSHA256,
                  document["role"] as? String == required.role,
                  document["stage"] as? String == required.id,
                  document["roleSequence"] as? Int == required.roleSequence,
                  let release = document["release"] as? [String: Any],
                  Set(release.keys) == ["version", "build", "commit"],
                  release["version"] as? String == manifest.release.version,
                  release["build"] as? String == manifest.release.build,
                  release["commit"] as? String == manifest.release.commit
            else {
                throw ProductionSyncQualificationError.invalidStageOrder
            }
        }
    }

    func predecessorDigest() throws -> String? {
        let directory = receiptURL.deletingLastPathComponent()
        try ProductionSyncQualificationFile.prepareDirectory(directory)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: receiptURL.path) else {
            throw ProductionSyncQualificationError.invalidStageOrder
        }
        let existing = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" }
        if stage.roleSequence == 1 {
            guard existing.isEmpty else {
                throw ProductionSyncQualificationError.invalidStageOrder
            }
            return nil
        }
        let previousStages = contract.stages.filter {
            $0.role == configuration.role
                && $0.roleSequence == stage.roleSequence - 1
        }
        guard previousStages.count == 1, let previous = previousStages.first else {
            throw ProductionSyncQualificationError.invalidContract
        }
        let previousURL = directory.appendingPathComponent(
            String(format: "%02d-%@.json", previous.roleSequence, previous.id))
        guard existing.count == stage.roleSequence - 1,
              try ProductionSyncQualificationFile.isRegularFile(previousURL),
              try ProductionSyncQualificationFile.permissions(previousURL) == 0o600,
              let document = try? JSONSerialization.jsonObject(
                with: Data(contentsOf: previousURL)) as? [String: Any],
              document["runID"] as? String == manifest.runID.uuidString.lowercased(),
              document["role"] as? String == configuration.role,
              document["stage"] as? String == previous.id,
              document["roleSequence"] as? Int == previous.roleSequence,
              document["executableSHA256"] as? String
                == manifest.executableSHA256
        else {
            throw ProductionSyncQualificationError.invalidStageOrder
        }
        return try ProductionSyncQualificationDigest.file(previousURL)
    }

    private func executeStage() async throws -> Outcome {
        let before = await transportStore.currentSnapshot()
        let result = try await performStage()
        let after = await transportStore.currentSnapshot()
        let account = after.currentAccountFingerprint
            ?? after.consentedAccountFingerprint
            ?? before.currentAccountFingerprint
            ?? before.consentedAccountFingerprint
        return Outcome(
            status: result.status,
            state: result.state,
            accountFingerprint: account,
            pushWakes: result.pushWakes,
            liveStageMarkerSHA256: result.liveStageMarkerSHA256)
    }

    func performStage() async throws -> StageResult {
        switch stageKey {
        case "a.prepare-existing", "a.enable", "b.enable",
             "a.include-existing", "b.receive-existing", "a.edit-a",
             "b.receive-a-edit", "b.edit-b", "a.receive-b-edit":
            try await performTransferStage()
        case "a.offline-prepare", "a.offline-attempt", "a.retry-relaunch",
             "b.receive-retry", "a.push-source", "b.await-push",
             "b.delete-tombstone", "a.receive-tombstone":
            try await performReliabilityStage()
        case "a.observe-signout", "a.resume-signin",
             "a.observe-account-switch", "a.enable-switched-account",
             "a.observe-account-restore", "a.enable-restored-account",
             "a.pause", "a.remove-device", "b.pause", "b.remove-device":
            try await performAccountStage()
        default:
            throw ProductionSyncQualificationError.invalidContract
        }
    }

    func performTransferStage() async throws -> StageResult {
        switch stageKey {
        case "a.prepare-existing":
            try await ProductionSyncQualificationCorpus.seed(
                manifest: manifest,
                store: meetingStore)
            return .init(status: await lifecycle.currentStatus(), state: .seed)
        case "a.enable":
            try await requireCorpus(.seed)
            return .init(status: await lifecycle.enable(), state: .seed)
        case "b.enable":
            try await requireCorpus(.absent)
            return .init(status: await lifecycle.enable(), state: .absent)
        case "a.include-existing":
            try await requireCorpus(.seed)
            return .init(
                status: await lifecycle.includeExistingLibrary(),
                state: .seed)
        case "b.receive-existing":
            try await requireCorpus(.absent)
            return .init(status: await lifecycle.synchronizeNow(), state: .seed)
        case "a.edit-a":
            try await update(to: .editA, from: .seed)
            return .init(status: await lifecycle.synchronizeNow(), state: .editA)
        case "b.receive-a-edit":
            try await requireCorpus(.seed)
            return .init(status: await lifecycle.synchronizeNow(), state: .editA)
        case "b.edit-b":
            try await update(to: .editB, from: .editA)
            return .init(status: await lifecycle.synchronizeNow(), state: .editB)
        case "a.receive-b-edit":
            try await requireCorpus(.editA)
            return .init(status: await lifecycle.synchronizeNow(), state: .editB)
        default:
            throw ProductionSyncQualificationError.invalidContract
        }
    }

    func performReliabilityStage() async throws -> StageResult {
        switch stageKey {
        case "a.offline-prepare":
            try await update(to: .retry, from: .editB)
            return .init(status: await lifecycle.currentStatus(), state: .retry)
        case "a.offline-attempt":
            try await requireCorpus(.retry)
            return .init(status: await lifecycle.synchronizeNow(), state: .retry)
        case "a.retry-relaunch":
            try await requireCorpus(.retry)
            return .init(status: await lifecycle.retryNow(), state: .retry)
        case "b.receive-retry":
            try await requireCorpus(.editB)
            return .init(status: await lifecycle.synchronizeNow(), state: .retry)
        case "a.push-source":
            let marker = try validatedLiveStageMarkerDigest()
            try await update(to: .push, from: .retry)
            return .init(
                status: await lifecycle.synchronizeNow(),
                state: .push,
                liveStageMarkerSHA256: marker)
        case "b.await-push":
            try await requireCorpus(.retry)
            return try await awaitSilentPush()
        case "b.delete-tombstone":
            try await ProductionSyncQualificationCorpus.delete(
                manifest: manifest,
                store: meetingStore)
            return .init(status: await lifecycle.synchronizeNow(), state: .deleted)
        case "a.receive-tombstone":
            try await requireCorpus(.push)
            return .init(status: await lifecycle.synchronizeNow(), state: .deleted)
        default:
            throw ProductionSyncQualificationError.invalidContract
        }
    }

    func performAccountStage() async throws -> StageResult {
        try await requireCorpus(.deleted)
        switch stageKey {
        case "a.observe-signout":
            return .init(status: await lifecycle.accountDidChange(), state: .deleted)
        case "a.resume-signin":
            return .init(status: await lifecycle.resumeIfConsented(), state: .deleted)
        case "a.observe-account-switch", "a.observe-account-restore":
            return .init(status: await lifecycle.accountDidChange(), state: .deleted)
        case "a.enable-switched-account", "a.enable-restored-account":
            return .init(status: await lifecycle.enable(), state: .deleted)
        case "a.pause", "b.pause":
            return .init(status: await lifecycle.pause(), state: .deleted)
        case "a.remove-device", "b.remove-device":
            return .init(status: await lifecycle.removeThisDevice(), state: .deleted)
        default:
            throw ProductionSyncQualificationError.invalidContract
        }
    }

    func update(
        to state: ProductionSyncQualificationCorpusState,
        from expected: ProductionSyncQualificationCorpusState
    ) async throws {
        try await ProductionSyncQualificationCorpus.update(
            to: state,
            from: expected,
            manifest: manifest,
            store: meetingStore)
    }

    func requireCorpus(_ state: ProductionSyncQualificationCorpusState) async throws {
        _ = try await ProductionSyncQualificationCorpus.facts(
            expecting: state,
            manifest: manifest,
            store: meetingStore)
    }

    private func validateOutcome(_ outcome: Outcome) throws {
        guard outcome.pushWakes >= 0,
              outcome.pushWakes <= contract.limits.maximumPushWakes
        else {
            throw ProductionSyncQualificationError.invalidLifecycle
        }
        try validateLifecycle(outcome)
        try validatePushWakes(outcome.pushWakes)
        if ["a.push-source", "b.await-push"].contains(stageKey) {
            guard let marker = outcome.liveStageMarkerSHA256,
                  ProductionSyncQualificationDigest.isSHA256(marker)
            else { throw ProductionSyncQualificationError.invalidLifecycle }
        } else if outcome.liveStageMarkerSHA256 != nil {
            throw ProductionSyncQualificationError.invalidLifecycle
        }
        if stageKey != "a.prepare-existing",
           outcome.accountFingerprint == nil {
            throw ProductionSyncQualificationError.invalidAccount
        }
    }

    private func validateLifecycle(_ outcome: Outcome) throws {
        let status = outcome.status
        switch stageKey {
        case "a.prepare-existing":
            try requireStatus(
                status, phase: .localOnly, account: .unknown,
                enabled: false, seed: .blocked)
            guard outcome.accountFingerprint == nil else {
                throw ProductionSyncQualificationError.invalidAccount
            }
        case "a.offline-prepare":
            try requireStatus(
                status, phase: .pending, account: .available,
                enabled: true, seed: .complete)
            guard status.progress.pendingLocalChanges >= 1
            else { throw ProductionSyncQualificationError.invalidLifecycle }
        case "a.offline-attempt":
            try validateOfflineAttempt(status)
        case "a.observe-signout":
            try requireStatus(
                status, phase: .paused, account: .signedOut,
                enabled: true, seed: .blocked,
                error: .invalidAccount)
        case "a.observe-account-switch", "a.observe-account-restore":
            try requireStatus(
                status, phase: .localOnly, account: .available,
                enabled: false, seed: .blocked,
                error: .invalidAccount)
        case "a.pause", "b.pause":
            try requireStatus(
                status, phase: .localOnly, account: .available,
                enabled: false, seed: .blocked)
        case "a.remove-device", "b.remove-device":
            try requireStatus(
                status, phase: .localOnly, account: .unknown,
                enabled: false, seed: .blocked)
        default:
            try validateSynchronized(status)
        }
    }

    func validateOfflineAttempt(_ status: CloudMeetingSyncStatus) throws {
        guard [.failed, .retrying].contains(status.phase),
              status.accountStatus == .available,
              status.isEnabled,
              status.initialSeedState == .complete,
              status.progress.pendingLocalChanges
                + status.progress.queuedTransfers >= 1
        else { throw ProductionSyncQualificationError.invalidLifecycle }
    }

    func validateSynchronized(_ status: CloudMeetingSyncStatus) throws {
        guard status.phase == .synchronized,
              status.accountStatus == .available,
              status.isEnabled,
              status.progress.pendingLocalChanges == 0,
              status.progress.queuedTransfers == 0,
              status.progress.retryingTransfers == 0,
              status.progress.failedTransfers == 0,
              status.initialSeedState == expectedInitialSeedState
        else { throw ProductionSyncQualificationError.invalidLifecycle }
    }

    func requireStatus(
        _ status: CloudMeetingSyncStatus,
        phase: CloudMeetingSyncPhase,
        account: CloudSyncAccountStatus,
        enabled: Bool,
        seed: CloudSyncInitialSeedState,
        error: ProductionSyncQualificationError = .invalidLifecycle
    ) throws {
        guard status.phase == phase,
              status.accountStatus == account,
              status.isEnabled == enabled,
              status.initialSeedState == seed
        else { throw error }
    }

    func validatePushWakes(_ pushWakes: Int) throws {
        if stageKey == "b.await-push" {
            guard (1...contract.limits.maximumPushWakes).contains(pushWakes)
            else { throw ProductionSyncQualificationError.invalidLifecycle }
        } else if pushWakes != 0 {
            throw ProductionSyncQualificationError.invalidLifecycle
        }
    }

    var expectedInitialSeedState: CloudSyncInitialSeedState {
        if stageKey.hasPrefix("a."),
           ![
               "a.enable",
               "a.enable-switched-account",
               "a.enable-restored-account"
           ].contains(stageKey) {
            return .complete
        }
        return .notRequested
    }

    func awaitSilentPush() async throws -> StageResult {
        let current = await lifecycle.currentStatus()
        guard current.isEnabled,
              current.accountStatus == .available,
              current.phase == .synchronized
        else {
            throw ProductionSyncQualificationError.invalidLifecycle
        }
        let stream = pushEvents()
        defer {
            ProductionSyncQualificationPushBridge.clear()
            NSApplication.shared.unregisterForRemoteNotifications()
        }
        NSApplication.shared.registerForRemoteNotifications()
        var registered = false
        var markerDigest: String?
        var wakeCount = 0
        for await event in stream {
            switch event {
            case .registered:
                if !registered {
                    markerDigest = try writeLiveStageMarker()
                    registered = true
                    print("production-sync await-push READY")
                }
            case .registrationFailed:
                throw ProductionSyncQualificationError.pushRegistrationFailed
            case .remoteChange:
                guard registered, let markerDigest else { continue }
                wakeCount += 1
                guard wakeCount <= contract.limits.maximumPushWakes else {
                    throw ProductionSyncQualificationError.invalidLifecycle
                }
                let status = await lifecycle.synchronizeNow()
                if (try? await ProductionSyncQualificationCorpus.facts(
                    expecting: .push,
                    manifest: manifest,
                    store: meetingStore)) != nil {
                    return .init(
                        status: status,
                        state: .push,
                        pushWakes: wakeCount,
                        liveStageMarkerSHA256: markerDigest)
                }
            case .timedOut:
                throw ProductionSyncQualificationError.pushTimedOut
            }
        }
        throw ProductionSyncQualificationError.pushTimedOut
    }

    private func pushEvents() -> AsyncStream<PushEvent> {
        AsyncStream(
            bufferingPolicy: .bufferingNewest(
                contract.limits.maximumPushWakes + 2)
        ) { continuation in
            ProductionSyncQualificationPushBridge.didRegister = {
                continuation.yield(.registered)
            }
            ProductionSyncQualificationPushBridge.didFailRegistration = {
                continuation.yield(.registrationFailed)
            }
            ProductionSyncQualificationPushBridge.didReceiveRemoteChange = {
                continuation.yield(.remoteChange)
            }
            let timeout = Task { @MainActor in
                try? await Task.sleep(
                    for: .seconds(configuration.timeoutSeconds - 5))
                guard !Task.isCancelled else { return }
                continuation.yield(.timedOut)
            }
            continuation.onTermination = { _ in timeout.cancel() }
        }
    }

    func writeLiveStageMarker() throws -> String {
        guard stageKey == "b.await-push" else {
            throw ProductionSyncQualificationError.invalidContract
        }
        let marker = ProductionSyncLiveStageMarker(
            collectedAt: Self.timestamp(),
            runID: ProductionSyncQualificationDigest.uuid(manifest.runID),
            contractSHA256: contractSHA256,
            release: manifest.release,
            executableSHA256: manifest.executableSHA256,
            codeResourcesSHA256: manifest.codeResourcesSHA256,
            provisioningProfileSHA256: manifest.provisioningProfileSHA256,
            role: configuration.role,
            stage: configuration.stage,
            processNonce: ProductionSyncQualificationDigest.uuid(processNonce),
            hostScopeSHA256: try ProductionSyncQualificationHost.scope(
                runNonce: manifest.runNonce))
        let url = liveStageMarkerURL(for: stageKey)
        try ProductionSyncQualificationFile.writeOwnerOnly(
            marker,
            to: url,
            maximumBytes: contract.limits.maximumReceiptBytes)
        return try ProductionSyncQualificationDigest.file(url)
    }

    func validatedLiveStageMarkerDigest() throws -> String {
        guard let requirement = stage.requiresLiveStage else {
            throw ProductionSyncQualificationError.invalidContract
        }
        let components = requirement.split(separator: ".", maxSplits: 1)
        let url = liveStageMarkerURL(for: requirement)
        let requiredKeys: Set<String> = [
            "schemaVersion", "kind", "collectedAt", "runID",
            "contractSHA256", "release", "executableSHA256", "role",
            "codeResourcesSHA256", "provisioningProfileSHA256",
            "stage", "processNonce", "hostScopeSHA256"
        ]
        guard components.count == 2,
              try ProductionSyncQualificationFile.isRegularFile(url),
              try ProductionSyncQualificationFile.permissions(url) == 0o600,
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= contract.limits.maximumReceiptBytes,
              let document = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(document.keys) == requiredKeys,
              document["schemaVersion"] as? Int == 1,
              document["kind"] as? String == "production-sync-live-stage",
              let collectedAt = document["collectedAt"] as? String,
              ProductionSyncQualificationDigest.isTimestamp(collectedAt),
              document["runID"] as? String
                == ProductionSyncQualificationDigest.uuid(manifest.runID),
              document["contractSHA256"] as? String == contractSHA256,
              document["executableSHA256"] as? String
                == manifest.executableSHA256,
              document["codeResourcesSHA256"] as? String
                == manifest.codeResourcesSHA256,
              document["provisioningProfileSHA256"] as? String
                == manifest.provisioningProfileSHA256,
              document["role"] as? String == String(components[0]),
              document["stage"] as? String == String(components[1]),
              let nonce = document["processNonce"] as? String,
              UUID(uuidString: nonce)?.uuidString.lowercased() == nonce,
              let host = document["hostScopeSHA256"] as? String,
              ProductionSyncQualificationDigest.isSHA256(host),
              let release = document["release"] as? [String: Any],
              Set(release.keys) == ["version", "build", "commit"],
              release["version"] as? String == manifest.release.version,
              release["build"] as? String == manifest.release.build,
              release["commit"] as? String == manifest.release.commit
        else {
            throw ProductionSyncQualificationError.invalidStageOrder
        }
        return ProductionSyncQualificationDigest.hex(data)
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
