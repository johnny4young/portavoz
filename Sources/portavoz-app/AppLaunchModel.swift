import Foundation
import Observation
import StorageKit

struct AppDatabaseLaunchFailure: Equatable, Sendable {
    let evidence: MeetingStoreOpenFailureEvidence
    let occurredAt: Date
    let databaseFilePresent: Bool
    let databaseFileBytes: UInt64?

    // Recovery needs the authority, but neither the view nor the exported
    // diagnostic document receives its path.
    let databaseURL: URL
}

struct AppLaunchDiagnosticDocument: Codable, Equatable, Sendable {
    struct Application: Codable, Equatable, Sendable {
        let version: String
        let build: String
    }

    struct OperatingSystem: Codable, Equatable, Sendable {
        let major: Int
        let minor: Int
        let patch: Int
    }

    struct Database: Codable, Equatable, Sendable {
        let filePresent: Bool
        let fileBytes: UInt64?
    }

    let schemaVersion: Int
    let generatedAt: Date
    let application: Application
    let operatingSystem: OperatingSystem
    let failure: MeetingStoreOpenFailureEvidence
    let database: Database
}

@MainActor
@Observable
final class AppLaunchModel {
    enum Phase {
        case opening
        case ready(AppServices)
        case databaseUnavailable(AppDatabaseLaunchFailure)
    }

    enum ArtifactState: Equatable {
        case idle
        case working
        case succeeded
        case failed
    }

    typealias ServicesFactory = @MainActor () throws -> AppServices

    private(set) var phase: Phase = .opening
    private(set) var recoveryCopyState: ArtifactState = .idle
    private(set) var diagnosticsState: ArtifactState = .idle

