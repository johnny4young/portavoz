import CryptoKit
import Foundation
import IntegrationsKit

enum ProductionSyncQualificationError: Error, Equatable {
    case invalidAdmission
    case invalidBundle
    case invalidContract
    case invalidManifest
    case invalidWorkspace
    case invalidStageOrder
    case invalidCorpus
    case invalidLifecycle
    case invalidAccount
    case pushRegistrationFailed
    case pushTimedOut
    case receiptWriteFailed
}

struct ProductionSyncQualificationConfiguration: Equatable {
    static let mode = "--production-sync-qualification"

    private struct Admission {
        let executable: String
        let manifest: String
        let workspace: String
        let role: String
        let stage: String
        let timeout: String
    }

    let manifestURL: URL
    let workspaceURL: URL
    let role: String
    let stage: String
    let timeoutSeconds: Int

    static func requested(
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> Self? {
        let modeIndexes = arguments.indices.filter { arguments[$0] == mode }
        let temporaryStoreIndexes = arguments.indices.filter {
            arguments[$0] == "-use-temp-store"
        }
        let forbiddenIsolationArguments = arguments.dropFirst().filter {
            $0.hasPrefix("-seed-")
                || $0.hasPrefix("-simulate-")
                || $0.hasPrefix("--bench")
        }
        guard !modeIndexes.isEmpty else { return nil }
        guard modeIndexes.count == 1,
              temporaryStoreIndexes.count == 1,
              forbiddenIsolationArguments.isEmpty,
              let manifest = try value(
                after: "--production-sync-manifest",
                in: arguments),
              let workspace = try value(
                after: "--production-sync-workspace",
                in: arguments),
              let role = try value(
                after: "--production-sync-role",
                in: arguments),
              let stage = try value(
                after: "--production-sync-stage",
                in: arguments),
              let timeoutRaw = try value(
                after: "--production-sync-timeout-seconds",
                in: arguments),
              let timeout = Int(timeoutRaw),
              let executable = arguments.first,
              (30...3_600).contains(timeout),
              ["a", "b"].contains(role),
              stage.range(
                of: "^[a-z][a-z0-9-]{0,63}$",
                options: .regularExpression) != nil
        else {
            throw ProductionSyncQualificationError.invalidAdmission
        }
        let admission = Admission(
            executable: executable,
            manifest: manifest,
            workspace: workspace,
            role: role,
            stage: stage,
            timeout: timeoutRaw)
        try validateExactArguments(arguments, admission: admission)
        let (manifestURL, workspaceURL) = try validatedURLs(admission)
        try validateEnvironment(
            environment,
            workspace: workspaceURL,
            role: role)
        return Self(
            manifestURL: manifestURL,
            workspaceURL: workspaceURL,
            role: role,
            stage: stage,
            timeoutSeconds: timeout)
    }

    static func isRequested(arguments: [String]) -> Bool {
        arguments.contains(mode)
    }

    private static func validateExactArguments(
        _ arguments: [String],
        admission: Admission
    ) throws {
        let expected = [
            admission.executable,
            "-NSTreatUnknownArgumentsAsOpen", "NO",
            "-ApplePersistenceIgnoreState", "YES",
            "-use-temp-store",
            mode,
            "--production-sync-manifest", admission.manifest,
            "--production-sync-workspace", admission.workspace,
            "--production-sync-role", admission.role,
            "--production-sync-stage", admission.stage,
            "--production-sync-timeout-seconds", admission.timeout
        ]
        guard arguments == expected else {
            throw ProductionSyncQualificationError.invalidAdmission
        }
    }

    private static func validatedURLs(_ admission: Admission) throws -> (URL, URL) {
        let manifest = URL(fileURLWithPath: admission.manifest).standardizedFileURL
        let workspace = URL(fileURLWithPath: admission.workspace).standardizedFileURL
        guard manifest.path.hasPrefix("/"),
              workspace.path.hasPrefix("/"),
              manifest.deletingLastPathComponent().path == workspace.path,
              manifest.lastPathComponent == "run.json"
        else {
            throw ProductionSyncQualificationError.invalidAdmission
        }
        return (manifest, workspace)
    }

    private static func value(
        after option: String,
        in arguments: [String]
    ) throws -> String? {
        let indexes = arguments.indices.filter { arguments[$0] == option }
        guard !indexes.isEmpty else { return nil }
        guard indexes.count == 1,
              let index = indexes.first,
              arguments.indices.contains(index + 1),
              !arguments[index + 1].isEmpty
        else {
            throw ProductionSyncQualificationError.invalidAdmission
        }
        return arguments[index + 1]
    }

    private static func validateEnvironment(
        _ environment: [String: String],
        workspace: URL,
        role: String
    ) throws {
        let qualificationKey = "PORTAVOZ_UI_TEST_DATABASE_PATH"
        let portavozKeys = Set(environment.keys.filter {
            $0.hasPrefix("PORTAVOZ_")
        })
        guard portavozKeys == [qualificationKey],
              let databasePath = environment[qualificationKey]
        else {
            throw ProductionSyncQualificationError.invalidAdmission
        }
        let database = URL(fileURLWithPath: databasePath).standardizedFileURL
        let expectedParent = workspace
            .appendingPathComponent("app-shell", isDirectory: true)
            .appendingPathComponent(role, isDirectory: true)
            .standardizedFileURL
        guard database.pathExtension == "sqlite",
              UUID(uuidString: database.deletingPathExtension().lastPathComponent) != nil,
              database.deletingLastPathComponent() == expectedParent
        else {
            throw ProductionSyncQualificationError.invalidAdmission
        }
    }
}

struct ProductionSyncQualificationContract: Decodable, Equatable {
    static let frozenSHA256 =
        "2f6fb818d79dde06f8334203a807e0f8e34d2eae926d22facbd2b7cc2a2d967b"

