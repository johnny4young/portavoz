// Session and delivery state stays private to this type and its same-file
// extensions; splitting it only for the line-count rule would expose it.
// swiftlint:disable file_length

import AppKit
import AudioCaptureKit
import Carbon.HIToolbox
import Foundation
import Observation
import PortavozCore
import SwiftUI
import TranscriptionKit

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
        /// The paste is in flight: a second trigger can neither cancel nor restart it.
        case delivering
        case verified(Int)
        case dispatched(Int)
        /// The voice detector heard no speech; the text is offered, never pasted.
        case noSpeech
        case failed(String)
        case recovery(DictationDeliveryOutcome.Refusal)
    }

    private(set) var phase: Phase = .idle
    /// Rows confirmed by the engine so far (coalesced, echo-trimmed).
    private(set) var confirmedText = ""
    /// The still-changing tail of what's being said.
    private(set) var partialText = ""
    /// Mic peak with fast attack / slow decay (same VU feel as the HUD).
    private(set) var micLevel: Float = 0
    private(set) var microphoneNotice: String?
    private var loadingModelSessionID: UUID?

    var isActive: Bool { phase == .preparing || phase == .listening || phase == .delivering }
    /// The app that was frontmost when dictation started — where the text
    /// will land. The strip shows it so you never dictate "blind" (4b).
    private(set) var targetApp: String?
    /// The caret or pointer the strip opens beside, read with the destination.
    private(set) var panelAnchor: DictationPanelAnchor?

    enum CopyStatus: Equatable { case idle, copied, failed }
    private(set) var recoveryText = ""
    private(set) var copyStatus: CopyStatus = .idle
    private(set) var isRetryingDelivery = false
    var canRetryDelivery: Bool { destination?.canRetry == true }
    private(set) var destination: CapturedDictationDestination?
    private var dependencies: DictationSessionDependencies?
    private(set) var deliveryID: UUID?
    private(set) var history: DictationHistorySession?
    var statsDraft: DictationStatsDraft?
    @ObservationIgnored private(set) var retryDeliveryTask: Task<Void, Never>?

    let shortcut = DictationShortcut()
    private var mousePTT: MouseButtonPTT?
    private var mousePTTButton: Int?
    /// True while the active session was started by the mouse button, so
    /// only that button's release may deliver (`MousePTTGesture`).
    private var mouseOwnsSession = false
    var modifierTrigger = ModifierTriggerState()
    private var microphone: (any AudioCaptureSource)?
    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var session: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var stopIssuedSessionID: UUID?
    private var relayEndedSessionID: UUID?
    @ObservationIgnored private let feedback = DictationFeedbackTimer()
    var pressedSessionID: UUID?
    private var sessionFeedbackWait: (@MainActor (Duration) async throws -> Void)?
    private(set) var activeSessionID: UUID?
    private var measurement: DictationSessionMeasurementRecorder?
    private var textPolicy = DictationTextPreferenceSnapshot.inert
    /// Set once delivery has prepared its text; a later panel choice could not apply.
    /// Only `start` clears it: between sessions `canChangeTextMode` is already false.
    private var textPolicySealed = false
    private let panel = DictationPanelController()
    private let presentsPanel: Bool
    private var sessionClock: (() -> Date)?
    @ObservationIgnored private var cancelKey: (any GlobalHotkeyRegistration)?
    @ObservationIgnored private var analysis = DictationSessionAnalysis()

    let lastText: DictationLastText

    init(presentsPanel: Bool = true, lastText: DictationLastText? = nil) {
        self.presentsPanel = presentsPanel
        // A headless controller never watches system sleep or lock.
        self.lastText = lastText ?? DictationLastText(observesSystem: presentsPanel)
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

    /// Press-to-release lapse that separates a toggle TAP from a
    /// hold-to-talk gesture.
    static let holdThreshold: TimeInterval = 0.5
    var pressedAt: Date?

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
        case .idle, .failed, .verified, .dispatched, .noSpeech:
            start(using: dependencies)
        case .preparing:
            cancel()
        case .listening:
            finishAndInsert()
        case .delivering:
            break
        case .recovery:
            showPanel()
        }
    }

    func start(services: AppServices) {
        start(using: services.makeDictationSessionDependencies())
    }

    private func start(using dependencies: DictationSessionDependencies) {
        // A global trigger cannot silently replace refused, undelivered words.
        // An unverified dispatch was already sent: its notice is non-modal and
        // a new dictation replaces it (never re-sending the old output).
        if case .recovery = phase { showPanel(); return }
        guard phase != .delivering else { return }
        retryDeliveryTask?.cancel()
        retryDeliveryTask = nil
        isRetryingDelivery = false
        deliveryID = nil
        destination = nil
        recoveryText = ""
        copyStatus = .idle
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
        panelAnchor = dependencies.locatePanelAnchor()
        textPolicy = DictationTextPreferences.snapshot(
            in: dependencies.defaults, bundleIdentifier: destination.bundleIdentifier)
        textPolicySealed = false
        phase = .preparing
        confirmedText = ""
        partialText = ""
        micLevel = 0
        microphoneNotice = nil
        retireMicrophoneReadiness()
        stopTask?.cancel()
        stopTask = nil
        let sessionID = UUID()
        history = dependencies.beginHistory().map { DictationHistorySession(sessionID: sessionID, write: $0) }
        activeSessionID = sessionID
        sessionClock = dependencies.now
        armCancelKey(dependencies, sessionID: sessionID)
        // Before the microphone opens, so the cue itself is never captured.
        dependencies.playCue(.start)
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
        let acquisition = DictationRuntimeAcquisition(acquire: dependencies.acquireRuntime)
        await runCapture(
            id: id, dependencies: dependencies, measurement: measurement,
            acquisition: acquisition, microphone: &microphone)
        // The lease outlives catch-path native cleanup, never the session.
        await acquisition.settle()
        // EOF can precede native teardown, and a cancelled session can overlap
        // its replacement. Retire only this source before releasing its owner.
        await microphone?.stop()
    }

    private func runCapture(
        id: UUID, dependencies: DictationSessionDependencies,
        measurement: DictationSessionMeasurementRecorder?,
        acquisition: DictationRuntimeAcquisition,
        microphone: inout (any AudioCaptureSource)?
    ) async {
        var localFeed: AsyncStream<AudioChunk>.Continuation?
        var pump: Task<Void, Never>?
        do {
            let input = try await dependencies.authorizedMicrophone()
            guard activeSessionID == id else { return }
            microphone = input.source
            self.microphone = input.source
            microphoneNotice = input.usesSystemFallback ? L10n.text(
                "Your preferred microphone is unavailable. Using the system default for this dictation.") : nil
            // Audio-first: speech during a cold load waits in the bounded relay.
            acquisition.start()
            let readiness = makeMicrophoneReadiness(id: id, dependencies: dependencies, measurement: measurement)
            defer { readiness.finish() }
            monitorCaptureFailure(input.source, id: id)
            readiness.beginDeadline(wait: dependencies.waitForFirstBufferDeadline)
            await input.warmUp()
            try Task.checkCancellation()
            let micStream = try await input.source.start()
            try Task.checkCancellation()
            guard activeSessionID == id else { throw CancellationError() }
            // Stream construction can precede its first hardware callback.
            // Only an admitted nonempty buffer starts the capture clock.
            measurement?.record(.microphoneReady)

            // Dictation has no durable original to replay. A bounded relay
            // remains safe only when every dropped chunk revokes delivery.
            let (audio, feed) = AsyncStream.makeStream(
                of: AudioChunk.self,
                bufferingPolicy: .bufferingNewest(DictationRelayPolicy.capacity))
            localFeed = feed
            self.feed = feed
            let analysis = DictationSessionAnalysis(gate: dependencies.makeSpeechGate(), pause: dependencies
                .makePauseDetector { [weak self] in Task { @MainActor in self?.stopAfterPause(sessionID: id) } })
            self.analysis = analysis
            pump = startPump(
                readiness: readiness, stream: micStream, feed: feed, sessionID: id, measurement: measurement,
                mirror: analysis.offer)

            let runtime = try await awaitRuntime(acquisition, id: id, measurement: measurement)
            analysis.pause?.arm()
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
    func finishAndInsert() {
        guard phase == .preparing || phase == .listening else { return }
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
        let playCue = dependencies?.playCue
        stopTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.stopTail)
            } catch {
                return
            }
            guard let self, self.activeSessionID == sessionID else { return }
            self.stopIssuedSessionID = sessionID
            await microphone?.stop()
            playCue?(.stop)
        }
    }

    /// Esc or the panel's cancel control: throw everything away.
    func cancel() {
        releaseCancelKey()
        releaseSpeechGate()
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
        textPolicy = .inert
        sessionClock = nil
        confirmedText = ""
        partialText = ""
        micLevel = 0
        retireMicrophoneReadiness()
        mouseOwnsSession = false
        modifierTrigger.ownsSession = false
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
        let original = DictationAssembler.text(confirmed: confirmedText, partial: partialText)
        let text = textPolicy.applying(to: original)
        prepareHistory(original: original, text: text, dependencies: dependencies)
        // Stop bookkeeping retires below while the phase stays active until the
        // insertion settles; the panel must not offer a choice that cannot apply.
        textPolicySealed = true
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
        releaseCancelKey()
        phase = .delivering
        showPanel()
        if let gate = analysis.gate, await gate.verdict() == .noSpeech {
            guard activeSessionID == sessionID else { return }
            presentNoSpeech(text, id: sessionID)
            return
        }
        guard activeSessionID == sessionID else { return }
        measurement?.record(.deliveryStarted)
        let result = await destination.insert(text)
        measurement?.finishDelivery(result)
        guard activeSessionID == sessionID else { return }
        completeSession(id: sessionID)
        deliveryID = sessionID
        presentDelivery(result, text: text, id: sessionID)
    }

    private func completeSession(id: UUID) {
        guard activeSessionID == id else { return }
        releaseCancelKey()
        releaseSpeechGate()
        activeSessionID = nil
        textPolicy = .inert
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
        modifierTrigger.ownsSession = false
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

}

