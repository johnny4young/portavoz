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
    /// path relative to it (D4).
    static var audioRoot: URL { supportRoot }

    let store: MeetingStore
    var modelsState: ModelsState = .unknown
    private(set) var transcriber: ParakeetEngine?
    private(set) var diarizer: PyannoteDiarizer?

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

    /// Downloads (verified) + loads both engines on first use.
    func loadEnginesIfNeeded() async throws {
        if transcriber != nil, diarizer != nil {
            modelsState = .ready
            return
        }
        let modelStore = ModelStore()
        do {
            modelsState = .downloading("Preparando modelos…")
            let engine = try await ParakeetEngine.loadRecommended(store: modelStore) { progress in
                let percent = Int(progress.fraction * 100)
                Task { @MainActor [weak self] in
                    self?.modelsState = .downloading("Descargando modelo de transcripción… \(percent)%")
                }
            }
            let diarizer = try await PyannoteDiarizer.loadRecommended(store: modelStore) { progress in
                let percent = Int(progress.fraction * 100)
                Task { @MainActor [weak self] in
                    self?.modelsState = .downloading("Descargando modelo de diarización… \(percent)%")
                }
            }
            self.transcriber = engine
            self.diarizer = diarizer
            modelsState = .ready
        } catch {
            modelsState = .failed(error.localizedDescription)
            throw error
        }
    }
}
