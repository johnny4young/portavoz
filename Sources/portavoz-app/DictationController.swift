import AppKit
import AudioCaptureKit
import Carbon.HIToolbox
import Foundation
import Observation
import PortavozCore
import SwiftUI
import TranscriptionKit

/// Pure capture-edge policy. The minimum is measured from the moment the
/// microphone stream actually starts, never from model preparation or panel
/// presentation, so a slow cold start cannot turn a tap into a valid capture.
struct DictationCapturePolicy {
    static let minimumCapture: TimeInterval = 0.75

    enum FinishDecision: Equatable {
        case cancel
        case stopAfterTail
    }

    static func finishDecision(
        captureStartedAt: Date?, now: Date
    ) -> FinishDecision {
        guard let captureStartedAt,
            now.timeIntervalSince(captureStartedAt) >= minimumCapture
        else { return .cancel }
        return .stopAfterTail
    }
}

private enum DictationSessionError: LocalizedError {
    case unexpectedCompletion

    var errorDescription: String? {
        L10n.text("The dictation session ended unexpectedly. Nothing was typed.")
    }
}

/// System-wide dictation (the MacParakeet-validated surface): press the
/// global hotkey anywhere, speak, press it again — the transcript lands in
/// whatever app is frontmost. Reuses the meeting pipeline as-is: Parakeet
/// streaming on the ANE, the caption coalescer's echo/noise hygiene, and
/// the user's custom vocabulary. Mic-only, nothing is stored: no meeting,
/// no database row, no audio file.
@MainActor
@Observable
final class DictationController {
    static let defaultsKey = "globalDictationEnabled"
    /// "auto" (or absent) lets the multilingual engine detect; "es"/"en"
    /// pin one dictation language without touching meeting settings.
    static let languageKey = "dictationLanguage"
    /// Bilingual hesitation-filler removal; on by default — polished text
    /// is the point of dictation, and the filter only ever drops tokens
    /// that are meaningless in both languages.
    static let fillerFilterKey = "dictationFillerFilter"
    /// The deterministic replacement rules as one JSON string
    /// (`DictationTextRules` codec).
    static let replacementsKey = "dictationReplacements"