private extension DictationController {
    func awaitRuntime(
        _ acquisition: DictationRuntimeAcquisition, id: UUID,
        measurement: DictationSessionMeasurementRecorder?
    ) async throws -> LiveTranscriptionRuntime {
        loadingModelSessionID = id
        defer { if loadingModelSessionID == id { loadingModelSessionID = nil } }
        let runtime = try await acquisition.runtime()
        measurement?.record(.runtimeReady)
        try Task.checkCancellation()
        guard activeSessionID == id else { throw CancellationError() }
        return runtime
    }

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
            // The relay only overflows while nothing drains it: the model is still loading.
            let message = failure == .interrupted && isLoadingModel
                ? L10n.text("The speech model took too long to load. Nothing was inserted. Try again in a moment.")
                : failure.message
            failSession(id: id, message: message, autoDismiss: false)
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
        measurement: DictationSessionMeasurementRecorder?,
        mirror: @escaping @Sendable (AudioChunk) -> Void
    ) -> Task<Void, Never> {
        readiness.pump(
            stream: stream, feed: feed, mirror: mirror,
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
            failSession(id: id, message: DictationMicrophoneReadiness.Failure.interrupted.message, autoDismiss: false)
        }
        return CancellationError()
    }
}

extension DictationController {
    private var hasPendingOutput: Bool {
        switch phase {
        case .recovery, .dispatched, .noSpeech: true
        default: false
        }
    }