    @ObservationIgnored private let arguments: [String]
    @ObservationIgnored private let databaseURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let servicesFactory: ServicesFactory
    @ObservationIgnored private var activatedServices = false

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init,
        servicesFactory: ServicesFactory? = nil
    ) {
        self.arguments = arguments
        let storagePolicy = AppStorageIsolationPolicy(
            arguments: arguments,
            environment: environment)
        databaseURL = storagePolicy.meetingStoreURL
        self.now = now
        self.servicesFactory = servicesFactory ?? {
            try AppServices(
                arguments: arguments,
                environment: environment,
                storagePolicy: storagePolicy)
        }
        openServices()
    }

    var services: AppServices? {
        guard case let .ready(services) = phase else { return nil }
        return services
    }

    var hasOperationInProgress: Bool {
        recoveryCopyState == .working || diagnosticsState == .working
    }

    func retry() async {
        guard !hasOperationInProgress else { return }
        phase = .opening
        await Task.yield()
        openServices()
        activateReadyServicesIfNeeded()
    }

    func saveRecoveryCopy(to destinationRoot: URL) async {
        guard case let .databaseUnavailable(failure) = phase,
              !hasOperationInProgress else { return }
        recoveryCopyState = .working
        do {
            _ = try await MeetingStore.makeReadOnlyRecoveryCopy(
                of: failure.databaseURL,
                in: destinationRoot,
                at: now())
            recoveryCopyState = .succeeded
        } catch {
            recoveryCopyState = .failed
        }
    }

    func exportDiagnostics(to destinationURL: URL) async {
        guard case let .databaseUnavailable(failure) = phase,
              !hasOperationInProgress else { return }
        diagnosticsState = .working
        do {
            let data = try diagnosticData(for: failure, generatedAt: now())
            try await Self.writeDiagnosticData(data, to: destinationURL)
            diagnosticsState = .succeeded
        } catch {
            diagnosticsState = .failed
        }
    }

    func diagnosticData(
        for failure: AppDatabaseLaunchFailure,
        generatedAt: Date
    ) throws -> Data {
        let document = Self.diagnosticDocument(
            for: failure,
            generatedAt: generatedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Starts every process owner exactly once and only after the authoritative
    /// database opened. Failed launch attempts therefore have no worker,
    /// scheduler, model, sync, or global-hotkey side effects.
    func activateReadyServicesIfNeeded() {
        guard !activatedServices, let services else { return }
        activatedServices = true

        let runsIsolatedResourceBenchmark =
            BenchMode.runsIsolatedResourceBenchmark(arguments: arguments)
        if !runsIsolatedResourceBenchmark {
            PortavozAppDelegate.services = services
        }

        BenchMode.runRecordBenchIfRequested(
            services: services,
            recording: services.recording)
        BenchMode.runRefineResourceBenchIfRequested(services: services)
        BenchMode.runSummaryResourceBenchIfRequested(services: services)
        BenchMode.runAskResourceBenchIfRequested(services: services)
        BenchMode.runIndexingResourceBenchIfRequested(services: services)

        // Resource evidence owns this process. Do not start sync, recovery,
        // provider discovery, or dictation registrations beside a measured
        // window; temporary storage alone would not isolate their resource use.
        guard !runsIsolatedResourceBenchmark else { return }

        services.startResourcePressureMonitoring()
        services.requestSearchReconciliation()
        Task { @MainActor in
            await services.commitmentReminders.send(.start)
        }
        Task { @MainActor in
            await services.meetingSync.start()
        }
        Task { @MainActor in
            await services.libraryMarkdownBackup.recoverAtLaunch()
        }
        Task { @MainActor in
            await RecordingRecoveryCoordinator.runIfNeeded(services: services)
            await PostCaptureProcessingCoordinator.resumeAfterRecovery(
                services: services)
            await services.configureInitialSummaryProviderIfNeeded()
        }
        services.dictation.syncHotkey(services: services)
        services.dictation.syncMousePTT(services: services)

        // The AppKit delegate may already have observed application launch
        // while the database was unavailable. Re-publish, without consuming,
        // any buffered App Intent now that its route destination exists.
        PortavozAppIntentBridge.notifyPendingStartRecordingRequest()
    }
}

private extension AppLaunchModel {
    func openServices() {
        do {
            phase = .ready(try servicesFactory())
        } catch {
            PortavozAppDelegate.services = nil
            phase = .databaseUnavailable(Self.failure(
                error: error,
                databaseURL: databaseURL,
                occurredAt: now()))
        }
    }

    static func failure(
        error: any Error,
        databaseURL: URL,
        occurredAt: Date
    ) -> AppDatabaseLaunchFailure {
        let manager = FileManager.default
        var isDirectory = ObjCBool(false)
        let isRegularFile = manager.fileExists(
            atPath: databaseURL.path,
            isDirectory: &isDirectory) && !isDirectory.boolValue
        let attributes = try? manager.attributesOfItem(
            atPath: databaseURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        return AppDatabaseLaunchFailure(
            evidence: MeetingStore.openFailureEvidence(for: error),
            occurredAt: occurredAt,
            databaseFilePresent: isRegularFile,
            databaseFileBytes: size,
            databaseURL: databaseURL)
    }

    static func diagnosticDocument(
        for failure: AppDatabaseLaunchFailure,
        generatedAt: Date
    ) -> AppLaunchDiagnosticDocument {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return AppLaunchDiagnosticDocument(
            schemaVersion: 1,
            generatedAt: generatedAt,
            application: .init(
                version: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
            operatingSystem: .init(
                major: version.majorVersion,
                minor: version.minorVersion,
                patch: version.patchVersion),
            failure: failure.evidence,
            database: .init(
                filePresent: failure.databaseFilePresent,
                fileBytes: failure.databaseFileBytes))
    }

    static func writeDiagnosticData(
        _ data: Data,
        to destinationURL: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let parent = destinationURL.deletingLastPathComponent()
            let stage = parent.appendingPathComponent(
                ".portavoz-launch-diagnostics-\(UUID().uuidString)")
            guard manager.createFile(
                atPath: stage.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            var published = false
            defer {
                if !published { try? manager.removeItem(at: stage) }
            }

            let handle = try FileHandle(forWritingTo: stage)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stage.path)
            if manager.fileExists(atPath: destinationURL.path) {
                _ = try manager.replaceItemAt(
                    destinationURL,
                    withItemAt: stage,
                    backupItemName: nil,
                    options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: stage, to: destinationURL)
            }
            published = true
        }.value
    }
}
