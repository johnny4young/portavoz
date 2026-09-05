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

enum LiveTranslationWorkPolicy {
    /// Live translation is intentionally a recent-context aid. If a lane is
    /// unavailable long enough to fall behind, older rows stay visible in
    /// their spoken language instead of creating an unbounded catch-up queue.
    static let recentRowLimit = 60

    /// Small batches publish the first translated row quickly and let a
    /// source/target change cancel between bounded framework calls.
    static let maximumBatchSize = 8
}

enum LiveTranslationAssetReadiness: Equatable, Sendable {
    case installed
    case downloadable
    case unsupported
}

enum LiveTranslationLaneAction: Equatable, Sendable {
    case translate
    case requestDownloadConsent
    case prepareAssets
    case passthroughUnsupported
}

/// Pure pair/asset state machine. Approval is scoped to one lane and never
/// survives a source or target transition; installed assets need no prompt on
/// the next recording or after relaunch.
enum LiveTranslationAssetPolicy {
    static func action(
        readiness: LiveTranslationAssetReadiness,
        downloadApproved: Bool,
        preparedInThisLane: Bool
    ) -> LiveTranslationLaneAction {
        switch readiness {
        case .installed:
            .translate
        case .downloadable where preparedInThisLane:
            .translate
        case .downloadable where downloadApproved:
            .prepareAssets
        case .downloadable:
            .requestDownloadConsent
        case .unsupported:
            .passthroughUnsupported
        }
    }
}

enum LiveTranslationRetryPolicy {
    static let maximumDelayMilliseconds = 8_000

    /// Deterministic exponential backoff prevents an offline or failed local
    /// provider from becoming a tight loop. Cancellation still interrupts the
    /// sleep immediately when the lane or recording closes.
    static func delayMilliseconds(afterFailure failureCount: Int) -> Int {
        let exponent = min(max(failureCount - 1, 0), 3)
        return min(1_000 << exponent, maximumDelayMilliseconds)
    }
}

private enum LiveTranslationBatchOutcome {
    case cancelled
    case completed
    case partial
    case failed
}

private enum LiveTranslationReadinessOutcome {
    case ready(prepared: Bool)
    case waitForWake
    case retry
    case stop
}

enum LiveTranslationRouting {
    typealias LanguageDetector = (String) -> String?

    static func nextPair(
        segments: [TranscriptSegment],
        translatedSourceTexts: [UUID: String],
        unsupportedIDs: Set<UUID>,
        target: String,
        detector: LanguageDetector = detectedLanguage
    ) -> LiveTranslationPair? {
        guard let normalizedTarget = LanguageCode(target)?.identifier else { return nil }
        let recent = Array(segments.suffix(
            LiveTranslationWorkPolicy.recentRowLimit))
        let openID = recent.last?.id
        for segment in recent {
            guard needsTranslation(
                segment,
                openID: openID,
                translatedSourceText: translatedSourceTexts[segment.id],
                unsupportedIDs: unsupportedIDs),
                let source = sourceLanguage(for: segment, detector: detector),
                source != normalizedTarget
            else { continue }
            return LiveTranslationPair(source: source, target: normalizedTarget)
        }
        return nil
    }

    static func pendingRows(
        segments: [TranscriptSegment],
        translatedSourceTexts: [UUID: String],
        unsupportedIDs: Set<UUID>,
        pair: LiveTranslationPair,
        detector: LanguageDetector = detectedLanguage
    ) -> [(id: UUID, text: String)] {
        let recent = Array(segments.suffix(
            LiveTranslationWorkPolicy.recentRowLimit))
        let openID = recent.last?.id
        return Array(recent.compactMap { segment in
            guard needsTranslation(
                segment,
                openID: openID,
                translatedSourceText: translatedSourceTexts[segment.id],
                unsupportedIDs: unsupportedIDs),
                sourceLanguage(for: segment, detector: detector) == pair.source
            else { return nil }
            return (segment.id, segment.text)
        }.prefix(LiveTranslationWorkPolicy.maximumBatchSize))
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

    /// Closed rows translate on every changed revision. The single growing
    /// row translates once it carries enough language evidence, then refreshes
    /// after a meaningful chunk or sentence boundary. This gives long turns
    /// near-real-time feedback without sending every partial token to Apple.
    private static func needsTranslation(
        _ segment: TranscriptSegment,
        openID: UUID?,
        translatedSourceText: String?,
        unsupportedIDs: Set<UUID>
    ) -> Bool {
        guard !unsupportedIDs.contains(segment.id), segment.text.count >= 4 else {
            return false
        }
        guard translatedSourceText != segment.text else { return false }
        guard segment.id == openID else { return true }
        guard hasEnoughLanguageEvidence(segment.text) else { return false }
        guard let translatedSourceText else { return true }
        let growth = segment.text.count - translatedSourceText.count
        return growth >= 18 || endsAtSentenceBoundary(segment.text)
    }

    private static func endsAtSentenceBoundary(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?。！？".contains(last)
    }
}

struct LiveTranslationAdmittedResults: Equatable, Sendable {
    let values: [UUID: String]
    let sourceTexts: [UUID: String]
}

/// Final source-revision ownership for asynchronous Translation responses.
/// Pair equality alone is insufficient because the newest row can grow under
/// one stable UUID while an older request is still in flight.
enum LiveTranslationResultAdmission {
    static func admit(
        values: [UUID: String],
        sourceTexts: [UUID: String],
        currentSegments: [TranscriptSegment],
        pair: LiveTranslationPair
    ) -> LiveTranslationAdmittedResults {
        var currentByID: [UUID: TranscriptSegment] = [:]
        var duplicateIDs: Set<UUID> = []
        for segment in currentSegments {
            let previous = currentByID.updateValue(segment, forKey: segment.id)
            if previous != nil {
                duplicateIDs.insert(segment.id)
            }
        }
        var admittedValues: [UUID: String] = [:]
        var admittedSources: [UUID: String] = [:]
        for (id, value) in values {
            guard let requestedSource = sourceTexts[id],
                !duplicateIDs.contains(id),
                let current = currentByID[id],
                current.text == requestedSource,
                LiveTranslationRouting.sourceLanguage(for: current) == pair.source,
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            admittedValues[id] = value
            admittedSources[id] = requestedSource
        }
        return LiveTranslationAdmittedResults(
            values: admittedValues,
            sourceTexts: admittedSources)
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
            translatedSourceTexts: controller.translatedSourceTexts,
            unsupportedIDs: controller.unsupportedTranslationRowIDs,
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
        let wakeHub = controller.liveTranslationWakeHub
        return content.translationTask(configuration(for: pair)) { session in
            guard let pair else { return }
            // The framework cancels this task when the configuration
            // changes or the view goes away.
            await Self.translationLoop(
                box: SessionBox(session: session),
                controller: controller,
                pair: pair,
                wakeHub: wakeHub)
        }
    }

