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

    private var hotkey: GlobalHotkey?
    private var mousePTT: MouseButtonPTT?
    /// True while the active session was started by the mouse button, so
    /// only that button's release may deliver (`MousePTTGesture`).
    private var mouseOwnsSession = false
    private var microphone: MicrophoneSource?
    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var session: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var failureDismissTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private let panel = DictationPanelController()

    /// Registers/unregisters the configured hotkey (⌥⌘D by default) to
    /// match the Settings toggle AND the recorded combination. Called at
    /// launch and whenever either changes — always re-registers so a new
    /// combo takes effect immediately.
    func syncHotkey(services: AppServices) {
        hotkey?.unregister()
        hotkey = nil
        guard UserDefaults.standard.bool(forKey: Self.defaultsKey) else {
            if phase == .listening { cancel() }
            return
        }
        let setting = HotkeySetting.load()
        hotkey = GlobalHotkey(
            keyCode: setting.keyCode,
            modifiers: setting.modifiers,
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
                guard self.phase == .listening,
                    let pressedAt = self.pressedAt,
                    Date().timeIntervalSince(pressedAt) > Self.holdThreshold
                else { return }
                self.finishAndInsert()
            })
    }

    /// Arms/disarms the push-to-talk mouse button to match the Settings
    /// toggle AND the recorded button. Separate from `syncHotkey` because
    /// the event tap needs Accessibility trust the Carbon hotkey does not;
    /// without it the tap silently stays down and dictation remains
    /// keyboard-only until the paste path prompts for the permission.
    func syncMousePTT(services: AppServices) {
        mousePTT?.invalidate()
        mousePTT = nil
        guard UserDefaults.standard.bool(forKey: Self.defaultsKey) else { return }
        let button = MouseButtonSetting.load()
        guard button != MouseButtonSetting.off else { return }
        mousePTT = MouseButtonPTT(
            button: button,
            onPress: { [weak self, weak services] in
                guard let self, let services else { return }
                self.handleMouse(.press, services: services)
            },
            onRelease: { [weak self, weak services] in
                guard let self, let services else { return }
                self.handleMouse(.release, services: services)
            })
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
        switch phase {
        case .idle, .failed, .inserted:
            start(services: services)
        case .listening:
            finishAndInsert()
        }
    }

    private func start(services: AppServices) {
        failureDismissTask?.cancel()
        failureDismissTask = nil
        // The paste needs Accessibility; ask BEFORE recording so the user
        // never dictates into a void.
        guard TextInserter.canInsert(promptIfNeeded: true) else {
            phase = .failed(L10n.text(
                // One-line UI copy.
                // swiftlint:disable:next line_length
                "Dictation needs the Accessibility permission to type into other apps — grant it in System Settings and try again."))
            panel.show(controller: self)
            scheduleFailureDismiss()
            return
        }
        // Capture the destination BEFORE the non-activating panel appears —
        // the frontmost app is still the one the user will dictate into.
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        phase = .listening
        confirmedText = ""
        partialText = ""
        micLevel = 0
        captureStartedAt = nil
        stopTask?.cancel()
        stopTask = nil
        let sessionID = UUID()
        activeSessionID = sessionID
        panel.show(controller: self)

        session = Task { [weak self, weak services] in
            guard let self, let services else { return }
            await self.runSession(id: sessionID, services: services)
        }
    }

    private func runSession(id: UUID, services: AppServices) async {
        let microphone = MicrophoneSource()
        var localFeed: AsyncStream<AudioChunk>.Continuation?
        var pump: Task<Void, Never>?
        do {
            let engine = try await services.loadTranscriberIfNeeded()
            try Task.checkCancellation()
            guard activeSessionID == id else { return }
            self.microphone = microphone

            await microphone.warmUp()
            try Task.checkCancellation()
            let micStream = try await microphone.start()
            try Task.checkCancellation()
            guard activeSessionID == id else {
                await microphone.stop()
                return
            }
            captureStartedAt = Date()

            let (audio, feed) = AsyncStream.makeStream(of: AudioChunk.self)
            localFeed = feed
            self.feed = feed
            pump = makeAudioPump(stream: micStream, feed: feed, sessionID: id)

            let vocabulary = VocabularyPrompt.parse(
                UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
            let hints = TranscriptionHints(vocabulary: vocabulary, meetingID: MeetingID())
            var captions: [TranscriptSegment] = []
            let coalescer = CaptionCoalescer()
            for try await segment in engine.transcribe(audio, hints: hints) {
                try Task.checkCancellation()
                guard activeSessionID == id else { throw CancellationError() }
                coalescer.apply(segment, to: &captions)
                let closed = captions.dropLast().map(\.text)
                confirmedText = closed.joined(separator: " ")
                partialText = captions.last?.text ?? ""
            }
            confirmedText = captions.map(\.text).joined(separator: " ")
            partialText = ""
            await pump?.value
            try Task.checkCancellation()
            guard activeSessionID == id else { return }
            await deliver(sessionID: id)
        } catch is CancellationError {
            localFeed?.finish()
            pump?.cancel()
            await microphone.stop()
            await pump?.value
        } catch {
            localFeed?.finish()
            pump?.cancel()
            await microphone.stop()
            await pump?.value
            failSession(id: id, message: L10n.format(
                "Dictation failed: %@", error.localizedDescription))
        }
    }

    private func makeAudioPump(
        stream: AsyncThrowingStream<AudioChunk, Error>,
        feed: AsyncStream<AudioChunk>.Continuation,
        sessionID: UUID
    ) -> Task<Void, Never> {
        let updateMeter: @MainActor @Sendable (Float) -> Void = { [weak self] peak in
            if let self, self.activeSessionID == sessionID {
                self.micLevel = max(peak, self.micLevel * 0.8)
            }
        }
        return Task.detached {
            do {
                for try await chunk in stream {
                    guard !Task.isCancelled else { break }
                    let peak = chunk.samples.reduce(Float(0)) { max($0, abs($1)) }
                    feed.yield(chunk)
                    await updateMeter(peak)
                }
            } catch {}
            feed.finish()
        }
    }

    /// Second hotkey press: stop the mic; the drained stream delivers.
    private func finishAndInsert() {
        guard phase == .listening else { return }
        guard stopTask == nil else { return }
        guard DictationCapturePolicy.finishDecision(
            captureStartedAt: captureStartedAt, now: Date()) == .stopAfterTail
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
        activeSessionID = nil
        captureStartedAt = nil
        mouseOwnsSession = false
        stopTask?.cancel()
        stopTask = nil
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

    private func deliver(sessionID: UUID) async {
        guard activeSessionID == sessionID else { return }
        let text = DictationAssembler.text(
            confirmed: confirmedText, partial: partialText)
        microphone = nil
        feed = nil
        stopTask = nil
        captureStartedAt = nil
        guard DictationAssembler.hasLexicalContent(text) else {
            completeSession(id: sessionID)
            phase = .idle
            panel.close()
            return
        }
        let result = await TextInserter.insert(text)
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
        session = nil
        microphone = nil
        feed = nil
        stopTask = nil
        captureStartedAt = nil
        mouseOwnsSession = false
    }

    private func failSession(id: UUID, message: String) {
        guard activeSessionID == id else { return }
        completeSession(id: id)
        phase = .failed(message)
        scheduleFailureDismiss()
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

    private struct IntelligenceUnavailable: Error, LocalizedError {
        var errorDescription: String? {
            L10n.text("The transcription model is not available.")
        }
    }
}
