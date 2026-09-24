import AppKit
import AudioCaptureKit
import Carbon.HIToolbox
import Foundation
import Observation
import PortavozCore
import SwiftUI
import TranscriptionKit

/// Pure capture-edge policy. The minimum is measured from the moment the
/// first nonempty microphone buffer arrives, never from model preparation or panel
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
        case preparing
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
    private(set) var microphoneNotice: String?

    var isActive: Bool { phase == .preparing || phase == .listening }
    /// The app that was frontmost when dictation started — where the text
    /// will land. The strip shows it so you never dictate "blind" (4b).
    private(set) var targetApp: String?

    let shortcut = DictationShortcut()
    private var mousePTT: MouseButtonPTT?
    private var mousePTTButton: Int?
    /// True while the active session was started by the mouse button, so
    /// only that button's release may deliver (`MousePTTGesture`).
    private var mouseOwnsSession = false
    private var microphone: (any AudioCaptureSource)?
    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var session: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopIssuedSessionID: UUID?
    private var failureDismissTask: Task<Void, Never>?
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

    /// Registers/unregisters the configured hotkey (⌥⌘D by default) to
    /// match the Settings toggle AND the recorded combination. Called at
    /// launch and whenever either changes — always re-registers so a new
    /// combo takes effect immediately.
    func syncHotkey(services: AppServices) {
        if !UserDefaults.standard.bool(forKey: Self.defaultsKey), isActive {
            cancel()
        }
        shortcut.sync(
            registrar: services.dictationShortcutRegistrar,
            onPress: { [weak self, weak services] in
                guard let self, let services else { return }
                self.pressedAt = Date()
                self.toggle(services: services)
            },
            onRelease: { [weak self] in
                guard let self else { return }
                // Hold-to-talk: a TAP (quick release) leaves the toggle
                // behavior untouched; holding the combo while speaking and
                // letting go delivers — the walkie-talkie gesture. The
                // threshold splits the two without any setting.
                guard self.isActive,
                    let pressedAt = self.pressedAt,
                    Date().timeIntervalSince(pressedAt) > Self.holdThreshold
                else { return }
                self.finishAndInsert()
            })
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
        if mouseOwnsSession, isActive {
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
            isListening: isActive,
            mouseOwnsSession: mouseOwnsSession) {
        case .start:
            mouseOwnsSession = true
            start(services: services)
            // A refused start (missing Accessibility trust) must not leave
            // the button claiming a session that never began.
            if !isActive { mouseOwnsSession = false }
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
    private var microphoneReadiness: DictationMicrophoneReadiness?

    /// Hotkey press: start listening, or finish-and-insert if already on.
    func toggle(services: AppServices) {
        toggle(using: services.makeDictationSessionDependencies())
    }

    func toggle(using dependencies: DictationSessionDependencies) {
        switch phase {
        case .idle, .failed, .inserted:
            start(using: dependencies)
        case .preparing:
            cancel()
        case .listening:
            finishAndInsert()
        }
    }

    private func start(services: AppServices) {
        start(using: services.makeDictationSessionDependencies())
    }

    private func start(using dependencies: DictationSessionDependencies) {
        failureDismissTask?.cancel()
        failureDismissTask = nil
        // The paste needs Accessibility; ask BEFORE recording so the user
        // never dictates into a void.
        guard dependencies.canInsert() else {
            phase = .failed(L10n.text(
                // One-line UI copy.
                // swiftlint:disable:next line_length
                "Dictation needs the Accessibility permission to type into other apps — grant it in System Settings and try again."))
            showPanel()
            scheduleFailureDismiss()
            return
        }
        // Capture the destination BEFORE the non-activating panel appears —
        // the frontmost app is still the one the user will dictate into.
        targetApp = dependencies.targetName()
        phase = .preparing
        confirmedText = ""
        partialText = ""
        micLevel = 0
        microphoneNotice = nil
        microphoneReadiness?.finish()
        microphoneReadiness = nil
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
        var microphone: (any AudioCaptureSource)?
        var localFeed: AsyncStream<AudioChunk>.Continuation?
        var pump: Task<Void, Never>?
        var ownedRuntime: LiveTranscriptionRuntime?
        // Keep the lease through catch-path native cleanup too. A defer inside
        // do runs before catch, while microphone.stop() may still be pending.
        defer { ownedRuntime?.finish() }
        do {
            let input = try await dependencies.authorizedMicrophone()
            guard activeSessionID == id else { return }
            microphone = input.source
            microphoneNotice = input.usesSystemFallback ? L10n.text(
                "Your preferred microphone is unavailable. Using the system default for this dictation.") : nil
            let runtime = try await dependencies.acquireRuntime()
            ownedRuntime = runtime
            try Task.checkCancellation()
            guard activeSessionID == id else { return }
            self.microphone = input.source
            let readiness = makeMicrophoneReadiness(id: id, dependencies: dependencies)
            defer { readiness.finish() }
            monitorCaptureFailure(input.source, id: id)
            readiness.beginDeadline(wait: dependencies.waitForFirstBufferDeadline)
            await input.warmUp()
            try Task.checkCancellation()
            let micStream = try await input.source.start()
            try Task.checkCancellation()
            guard activeSessionID == id else {
                await microphone?.stop()
                return
            }
            // Stream construction can precede its first hardware callback.
            // Only an admitted nonempty buffer starts the capture clock.

            // Dictation has no durable original to replay. A bounded relay
            // remains safe only when every dropped chunk revokes delivery.
            let (audio, feed) = AsyncStream.makeStream(
                of: AudioChunk.self,
                bufferingPolicy: .bufferingNewest(128))
            localFeed = feed
            self.feed = feed
            pump = readiness.pump(stream: micStream, feed: feed) { [weak self] peak in
                guard let self, activeSessionID == id else { return }
                micLevel = max(peak, micLevel * 0.8)
            }

            try await consumeCaptions(audio, runtime: runtime, id: id, dependencies: dependencies)
            await pump?.value
            try Task.checkCancellation()
            guard activeSessionID == id else { return }
            try verifyCaptureIntegrity(source: input.source, id: id)
            await deliver(sessionID: id, dependencies: dependencies)
        } catch is CancellationError {
            localFeed?.finish()
            pump?.cancel()
            await microphone?.stop()
            await pump?.value
        } catch {
            localFeed?.finish()
            pump?.cancel()
            await microphone?.stop()
            await pump?.value
            if let message = DictationMicrophoneReadiness.preparationMessage(for: error) {
                failSession(id: id, message: message, autoDismiss: false)
            } else {
                failSession(id: id, message: L10n.format(
                    "Dictation failed: %@", error.localizedDescription))
            }
        }
    }

    /// Second hotkey press: stop the mic; the drained stream delivers.
    private func finishAndInsert() {
        guard isActive else { return }
        guard stopTask == nil else { return }
        guard DictationCapturePolicy.finishDecision(
            captureStartedAt: microphoneReadiness?.firstFrameAt,
            now: sessionClock?() ?? Date()) == .stopAfterTail
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
        microphoneReadiness?.finish()
        microphoneReadiness = nil
        mouseOwnsSession = false
        stopTask?.cancel()
        stopTask = nil
        stopIssuedSessionID = nil
        failureDismissTask?.cancel()
        failureDismissTask = nil
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
        microphoneReadiness?.finish()
        microphoneReadiness = nil
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
            do {
                try await Task.sleep(for: .milliseconds(1600))
            } catch {
                return
            }
            guard case .inserted = phase else { return }
            phase = .idle
            panel.close()
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
        session = nil
        microphone = nil
        feed = nil
        stopTask = nil
        stopIssuedSessionID = nil
        microphoneReadiness?.finish()
        microphoneReadiness = nil
        mouseOwnsSession = false
    }

    private func failSession(id: UUID, message: String, autoDismiss: Bool = true) {
        guard activeSessionID == id else { return }
        completeSession(id: id)
        phase = .failed(message)
        if autoDismiss { scheduleFailureDismiss() }
    }

    private func scheduleFailureDismiss() {
        failureDismissTask?.cancel()
        failureDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            guard let self, case .failed = self.phase else { return }
            self.failureDismissTask = nil
            self.phase = .idle
            self.panel.close()
        }
    }

}

