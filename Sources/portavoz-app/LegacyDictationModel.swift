import AppKit
import Foundation
import Observation
import OSLog
import StorageKit

/// Whether the one notice that dictation moved to Secreteo is due. Only a user who dictated sees
/// it, once; disposable libraries see it only when a UI test forces it.
struct LegacyDictationNotice {
    static let shownKey = "dictationMovedNoticeShown"
    static let forceArgument = "-show-dictation-moved-notice"
    /// The 1.x dictation switch. Only the user ever wrote it, so its presence means they used dictation.
    static let dictationSwitchKey = "globalDictationEnabled"

    let defaults: UserDefaults
    let usesTemporaryStore: Bool
    let forced: Bool

    func isDue(hasLegacyRows: Bool) -> Bool {
        guard hasLegacyRows || defaults.object(forKey: Self.dictationSwitchKey) != nil else { return false }
        if usesTemporaryStore { return forced }
        return !defaults.bool(forKey: Self.shownKey)
    }

    func markShown() {
        guard !usesTemporaryStore else { return }
        defaults.set(true, forKey: Self.shownKey)
    }
}

/// The dictation rows a 1.x library kept: purged on their frozen horizons at open, after wake and
/// when capture ends, deletable at once from Settings, and announced once.
@MainActor
@Observable
final class LegacyDictationModel {
    struct Client: Sendable {
        var purgeExpired: @Sendable (Date) async throws -> Void
        var hasRows: @Sendable () async throws -> Bool
        var deleteAll: @Sendable () async throws -> Void
        var seedForUITests: @Sendable (Date) async throws -> Void = { _ in }
    }

    private(set) var hasRows = false
    private(set) var deleteFailed = false
    private var noticeHostID: UUID?

    @ObservationIgnored private let client: Client
    @ObservationIgnored private let notice: LegacyDictationNotice
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var noticeIsDue = false
    @ObservationIgnored private var waitingHostID: UUID?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    private static let logger = Logger(subsystem: "app.portavoz.mac", category: "legacy-dictation")

    init(client: Client, notice: LegacyDictationNotice, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.notice = notice
        self.now = now
    }

    /// Once per process. The notice waits for this purge, so rows that just expired do not count.
    func open(observesWake: Bool = true) {
        guard opening == nil else { return }
        opening = Task { [weak self] in
            guard let self else { return }
            do { try await client.seedForUITests(now()) } catch { Self.logger.error("legacy dictation seed failed") }
            await purgeExpired()
            noticeIsDue = notice.isDue(hasLegacyRows: hasRows)
            if let waitingHostID { presentNoticeIfDue(in: waitingHostID) }
        }
        guard observesWake else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeExpiredInBackground() }
        }
    }

    /// Maintenance and wake triggers; a process that never opened, such as a benchmark, stays untouched.
    func purgeExpiredInBackground() {
        guard opening != nil else { return }
        Task(priority: .utility) { await purgeExpired() }
    }

    /// Never shown and never blocking: a failed purge is retried at the next trigger.
    func purgeExpired() async {
        do {
            try await client.purgeExpired(now())
        } catch {
            Self.logger.error("legacy dictation purge failed: \(String(describing: error), privacy: .private)")
        }
        await refresh()
    }

    func deleteAll() async {
        do {
            try await client.deleteAll()
            deleteFailed = false
        } catch {
            deleteFailed = true
            Self.logger.error("legacy dictation delete failed: \(String(describing: error), privacy: .private)")
        }
        await refresh()
    }

    /// The first main window to ask presents the notice, after the opening purge, and marks it shown.
    func claimNotice(in hostID: UUID) async {
        guard let opening else {
            if waitingHostID == nil { waitingHostID = hostID }
            return
        }
        await opening.value
        presentNoticeIfDue(in: hostID)
    }

    func presentsNotice(in hostID: UUID) -> Bool { noticeHostID == hostID }

    func dismissNotice() { noticeHostID = nil }

    private func presentNoticeIfDue(in hostID: UUID) {
        guard noticeIsDue, noticeHostID == nil else { return }
        noticeIsDue = false
        notice.markShown()
        noticeHostID = hostID
    }

    private func refresh() async {
        do {
            hasRows = try await client.hasRows()
        } catch {
            Self.logger.error("legacy dictation read failed: \(String(describing: error), privacy: .private)")
        }
    }
}

extension AppServices {
    static func makeLegacyDictationModel(
        store: MeetingStore, defaults: UserDefaults, arguments: [String], usesTemporaryStore: Bool
    ) -> LegacyDictationModel {
        LegacyDictationModel(
            client: LegacyDictationModel.Client(
                purgeExpired: { try await store.purgeExpiredLegacyDictationData(now: $0) },
                hasRows: { try await !store.legacyDictationRows().isEmpty },
                deleteAll: { try await store.deleteAllLegacyDictationData() },
                seedForUITests: legacyDictationSeed(
                    store: store, arguments: arguments, usesTemporaryStore: usesTemporaryStore)),
            notice: LegacyDictationNotice(
                defaults: defaults, usesTemporaryStore: usesTemporaryStore,
                forced: arguments.contains(LegacyDictationNotice.forceArgument)))
    }

    private static func legacyDictationSeed(
        store: MeetingStore, arguments: [String], usesTemporaryStore: Bool
    ) -> @Sendable (Date) async throws -> Void {
        #if DEBUG
        if usesTemporaryStore, arguments.contains("-seed-legacy-dictation") {
            return { try await store.seedLegacyDictationStatsDayForUITests(now: $0) }
        }
        #endif
        return { _ in }
    }
}
