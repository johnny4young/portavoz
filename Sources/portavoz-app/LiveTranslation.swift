import PortavozCore
import SwiftUI

enum LiveTranscriptState: Equatable {
    case idle
    case preparing
    case available
    case failed
}

enum LiveTranslationState: Equatable {
    case off
    case waitingForTranscript
    case ready
    case needsDownload
    case translating
    case active
    case unsupported
    case failed
}

#if canImport(Translation)
import Translation

/// Live translated captions (M6): a view modifier that keeps a
/// `TranslationSession` alive while recording and back-fills a
/// translation for every caption that lacks one. The OS may ask to
/// download the language pair on first use — that's the interactive bit
/// pending user verification.
@available(macOS 15.0, *)
struct LiveTranslationModifier: ViewModifier {
    @Bindable var controller: RecordingController

    private var configuration: TranslationSession.Configuration? {
        guard let target = controller.translationTarget else { return nil }
        return TranslationSession.Configuration(
            source: nil,  // auto-detect per caption
            target: Locale.Language(identifier: target)
        )
    }

    /// The SwiftUI overlay hands the session to a MainActor closure, but
    /// its async methods are nonisolated — under Swift 6 that's a region
    /// violation. Confinement: the box only ever lives inside the single
    /// translationTask task and the session is used serially there.
    private struct SessionBox: @unchecked Sendable {
        let session: TranslationSession
    }

    func body(content: Content) -> some View {
        let controller = self.controller
        return content.translationTask(configuration) { session in
            // The framework cancels this task when the configuration
            // changes or the view goes away.
            await Self.translationLoop(box: SessionBox(session: session), controller: controller)
        }
    }

    private typealias Row = (id: UUID, text: String, source: String?)
    private typealias Ready = (id: UUID, text: String)
    private struct Partition {
        let ready: [Ready]
        let needsDownload: Bool
        let hasUnsupportedPair: Bool
        let cache: [String: LanguageAvailability.Status]
    }

    nonisolated private static func translationLoop(
        box: SessionBox, controller: RecordingController
    ) async {
        // Within one task the target is constant (a picker change restarts
        // the translationTask). Cache each source→target availability so the
        // check runs once per language, not once per row every 700 ms.
        guard let target = await MainActor.run(body: { controller.translationTarget })
        else { return }
        let targetLanguage = Locale.Language(identifier: target)
        let availability = LanguageAvailability()
        var statusCache: [String: LanguageAvailability.Status] = [:]
        var didPrepare = false

        while !Task.isCancelled {
            let snapshot = await MainActor.run {
                (controller.translationTarget, controller.translationDownloadApproved)
            }
            guard snapshot.0 == target else { return }
            let approved = snapshot.1
            if approved && !didPrepare {
                guard await Self.prepare(
                    box: box,
                    controller: controller,
                    target: target
                ) else {
                    guard await Self.sleep(milliseconds: 2_000) else { return }
                    continue
                }
                didPrepare = true
            }
            let pending = await Self.pendingRows(controller: controller, target: target)
            if pending.isEmpty {
                await Self.publishIdleState(controller: controller, target: target)
                guard await Self.sleep(milliseconds: 700) else { return }
                continue
            }
            let partition = await Self.partition(
                pending, approved: approved, target: target, targetLanguage: targetLanguage,
                availability: availability, cache: statusCache)
            statusCache = partition.cache
            if partition.needsDownload && !approved {
                await MainActor.run {
                    controller.updateLiveTranslationState(.needsDownload, forTarget: target)
                }
            } else if partition.ready.isEmpty, partition.hasUnsupportedPair {
                await MainActor.run {
                    controller.updateLiveTranslationState(.unsupported, forTarget: target)
                }
            } else if !partition.ready.isEmpty {
                await MainActor.run {
                    controller.updateLiveTranslationState(.translating, forTarget: target)
                }
                let translated = await Self.apply(
                    partition.ready,
                    box: box,
                    controller: controller,
                    target: target)
                await MainActor.run {
                    controller.updateLiveTranslationState(
                        translated ? .active : .failed,
                        forTarget: target)
                }
            }
            let retryDelay = await Self.translatedRetryDelay(controller: controller)
            guard await Self.sleep(milliseconds: retryDelay) else { return }
        }
    }

    nonisolated private static func translatedRetryDelay(
        controller: RecordingController
    ) async -> Int {
        await MainActor.run { controller.translationState == .failed ? 3_000 : 700 }
    }

