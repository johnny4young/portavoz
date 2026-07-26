import NaturalLanguage
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
    case partiallyUnsupported
    case failed

    /// Only states that need explanatory UI expose copy. Execution failures
    /// remain visible while the translation loop backs off and retries.
    var statusMessageKey: String? {
        switch self {
        case .waitingForTranscript:
            "Live translation will start as soon as captions are available."
        case .unsupported:
            "Apple Translation does not support this language pair on this Mac."
        case .partiallyUnsupported:
            """
            Some captions stay in their original language because Apple Translation \
            does not support their language pair on this Mac.
            """
        case .failed:
            "Live translation paused after an error. Retrying automatically…"
        case .off, .ready, .needsDownload, .translating, .active:
            nil
        }
    }

    /// The live-captions failure banner owns terminal model-load failures.
    /// Keeping the translation waiting banner beside it would promise that
    /// captions can still arrive during a recording where they cannot.
    func shouldPresentStatus(liveTranscriptState: LiveTranscriptState) -> Bool {
        switch self {
        case .waitingForTranscript:
            liveTranscriptState != .failed
        case .unsupported, .partiallyUnsupported, .failed:
            true
        case .off, .ready, .needsDownload, .translating, .active:
            false
        }
    }
}

/// One explicit source→target lane. Apple Translation presents a source
/// picker when a session uses `source: nil` and automatic detection is
/// uncertain. Live meetings cannot tolerate that modal on every short turn,
/// so Portavoz resolves each closed caption locally and creates a concrete
/// session for that language only.
struct LiveTranslationPair: Equatable, Sendable {
    let source: String
    let target: String
}

enum LiveTranslationRouting {
    typealias LanguageDetector = (String) -> String?

    static func nextPair(
        segments: [TranscriptSegment],
        handledIDs: Set<UUID>,
        target: String,
        detector: LanguageDetector = detectedLanguage
    ) -> LiveTranslationPair? {
        guard let normalizedTarget = LanguageCode(target)?.identifier else { return nil }
        let openID = segments.last?.id
        for segment in segments.suffix(60) where segment.id != openID {
            guard !handledIDs.contains(segment.id), segment.text.count >= 4,
                let source = sourceLanguage(for: segment, detector: detector),
                source != normalizedTarget
            else { continue }
            return LiveTranslationPair(source: source, target: normalizedTarget)
        }
        return nil
    }

    static func pendingRows(
        segments: [TranscriptSegment],
        handledIDs: Set<UUID>,
        pair: LiveTranslationPair,
        detector: LanguageDetector = detectedLanguage
    ) -> [(id: UUID, text: String)] {
        let openID = segments.last?.id
        return segments.suffix(60).compactMap { segment in
            guard segment.id != openID,
                !handledIDs.contains(segment.id),
                segment.text.count >= 4,
                sourceLanguage(for: segment, detector: detector) == pair.source
            else { return nil }
            return (segment.id, segment.text)
        }
    }

    static func sourceLanguage(
        for segment: TranscriptSegment,
        detector: LanguageDetector = detectedLanguage
    ) -> String? {
        if let explicit = LanguageCode(segment.language)?.identifier {
            return explicit
        }
        guard hasEnoughLanguageEvidence(segment.text) else { return nil }
        return LanguageCode(detector(segment.text))?.identifier
    }

    /// Short or low-confidence rows stay in their spoken language. Guessing
    /// would either translate English into English or revive Apple's modal.
    static func detectedLanguage(_ text: String) -> String? {
        guard hasEnoughLanguageEvidence(text) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let candidate = recognizer.languageHypotheses(withMaximum: 1).first,
            candidate.value >= 0.65
        else { return nil }
        return LanguageCode(candidate.key.rawValue)?.identifier
    }