    struct Corpus: Decodable, Equatable {
        let schemaVersion: Int
        let sha256: String
        let languages: [String]
    }

    struct Stage: Decodable, Equatable {
        let id: String
        let role: String
        let roleSequence: Int
        let requires: [String]
        let externalAction: String
        let requiresLiveStage: String?
    }

    struct Limits: Decodable, Equatable {
        let maximumReceiptBytes: Int
        let maximumPushWakes: Int
        let defaultStageTimeoutSeconds: Int
        let pushStageTimeoutSeconds: Int
    }

    let schemaVersion: Int
    let kind: String
    let scope: String
    let proof: String
    let corpus: Corpus
    let roles: [String]
    let stages: [Stage]
    let limits: Limits

    func stage(role: String, id: String) throws -> Stage {
        let matches = stages.filter { $0.role == role && $0.id == id }
        guard matches.count == 1, let stage = matches.first else {
            throw ProductionSyncQualificationError.invalidContract
        }
        return stage
    }

    static func load(bundle: Bundle = .main) throws -> (Self, Data, String) {
        guard let resource = bundle.url(
            forResource: "production-sync-qualification",
            withExtension: "json"),
              try ProductionSyncQualificationFile.isRegularFile(resource),
              let data = try? Data(contentsOf: resource),
              data.count <= 1024 * 1024,
              let contract = try? JSONDecoder().decode(Self.self, from: data)
        else {
            throw ProductionSyncQualificationError.invalidContract
        }
        let digest = ProductionSyncQualificationDigest.hex(data)
        guard digest == frozenSHA256 else {
            throw ProductionSyncQualificationError.invalidContract
        }
        try contract.validate()
        return (contract, data, digest)
    }

    func validate() throws {
        guard schemaVersion == 1,
              kind == "production-sync-qualification-contract",
              scope == "production-sync",
              proof == "admission",
              corpus.schemaVersion == 1,
              ProductionSyncQualificationDigest.isSHA256(corpus.sha256),
              corpus.languages == ["en", "es"],
              roles == ["a", "b"],
              !stages.isEmpty,
              limits.maximumReceiptBytes == 65_536,
              (1...10).contains(limits.maximumPushWakes),
              limits.defaultStageTimeoutSeconds >= 30,
              limits.pushStageTimeoutSeconds >= limits.defaultStageTimeoutSeconds
        else {
            throw ProductionSyncQualificationError.invalidContract
        }
        let keys = stages.map { "\($0.role).\($0.id)" }
        guard Set(keys).count == keys.count else {
            throw ProductionSyncQualificationError.invalidContract
        }
        for role in roles {
            let sequence = stages
                .filter { $0.role == role }
                .map(\.roleSequence)
                .sorted()
            guard sequence == Array(1...sequence.count) else {
                throw ProductionSyncQualificationError.invalidContract
            }
        }
        let known = Set(keys)
        let externalActions: Set<String> = [
            "none", "disable-network", "restore-network",
            "sign-out-original-account", "sign-in-original-account",
            "switch-to-secondary-account", "restore-original-account"
        ]
        guard stages.allSatisfy({ stage in
            ["a", "b"].contains(stage.role)
                && stage.roleSequence > 0
                && Set(stage.requires).count == stage.requires.count
                && stage.requires.allSatisfy(known.contains)
                && !stage.requires.contains("\(stage.role).\(stage.id)")
                && externalActions.contains(stage.externalAction)
                && (stage.requiresLiveStage.map(known.contains) ?? true)
        }) else {
            throw ProductionSyncQualificationError.invalidContract
        }
        let liveRequirements = Dictionary(uniqueKeysWithValues: stages.compactMap { stage -> (String, String)? in
            guard let requirement = stage.requiresLiveStage else { return nil }
            return ("\(stage.role).\(stage.id)", requirement)
        })
        guard liveRequirements == ["a.push-source": "b.await-push"] else {
            throw ProductionSyncQualificationError.invalidContract
        }
        try validateAcyclicGraph()
    }

