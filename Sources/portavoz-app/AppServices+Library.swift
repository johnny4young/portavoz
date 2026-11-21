import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

extension AppServices {
    /// Creates one presentation model per Library window. AppServices stays
    /// the composition root while StorageKit observation stays private.
    func makeLibraryModel(
        searchDelay: Duration = .milliseconds(250)
    ) -> LibraryModel {
        LibraryModel(client: self, searchDelay: searchDelay)
    }
}

extension AppServices: LibraryModelClient {
    func observeLibrary() -> AsyncStream<LibraryUpdate> {
        let store = store
        return makeApplicationLibraryStream(
            meetings: store.observeLibraryMeetings(),
            openItems: store.observeLibraryOpenItems(),
            trash: store.observeLibraryTrash(),
            storeVoiceColumns: { ids in
                // Chunked so filling an upgraded library never holds the writer for long.
                for start in stride(from: 0, to: ids.count, by: 50) where !Task.isCancelled {
                    _ = try? await store.voiceColumns(for: Array(ids[start..<min(ids.count, start + 50)]))
                }
            })
    }

    func observeLibrarySearch(
        _ query: String
    ) -> AsyncThrowingStream<[LibrarySearchHit], Error> {
        let queries = BilingualSearchQueryExpander().expand(query)
        let lexicalStream = store.observeLibrarySearch(queries)
        let semanticSearch = librarySemanticSearch
        let allowSemantic: Bool
        if case .recording = recording.phase {
            allowSemantic = false
        } else {
            allowSemantic = true
        }
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let semanticTask = Task {
                    guard allowSemantic else { return [LibrarySearchHit]() }
                    guard let hits = try? await semanticSearch.search(query) else {
                        return []
                    }
                    return hits.map(makeApplicationSearchHit)
                }
                defer { semanticTask.cancel() }
                do {
                    var semanticHits: [LibrarySearchHit]?
                    for try await lexical in lexicalStream {
                        let lexicalHits = lexical.map(makeApplicationSearchHit)
                        continuation.yield(lexicalHits)
                        if semanticHits == nil {
                            semanticHits = await semanticTask.value
                        }
                        continuation.yield(fuseLibrarySearch(
                            lexical: lexicalHits,
                            semantic: semanticHits ?? [],
                            limit: 20))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func renameLibraryMeeting(_ meeting: Meeting) async throws {
        defer { requestSearchReconciliation() }
        try await store.save(meeting)
    }

    func setLibraryActionItem(_ id: UUID, done: Bool) async throws {
        defer { requestSearchReconciliation() }
        try await store.setActionItem(id, done: done)
    }

    func deleteLibraryMeeting(_ id: MeetingID) async throws {
        try await audioImportUITestFixture?.beforeLibraryDeletion()
        defer { requestSearchReconciliation() }
        try await meetingLifecycle.delete(id)
    }

    func restoreLibraryMeeting(_ id: MeetingID) async throws {
        defer { requestSearchReconciliation() }
        do {
            try await meetingLifecycle.restore(id)
        } catch AudioImportFileError.acquisitionBusy {
            // Same localized contention copy as purge, never a raw enum description.
            throw AudioImportQueueError.busy
        }
        audioImports.start()
    }

    func purgeLibraryMeeting(_ entry: LibraryTrashItem) async throws {
        try await purgeMeeting(meetingID: entry.meeting.id)
    }

    func enqueueLibraryAudio(_ urls: [URL]) async throws {
        try await audioImports.admit(urls)
    }

    func importLibraryFile(
        _ url: URL,
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> MeetingID {
        if url.pathExtension.lowercased() == MeetingBundle.fileExtension {
            return try await importBundle(from: url)
        }
        throw AudioImportQueueError.selectionLimit
    }

    func libraryAgenda() -> LibraryModel.Agenda? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-seed-brief") {
            return LibraryModel.Agenda(
                offerCalendar: false,
                today: [UpcomingEvent(
                    id: "ui-test-upcoming-rollout",
                    title: "Presupuesto rollout",
                    startDate: Self.fixtureAgendaStart.addingTimeInterval(15 * 60),
                    attendees: ["Ana"])],
                tomorrow: [])
        }
        // Opt-in, because agenda rows lengthen the sidebar and the other
        // showcase journeys assert on a meeting row being reachable there.
        if arguments.contains("-seed-showcase-agenda") {
            return Self.showcaseAgenda()
        }
        guard !ProcessInfo.processInfo.arguments.contains("-use-temp-store") else {
            return nil
        }
        let events = CalendarAttendeeSource().upcomingEvents()
        let startOfTomorrow = Calendar.current.startOfDay(
            for: Date().addingTimeInterval(24 * 3_600))
        return LibraryModel.Agenda(
            offerCalendar: CalendarAttendeeSource.accessUndetermined,
            today: events.filter { $0.startDate < startOfTomorrow },
            tomorrow: events.filter { $0.startDate >= startOfTomorrow })
    }

    func requestLibraryCalendarAccess() async {
        _ = await CalendarAttendeeSource.requestAccess()
    }

    func buildLibraryBrief(for event: UpcomingEvent) async -> MeetingBrief? {
        try? await meetingBriefUseCase.execute(event)
    }

    func libraryBriefLines(for event: UpcomingEvent) async throws -> MeetingBriefLines? {
        try await meetingBriefLinesUseCase.execute(event)
    }

    func pendingLibraryAutomations() async -> Int {
        (try? await loadSkillOfferReview())?.offers.count ?? 0
    }
}

private func makeApplicationLibraryStream(
    meetings: AsyncThrowingStream<MeetingStore.LibraryMeetingRows, Error>,
    openItems: AsyncThrowingStream<[MeetingStore.OpenActionItem], Error>,
    trash: AsyncThrowingStream<[MeetingStore.DeletedMeeting], Error>,
    storeVoiceColumns: @escaping @Sendable ([MeetingID]) async -> Void
) -> AsyncStream<LibraryUpdate> {
    AsyncStream { continuation in
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                // Stored off the meetings loop, so a long backfill never holds back sidebar updates.
                let (uncachedBatches, uncachedSink) = AsyncStream.makeStream(of: [MeetingID].self)
                group.addTask {
                    for await ids in uncachedBatches { await storeVoiceColumns(ids) }
                }
                group.addTask {
                    defer { uncachedSink.finish() }
                    do {
                        // Queued once while uncached: a failed rebuild is not retried on every
                        // refresh, and a meeting dropped again later is queued again.
                        var queued = Set<MeetingID>()
                        for try await value in meetings {
                            continuation.yield(.meetings(
                                makeApplicationMeetingRows(value.rows),
                                failures: value.failures))
                            let uncached = value.uncachedVoiceColumns.filter { !queued.contains($0) }
                            queued = Set(value.uncachedVoiceColumns)
                            if !uncached.isEmpty { uncachedSink.yield(uncached) }
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.meetings))
                    }
                }
                group.addTask {
                    do {
                        for try await value in openItems {
                            continuation.yield(.openItems(
                                value.map(makeApplicationOpenItem)))
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.openItems))
                    }
                }
                group.addTask {
                    do {
                        for try await value in trash {
                            continuation.yield(.trash(
                                value.map(makeApplicationTrashItem)))
                        }
                    } catch is CancellationError {
                        // Parent cancellation ends the complete merged stream.
                    } catch {
                        continuation.yield(.failed(.trash))
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

private func makeApplicationMeetingRows(
    _ rows: [MeetingStore.LibraryMeetingRow]
) -> [LibraryMeetingRow] {
    rows.map { row in
        LibraryMeetingRow(
            meeting: row.meeting,
            voiceStrip: row.voiceColumns.map(VoiceStripColumns.init(columns:)) ?? .empty)
    }
}

private func makeApplicationOpenItem(
    _ item: MeetingStore.OpenActionItem
) -> LibraryOpenItem {
    LibraryOpenItem(
        meetingID: item.meetingID,
        meetingTitle: item.meetingTitle,
        item: item.item)
}

private func makeApplicationTrashItem(
    _ item: MeetingStore.DeletedMeeting
) -> LibraryTrashItem {
    LibraryTrashItem(meeting: item.meeting, deletedAt: item.deletedAt)
}

private func makeApplicationSearchHit(_ hit: SearchHit) -> LibrarySearchHit {
    LibrarySearchHit(
        meetingID: hit.meetingID,
        meetingTitle: hit.meetingTitle,
        segmentID: hit.segmentID,
        sourceSegmentIDs: hit.sourceSegmentIDs,
        snippet: hit.snippet,
        startTime: hit.startTime)
}

private func fuseLibrarySearch(
    lexical: [LibrarySearchHit],
    semantic: [LibrarySearchHit],
    limit: Int
) -> [LibrarySearchHit] {
    let orderedIDs = LibrarySearchFusion.exactFirst(
        lexical: lexical.map(\.segmentID),
        semantic: semantic.map(\.segmentID),
        limit: limit)
    var hits: [UUID: LibrarySearchHit] = [:]
    for hit in semantic { hits[hit.segmentID] = hit }
    for hit in lexical { hits[hit.segmentID] = hit }
    return orderedIDs.compactMap { hits[$0] }
}