// Keep audio admission, transcript projection and capture-failure policy
// together without expanding the gesture/panel coordinator body.
extension DictationController {
    private func monitorCaptureFailure(_ source: any AudioCaptureSource, id: UUID) {
        (source as? any CaptureReportingSource)?.setCaptureFailureHandler { [weak self] in
            Task { @MainActor [weak self] in self?.failCapture(id: id) }
        }
    }

    private func consumeCaptions(
        _ audio: AsyncStream<AudioChunk>, runtime: LiveTranscriptionRuntime,
        id: UUID, dependencies: DictationSessionDependencies
    ) async throws {
        let hints = transcriptionHints(defaults: dependencies.defaults)
        var captions: [TranscriptSegment] = []
        let coalescer = CaptionCoalescer()
        for try await segment in runtime.engine.transcribe(audio, hints: hints) {
            try Task.checkCancellation()
            guard activeSessionID == id else { throw CancellationError() }
            coalescer.apply(segment, to: &captions)
            confirmedText = captions.dropLast().map(\.text).joined(separator: " ")
            partialText = captions.last?.text ?? ""
        }
        try Task.checkCancellation()
        guard activeSessionID == id else { throw CancellationError() }
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

    private func makeMicrophoneReadiness(
        id: UUID, dependencies: DictationSessionDependencies
    ) -> DictationMicrophoneReadiness {
        let readiness = DictationMicrophoneReadiness(now: dependencies.now, onReady: { [weak self] in
            guard let self, activeSessionID == id else { return }
            phase = .listening
        }, onFailure: { [weak self] failure in
            guard let self, activeSessionID == id else { return }
            session?.cancel()
            stopTask?.cancel()
            feed?.finish()
            let source = microphone
            Task { await source?.stop() }
            failSession(id: id, message: failure.message, autoDismiss: false)
        })
        microphoneReadiness = readiness
        return readiness
    }

    private func failCapture(id: UUID) {
        // Once delivery relinquishes capture, a late report cannot promise
        // to undo an already-dispatched edit.
        guard activeSessionID == id, microphone != nil else { return }
        microphoneReadiness?.failCapture()
    }

    private func verifyCaptureIntegrity(source: any AudioCaptureSource, id: UUID) throws {
        if (source as? any CaptureReportingSource)?.captureReport.failure != nil {
            failCapture(id: id)
            throw CancellationError()
        }
        // EOF without our actual Stop call can be device teardown, even
        // when the source omits a failure report.
        guard stopIssuedSessionID == id else {
            failCapture(id: id)
            throw CancellationError()
        }
    }
}
