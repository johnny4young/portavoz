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
    private var microphone: MicrophoneSource?
    private var feed: AsyncStream<AudioChunk>.Continuation?
    private var session: Task<Void, Never>?
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

    /// Press-to-release lapse that separates a toggle TAP from a
    /// hold-to-talk gesture.
    private static let holdThreshold: TimeInterval = 0.5
    private var pressedAt: Date?

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
        panel.show(controller: self)

        session = Task { [weak self, weak services] in
            guard let self, let services else { return }
            do {
                let engine = try await services.loadTranscriberIfNeeded()
                let microphone = MicrophoneSource()
                self.microphone = microphone
                await microphone.warmUp()
                let micStream = try await microphone.start()

                let (audio, feed) = AsyncStream.makeStream(of: AudioChunk.self)
                self.feed = feed
                let pump = Task { [weak self] in
                    do {
                        for try await chunk in micStream {
                            let peak = chunk.samples.reduce(Float(0)) { max($0, abs($1)) }
                            if let self { self.micLevel = max(peak, self.micLevel * 0.8) }
                            feed.yield(chunk)
                        }
                    } catch {}
                    feed.finish()
                }

                let vocabulary = VocabularyPrompt.parse(
                    UserDefaults.standard.string(forKey: "customVocabulary") ?? "")
                let hints = TranscriptionHints(vocabulary: vocabulary, meetingID: MeetingID())
                var captions: [TranscriptSegment] = []
                let coalescer = CaptionCoalescer()
                for try await segment in engine.transcribe(audio, hints: hints) {
                    coalescer.apply(segment, to: &captions)
                    let closed = captions.dropLast().map(\.text)
                    self.confirmedText = closed.joined(separator: " ")
                    self.partialText = captions.last?.text ?? ""
                }
                // Stream drained (mic stopped): everything is confirmed now.
                self.confirmedText = captions.map(\.text).joined(separator: " ")
                self.partialText = ""
                await pump.value
                self.deliver()
            } catch {
                self.phase = .failed(L10n.format(
                    "Dictation failed: %@", error.localizedDescription))
                self.scheduleFailureDismiss()
            }
        }
    }

    /// Second hotkey press: stop the mic; the drained stream delivers.
    private func finishAndInsert() {
        guard phase == .listening else { return }
        let microphone = self.microphone
        Task { await microphone?.stop() }
    }

    /// Esc in the panel: throw everything away.
    func cancel() {
        session?.cancel()
        session = nil
        let microphone = self.microphone
        Task { await microphone?.stop() }
        self.microphone = nil
        feed = nil
        phase = .idle
        panel.close()
    }

    private func deliver() {
        let text = DictationAssembler.text(
            confirmed: confirmedText, partial: partialText)
        microphone = nil
        feed = nil
        session = nil
        guard !text.isEmpty else {
            phase = .idle
            panel.close()
            return
        }
        TextInserter.insert(text)
        // Confirm the insertion for a beat, then fade — the user sees it took.
        let words = text.split(whereSeparator: \.isWhitespace).count
        phase = .inserted(words)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard let self, case .inserted = self.phase else { return }
            self.phase = .idle
            self.panel.close()
        }
    }

    private func scheduleFailureDismiss() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, case .failed = self.phase else { return }
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
