import ApplicationKit
import Foundation
import Observation
import PortavozCore

/// The history consent and the loaded pages. Dictation reads the consent
/// generation from here when a session starts; the store revalidates it.
@MainActor
@Observable
final class DictationHistoryModel {
    private(set) var policy = DictationHistoryPolicy.off
    private(set) var isLoaded = false
    private(set) var records: [DictationRecord] = []
    private(set) var hasMore = false
    private(set) var failure: String?
    private(set) var filter = DictationRecordFilter.all
    /// Applications with saved dictations, for the filter menu.
    private(set) var applications: [String] = []
    /// Meetings whose notes hold a copy of each loaded dictation.
    private(set) var meetingLinks: [DictationRecordID: [DictationMeetingLink]] = [:]
    /// Dictations just added to a meeting whose tidied notes hide new raw notes.
    private(set) var needsTidyUp: Set<DictationRecordID> = []
    @ObservationIgnored private let store: any DictationHistoryStore & DictationMeetingNoteStore
    /// Drops a page that arrives after a newer filter was applied.
    @ObservationIgnored private var pageRequest = 0

    init(store: any DictationHistoryStore & DictationMeetingNoteStore) {
        self.store = store
    }

    /// Reads the consent, drops expired rows and loads the newest page.
    func load() async {
        do {
            _ = try await PurgeExpiredDictations(store: store).execute(())
            policy = try await LoadDictationHistoryPolicy(store: store).execute(())
            applications = try await ListDictationApplications(store: store).execute(())
            if let application = filter.applicationName, !applications.contains(application) {
                filter.applicationName = nil
            }
            try await reloadPage()
            isLoaded = true
            failure = nil
        } catch {
            failure = L10n.text("Dictation history could not be loaded.")
        }
    }

    /// Shows the newest page that matches; every filter applies before the page limit.
    func apply(_ filter: DictationRecordFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        do {
            try await reloadPage()
            failure = nil
        } catch {
            failure = L10n.text("Dictation history could not be loaded.")
        }
    }

    /// Shows only this dictation the next time the history loads, as when an
    /// Ask citation opens it.
    func focus(on id: DictationRecordID) {
        filter = DictationRecordFilter(recordID: id)
        records = records.filter { $0.id == id }
    }

    func loadMore() async {
        guard hasMore, let last = records.last else { return }
        let request = pageRequest
        do {
            let page = try await ListDictations(store: store).execute(.init(filter: filter, after: last))
            guard request == pageRequest else { return }
            records += page
            hasMore = page.count == ListDictations.pageSize
            await refreshMeetingLinks()
        } catch {
            failure = L10n.text("Dictation history could not be loaded.")
        }
    }

    private func reloadPage() async throws {
        pageRequest += 1
        let request = pageRequest
        let page = try await ListDictations(store: store).execute(.init(filter: filter))
        guard request == pageRequest else { return }
        records = page
        hasMore = page.count == ListDictations.pageSize
        await refreshMeetingLinks()
    }

    /// Finished meetings for the picker; the one recorded during the dictation first.
    func meetingChoices(for record: DictationRecord) async -> [DictationMeetingChoice] {
        do {
            return try await ListMeetingsForDictation(store: store).execute(record)
        } catch {
            failure = L10n.text("Meetings could not be loaded.")
            return []
        }
    }

    @discardableResult
    func add(_ record: DictationRecord, to meeting: DictationMeetingChoice) async -> AddDictationToMeetingOutcome? {
        do {
            let outcome = try await AddDictationToMeeting(store: store).execute(
                .init(dictationID: record.id, meetingID: meeting.id))
            if case .added(_, let tidiedNotes) = outcome, tidiedNotes { needsTidyUp.insert(record.id) }
            await refreshMeetingLinks()
            return outcome
        } catch {
            failure = L10n.text("The dictation could not be added to the meeting.")
            return nil
        }
    }

    private func refreshMeetingLinks() async {
        meetingLinks = (try? await LoadDictationMeetingLinks(store: store).execute(records.map(\.id))) ?? [:]
    }

    func update(
        isEnabled: Bool? = nil, keepsOriginal: Bool? = nil, retentionDays: Int? = nil, exposesToAgents: Bool? = nil
    ) async {
        let request = UpdateDictationHistoryPolicy.Request(
            isEnabled: isEnabled ?? policy.isEnabled,
            keepsOriginal: keepsOriginal ?? policy.keepsOriginal,
            retentionDays: retentionDays ?? policy.retentionDays,
            exposesToAgents: exposesToAgents ?? policy.exposesToAgents)
        do {
            policy = try await UpdateDictationHistoryPolicy(store: store).execute(request)
            if retentionDays != nil { await load() }
        } catch {
            failure = L10n.text("The history setting could not be saved.")
        }
    }

    func delete(_ id: DictationRecordID) async {
        do {
            if try await DeleteDictation(store: store).execute(id) {
                records.removeAll { $0.id == id }
            }
        } catch {
            failure = L10n.text("The dictation could not be deleted.")
        }
    }

    func deleteAll() async {
        do {
            _ = try await DeleteAllDictations(store: store).execute(())
            records = []
            hasMore = false
            applications = []
            filter = .all
            policy = try await LoadDictationHistoryPolicy(store: store).execute(())
        } catch {
            failure = L10n.text("The dictations could not be deleted.")
        }
    }

    /// Nil unless history is on now; the writer keeps this generation.
    func admit() -> DictationHistoryWriter? {
        guard isLoaded, policy.isEnabled else { return nil }
        let generation = policy.generation
        return { [weak self] record in
            guard let self else { return false }
            return await self.save(record, generation: generation)
        }
    }

    private func save(_ record: DictationRecord, generation: Int) async -> Bool {
        do {
            let outcome = try await RecordDictation(store: store).execute(
                .init(record: record, admittedGeneration: generation))
            if outcome == .saved { show(record) }
            return true
        } catch {
            return false
        }
    }

    private func show(_ record: DictationRecord) {
        if let application = record.applicationName, !applications.contains(application) {
            applications = (applications + [application]).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else if filter.isUnfiltered {
            records.insert(record, at: 0)
        }
    }
}