    static func fillerFilterEnabled(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: fillerFilterKey) as? Bool) ?? true
    }

    enum Phase: Equatable {
        case idle
        case listening
        /// Words landed in the target app — a brief confirmation before the
        /// strip fades, so the user sees the dictation took (design system
        /// 4b: "inserted, no trace").
        case inserted(Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Rows confirmed by the engine so far (coalesced, echo-trimmed).
    private(set) var confirmedText = ""
    /// The still-changing tail of what's being said.
    private(set) var partialText = ""
    /// Mic peak with fast attack / slow decay (same VU feel as the HUD).
    private(set) var micLevel: Float = 0
    /// The app that was frontmost when dictation started — where the text
    /// will land. The strip shows it so you never dictate "blind" (4b).
    private(set) var targetApp: String?

    let shortcut = DictationShortcut()
    private var mousePTT: MouseButtonPTT?
    private var mousePTTButton: Int?
    /// True while the active session was started by the mouse button, so
    /// only that button's release may deliver (`MousePTTGesture`).
    private var mouseOwnsSession = false
    private var pressedSessionID: UUID?
    private var microphone: (any AudioCaptureSource)?
    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var session: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopIssuedSessionID: UUID?
    private var feedbackDismissTask: Task<Void, Never>?
    private var feedbackID: UUID?
    private var sessionFeedbackWait: (@MainActor (Duration) async throws -> Void)?
    private var activeSessionID: UUID?
    private let panel = DictationPanelController()
    private let presentsPanel: Bool
    private var sessionClock: (() -> Date)?

    init(presentsPanel: Bool = true) {
        self.presentsPanel = presentsPanel
    }

    private func showPanel() {
        if presentsPanel { panel.show(controller: self) }
    }

    /// Arms/disarms the push-to-talk mouse button to match the Settings
    /// toggle AND the recorded button. Separate from `syncHotkey` because
    /// the event tap needs Accessibility trust the Carbon hotkey does not;
    /// setup can prompt explicitly and returning from System Settings retries
    /// a tap that could not be created while permission was absent.
    func syncMousePTT(
        services: AppServices,
        promptIfNeeded: Bool = false
    ) {
        let enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        let storedButton = MouseButtonSetting.load()
        let desiredButton = enabled
            && MouseButtonSetting.isEligible(storedButton) ? storedButton : nil
        if mousePTT != nil, mousePTTButton == desiredButton { return }

        // Rebinding or disabling while the mouse owns capture would otherwise
        // discard the matching release event and strand a listening session.
        if mouseOwnsSession, phase == .listening {
            cancel()
        }
        mousePTT?.invalidate()
        mousePTT = nil
        mousePTTButton = nil
        guard !services.usesTemporaryMeetingStore, let desiredButton else { return }

        // Configuring a system-wide mouse trigger is the earliest useful time
        // to explain its Accessibility requirement. A denied/pending prompt
        // leaves the keyboard hotkey intact; applicationDidBecomeActive retries
        // after the user returns from System Settings.
        if promptIfNeeded {
            _ = TextInserter.canInsert(promptIfNeeded: true)
        }
        guard let ptt = MouseButtonPTT(
            button: desiredButton,
            onPress: { [weak self, weak services] in
                guard let self, let services else { return }
                self.handleMouse(.press, services: services)
            },
            onRelease: { [weak self, weak services] in
                guard let self, let services else { return }
                self.handleMouse(.release, services: services)
            })
        else { return }
        mousePTT = ptt
        mousePTTButton = desiredButton
    }

    private func handleMouse(
        _ event: MousePTTGesture.Event, services: AppServices
    ) {
        switch MousePTTGesture.action(
            for: event,
            isListening: phase == .listening,
            mouseOwnsSession: mouseOwnsSession) {
        case .start:
            mouseOwnsSession = true
            start(services: services)
            // A refused start (missing Accessibility trust) must not leave
            // the button claiming a session that never began.
            if phase != .listening { mouseOwnsSession = false }
        case .finish:
            mouseOwnsSession = false
            finishAndInsert()
        case .ignore:
            break
        }
    }

    /// Press-to-release lapse that separates a toggle TAP from a
    /// hold-to-talk gesture.
    private static let holdThreshold: TimeInterval = 0.5
    private var pressedAt: Date?

    /// The mic keeps capturing this long after the finish gesture so the
    /// tail of the last word survives — stopping on the release clips it
    /// mid-phoneme.
    private static let stopTail: Duration = .milliseconds(250)
    private var captureStartedAt: Date?

    /// Hotkey press: start listening, or finish-and-insert if already on.
    func toggle(services: AppServices) {
        toggle(using: services.makeDictationSessionDependencies())
    }

    func toggle(using dependencies: DictationSessionDependencies) {
        switch phase {
        case .idle, .failed, .inserted:
            start(using: dependencies)
        case .listening:
            finishAndInsert()
        }
    }

    private func start(services: AppServices) {
        start(using: services.makeDictationSessionDependencies())
    }

    private func start(using dependencies: DictationSessionDependencies) {
        pressedAt = nil
        pressedSessionID = nil
        cancelFeedbackDismissal()
        sessionFeedbackWait = dependencies.waitForFeedbackDismissal
        // The paste needs Accessibility; ask BEFORE recording so the user
        // never dictates into a void.
        guard dependencies.canInsert() else {
            phase = .failed(L10n.text(
                // One-line UI copy.
                // swiftlint:disable:next line_length
                "Dictation needs the Accessibility permission to type into other apps — grant it in System Settings and try again."))
            showPanel()
            scheduleFeedbackDismiss(after: .seconds(6), wait: dependencies.waitForFeedbackDismissal)
            return
        }
        // Capture the destination BEFORE the non-activating panel appears —
        // the frontmost app is still the one the user will dictate into.
        targetApp = dependencies.targetName()
        phase = .listening
        confirmedText = ""
        partialText = ""
        micLevel = 0
        captureStartedAt = nil
        stopTask?.cancel()
        stopTask = nil
        stopIssuedSessionID = nil
        let sessionID = UUID()
        activeSessionID = sessionID
        sessionClock = dependencies.now
        showPanel()

        session = Task { [weak self] in
            await self?.runSession(id: sessionID, dependencies: dependencies)
        }
    }

    private func runSession(id: UUID, dependencies: DictationSessionDependencies) async {
        let input = dependencies.makeMicrophone()
        let microphone = input.source
        var localFeed: AsyncStream<AudioChunk>.Continuation?
        var pump: Task<Void, Never>?
        var retainedRuntime: LiveTranscriptionRuntime?
        defer { retainedRuntime?.finish() }
        do {
            let runtime = try await dependencies.acquireRuntime()
            retainedRuntime = runtime
            try Task.checkCancellation()
            guard activeSessionID == id else { return }
            self.microphone = microphone
            let captureFailed: @MainActor @Sendable () -> Void = { [weak self] in
                self?.failCapture(id: id)
            }
            (microphone as? any CaptureReportingSource)?.setCaptureFailureHandler {
                Task { await captureFailed() }
            }

            await input.warmUp()
            try Task.checkCancellation()
            let micStream = try await microphone.start()
            try Task.checkCancellation()
            guard activeSessionID == id else {
                await microphone.stop()
                return
            }
            captureStartedAt = dependencies.now()

            // Dictation has no durable original to replay. Keep the bounded
            // handoff, but any dropped audio invalidates automatic delivery.
            let (audio, feed) = AsyncStream.makeStream(
                of: AudioChunk.self,
                bufferingPolicy: .bufferingNewest(128))
            localFeed = feed
            self.feed = feed
            pump = makeAudioPump(stream: micStream, feed: feed, sessionID: id, onFailure: captureFailed)

            try await consumeCaptions(
                from: runtime.engine.transcribe(audio, hints: transcriptionHints(defaults: dependencies.defaults)),
                sessionID: id)
            // A recognizer can complete while the microphone remains live.
            // Neither its EOF nor a pending Stop tail authorizes delivery.
            guard stopIssuedSessionID == id else { throw DictationSessionError.unexpectedCompletion }
            let nativeStop = stopTask
            await pump?.value
            await nativeStop?.value
            try Task.checkCancellation()
            guard activeSessionID == id else { return }
            if (microphone as? any CaptureReportingSource)?.captureReport.failure != nil {
                failCapture(id: id)
                try Task.checkCancellation()
            }
            await deliver(sessionID: id, dependencies: dependencies)
        } catch {
            localFeed?.finish()
            pump?.cancel()
            await microphone.stop()
            await pump?.value
            // A dependency can throw CancellationError without cancelling the
            // owning task. Only that task or an obsolete identity is silent.
            guard !Task.isCancelled, activeSessionID == id else { return }
            let reason = error is CancellationError
                ? DictationSessionError.unexpectedCompletion.localizedDescription
                : error.localizedDescription
            failSession(id: id, message: L10n.format(
                "Dictation failed: %@", reason))
        }
    }

    private func consumeCaptions(
        from stream: AsyncThrowingStream<TranscriptSegment, Error>, sessionID: UUID
    ) async throws {
        var captions: [TranscriptSegment] = []
        let coalescer = CaptionCoalescer()
        for try await segment in stream {
            try Task.checkCancellation()
            guard activeSessionID == sessionID else { throw CancellationError() }
            coalescer.apply(segment, to: &captions)
            confirmedText = captions.dropLast().map(\.text).joined(separator: " ")
            partialText = captions.last?.text ?? ""
        }
        // A cancelled iterator can end normally. Enter cleanup before joining
        // a detached pump that may still await its source, or publishing text.
        try Task.checkCancellation()
        guard activeSessionID == sessionID else { throw CancellationError() }
        confirmedText = captions.map(\.text).joined(separator: " ")
        partialText = ""
    }

    private func transcriptionHints(defaults: UserDefaults) -> TranscriptionHints {
        let vocabulary = VocabularyPrompt.parse(
            defaults.string(forKey: "customVocabulary") ?? "")
        // Language stays constrained to the two dictation languages: any
        // stored value outside {es, en} means auto-detect.
        let languageSetting = defaults.string(forKey: Self.languageKey)
        return TranscriptionHints(
            language: ["es", "en"].contains(languageSetting) ? languageSetting : nil,
            vocabulary: vocabulary,
            meetingID: MeetingID())
    }

    private func makeAudioPump(
        stream: AsyncThrowingStream<AudioChunk, Error>,
        feed: AsyncStream<AudioChunk>.Continuation,
        sessionID: UUID,
        onFailure: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        let updateMeter: @MainActor @Sendable (Float) -> Void = { [weak self] peak in
            if let self, self.activeSessionID == sessionID {
                self.micLevel = max(peak, self.micLevel * 0.8)
            }
        }
        return makeDictationAudioPump(stream: stream, feed: feed, onLevel: updateMeter, onFailure: onFailure)
    }

    private func failCapture(id: UUID) {
        // Delivery relinquishes capture before awaiting a platform edit. A
        // delayed notification cannot promise to undo an event already posted.
        guard activeSessionID == id, microphone != nil else { return }
        session?.cancel()
        stopTask?.cancel()
        // Revoke delivery before closing the feed can drain a partial result.
        failSession(id: id, message: L10n.text(
            "Audio capture was interrupted. Nothing was inserted. Try dictating again."))
    }

    /// Second hotkey press: stop the mic; the drained stream delivers.
    private func finishAndInsert() {
        guard phase == .listening else { return }
        guard stopTask == nil else { return }
        guard DictationCapturePolicy.finishDecision(
            captureStartedAt: captureStartedAt, now: sessionClock?() ?? Date()) == .stopAfterTail
        else {
            cancel()
            return
        }
        guard let sessionID = activeSessionID else {
            cancel()
            return
        }
        let microphone = self.microphone
        stopTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.stopTail)
            } catch {
                return
            }
            guard let self, self.activeSessionID == sessionID else { return }
            self.stopIssuedSessionID = sessionID
            await microphone?.stop()
        }
    }

    /// Esc in the panel: throw everything away.
    func cancel() {
        activeSessionID = nil
        sessionClock = nil
        captureStartedAt = nil
        mouseOwnsSession = false
        pressedAt = nil
        pressedSessionID = nil
        stopTask?.cancel()
        stopTask = nil
        stopIssuedSessionID = nil
        sessionFeedbackWait = nil
        cancelFeedbackDismissal()
        session?.cancel()
        session = nil
        let microphone = self.microphone
        Task { await microphone?.stop() }
        self.microphone = nil
        feed?.finish()
        feed = nil
        phase = .idle
        panel.close()
    }

    private func deliver(sessionID: UUID, dependencies: DictationSessionDependencies) async {
        guard activeSessionID == sessionID else { return }
        // The two-tier dictionary's deterministic tier plus the filler
        // filter run on the final text only — meeting transcripts stay
        // verbatim records and never pass through here.
        let text = DictationTextRules.apply(
            DictationAssembler.text(
                confirmed: confirmedText, partial: partialText),
            replacements: DictationTextRules.decode(
                replacements: dependencies.defaults.string(
                    forKey: Self.replacementsKey) ?? ""),
            removeFillers: Self.fillerFilterEnabled(in: dependencies.defaults))
        microphone = nil
        feed = nil
        stopTask = nil
        stopIssuedSessionID = nil
        captureStartedAt = nil
        guard DictationAssembler.hasLexicalContent(text) else {
            completeSession(id: sessionID)
            phase = .idle
            panel.close()
            return
        }
        let result = await dependencies.insert(text)
        guard activeSessionID == sessionID else { return }
        switch result {
        case .inserted:
            completeSession(id: sessionID)
            let words = text.split(whereSeparator: \.isWhitespace).count
            phase = .inserted(words)
            scheduleFeedbackDismiss(after: .milliseconds(1600), wait: dependencies.waitForFeedbackDismissal)
        case .secureField:
            failSession(
                id: sessionID,
                message: L10n.text("Dictation never types into password fields."))
        case .focusUnavailable:
            failSession(
                id: sessionID,
                message: L10n.text(
                    "Dictation couldn't verify the focused field, so it didn't type anything."))
        case .modifiersStillPressed:
            failSession(
                id: sessionID,
                message: L10n.text(
                    "Release Command, Option, Control, and Shift, then try again."))
        case .clipboardUnavailable, .eventUnavailable:
            failSession(
                id: sessionID,
                message: L10n.text(
                    "Dictation couldn't type into the focused app. Try again."))
        case .cancelled:
            return
        }
    }

    private func completeSession(id: UUID) {
        guard activeSessionID == id else { return }
        activeSessionID = nil
        sessionClock = nil
        pressedAt = nil
        pressedSessionID = nil
        session = nil
        microphone = nil
        feed = nil
        stopTask = nil
        stopIssuedSessionID = nil
        sessionFeedbackWait = nil
        captureStartedAt = nil
        mouseOwnsSession = false
    }

    private func failSession(id: UUID, message: String) {
        guard activeSessionID == id else { return }
        let wait: @MainActor (Duration) async throws -> Void = sessionFeedbackWait
            ?? { try await Task.sleep(for: $0) }
        completeSession(id: id)
        phase = .failed(message)
        scheduleFeedbackDismiss(after: .seconds(6), wait: wait)
    }

    private func cancelFeedbackDismissal() {
        feedbackID = nil
        feedbackDismissTask?.cancel()
        feedbackDismissTask = nil
    }

    private func scheduleFeedbackDismiss(
        after delay: Duration,
        wait: @escaping @MainActor (Duration) async throws -> Void
    ) {
        cancelFeedbackDismissal()
        let id = UUID()
        feedbackID = id
        feedbackDismissTask = Task { [weak self] in
            do {
                try await wait(delay)
            } catch {
                return
            }
            guard let self, self.feedbackID == id, !Task.isCancelled else { return }
            self.feedbackID = nil
            self.feedbackDismissTask = nil
            self.phase = .idle
            self.panel.close()
        }
    }

}

