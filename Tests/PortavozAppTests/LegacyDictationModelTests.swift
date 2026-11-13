import Foundation
import GRDB
import Testing

@testable import portavoz_app
@testable import StorageKit

@MainActor
struct LegacyDictationModelTests {
    private final class Calls: @unchecked Sendable {
        let lock = NSLock()
        private var purges: [Date] = []
        var rows = false
        var failsPurge = false

        func purge(_ now: Date) throws {
            lock.withLock { purges.append(now) }
            if failsPurge { throw CancellationError() }
        }

        var purgeCount: Int { lock.withLock { purges.count } }
    }

    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "legacy-dictation-\(UUID().uuidString)")!
    }

    private static func model(
        calls: Calls, defaults: UserDefaults, disposable: Bool = false, forced: Bool = false
    ) -> LegacyDictationModel {
        LegacyDictationModel(
            client: .init(
                purgeExpired: { try calls.purge($0) },
                hasRows: { calls.rows },
                deleteAll: { calls.rows = false }),
            notice: LegacyDictationNotice(defaults: defaults, usesTemporaryStore: disposable, forced: forced))
    }

    @Test
    func aFreshInstallIsNeverToldAndAnUpgradeIsToldOnce() async {
        let fresh = Self.defaults()
        let calls = Calls()
        let first = Self.model(calls: calls, defaults: fresh)
        first.open(observesWake: false)
        await first.claimNotice(in: UUID())
        #expect(calls.purgeCount == 1, "opening purges before deciding")
        #expect(fresh.object(forKey: LegacyDictationNotice.shownKey) == nil)

        for used in [(rows: true, switchSet: false), (rows: false, switchSet: true)] {
            let defaults = Self.defaults()
            if used.switchSet { defaults.set(false, forKey: LegacyDictationNotice.dictationSwitchKey) }
            let upgraded = Calls()
            upgraded.rows = used.rows
            let host = UUID()
            let launch = Self.model(calls: upgraded, defaults: defaults)
            launch.open(observesWake: false)
            await launch.claimNotice(in: host)
            #expect(launch.presentsNotice(in: host))
            #expect(!launch.presentsNotice(in: UUID()), "one window presents it")
            launch.dismissNotice()
            #expect(!launch.presentsNotice(in: host))

            let relaunch = Self.model(calls: upgraded, defaults: defaults)
            relaunch.open(observesWake: false)
            await relaunch.claimNotice(in: host)
            #expect(!relaunch.presentsNotice(in: host), "shown once across launches")
        }
    }

    @Test
    func aWindowThatAsksBeforeLaunchOpensStillPresentsTheNotice() async {
        let calls = Calls()
        calls.rows = true
        let early = UUID()
        let model = Self.model(calls: calls, defaults: Self.defaults())
        await model.claimNotice(in: early)
        #expect(!model.presentsNotice(in: early), "nothing is decided before the opening purge")
        model.open(observesWake: false)
        await model.claimNotice(in: UUID())
        #expect(model.presentsNotice(in: early))
    }

    @Test
    func aDisposableLibraryIsToldOnlyWhenForcedAndNeverRemembersIt() async {
        let defaults = Self.defaults()
        let calls = Calls()
        calls.rows = true
        let host = UUID()
        let plain = Self.model(calls: calls, defaults: defaults, disposable: true)
        plain.open(observesWake: false)
        await plain.claimNotice(in: host)
        #expect(!plain.presentsNotice(in: host))

        let forced = Self.model(calls: calls, defaults: defaults, disposable: true, forced: true)
        forced.open(observesWake: false)
        await forced.claimNotice(in: host)
        #expect(forced.presentsNotice(in: host))
        #expect(defaults.object(forKey: LegacyDictationNotice.shownKey) == nil)
    }

    @Test
    func aFailedPurgeNeitherBlocksTheNoticeNorTheRowsAndMaintenanceWaitsForOpen() async {
        let calls = Calls()
        calls.rows = true
        calls.failsPurge = true
        let model = Self.model(calls: calls, defaults: Self.defaults())
        model.purgeExpiredInBackground()
        await Task.yield()
        #expect(calls.purgeCount == 0, "a process that never opened is left alone")

        let host = UUID()
        model.open(observesWake: false)
        await model.claimNotice(in: host)
        #expect(model.hasRows)
        #expect(model.presentsNotice(in: host))

        await model.deleteAll()
        #expect(!model.hasRows)
        #expect(!model.deleteFailed)
    }

    @Test
    func theStoreClientPurgesExpiredRowsAndDeletesTheRest() async throws {
        let store = try MeetingStore.inMemory()
        let now = Date()
        try await store.database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictationStatsDay (day, applicationName, dictations, words, spokenMs, notDelivered)
                    VALUES ('2000-01-01', 'Notes', 1, 3, 1200, 0)
                    """)
        }
        try await store.seedLegacyDictationStatsDayForUITests(now: now)
        let model = AppServices.makeLegacyDictationModel(
            store: store, defaults: Self.defaults(), arguments: [], usesTemporaryStore: false)
        model.open(observesWake: false)
        await model.claimNotice(in: UUID())
        #expect(try await store.legacyDictationRows().statsDays == 1, "only the expired day went")
        #expect(model.hasRows)

        await model.deleteAll()
        #expect(try await store.legacyDictationRows().isEmpty)
        #expect(!model.hasRows)
    }
}
