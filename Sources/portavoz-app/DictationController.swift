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

enum DictationSessionError: LocalizedError {
    case unexpectedCompletion

    var errorDescription: String? {
        L10n.text("The dictation session ended unexpectedly. Nothing was typed.")
    }
}

/// System-wide dictation (the MacParakeet-validated surface): press the
/// global hotkey anywhere, speak, press it again — the transcript lands in
/// the captured original field, or stays available for explicit recovery.
/// Reuses the meeting pipeline as-is: Parakeet
/// streaming on the ANE, the caption coalescer's echo/noise hygiene, and
/// the user's custom vocabulary. Mic-only, nothing is stored: no meeting,
/// no database row, no audio file.
@MainActor
@Observable
final class DictationController {
    static let defaultsKey = "globalDictationEnabled"
    /// "auto" (or absent) lets the multilingual engine detect; "es"/"en"
    /// request the backend's script-aware filter without touching meeting settings.
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
        case recovery(TextInserter.InsertionResult)
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

    enum CopyStatus: Equatable { case idle, copied, failed }
    private(set) var recoveryText = ""
    private(set) var copyStatus: CopyStatus = .idle
    private(set) var isRetryingDelivery = false
    var canRetryDelivery: Bool { destination?.canRetry == true }
    private var destination: CapturedDictationDestination?
    private var dependencies: DictationSessionDependencies?
    private var deliveryID: UUID?
    @ObservationIgnored private(set) var retryDeliveryTask: Task<Void, Never>?

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
    private var relayEndedSessionID: UUID?
    private var feedbackDismissTask: Task<Void, Never>?
    private var feedbackID: UUID?
    private var pressedSessionID: UUID?
    private var sessionFeedbackWait: (@MainActor (Duration) async throws -> Void)?
    private var activeSessionID: UUID?
    private var measurement: DictationSessionMeasurementRecorder?
    private var textPolicy = DictationTextPreferenceSnapshot(mode: .literal, removeFillers: false, replacements: [])
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
        case .recovery:
            showPanel()
        }
    }

    private func start(services: AppServices) {
        start(using: services.makeDictationSessionDependencies())
    }

    private func start(using dependencies: DictationSessionDependencies) {
        // A global trigger cannot silently replace undelivered words.
        if case .recovery = phase { showPanel(); return }
        retryDeliveryTask?.cancel()
        retryDeliveryTask = nil
        deliveryID = nil
        destination = nil
        self.dependencies = dependencies
        sessionFeedbackWait = dependencies.waitForFeedbackDismissal
        measurement = dependencies.measurementSink.map {
            DictationSessionMeasurementRecorder(now: dependencies.measurementClock, sink: $0)
        }
        pressedAt = nil
        pressedSessionID = nil
        cancelFeedbackDismissal()
        // The paste needs Accessibility; ask BEFORE recording so the user
        // never dictates into a void.
        guard dependencies.canInsert() else {
            self.dependencies = nil
            measurement?.finish(.permissionDenied)
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
        let destination = dependencies.captureDestination()
        self.destination = destination
        targetApp = destination.name
        textPolicy = DictationTextPreferences.snapshot(
            in: dependencies.defaults, bundleIdentifier: destination.bundleIdentifier)
        phase = .preparing
        confirmedText = ""
        partialText = ""
        micLevel = 0
        microphoneNotice = nil
        retireMicrophoneReadiness()
        stopTask?.cancel()
        stopTask = nil
        let sessionID = UUID()
        activeSessionID = sessionID
        sessionClock = dependencies.now
        showPanel()

        let finishCapture = dependencies.beginCapture()
        let measurement = self.measurement
        session = Task { [weak self] in
            defer { finishCapture() }
            await self?.runSession(id: sessionID, dependencies: dependencies, measurement: measurement)
        }
    }

    private func runSession(
        id: UUID, dependencies: DictationSessionDependencies,
        measurement: DictationSessionMeasurementRecorder?
    ) async {
        var microphone: (any AudioCaptureSource)?
        await runCapture(id: id, dependencies: dependencies, measurement: measurement, microphone: &microphone)
        // EOF can precede native teardown, and a cancelled session can overlap
        // its replacement. Retire only this source before releasing its owner.
        await microphone?.stop()
    }

    private func runCapture(
        id: UUID, dependencies: DictationSessionDependencies,
        measurement: DictationSessionMeasurementRecorder?,
        microphone: inout (any AudioCaptureSource)?
    ) async {
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
            measurement?.record(.runtimeReady)
            ownedRuntime = runtime
            try Task.checkCancellation()
            guard activeSessionID == id else { return }
            self.microphone = input.source
            let readiness = makeMicrophoneReadiness(
                id: id, dependencies: dependencies, measurement: measurement)
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
            measurement?.record(.microphoneReady)

            // Dictation has no durable original to replay. A bounded relay
            // remains safe only when every dropped chunk revokes delivery.
            let (audio, feed) = AsyncStream.makeStream(
                of: AudioChunk.self,
                bufferingPolicy: .bufferingNewest(128))
            localFeed = feed
            self.feed = feed
            pump = startPump(
                readiness: readiness, stream: micStream, feed: feed, sessionID: id, measurement: measurement)

            try await consumeCaptions(
                from: runtime.engine.transcribe(audio, hints: dependencies.transcriptionHints()),
                sessionID: id, measurement: measurement)
            // Captions that end while audio still flows leave the rest untranscribed.
            if activeSessionID == id, relayEndedSessionID != id { throw rejectDelivery(id: id) }
            try await awaitCaptureCompletion(id: id, pump: pump, source: input.source)
            await deliver(sessionID: id, dependencies: dependencies)
        } catch {
            let cancelled = Task.isCancelled || activeSessionID != id
            let permissionDenied = (error as? DictationMicrophoneReadiness.Failure) == .permissionRequired
            measurement?.finish(cancelled ? .cancelled : (permissionDenied ? .permissionDenied : .pipelineFailed))
            await stopCapture(feed: localFeed, pump: pump, microphone: microphone)
            guard !Task.isCancelled, activeSessionID == id else { return }
            if let message = DictationMicrophoneReadiness.preparationMessage(for: error) {
                failSession(id: id, message: message, autoDismiss: false)
            } else if error is CancellationError {
                // Nothing was typed: keep it visible like a capture interruption.
                failSession(
                    id: id, message: LiveSpeechFailureMessage.dictation(DictationSessionError.unexpectedCompletion),
                    autoDismiss: false)
            } else {
                failSession(id: id, message: LiveSpeechFailureMessage.dictation(error))
            }
        }
    }

    /// Second hotkey press: stop the mic; the drained stream delivers.
    private func finishAndInsert() {
        guard isActive else { return }
        guard stopTask == nil else { return }
        measurement?.record(.stopRequested)
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
        retryDeliveryTask?.cancel()
        retryDeliveryTask = nil
        deliveryID = nil
        destination = nil
        dependencies = nil
        recoveryText = ""
        targetApp = nil
        copyStatus = .idle
        isRetryingDelivery = false
        measurement?.finish(.cancelled)
        measurement = nil
        sessionFeedbackWait = nil
        activeSessionID = nil
        textPolicy = .init(mode: .literal, removeFillers: false, replacements: [])
        sessionClock = nil
        confirmedText = ""
        partialText = ""
        micLevel = 0
        retireMicrophoneReadiness()
        mouseOwnsSession = false
        stopTask?.cancel()
        stopTask = nil
        pressedAt = nil
        pressedSessionID = nil
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
        guard activeSessionID == sessionID, let destination else { return }
        // The two-tier dictionary's deterministic tier plus the filler
        // filter run on the final text only — meeting transcripts stay
        // verbatim records and never pass through here.
        let measurement = self.measurement
        let text = textPolicy.applying(to: DictationAssembler.text(
            confirmed: confirmedText, partial: partialText))
        measurement?.record(.textPrepared)
        microphone = nil
        feed = nil
        stopTask = nil
        retireMicrophoneReadiness()
        guard DictationAssembler.hasLexicalContent(text) else {
            measurement?.finish(.empty)
            completeSession(id: sessionID)
            self.destination = nil
            self.dependencies = nil
            phase = .idle
            panel.close()
            return
        }
        measurement?.record(.deliveryStarted)
        let result = await destination.insert(text)
        measurement?.finishDelivery(result)
        guard activeSessionID == sessionID else { return }
        completeSession(id: sessionID)
        deliveryID = sessionID
        if result == .inserted {
            showDispatchedText(text, id: sessionID)
        } else {
            recoveryText = text
            copyStatus = .idle
            phase = .recovery(result)
            showPanel()
        }
    }

    private func completeSession(id: UUID) {
        guard activeSessionID == id else { return }
        activeSessionID = nil
        textPolicy = .init(mode: .literal, removeFillers: false, replacements: [])
        sessionClock = nil
        pressedAt = nil
        pressedSessionID = nil
        sessionFeedbackWait = nil
        session = nil
        microphone = nil
        feed = nil
        stopTask = nil
        retireMicrophoneReadiness()
        mouseOwnsSession = false
    }

    private func failSession(id: UUID, message: String, autoDismiss: Bool = true) {
        guard activeSessionID == id else { return }
        let wait: @MainActor (Duration) async throws -> Void = sessionFeedbackWait
            ?? { try await Task.sleep(for: $0) }
        completeSession(id: id)
        destination = nil
        dependencies = nil
        phase = .failed(message)
        if autoDismiss { scheduleFeedbackDismiss(after: .seconds(6), wait: wait) }
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
            self.deliveryID = nil
            self.destination = nil
            self.dependencies = nil
            self.phase = .idle
            self.panel.close()
        }
    }

}

