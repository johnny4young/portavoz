import DiarizationKit
import Foundation
import ModelStoreKit
import Observation
import PortavozCore
import StorageKit
import SwiftUI
import TranscriptionKit

/// Composition root: the database, the ML engines (loaded once, shared by
/// every recording), and cross-view invalidation. Lives on the main actor;
/// the engines themselves do their work off it.
@MainActor
@Observable
final class AppServices {
    enum ModelsState: Equatable {
        case unknown
        case downloading(String)
        case ready
        case failed(String)
    }

    /// `~/Library/Application Support/Portavoz`
    static var supportRoot: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support")
        return base.appendingPathComponent("Portavoz", isDirectory: true)
    }

    /// Meeting audio lives under here; the database only ever stores the
    /// path relative to it (D4). The user can point it elsewhere in
    /// Ajustes → Grabaciones; reads should go through
    /// `RecordingsLocation.shared.resolve(_:)` for the old-root fallback.
    static var audioRoot: URL { RecordingsLocation.shared.currentRoot() }

    let store: MeetingStore
    var modelsState: ModelsState = .unknown
    private(set) var transcriber: ParakeetEngine?
    private(set) var diarizer: PyannoteDiarizer?
    private(set) var whisper: WhisperEngine?

    /// Bumped after any write so list/detail views know to reload.
    var libraryVersion = 0

    init() {
        do {
            store = try MeetingStore(databaseURL: MeetingStore.defaultDatabaseURL)
        } catch {
            // No database, no app — surfacing a broken half-UI would be
            // worse than failing loudly at launch.
            fatalError("cannot open the Portavoz database: \(error)")
        }
    }

    /// Downloads (verified) + loads both engines on first use. The
    /// diarizer carries the enrolled voiceprint when one exists.
    func loadEnginesIfNeeded() async throws {
        if transcriber != nil, diarizer != nil {
            modelsState = .ready
            return
        }
        let modelStore = ModelStore()
        do {
            modelsState = .downloading("Preparando modelos…")
            if transcriber == nil {
                transcriber = try await ParakeetEngine.loadRecommended(store: modelStore) { progress in
                    let percent = Int(progress.fraction * 100)
                    Task { @MainActor [weak self] in
                        self?.modelsState = .downloading("Descargando modelo de transcripción… \(percent)%")
                    }
                }
            }
            if diarizer == nil {
                let voiceprint = (try? VoiceprintStore().load()) ?? nil
                diarizer = try await PyannoteDiarizer.loadRecommended(
                    store: modelStore, voiceprint: voiceprint
                ) { progress in
                    let percent = Int(progress.fraction * 100)
                    Task { @MainActor [weak self] in
                        self?.modelsState = .downloading("Descargando modelo de diarización… \(percent)%")
                    }
                }
            }
            modelsState = .ready
        } catch {
            modelsState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// The D7 quality re-pass engine (Whisper large-v3-turbo, 1.6 GB,
    /// sha256-verified) — loaded on the first refine, then shared.
    func loadWhisperIfNeeded(
        progress: @escaping @MainActor (String) -> Void
    ) async throws -> WhisperEngine {
        if let whisper { return whisper }
        let engine = try await WhisperEngine.loadRecommended(store: ModelStore()) { update in
            guard update.totalBytes > 0 else { return }
            let percent = Int(update.fraction * 100)
            Task { @MainActor in
                progress("Descargando Whisper (1.6 GB, solo una vez)… \(percent)%")
            }
        }
        whisper = engine
        return engine
    }

    /// Called after enrolling/deleting the voiceprint so the next load
    /// rebuilds the diarizer with the new identity state.
    func invalidateDiarizer() {
        diarizer = nil
    }
}