extension DictationController {
    /// Re-register the configured hotkey after either Settings value changes.
    func syncHotkey(services: AppServices) {
        if !UserDefaults.standard.bool(forKey: Self.defaultsKey), phase == .listening {
            cancel()
        }
        shortcut.sync(
            registrar: services.dictationShortcutRegistrar,
            onPress: { [weak self, weak services] in
                guard let self, let services else { return }
                self.handleHotkeyPress(using: services.makeDictationSessionDependencies(), at: Date())
            },
            onRelease: { [weak self] in
                guard let self else { return }
                self.handleHotkeyRelease(at: Date())
            })
    }

    func handleHotkeyPress(using dependencies: DictationSessionDependencies, at now: Date) {
        let wasListening = phase == .listening
        toggle(using: dependencies)
        // Only a press that actually began this session can later finish it
        // on release. A second press remains the recovery for a lost key-up.
        if !wasListening, phase == .listening {
            pressedAt = now
            pressedSessionID = activeSessionID
        } else {
            pressedAt = nil
            pressedSessionID = nil
        }
    }

    func handleHotkeyRelease(at now: Date) {
        let ownsSession = activeSessionID != nil && pressedSessionID == activeSessionID
        let heldLongEnough = pressedAt.map { now.timeIntervalSince($0) > Self.holdThreshold } ?? false
        pressedAt = nil
        pressedSessionID = nil
        guard ownsSession, phase == .listening, heldLongEnough else { return }
        finishAndInsert()
    }
}