    private func validateAcyclicGraph() throws {
        var unresolved = Dictionary(uniqueKeysWithValues: stages.map {
            ("\($0.role).\($0.id)", Set($0.requires))
        })
        var resolved: Set<String> = []
        while !unresolved.isEmpty {
            let ready = unresolved.compactMap { key, requirements in
                requirements.isSubset(of: resolved) ? key : nil
            }
            guard !ready.isEmpty else {
                throw ProductionSyncQualificationError.invalidContract
            }
            for key in ready {
                resolved.insert(key)
                unresolved.removeValue(forKey: key)
            }
        }
    }
}

struct ProductionSyncQualificationManifest: Decodable, Equatable {
    struct Release: Codable, Equatable {
        let version: String
        let build: String
        let commit: String
    }

    struct Corpus: Decodable, Equatable {
        let sha256: String
        let meetingID: UUID
        let speakerIDs: [UUID]
        let segmentIDs: [UUID]
    }

    let schemaVersion: Int
    let kind: String
    let runID: UUID
    let createdAt: String
    let release: Release
    let contractSHA256: String
    let executableSHA256: String
    let codeResourcesSHA256: String
    let provisioningProfileSHA256: String
    let runNonce: String
    let corpus: Corpus

    static func load(
        from url: URL,
        contract: ProductionSyncQualificationContract,
        contractSHA256: String,
        bundle: Bundle = .main
    ) throws -> Self {
        guard try ProductionSyncQualificationFile.isRegularFile(url),
              try ProductionSyncQualificationFile.permissions(url) == 0o600,
              let data = try? Data(contentsOf: url),
              data.count <= 65_536,
              try exactShape(data),
              let manifest = try? JSONDecoder().decode(Self.self, from: data)
        else {
            throw ProductionSyncQualificationError.invalidManifest
        }
        try manifest.validate(
            contract: contract,
            contractSHA256: contractSHA256,
            bundle: bundle)
        return manifest
    }

    func validate(
        contract: ProductionSyncQualificationContract,
        contractSHA256: String,
        bundle: Bundle = .main
    ) throws {
        let identities = [corpus.meetingID]
            + corpus.speakerIDs
            + corpus.segmentIDs
        guard schemaVersion == 1,
              kind == "production-sync-qualification-run",
              ProductionSyncQualificationDigest.isTimestamp(createdAt),
              release.version.range(
                of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?$",
                options: .regularExpression) != nil,
              release.build.range(
                of: "^[0-9]+$",
                options: .regularExpression) != nil,
              release.commit.range(
                of: "^[0-9a-f]{40}$",
                options: .regularExpression) != nil,
              self.contractSHA256 == contractSHA256,
              ProductionSyncQualificationDigest.isSHA256(executableSHA256),
              ProductionSyncQualificationDigest.isSHA256(codeResourcesSHA256),
              ProductionSyncQualificationDigest.isSHA256(
                provisioningProfileSHA256),
              ProductionSyncQualificationDigest.isSHA256(runNonce),
              corpus.sha256 == contract.corpus.sha256,
              corpus.speakerIDs.count == 2,
              corpus.segmentIDs.count == 2,
              Set(identities).count == identities.count
        else {
            throw ProductionSyncQualificationError.invalidManifest
        }
        guard let info = bundle.infoDictionary,
              info["CFBundleIdentifier"] as? String == "app.portavoz.mac",
              info["CFBundleDisplayName"] as? String
                == "Portavoz Sync Qualification",
              info["CFBundleName"] as? String
                == "Portavoz Sync Qualification",
              info["CFBundleShortVersionString"] as? String == release.version,
              info["CFBundleVersion"] as? String == release.build,
              info["PortavozSourceCommit"] as? String == release.commit,
              let executableURL = bundle.executableURL,
              try ProductionSyncQualificationDigest.file(executableURL)
                == executableSHA256,
              try ProductionSyncQualificationDigest.file(
                bundle.bundleURL.appendingPathComponent(
                    "Contents/_CodeSignature/CodeResources"))
                == codeResourcesSHA256,
              try ProductionSyncQualificationDigest.file(
                bundle.bundleURL.appendingPathComponent(
                    "Contents/embedded.provisionprofile"))
                == provisioningProfileSHA256
        else {
            throw ProductionSyncQualificationError.invalidBundle
        }
    }