    private typealias Ready = (id: UUID, text: String)

    nonisolated private static func translationLoop(
        box: SessionBox,
        controller: RecordingController,
        pair: LiveTranslationPair,
        wakeHub: LiveTranslationWakeHub
    ) async {
        let subscription = wakeHub.subscribe()
        defer { subscription.cancel() }
        guard let readiness = await Self.openLane(controller: controller, pair: pair) else { return }
        if readiness == .unsupported {
            await Self.holdUnsupportedLane(
                controller: controller,
                pair: pair,
                wakes: subscription.stream)
            return
        }
        var didPrepare = false
        var consecutiveFailures = 0
        var wakes = subscription.stream.makeAsyncIterator()

        while !Task.isCancelled {
            let snapshot = await Self.laneSnapshot(controller: controller)
            guard !Task.isCancelled, snapshot.0 == pair.target, snapshot.1 == pair.source else { return }
            let readinessOutcome = await Self.advanceLaneReadiness(
                readiness: readiness,
                downloadApproved: snapshot.2,
                preparedInThisLane: didPrepare,
                box: box,
                controller: controller,
                pair: pair)
            switch readinessOutcome {
            case .ready(let prepared):
                didPrepare = prepared
            case .waitForWake:
                guard await wakes.next() != nil else { return }
                continue
            case .retry:
                continue
            case .stop:
                return
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
                guard await wakes.next() != nil else { return }
                continue
            }
            await MainActor.run {
                controller.updateLiveTranslationState(.translating, for: pair)
            }
            let outcome = await Self.apply(
                pending,
                box: box,
                controller: controller,
                pair: pair)
            guard let updatedFailureCount = await Self.handleBatchOutcome(
                outcome,
                consecutiveFailures: consecutiveFailures,
                controller: controller,
                pair: pair)
            else { return }
            consecutiveFailures = updatedFailureCount
        }
    }

