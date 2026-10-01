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
        case verified(Int)
        case dispatched(Int)
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

    var isActive: Bool { phase == .preparing || phase == .listening }
    /// The app that was frontmost when dictation started — where the text
    /// will land. The strip shows it so you never dictate "blind" (4b).
    private(set) var targetApp: String?

    enum CopyStatus: Equatable { case idle, copied, failed }
    private(set) var recoveryText = ""
    private(set) var copyStatus: CopyStatus = .idle
    private(set) var isRetryingDelivery = false
    var canRetryDelivery: Bool { destination?.canRetry == true }
    private var hasPendingOutput: Bool {
        switch phase {
        case .recovery, .dispatched: true
        default: false
        }
    }
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
    @ObservationIgnored private(set) var dismissTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var measurement: DictationSessionMeasurementRecorder?
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
        case .idle, .failed, .verified:
            start(using: dependencies)
        case .preparing:
            cancel()
        case .listening:
            finishAndInsert()
        case .recovery, .dispatched:
            showPanel()
        }
    }

    private func start(services: AppServices) {
        start(using: services.makeDictationSessionDependencies())
    }

    private func start(using dependencies: DictationSessionDependencies) {
        // A global trigger cannot silently replace undelivered words.
        if hasPendingOutput { showPanel(); return }
        retryDeliveryTask?.cancel()
        retryDeliveryTask = nil
        deliveryID = nil
        destination = nil
        self.dependencies = dependencies
        measurement = dependencies.measurementSink.map {
            DictationSessionMeasurementRecorder(now: dependencies.measurementClock, sink: $0)
        }
        dismissTask?.cancel()
        dismissTask = nil
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
            scheduleFailureDismiss()
            return
        }
        // Capture the destination BEFORE the non-activating panel appears —
        // the frontmost app is still the one the user will dictate into.
        let destination = dependencies.captureDestination()
        self.destination = destination
        targetApp = destination.name
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

            // Bounded like every other live audio handoff (the recording lane
            // uses the same 128-buffer window). The pump never suspends on the
            // consumer, so an unbounded stream lets a stalled engine grow the
            // backlog for as long as dictation runs; dropping the oldest audio
            // is the same trade live transcription already makes.
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
            await pump?.value
            try Task.checkCancellation()
            guard activeSessionID == id else { return }
            await deliver(sessionID: id, dependencies: dependencies)
        } catch is CancellationError {
            measurement?.finish(.cancelled)
            await stopCapture(feed: localFeed, pump: pump, microphone: microphone)
        } catch {
            let permissionDenied = (error as? DictationMicrophoneReadiness.Failure) == .permissionRequired
            measurement?.finish(permissionDenied ? .permissionDenied : .pipelineFailed)
            await stopCapture(feed: localFeed, pump: pump, microphone: microphone)
            if let message = DictationMicrophoneReadiness.preparationMessage(for: error) {
                failSession(id: id, message: message, autoDismiss: false)
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
        activeSessionID = nil
        sessionClock = nil
        confirmedText = ""
        partialText = ""
        micLevel = 0
        retireMicrophoneReadiness()
        mouseOwnsSession = false
        stopTask?.cancel()
        stopTask = nil
        dismissTask?.cancel()
        dismissTask = nil
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
        let text = DictationTextRules.apply(
            DictationAssembler.text(
                confirmed: confirmedText, partial: partialText),
            replacements: DictationTextRules.decode(
                replacements: dependencies.defaults.string(
                    forKey: Self.replacementsKey) ?? ""),
            removeFillers: Self.fillerFilterEnabled(in: dependencies.defaults))
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
        presentDelivery(result, text: text, id: sessionID)
    }

    private func completeSession(id: UUID) {
        guard activeSessionID == id else { return }
        activeSessionID = nil
        sessionClock = nil
        session = nil
        microphone = nil
        feed = nil
        stopTask = nil
        retireMicrophoneReadiness()
        mouseOwnsSession = false
    }

    private func failSession(id: UUID, message: String, autoDismiss: Bool = true) {
        guard activeSessionID == id else { return }
        completeSession(id: id)
        destination = nil
        dependencies = nil
        phase = .failed(message)
        if autoDismiss { scheduleFailureDismiss() }
    }

    private func scheduleFailureDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            guard let self, case .failed = self.phase else { return }
            self.dismissTask = nil
            self.phase = .idle
            self.panel.close()
        }
    }

}

private extension DictationController {
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
            feed?.finish()
            let source = microphone
            Task { await source?.stop() }
            failSession(id: id, message: failure.message, autoDismiss: false)
        })
        microphoneReadiness = readiness
        return readiness
    }

    func retireMicrophoneReadiness() {
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
            onInputEnded: { if let measurement { await measurement.record(.inputEnded) } },
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
}

extension DictationController {
    func copyPendingText() {
        guard hasPendingOutput, !isRetryingDelivery, let dependencies else { return }
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
            self.presentDelivery(result, text: text, id: id)
            guard self.deliveryID == id || self.deliveryID == nil else { return }
            self.retryDeliveryTask = nil
        }
    }

    private func presentDelivery(_ result: DictationDeliveryOutcome, text: String, id: UUID) {
        if case .refused(let failure) = result {
            recoveryText = text
            copyStatus = .idle
            phase = .recovery(failure)
            showPanel()
            return
        }
        copyStatus = .idle
        dismissTask?.cancel()
        dismissTask = nil
        destination = nil
        let words = text.split(whereSeparator: \.isWhitespace).count
        phase = result == .verified ? .verified(words) : .dispatched(words)
        // Unknown acknowledgement is neither failure nor permission to replay.
        // Keep complete output until explicit Copy/Discard; capture is finished.
        recoveryText = result == .dispatched ? text : ""
        showPanel()
        guard result == .verified else { return }
        // Only verified feedback expires. Its timer cannot hold the runtime lease.
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
            guard let self, self.deliveryID == id else { return }
            self.dismissTask = nil
            self.deliveryID = nil
            self.destination = nil
            self.dependencies = nil
            self.phase = .idle
            self.panel.close()
        }
    }
}