    func copyPendingText() {
        guard hasPendingOutput, !isRetryingDelivery, let dependencies else { return }
        copyStatus = dependencies.copyText(recoveryText) ? .copied : .failed
        // Someone using the panel decides when it closes; Escape returns to the destination.
        if case .dispatched = phase {
            cancelFeedbackDismissal()
            releaseCancelKey()
        }
    }

    /// Closes a delivery notice now, keeping the text for Paste last.
    func dismissFeedback() {
        switch phase {
        case .verified, .dispatched: closeFeedback()
        default: return
        }
    }

    func retryUndeliveredText() {
        guard case .recovery = phase, !isRetryingDelivery,
              let id = deliveryID, let destination, destination.canRetry else { return }
        replay(recoveryText, into: destination, id: id)
    }

    /// Pastes the remembered text into whatever is focused now, through the
    /// same delivery and recovery path as a fresh dictation. Undelivered words
    /// in recovery are that text, so they paste where the user is now.
    func pasteLastDictation(using dependencies: DictationSessionDependencies) {
        guard !isActive, retryDeliveryTask == nil, let text = pastableText(), dependencies.canInsert()
        else { return }
        cancelFeedbackDismissal()
        self.dependencies = dependencies
        let id = UUID()
        deliveryID = id
        replay(text, into: dependencies.captureDestination(), id: id)
    }

    private func replay(_ text: String, into destination: CapturedDictationDestination, id: UUID) {
        self.destination = destination
        isRetryingDelivery = true
        retryDeliveryTask = Task { [weak self] in
            let result = await destination.insert(text)
            guard let self, self.deliveryID == id, !Task.isCancelled else { return }
            self.isRetryingDelivery = false
            self.presentDelivery(result, text: text, id: id)
            self.retryDeliveryTask = nil
        }
    }