    nonisolated private static func sleep(milliseconds: Int) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return true
        } catch {
            return false
        }
    }

    nonisolated private static func publishIdleState(
        controller: RecordingController,
        target: String
    ) async {
        await MainActor.run {
            if controller.liveTranscriptState != .available, controller.captions.isEmpty {
                controller.updateLiveTranslationState(.waitingForTranscript, forTarget: target)
            } else if controller.translations.isEmpty {
                controller.updateLiveTranslationState(.ready, forTarget: target)
            } else {
                controller.updateLiveTranslationState(.active, forTarget: target)
            }
        }
    }

    /// Downloads the language assets via Apple's deliberate, expected sheet.
    /// Returns false (and clears approval) if the user cancels, so the loop
    /// falls back to the gated banner instead of auto-presenting the sheet.
    nonisolated private static func prepare(
        box: SessionBox,
        controller: RecordingController,
        target: String
    ) async -> Bool {
        do {
            try await box.session.prepareTranslation()
            return await MainActor.run { controller.translationTarget == target }
        } catch {
            await MainActor.run {
                guard controller.translationTarget == target else { return }
                controller.translationDownloadApproved = false
                controller.updateLiveTranslationState(.failed, forTarget: target)
            }
            return false
        }
    }

    /// The closed, not-yet-translated caption rows. The newest row is still
    /// growing (the coalescer only ever extends the last one), so it's skipped.
    nonisolated private static func pendingRows(
        controller: RecordingController,
        target: String
    ) async -> [Row] {
        await MainActor.run {
            guard controller.translationTarget == target else { return [] }
            let openID = controller.captions.last?.id
            return controller.captions.suffix(60)
                .filter {
                    $0.id != openID
                        && controller.translations[$0.id] == nil
                        && $0.text.count >= 4
                        && $0.language != target
                }
                .map { ($0.id, $0.text, $0.language) }
        }
    }

    /// Splits pending rows into ones whose language pair is installed (safe to
    /// translate now) and flags whether any pair still needs downloading.
    /// Skipping uninstalled pairs is what prevents Apple's sheet from popping
    /// up mid-meeting; once the user approves, every row is translated.
    nonisolated private static func partition(
        _ pending: [Row], approved: Bool, target: String, targetLanguage: Locale.Language,
        availability: LanguageAvailability, cache: [String: LanguageAvailability.Status]
    ) async -> Partition {
        if approved {
            return Partition(
                ready: pending.map { ($0.id, $0.text) },
                needsDownload: false,
                hasUnsupportedPair: false,
                cache: cache)
        }
        var cache = cache
        var ready: [Ready] = []
        var needsDownload = false
        var hasUnsupportedPair = false
        for row in pending {
            let source = row.source ?? Self.likelySource(for: target)
            let status: LanguageAvailability.Status
            if let cached = cache[source] {
                status = cached
            } else {
                status = await availability.status(
                    from: Locale.Language(identifier: source), to: targetLanguage)
                cache[source] = status
            }
            switch status {
            case .installed: ready.append((row.id, row.text))
            case .supported: needsDownload = true  // downloadable, not yet installed
            default: hasUnsupportedPair = true
            }
        }
        return Partition(
            ready: ready,
            needsDownload: needsDownload,
            hasUnsupportedPair: hasUnsupportedPair,
            cache: cache)
    }

    /// Translates the ready rows and stores the results on the controller.
    nonisolated private static func apply(
        _ ready: [Ready],
        box: SessionBox,
        controller: RecordingController,
        target: String
    ) async -> Bool {
        guard !ready.isEmpty else { return true }
        let requests = ready.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
        }
        let responses: [TranslationSession.Response]
        do {
            responses = try await box.session.translations(from: requests)
        } catch {
            return false
        }
        let translated: [UUID: String] = responses.reduce(into: [:]) { values, response in
            guard
                let identifier = response.clientIdentifier,
                let id = UUID(uuidString: identifier)
            else { return }
            values[id] = response.targetText
        }
        return await MainActor.run {
            controller.storeLiveTranslations(translated, forTarget: target)
        }
    }

    /// Best-guess source when a caption has no detected language: the
    /// opposite of the target for the two languages the picker offers, else
    /// the device language. Only used to check availability, never to force a
    /// translation of the wrong pair.
    nonisolated private static func likelySource(for target: String) -> String {
        switch target {
        case "es": return "en"
        case "en": return "es"
        default: return Locale.current.language.languageCode?.identifier ?? "en"
        }
    }
}
#endif

extension View {
    /// Applies live translation when the OS supports it; a no-op earlier.
    @ViewBuilder
    func liveTranslation(_ controller: RecordingController) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            modifier(LiveTranslationModifier(controller: controller))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
