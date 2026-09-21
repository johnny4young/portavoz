import ApplicationKit
import Foundation
import Observation
import PortavozCore

@MainActor
protocol AudioImportQueueClient: AnyObject {
    func observeAudioImports(offset: Int) -> AsyncThrowingStream<AudioImportQueuePage, Error>
    func admitAudioImports(_ urls: [URL]) async throws
    func makeAudioImportWorker() -> ProcessAudioImports
    func nextAudioImportWake() async throws -> Date?
    func cancelAudioImport(_ id: MeetingID) async throws
    func retryAudioImport(_ id: MeetingID) async throws
    func audioImportWorkFinished()
}

/// One process owner; closing a Library window does not cancel admitted work.
@Observable @MainActor
final class AudioImportQueueModel {
    private(set) var page = AudioImportQueuePage(entries: [], total: 0, unfinished: 0, offset: 0)
    private(set) var currentID: MeetingID?
    private(set) var phase: ImportMeetingProgress?
    private(set) var isAdmitting = false
    private(set) var isDraining = false
    private(set) var error: String?
    private(set) var offset = 0
    private(set) var storageMoveActive = false
    @ObservationIgnored private weak var client: (any AudioImportQueueClient)?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var drain: Task<Void, Never>?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var rerun = false

    init(client: any AudioImportQueueClient) { self.client = client }

    deinit { observation?.cancel(); drain?.cancel(); wake?.cancel() }

    func start() {
        if observation == nil { observePage() }
        kick()
    }

    func admit(_ urls: [URL]) async throws {
        guard let client, !isAdmitting, !storageMoveActive else { throw AudioImportQueueError.busy }
        isAdmitting = true
        defer { isAdmitting = false }
        try await client.admitAudioImports(urls)
        showPage(0)
        kick()
    }

    func showPage(_ next: Int) {
        guard next >= 0 else { return }
        offset = next
        observePage()
    }

    func dismissError() {
        error = nil
        // A failed stream has ended. Resume the read projection so dismissal
        // cannot leave an empty queue with no way to discover admitted work.
        observePage()
    }

    func cancel(_ id: MeetingID) async {
        do {
            try await client?.cancelAudioImport(id)
            if currentID == id {
                rerun = true
                drain?.cancel()
            } else { kick() }
        } catch { self.error = AudioImportQueueError.storage.localizedDescription }
    }

    func retry(_ id: MeetingID) async {
        do {
            try await client?.retryAudioImport(id)
            kick()
        } catch { self.error = AudioImportQueueError.storage.localizedDescription }
    }

    /// Joins native/model cleanup before another owner may start.
    func suspend() async {
        generation += 1
        rerun = false
        wake?.cancel()
        wake = nil
        let current = drain
        current?.cancel()
        await current?.value
        drain = nil
        isDraining = false
        currentID = nil
        phase = nil
    }

    func beginStorageMove() throws {
        guard !storageMoveActive, !isAdmitting, !isDraining, page.unfinished == 0 else {
            throw AudioImportQueueError.busy
        }
        storageMoveActive = true
    }

    func endStorageMove() { storageMoveActive = false; kick() }

    private func observePage() {
        observation?.cancel()
        observationGeneration += 1
        let revision = observationGeneration
        guard let stream = client?.observeAudioImports(offset: offset) else { return }
        observation = Task { [weak self] in
            do {
                for try await page in stream {
                    guard let self, !Task.isCancelled, revision == self.observationGeneration else { return }
                    if page.entries.isEmpty, self.offset > 0 {
                        self.showPage(max(0, self.offset - 20))
                        return
                    }
                    self.page = page
                }
            } catch {
                guard !Task.isCancelled, let self, revision == self.observationGeneration else { return }
                self.error = AudioImportQueueError.storage.localizedDescription
            }
        }
    }

    private func kick() {
        guard !storageMoveActive, let client else { return }
        wake?.cancel()
        wake = nil
        guard drain == nil else { rerun = true; return }
        generation += 1
        let revision = generation
        let worker = client.makeAudioImportWorker()
        rerun = false
        isDraining = true
        drain = Task { [weak self] in
            do {
                _ = try await worker.execute(.init(started: { [weak self] id in
                    await self?.started(id, revision: revision)
                }, progress: { [weak self] id, phase in
                    await self?.progress(id, phase: phase, revision: revision)
                }))
            } catch {
                if !(error is CancellationError), !Task.isCancelled {
                    self?.error = AudioImportQueueError.storage.localizedDescription
                }
            }
            await self?.finished(revision: revision)
        }
    }

    private func started(_ id: MeetingID, revision: Int) {
        guard generation == revision else { return }
        currentID = id
        phase = nil
    }

    private func progress(_ id: MeetingID, phase: ImportMeetingProgress, revision: Int) {
        guard generation == revision, currentID == id else { return }
        self.phase = phase
    }

    private func finished(revision: Int) async {
        guard generation == revision else { return }
        drain = nil
        isDraining = false
        currentID = nil
        phase = nil
        client?.audioImportWorkFinished()
        if rerun { kick(); return }
        do {
            let next = try await client?.nextAudioImportWake()
            guard generation == revision, drain == nil, let next else { return }
            wake = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) } catch { return }
                guard !Task.isCancelled else { return }
                self?.kick()
            }
        } catch { self.error = AudioImportQueueError.storage.localizedDescription }
    }
}

enum AudioImportQueueError: Error, LocalizedError {
    case busy, storage, partialRemoval, selectionLimit, mixedBundles

    var errorDescription: String? {
        switch self {
        case .busy: L10n.text("Audio work is still finishing. Try again shortly.")
        case .storage: L10n.text("The import queue could not be updated. Your original files have not been changed.")
        case .partialRemoval: L10n.text("The meeting was deleted, but some audio files could not be removed.")
        case .mixedBundles: L10n.text("Import a meeting bundle on its own, or choose multiple audio files.")
        case .selectionLimit: L10n.text("Choose between 1 and 1,000 audio files to import.")
        }
    }
}
