import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// The statistics consent and the summary the Dictations page shows.
@MainActor
@Observable
final class DictationStatsModel {
    static let ranges = [7, 30]

    private(set) var isEnabled = false
    private(set) var range = 7
    private(set) var summary = DictationStatsSummary(days: [], topApplications: [])
    private(set) var failure: String?
    @ObservationIgnored private let store: any DictationStatsStore
    @ObservationIgnored private let now: @Sendable () -> Date

    init(store: any DictationStatsStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func load() async {
        do {
            isEnabled = try await LoadDictationStatsConsent(store: store).execute(())
            try await refresh()
            failure = nil
        } catch {
            failure = L10n.text("Dictation statistics could not be loaded.")
        }
    }

    func update(isEnabled: Bool) async {
        do {
            self.isEnabled = try await UpdateDictationStatsConsent(store: store).execute(isEnabled)
            try await refresh()
        } catch {
            failure = L10n.text("The statistics setting could not be saved.")
        }
    }

    func show(range: Int) async {
        guard Self.ranges.contains(range), range != self.range else { return }
        self.range = range
        try? await refresh()
    }

    func deleteAll() async {
        do {
            try await DeleteDictationStats(store: store).execute(())
            try await refresh()
        } catch {
            failure = L10n.text("The statistics could not be deleted.")
        }
    }

    func record(_ sample: DictationStatsSample) {
        let store = store
        let now = now
        Task { [weak self] in
            _ = try? await RecordDictationStats(store: store, now: now).execute(sample)
            try? await self?.refresh()
        }
    }

    private func refresh() async throws {
        summary = try await LoadDictationStatsSummary(store: store, now: now).execute(range)
    }
}

extension AppServices {
    /// Disposable launches can start with statistics on and a week of sample days.
    func loadDictationStats() async {
        let arguments = ProcessInfo.processInfo.arguments
        if usesTemporaryMeetingStore, arguments.contains("-seed-dictation-stats") {
            try? await store.setDictationStatsEnabled(true)
            let calendar = Calendar.current
            let samples = [(0, "Slack", 42), (0, "Mail", 120), (1, "Slack", 18), (3, "Notes", 64)]
            for (offset, sample) in samples.enumerated() {
                let date = calendar.date(byAdding: .day, value: -sample.0, to: Date()) ?? Date()
                _ = try? await store.recordDictationStats(DictationStatsSample(
                    id: DictationRecordID(), day: DictationStatsCalendar.day(of: date, calendar: calendar),
                    words: sample.2, spokenDuration: Double(sample.2) / 2.5, applicationName: sample.1,
                    delivered: offset != 3))
            }
        }
        await dictationStats.load()
    }
}