    nonisolated private static func advanceLaneReadiness(
        readiness: LiveTranslationAssetReadiness,
        downloadApproved: Bool,
        preparedInThisLane: Bool,
        box: SessionBox,
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> LiveTranslationReadinessOutcome {
        guard !Task.isCancelled else { return .stop }
        switch LiveTranslationAssetPolicy.action(
            readiness: readiness,
            downloadApproved: downloadApproved,
            preparedInThisLane: preparedInThisLane) {
        case .translate:
            return .ready(prepared: preparedInThisLane)
        case .requestDownloadConsent:
            await MainActor.run {
                controller.updateLiveTranslationState(.needsDownload, for: pair)
            }
            return .waitForWake
        case .prepareAssets:
            let prepared = await Self.prepare(
                box: box,
                controller: controller,
                pair: pair)
            return prepared ? .ready(prepared: true) : .retry
        case .passthroughUnsupported:
            return .stop
        }
    }

    nonisolated private static func handleBatchOutcome(
        _ outcome: LiveTranslationBatchOutcome,
        consecutiveFailures: Int,
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> Int? {
        switch outcome {
        case .cancelled:
            return nil
        case .completed:
            await MainActor.run {
                controller.updateLiveTranslationState(.active, for: pair)
            }
            return 0
        case .partial, .failed:
            let updatedFailureCount = consecutiveFailures + 1
            await MainActor.run {
                controller.updateLiveTranslationState(.failed, for: pair)
            }
            let delay = LiveTranslationRetryPolicy.delayMilliseconds(
                afterFailure: updatedFailureCount)
            return await Self.sleep(milliseconds: delay)
                ? updatedFailureCount
                : nil
        }
    }

    nonisolated private static func laneSnapshot(
        controller: RecordingController
    ) async -> (String?, String?, Bool) {
        await MainActor.run {
            (
                controller.translationTarget,
                controller.translationSource,
                controller.translationDownloadApproved
            )
        }
    }

    /// An unsupported lane stays resident instead of returning after the
    /// one-shot marking in `openLane`: `translationTask` only re-fires when
    /// the CONFIGURATION changes, so a same-language row that closes after
    /// that snapshot would keep producing the identical configuration —
    /// never getting marked, pinning `nextPair` to this dead lane, and
    /// starving every later supported lane for up to a full routing window
    /// (D128). Marking each new arrival flips it to passthrough, routing
    /// recomputes, and the framework cancels this task the moment a
    /// different pair (or none) is selected — the same exit the supported
    /// idle loop relies on.
    nonisolated private static func holdUnsupportedLane(
        controller: RecordingController,
        pair: LiveTranslationPair,
        wakes: AsyncStream<Void>
    ) async {
        var wakeIterator = wakes.makeAsyncIterator()
        while !Task.isCancelled {
            let snapshot = await MainActor.run {
                (controller.translationTarget, controller.translationSource)
            }
            guard !Task.isCancelled, snapshot.0 == pair.target, snapshot.1 == pair.source else { return }
            let pending = await Self.pendingRows(controller: controller, pair: pair)
            if !pending.isEmpty {
                await MainActor.run {
                    controller.markUnsupportedLiveTranslationRows(
                        Set(pending.map(\.id)),
                        for: pair)
                }
            }
            guard await wakeIterator.next() != nil else { return }
        }
    }

    /// Claims the lane and resolves whether Apple Translation can serve it.
    /// Cancellation ends the task without inventing unsupported state or
    /// requesting framework work on behalf of a superseded task.
    nonisolated private static func openLane(
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> LiveTranslationAssetReadiness? {
        guard !Task.isCancelled else { return nil }
        await MainActor.run { controller.beginLiveTranslationPair(pair) }
        guard await MainActor.run(body: { controller.isCurrentLiveTranslationTask(for: pair) })
        else { return nil }
        // Keep the receiver named: ArchitectureDependencyTests pins this call
        // shape so `status` can never regress to `try? await`, which would
        // swallow the unsupported-pair answer instead of surfacing it.
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: pair.source),
            to: Locale.Language(identifier: pair.target))
        guard !Task.isCancelled else { return nil }
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
            return .unsupported
        }
        return status == .installed ? .installed : .downloadable
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
    /// Returns false (and clears approval) if preparation fails or the user
    /// cancels. The loop returns to the deliberate consent banner instead of
    /// auto-presenting Apple's download sheet during an offline retry.
    nonisolated private static func prepare(
        box: SessionBox,
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> Bool {
        do {
            try Task.checkCancellation()
            try await box.session.prepareTranslation()
            return await MainActor.run {
                controller.isCurrentLiveTranslationTask(for: pair)
            }
        } catch {
            await MainActor.run {
                controller.failLiveTranslationPreparation(for: pair)
            }
            return false
        }
    }

    /// Not-yet-translated source revisions. The newest row can grow under a
    /// stable ID; routing rate-limits it by text growth rather than waiting
    /// indefinitely for a later row to close it.
    nonisolated private static func pendingRows(
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> [Ready] {
        await MainActor.run {
            guard controller.isCurrentLiveTranslationTask(for: pair) else { return [] }
            return LiveTranslationRouting.pendingRows(
                segments: controller.captions,
                translatedSourceTexts: controller.translatedSourceTexts,
                unsupportedIDs: controller.unsupportedTranslationRowIDs,
                pair: pair)
        }
    }

    /// Translates the ready rows and stores the results on the controller.
    nonisolated private static func apply(
        _ ready: [Ready],
        box: SessionBox,
        controller: RecordingController,
        pair: LiveTranslationPair
    ) async -> LiveTranslationBatchOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard !ready.isEmpty else { return .completed }
        let requests = ready.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
        }
        var storedIDs: Set<UUID> = []
        do {
            for try await response in box.session.translate(batch: requests) {
                guard !Task.isCancelled else { return .cancelled }
                guard
                    let identifier = response.clientIdentifier,
                    let id = UUID(uuidString: identifier),
                    let sourceText = ready.first(where: { $0.id == id })?.text
                else { continue }
                let stored = await MainActor.run {
                    controller.storeLiveTranslations(
                        [id: response.targetText],
                        sourceTexts: [id: sourceText],
                        for: pair)
                }
                if stored { storedIDs.insert(id) }
            }
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            return storedIDs.isEmpty ? .failed : .partial
        }
        guard !Task.isCancelled else { return .cancelled }
        return storedIDs.count == ready.count ? .completed : .partial
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