    private func presentDelivery(_ result: DictationDeliveryOutcome, text: String, id: UUID) {
        guard deliveryID == id, let dependencies else { return }
        cancelFeedbackDismissal()
        copyStatus = .idle
        lastText.remember(text)
        recordHistory(result, id: id)
        if case .refused(let failure) = result {
            recoveryText = text
            phase = .recovery(failure)
            showPanel()
            return
        }
        destination = nil
        let words = text.split(whereSeparator: \.isWhitespace).count
        phase = result == .verified ? .verified(words) : .dispatched(words)
        // A posted event may arrive late; retained output never authorizes replay.
        recoveryText = result == .dispatched ? text : ""
        showPanel()
        // Unverified output closes too; Paste last still holds it for 15 minutes.
        scheduleFeedbackDismiss(
            after: result == .verified ? .milliseconds(1600) : Self.unverifiedFeedbackDuration,
            wait: dependencies.waitForFeedbackDismissal)
        if result == .dispatched { armFeedbackDismissKey(dependencies) }
    }
}

// A session override changes text policy, never preferences or destination authority.
extension DictationController {
    /// When the first audio arrived, for the compact indicator's elapsed time.
    var captureStartedAt: Date? { microphoneReadiness?.firstFrameAt }
    static let unverifiedFeedbackDuration: Duration = .seconds(4)
    /// Listening while the model still loads; the relay holds the speech.
    var isLoadingModel: Bool { loadingModelSessionID != nil && loadingModelSessionID == activeSessionID }
    var textMode: DictationTextMode { textPolicy.mode }
    var canChangeTextMode: Bool {
        isActive && activeSessionID != nil && !textPolicySealed && stopTask == nil
            && stopIssuedSessionID != activeSessionID
    }

    func selectTextMode(_ mode: DictationTextMode) {
        guard canChangeTextMode else { return }
        textPolicy.mode = mode
    }
}

// Session-owned auxiliaries: the Escape claim and feedback dismissal.
private extension DictationController {
    func armCancelKey(_ dependencies: DictationSessionDependencies, sessionID: UUID) {
        releaseCancelKey()
        cancelKey = dependencies.registerCancelKey { [weak self] in
            // Leave the Carbon callback before its own registration is removed.
            Task { @MainActor [weak self] in
                guard let self, self.activeSessionID == sessionID,
                      self.phase == .preparing || self.phase == .listening else { return }
                self.cancel()
            }
        }
    }

    func releaseCancelKey() {
        cancelKey?.unregister()
        cancelKey = nil
    }

    func releaseSpeechGate() {
        analysis.cancel()
        analysis = DictationSessionAnalysis()
    }

    /// A tap-started dictation ends itself after a pause; a held trigger never does.
    func stopAfterPause(sessionID: UUID) {
        guard activeSessionID == sessionID, phase == .listening, !isLoadingModel, stopTask == nil, !mouseOwnsSession,
              !modifierTrigger.ownsSession, pressedSessionID != sessionID else { return }
        finishAndInsert()
    }

    /// No paste: the text stays reachable for Copy in case speech was missed.
    func presentNoSpeech(_ text: String, id: UUID) {
        measurement?.finish(.noSpeech)
        completeSession(id: id)
        deliveryID = id
        destination = nil
        cancelFeedbackDismissal()
        copyStatus = .idle
        recoveryText = text
        lastText.remember(text)
        phase = .noSpeech
        showPanel()
    }

    func cancelFeedbackDismissal() {
        feedback.cancel()
    }

    func scheduleFeedbackDismiss(
        after delay: Duration,
        wait: @escaping @MainActor (Duration) async throws -> Void
    ) {
        feedback.schedule(after: delay, wait: wait) { [weak self] in self?.closeFeedback() }
    }

    /// Escape closes the unverified notice only while it counts down.
    func armFeedbackDismissKey(_ dependencies: DictationSessionDependencies) {
        releaseCancelKey()
        cancelKey = dependencies.registerCancelKey { [weak self] in
            Task { @MainActor [weak self] in
                // A queued press after Copy or a newer session must not close anything.
                guard let self, case .dispatched = self.phase, self.feedback.isCounting else { return }
                self.dismissFeedback()
            }
        }
    }

    func closeFeedback() {
        releaseCancelKey()
        cancelFeedbackDismissal()
        deliveryID = nil
        destination = nil
        dependencies = nil
        recoveryText = ""
        copyStatus = .idle
        phase = .idle
        panel.close()
    }

}

// The mouse trigger reads private session state, so it stays in this file.
extension DictationController {
    fileprivate func handleMouse(
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
}