extension DictationController {
    /// Re-register the configured hotkey after either Settings value changes.
    func syncHotkey(services: AppServices) {
        if !UserDefaults.standard.bool(forKey: Self.defaultsKey), isActive {
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
        let wasActive = isActive
        toggle(using: dependencies)
        // Only a press that actually began this session can later finish it
        // on release. A second press remains the recovery for a lost key-up.
        if !wasActive, isActive {
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
        guard ownsSession, isActive, heldLongEnough else { return }
        finishAndInsert()
    }
}

private extension DictationController {
    func awaitCaptureCompletion(
        id: UUID, pump: Task<Void, Never>?, source: any AudioCaptureSource
    ) async throws {
        // Reject recognizer EOF before joining a producer that may still be live.
        guard stopIssuedSessionID == id else { throw rejectDelivery(id: id) }
        let nativeStop = stopTask
        await pump?.value
        await nativeStop?.value
        try Task.checkCancellation()
        guard activeSessionID == id else { throw CancellationError() }
        try verifyCaptureIntegrity(source: source, id: id)
    }

    func monitorCaptureFailure(_ source: any AudioCaptureSource, id: UUID) {
        (source as? any CaptureReportingSource)?.setCaptureFailureHandler { [weak self] in
            Task { @MainActor [weak self] in self?.failCapture(id: id) }
        }
    }

    func makeMicrophoneReadiness(
        id: UUID, dependencies: DictationSessionDependencies,
        measurement: DictationSessionMeasurementRecorder?
    ) -> DictationMicrophoneReadiness {
        let readiness = DictationMicrophoneReadiness(now: dependencies.now, onReady: { [weak self] in
            guard let self, activeSessionID == id else { return }
            phase = .listening
        }, onFailure: { [weak self] failure in
            guard let self, activeSessionID == id else { return }
            // The session task then unwinds as cancelled; keep the real outcome.
            measurement?.finish(.pipelineFailed)
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

    func retireMicrophoneReadiness() {
        stopIssuedSessionID = nil
        relayEndedSessionID = nil
        microphoneReadiness?.finish()
        microphoneReadiness = nil
    }

    /// Native stop runs before the pump drains, on every failed or cancelled start.
    func stopCapture(
        feed: AsyncStream<AudioChunk>.Continuation?, pump: Task<Void, Never>?,
        microphone: (any AudioCaptureSource)?
    ) async {
        feed?.finish()
        pump?.cancel()
        await microphone?.stop()
        await pump?.value
    }

    func startPump(
        readiness: DictationMicrophoneReadiness, stream: AsyncThrowingStream<AudioChunk, Error>,
        feed: AsyncStream<AudioChunk>.Continuation, sessionID: UUID,
        measurement: DictationSessionMeasurementRecorder?
    ) -> Task<Void, Never> {
        readiness.pump(
            stream: stream, feed: feed,
            onInputEnded: { [weak self] in
                if let measurement { await measurement.record(.inputEnded) }
                await self?.markRelayEnded(sessionID)
            },
            updateMeter: { [weak self] peak in
                guard let self, activeSessionID == sessionID else { return }
                measurement?.record(.firstBufferHandled)
                micLevel = max(peak, micLevel * 0.8)
            })
    }

    func consumeCaptions(
        from stream: AsyncThrowingStream<TranscriptSegment, Error>,
        sessionID: UUID, measurement: DictationSessionMeasurementRecorder?
    ) async throws {
        var transcript = DictationTranscriptProjection()
        for try await segment in stream {
            try Task.checkCancellation()
            guard activeSessionID == sessionID else { throw CancellationError() }
            measurement?.record(.firstCaptionHandled)
            if transcript.apply(segment) {
                confirmedText = transcript.confirmedText
            }
            if partialText != transcript.partialText {
                partialText = transcript.partialText
            }
        }
        // A cancelled AsyncStream can finish normally, without throwing.
        try Task.checkCancellation()
        guard activeSessionID == sessionID else { throw CancellationError() }
        measurement?.record(.transcriptionEnded)
        confirmedText = transcript.finalText
        partialText = ""
    }

    func failCapture(id: UUID) {
        // Once delivery relinquishes capture, a late report cannot promise
        // to undo an already-dispatched edit.
        guard activeSessionID == id, microphone != nil else { return }
        microphoneReadiness?.failCapture()
    }

    func verifyCaptureIntegrity(source: any AudioCaptureSource, id: UUID) throws {
        if (source as? any CaptureReportingSource)?.captureReport.failure != nil {
            throw rejectDelivery(id: id)
        }
        // EOF without our actual Stop call can be device teardown, even
        // when the source omits a failure report.
        guard stopIssuedSessionID == id else { throw rejectDelivery(id: id) }
    }

    func markRelayEnded(_ id: UUID) {
        guard activeSessionID == id else { return }
        relayEndedSessionID = id
    }

    /// Fails the session even when readiness no longer accepts a rejection.
    func rejectDelivery(id: UUID) -> CancellationError {
        failCapture(id: id)
        if activeSessionID == id {
            measurement?.finish(.pipelineFailed)
            failSession(
                id: id, message: DictationMicrophoneReadiness.Failure.interrupted.message, autoDismiss: false)
        }
        return CancellationError()
    }
}

extension DictationController {
    func copyUndeliveredText() {
        guard case .recovery = phase, !isRetryingDelivery, let dependencies else { return }
        copyStatus = dependencies.copyText(recoveryText) ? .copied : .failed
    }

    func retryUndeliveredText() {
        guard case .recovery = phase, !isRetryingDelivery,
              let id = deliveryID, let destination, destination.canRetry else { return }
        let text = recoveryText
        isRetryingDelivery = true
        retryDeliveryTask = Task { [weak self] in
            let result = await destination.insert(text)
            guard let self, self.deliveryID == id, !Task.isCancelled else { return }
            self.isRetryingDelivery = false
            if result == .inserted {
                self.showDispatchedText(text, id: id)
            } else {
                self.phase = .recovery(result)
            }
            guard self.deliveryID == id || self.deliveryID == nil else { return }
            self.retryDeliveryTask = nil
        }
    }

    private func showDispatchedText(_ text: String, id: UUID) {
        guard deliveryID == id, let dependencies else { return }
        recoveryText = ""
        copyStatus = .idle
        phase = .inserted(text.split(whereSeparator: \.isWhitespace).count)
        showPanel()
        scheduleFeedbackDismiss(after: .milliseconds(1600), wait: dependencies.waitForFeedbackDismissal)
    }
}

// A session override changes text policy, never preferences or destination authority.
extension DictationController {
    var textMode: DictationTextMode { textPolicy.mode }
    var canChangeTextMode: Bool {
        isActive && activeSessionID != nil && stopTask == nil && stopIssuedSessionID != activeSessionID
    }

    func selectTextMode(_ mode: DictationTextMode) {
        guard canChangeTextMode else { return }
        textPolicy.mode = mode
    }
}