    private static func exactShape(_ data: Data) throws -> Bool {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == [
                "schemaVersion", "kind", "runID", "createdAt", "release",
                "contractSHA256", "executableSHA256", "codeResourcesSHA256",
                "provisioningProfileSHA256", "runNonce", "corpus"
              ],
              let release = root["release"] as? [String: Any],
              Set(release.keys) == ["version", "build", "commit"],
              let corpus = root["corpus"] as? [String: Any],
              Set(corpus.keys) == [
                "sha256", "meetingID", "speakerIDs", "segmentIDs"
              ]
        else {
            return false
        }
        return true
    }
}

struct ProductionSyncQualificationReceipt: Encodable, Equatable {
    struct Corpus: Encodable, Equatable {
        let sha256: String
        let state: String
        let liveMeetings: Int
        let deletedMeetings: Int
    }

    struct Lifecycle: Encodable, Equatable {
        let phase: String
        let accountStatus: String
        let isEnabled: Bool
        let initialSeedState: String
        let pendingLocalChanges: Int
        let queuedTransfers: Int
        let retryingTransfers: Int
        let failedTransfers: Int
    }

    struct OperatingSystem: Encodable, Equatable {
        let major: Int
        let minor: Int
        let patch: Int
        let build: String
        let architecture: String
    }

    let schemaVersion = 1
    let kind = "production-sync-stage"
    let collectedAt: String
    let runID: String
    let contractSHA256: String
    let release: ProductionSyncQualificationManifest.Release
    let executableSHA256: String
    let codeResourcesSHA256: String
    let provisioningProfileSHA256: String
    let role: String
    let stage: String
    let roleSequence: Int
    let processNonce: String
    let hostScopeSHA256: String
    let accountScopeSHA256: String?
    let predecessorSHA256: String?
    let liveStageMarkerSHA256: String?
    let corpus: Corpus
    let lifecycle: Lifecycle
    let pushWakes: Int
    let os: OperatingSystem
}

struct ProductionSyncLiveStageMarker: Encodable, Equatable {
    let schemaVersion = 1
    let kind = "production-sync-live-stage"
    let collectedAt: String
    let runID: String
    let contractSHA256: String
    let release: ProductionSyncQualificationManifest.Release
    let executableSHA256: String
    let codeResourcesSHA256: String
    let provisioningProfileSHA256: String
    let role: String
    let stage: String
    let processNonce: String
    let hostScopeSHA256: String
}

enum ProductionSyncQualificationDigest {
    static func uuid(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func file(_ url: URL) throws -> String {
        guard try ProductionSyncQualificationFile.isRegularFile(url),
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            throw ProductionSyncQualificationError.invalidBundle
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func scoped(
        namespace: String,
        runNonce: String,
        value: String
    ) -> String {
        hex(Data("\(namespace)\u{0}\(runNonce)\u{0}\(value)".utf8))
    }

    static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    static func isTimestamp(_ value: String) -> Bool {
        ISO8601DateFormatter().date(from: value) != nil && value.hasSuffix("Z")
    }
}

enum ProductionSyncQualificationFile {
    static func isRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path)
        return attributes[.posixPermissions] as? Int ?? -1
    }

    static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard isDirectory.boolValue,
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw ProductionSyncQualificationError.invalidWorkspace
            }
        } else {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path)
    }

    static func isOwnerOnlyDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let mode = try permissions(url)
        return values.isDirectory == true
            && values.isSymbolicLink != true
            && mode == 0o700
    }

    static func writeOwnerOnly<T: Encodable>(
        _ value: T,
        to url: URL,
        maximumBytes: Int
    ) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value) + Data([0x0A])
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ProductionSyncQualificationError.receiptWriteFailed
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            guard FileManager.default.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: temporary)
            else {
                throw ProductionSyncQualificationError.receiptWriteFailed
            }
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw ProductionSyncQualificationError.receiptWriteFailed
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw ProductionSyncQualificationError.invalidStageOrder
            }
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let qualification = error as? ProductionSyncQualificationError {
                throw qualification
            }
            throw ProductionSyncQualificationError.receiptWriteFailed
        }
    }
}

extension ProductionSyncQualificationReceipt.Lifecycle {
    init(status: CloudMeetingSyncStatus) {
        phase = status.phase.rawValue
        accountStatus = status.accountStatus.rawValue
        isEnabled = status.isEnabled
        initialSeedState = switch status.initialSeedState {
        case .blocked: "blocked"
        case .notRequested: "notRequested"
        case .requested: "requested"
        case .complete: "complete"
        }
        pendingLocalChanges = status.progress.pendingLocalChanges
        queuedTransfers = status.progress.queuedTransfers
        retryingTransfers = status.progress.retryingTransfers
        failedTransfers = status.progress.failedTransfers
    }
}