    private static func hasEnoughLanguageEvidence(_ text: String) -> Bool {
        let letterCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) { count += 1 }
        }
        return letterCount >= 12
    }
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

    private var pair: LiveTranslationPair? {
        guard let target = controller.translationTarget else { return nil }
        return LiveTranslationRouting.nextPair(
            segments: controller.captions,
            handledIDs: controller.liveTranslationHandledIDs,
            target: target)
    }

    private func configuration(
        for pair: LiveTranslationPair?
    ) -> TranslationSession.Configuration? {
        guard let pair else { return nil }
        return TranslationSession.Configuration(
            source: Locale.Language(identifier: pair.source),
            target: Locale.Language(identifier: pair.target)
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
        let pair = self.pair
        return content.translationTask(configuration(for: pair)) { session in
            guard let pair else { return }
            // The framework cancels this task when the configuration
            // changes or the view goes away.
            await Self.translationLoop(
                box: SessionBox(session: session),
                controller: controller,
                pair: pair)
        }
    }

    private typealias Ready = (id: UUID, text: String)

    nonisolated private static func translationLoop(
        box: SessionBox,
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async {
        guard let status = await Self.openLane(controller: controller, pair: pair)
        else { return }
        var didPrepare = false

        while !Task.isCancelled {
            let snapshot = await MainActor.run {
                (
                    controller.translationTarget,
                    controller.translationSource,
                    controller.translationDownloadApproved
                )
            }
            guard snapshot.0 == pair.target, snapshot.1 == pair.source else { return }
            let approved = snapshot.2
            if status == .supported, !approved {
                await MainActor.run {
                    controller.updateLiveTranslationState(.needsDownload, for: pair)
                }
                guard await Self.sleep(milliseconds: 700) else { return }
                continue
            }
            if status == .supported, approved, !didPrepare {
                guard await Self.prepare(
                    box: box,
                    controller: controller,
                    pair: pair
                ) else {
                    guard await Self.sleep(milliseconds: 2_000) else { return }
                    continue
                }
                didPrepare = true
            }
            let pending = await Self.pendingRows(controller: controller, pair: pair)
            if pending.isEmpty {
                // Idle is not the end of the lane. `translationTask` only
                // re-runs when the CONFIGURATION changes, and a lull whose
                // next caption is the same language produces an identical
                // configuration — returning here would strand that lane
                // until someone spoke a different language. The guard at the
                // top of the loop is what ends a lane the controller has
                // moved on from.
                await Self.publishIdleState(controller: controller, pair: pair)
                guard await Self.sleep(milliseconds: 700) else { return }
                continue
            }
            await MainActor.run {
                controller.updateLiveTranslationState(.translating, for: pair)
            }
            let translated = await Self.apply(
                pending,
                box: box,
                controller: controller,
                pair: pair)
            await MainActor.run {
                controller.updateLiveTranslationState(
                    translated ? .active : .failed, for: pair)
            }
            let retryDelay = await Self.translatedRetryDelay(controller: controller)
            guard await Self.sleep(milliseconds: retryDelay) else { return }
        }
    }

    /// Claims the lane and resolves whether Apple Translation can serve it.
    /// nil means the pair is unsupported on this Mac and the loop must not
    /// start — the UI already carries that explanation.
    nonisolated private static func openLane(
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> LanguageAvailability.Status? {
        await MainActor.run { controller.beginLiveTranslationPair(pair) }
        // Keep the receiver named: ArchitectureDependencyTests pins this call
        // shape so `status` can never regress to `try? await`, which would
        // swallow the unsupported-pair answer instead of surfacing it.
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: pair.source),
            to: Locale.Language(identifier: pair.target))
        guard status != .unsupported else {
            let pending = await pendingRows(controller: controller, pair: pair)
            await MainActor.run {
                if pending.isEmpty {
                    controller.updateLiveTranslationState(.unsupported, for: pair)
                } else {
                    controller.markUnsupportedLiveTranslationRows(
                        Set(pending.map(\.id)),
                        for: pair)
                }
            }
            return nil
        }
        return status
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
        pair: LiveTranslationPair
    ) async {
        await MainActor.run {
            if controller.liveTranscriptState != .available, controller.captions.isEmpty {
                controller.updateLiveTranslationState(.waitingForTranscript, for: pair)
            } else if controller.translations.isEmpty {
                controller.updateLiveTranslationState(.ready, for: pair)
            } else {
                controller.updateLiveTranslationState(.active, for: pair)
            }
        }
    }

    /// Downloads the language assets via Apple's deliberate, expected sheet.
    /// Returns false (and clears approval) if the user cancels, so the loop
    /// falls back to the gated banner instead of auto-presenting the sheet.
    nonisolated private static func prepare(
        box: SessionBox,
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> Bool {
        do {
            try await box.session.prepareTranslation()
            return await MainActor.run {
                controller.translationTarget == pair.target
                    && controller.translationSource == pair.source
            }
        } catch {
            await MainActor.run {
                guard controller.translationTarget == pair.target,
                    controller.translationSource == pair.source
                else { return }
                controller.translationDownloadApproved = false
                controller.updateLiveTranslationState(.failed, for: pair)
            }
            return false
        }
    }

    /// The closed, not-yet-translated caption rows. The newest row is still
    /// growing (the coalescer only ever extends the last one), so it's skipped.
    nonisolated private static func pendingRows(
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> [Ready] {
        await MainActor.run {
            guard controller.translationTarget == pair.target,
                controller.translationSource == pair.source
            else { return [] }
            return LiveTranslationRouting.pendingRows(
                segments: controller.captions,
                handledIDs: controller.liveTranslationHandledIDs,
                pair: pair)
        }
    }

    /// Translates the ready rows and stores the results on the controller.
    nonisolated private static func apply(
        _ ready: [Ready],
        box: SessionBox,
        controller: RecordingController,
        pair: LiveTranslationPair
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
            controller.storeLiveTranslations(translated, for: pair)
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
