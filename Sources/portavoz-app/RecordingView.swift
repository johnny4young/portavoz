import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

/// Live recording: timer, streaming captions, then the processing states
/// until the meeting lands in the library.
struct RecordingView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings
    @Binding var route: Route?
    /// Calendar event this recording came from (brief's "Record this
    /// meeting") — nil for a blank recording.
    let event: UpcomingEvent?
    /// Recovery routing reuses the exact failure UI but must never trigger a
    /// new capture merely because SwiftUI constructed the destination.
    let startsAutomatically: Bool
    /// Shared with the menu bar and the HUD (AppServices): the session
    /// must be visible and stoppable from outside this view.
    private var controller: RecordingController { services.recording }
    /// Compact floating HUD (GAPS #4): recording without the full window.
    @State private var hud = RecordingHUDController()
    /// One-tap dismiss for the "no incoming audio" nudge (in-person meetings
    /// legitimately have a silent system channel).
    @State private var systemWarningDismissed = false
    /// A hard-limited call may remain usable, so the quality warning is
    /// dismissable without changing or attenuating captured audio.
    @State private var clippingWarningDismissed = false
    /// One-tap dismiss for the "capturing app directly" note.
    @State private var appTapNoteDismissed = false
    /// Where the user put the divider between the captions and the assist
    /// area, kept across recordings.
    @AppStorage("recording.assist.fraction")
    private var assistFraction = RecordingAssistLayout.defaultFraction
    /// The fraction the current divider drag started from.
    @State private var dividerAnchor: Double?
    /// The fraction being dragged right now. `@AppStorage` is written once, on
    /// release: writing it per frame put a `UserDefaults` round trip and a full
    /// `RecordingView` invalidation — captions re-projected and all — into every
    /// tick of the gesture.
    @State private var draggingFraction: Double?

    var body: some View {
        VStack(spacing: 16) {
            switch controller.phase {
            case .idle, .preparing:
                Spacer()
                ProgressView()
                Text(preparingText)
                    .foregroundStyle(.secondary)
                Spacer()

            case .recording:
                // Design system 4a: a compact top bar, then a single column
                // — the words ARE the interface. Captions are the focal
                // lyrics area; the Companion cards and notes flow below.
                recordingBar
                if controller.micLevelLow {
                    micLowBanner
                }
                if controller.systemAudioMissing && !systemWarningDismissed {
                    systemAudioBanner
                }
                if controller.systemAudioClipping && !clippingWarningDismissed {
                    systemAudioClippingBanner
                }
                if controller.microphoneCaptureFailed {
                    Label(L10n.text("Microphone capture failed. Stop and start a new recording."),
                          systemImage: "mic.slash.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("recording-microphone-capture-failure")
                }
                if controller.systemCaptureHealth != .healthy {
                    systemCaptureHealthBanner
                }
                if !controller.tappedMeetingApps.isEmpty && !appTapNoteDismissed {
                    appTapBanner
                }
                if controller.liveTranscriptState == .preparing
                    || controller.liveTranscriptState == .failed {
                    liveTranscriptStatusBanner
                }
                if controller.translationNeedsDownload {
                    translationDownloadBanner
                } else if controller.translationState.shouldPresentStatus(
                    liveTranscriptState: controller.liveTranscriptState
                ) {
                    translationStatusBanner
                }
                assistSplit

            case .processing(let step):
                Spacer()
                ProgressView()
                Text(step).foregroundStyle(.secondary)
                Spacer()

            case .done(let meetingID):
                Color.clear.onAppear {
                    // Flag this as just-recorded so the detail can offer the
                    // post-meeting mirror (6a-2) once, if the user opted in.
                    services.justRecorded = meetingID
                    route = .meeting(meetingID)
                    // Release the shared session so the NEXT "New recording"
                    // starts fresh instead of bouncing back to this meeting.
                    controller.readyForNextSession()
                }

            case .failed(let message):
                Spacer()
                ContentUnavailableView {
                    Label("Something went wrong", systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("recording-failure")
                } description: {
                    VStack(spacing: 8) {
                        Text(message)
                        if let context = controller.failureContext {
                            Text(L10n.format("Error reference: %@", context.code))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("recording-failure-reference")
                        }
                    }
                } actions: {
                    recordingFailureActions
                }
                Spacer()
            }
        }
        .navigationTitle("Recording")
        .liveTranslation(controller)
        .task { await startRecording() }
        .onDisappear { hud.close() }
    }

    @MainActor
    private func startRecording() async {
        guard startsAutomatically else { return }
        await controller.start(services: services, event: event)

        services.simulateStopIntentIfRequested()
    }

    /// Captions and the assist area split the flexible height and the user
    /// owns where the line sits. The assist area used to be pinned at
    /// `maxHeight: 260` while the captions took every flexible point, so a
    /// taller window grew only the captions (D504).
    private var assistSplit: some View {
        GeometryReader { geo in
            let split = RecordingAssistLayout.split(
                total: geo.size.height,
                fraction: draggingFraction ?? assistFraction)
            VStack(spacing: 0) {
                LiveRecordingCaptionsView(controller: controller)
                    .frame(height: split.captions)
                    .padding(.horizontal, 20)
                assistDivider(total: geo.size.height)
                RecordingAssistPanel(controller: controller)
                    .frame(height: split.assist)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 16)
    }

    private func assistDivider(total: CGFloat) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 46, height: 4)
            .frame(maxWidth: .infinity, minHeight: RecordingAssistLayout.dividerHeight)
            .contentShape(Rectangle())
            // `set`, not `push`/`pop`: the divider only exists inside the
            // recording phase, so a teardown while the pointer rests on it
            // never delivers the matching exit and the pushed cursor would
            // outlive the view.
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let anchor = dividerAnchor ?? assistFraction
                        dividerAnchor = anchor
                        draggingFraction = RecordingAssistLayout.fraction(
                            from: anchor,
                            draggedUpBy: -value.translation.height,
                            total: total)
                    }
                    .onEnded { _ in
                        if let dragged = draggingFraction { assistFraction = dragged }
                        draggingFraction = nil
                        dividerAnchor = nil
                    })
            .accessibilityElement()
            .accessibilityLabel(L10n.text("Assist area height"))
            .accessibilityIdentifier("recording-assist-divider")
            .accessibilityAdjustableAction { direction in
                let step = RecordingAssistLayout.fractionStep
                switch direction {
                case .increment:
                    assistFraction = RecordingAssistLayout.clamp(assistFraction + step)
                case .decrement:
                    assistFraction = RecordingAssistLayout.clamp(assistFraction - step)
                @unknown default:
                    break
                }
            }
    }

    private var recordingBar: some View {
        RecordingToolbar(
            controller: controller,
            companionAvailable: services.companionAvailable,
            onStop: { Task { await controller.stop(services: services) } },
            onCompact: enterCompactMode
        )
    }

    /// Shrinks the recording to the floating HUD and miniaturizes the main
    /// window (Dock keeps it reachable). The HUD auto-expands back when the
    /// recording leaves the `.recording` phase.
    private func enterCompactMode() {
        guard !hud.isVisible else { return }
        hud.show(content: RecordingHUDView(
            controller: controller,
            onExpand: { exitCompactMode() },
            onStop: { Task { await controller.stop(services: services) } },
            onHeight: { [hud] height in hud.setContentHeight(height) }))
        NSApp.keyWindow?.miniaturize(nil)
    }

    private func exitCompactMode() {
        hud.close()
        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

}

/// High-frequency caption projection has its own observation boundary. Mic
/// meter updates and capture-health counters can now refresh the toolbar or a
/// banner without rebuilding the bounded transcript carousel.
private struct LiveRecordingCaptionsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var controller: RecordingController

    var body: some View {
        let projection = LiveCaptionParagraphProjector.project(
            captions: controller.captions,
            liveSpeakerLabels: controller.liveSpeakerLabels,
            translations: controller.translations)
        GeometryReader { geo in
            FocusedTranscriptView(
                segments: projection.segments,
                activeID: projection.segments.last?.id,
                height: geo.size.height,
                anchor: UnitPoint(x: 0.5, y: 0.82),
                followSignal: projection.segments.last?.endTime ?? 0,
                mode: .live,
                scrollAccessibilityIdentifier: "recording-live-transcript"
            ) { segment, active in
                captionRow(
                    segment,
                    active: active,
                    translation: projection.translations[segment.id])
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func captionRow(
        _ segment: TranscriptSegment,
        active: Bool,
        translation: String?
    ) -> some View {
        let voice = liveVoice(for: segment)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(voice.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(voice.isMe ? VoicePalette.meContrast : pillInk(voice))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(pillBackground(voice), in: Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(segment.text)
                    .font(active ? .title3.weight(.medium) : .body)
                    .foregroundStyle(segment.isFinal ? .primary : .secondary)
                if let translated = translation {
                    translatedCaption(translated, segmentID: segment.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, active && voice.isMe ? 10 : 0)
        .background {
            if active && voice.isMe {
                RoundedRectangle(cornerRadius: PVDesign.radiusCard)
                    .fill(VoicePalette.me.opacity(0.12))
                    .strokeBorder(VoicePalette.me.opacity(0.35))
            }
        }
        .padding(.horizontal, 8)
    }

    private func translatedCaption(
        _ translated: String,
        segmentID: UUID
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Capsule()
                .fill(Color.indigo)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "character.bubble")
                        .accessibilityHidden(true)
                    Text(liveTranslationLabel)
                        .accessibilityLabel(liveTranslationLabel)
                        .accessibilityIdentifier(
                            "recording-live-translation-\(segmentID.uuidString)")
                }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.indigo)
                Text(translated)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Color.indigo.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 7))
    }

    private var liveTranslationLabel: String {
        switch LanguageCode(controller.translationTarget)?.identifier {
        case "es":
            L10n.text("Spanish translation")
        case "en":
            L10n.text("English translation")
        default:
            L10n.text("Translation")
        }
    }

    private func pillInk(_ voice: (label: String, isMe: Bool)) -> Color {
        guard voice.label != L10n.text("Them") else { return .secondary }
        return VoicePalette.color(
            index: VoiceHue.index(name: voice.label, fallbackOrder: 0),
            colorScheme: colorScheme)
    }

    private func pillBackground(_ voice: (label: String, isMe: Bool)) -> Color {
        if voice.isMe { return VoicePalette.me }
        guard voice.label != L10n.text("Them") else {
            return Color(nsColor: .quaternarySystemFill)
        }
        return pillInk(voice).opacity(0.22)
    }

    private func liveVoice(
        for segment: TranscriptSegment
    ) -> (label: String, isMe: Bool) {
        if segment.channel == .microphone { return (L10n.text("Me"), true) }
        if let voice = controller.liveSpeakerLabels[segment.id] {
            return voice == "Me" ? (L10n.text("Me"), true) : (voice, false)
        }
        return (L10n.text("Them"), false)
    }
}

// MARK: - Capture / translation nudges
//
// The dismissable banners over the caption area, split out to keep the main
// view body under the length limit. `private` stays file-scoped, so these
// still reach `controller` and `systemWarningDismissed`.
extension RecordingView {
    /// A tap that stops invoking its callback is different from silent audio:
    /// the remote timeline has stopped advancing. This critical notice cannot
    /// be dismissed; it clears only after frames return or the recording ends.
    var systemCaptureHealthBanner: some View {
        HStack(spacing: 10) {
            Label {
                Text(systemCaptureHealthMessage)
            } icon: {
                Image(systemName: systemCaptureHealthIcon)
            }
            .accessibilityIdentifier("recording-system-capture-health")
            Spacer(minLength: 4)
            if controller.shouldSuggestStopForRemoteOutage {
                Button("Stop now") {
                    Task { await controller.stop(services: services) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .accessibilityIdentifier("recording-stop-after-remote-outage")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(systemCaptureHealthColor)
        .padding(.horizontal, 20)
    }

    private var systemCaptureHealthMessage: String {
        switch controller.systemCaptureHealth {
        case .healthy:
            ""
        case .stalled, .recovering:
            if controller.shouldSuggestStopForRemoteOutage {
                L10n.text(
                    "Remote audio has been unavailable for two minutes. If the call ended, stop this recording.")
            } else {
                L10n.text(
                    "Remote audio stopped — reconnecting… Your microphone is still recording.")
            }
        case .recovered:
            L10n.text("Remote audio capture recovered.")
        case .failed:
            L10n.text(
                "Remote audio capture failed. Stop and start a new recording to avoid losing the call.")
        }
    }

    private var systemCaptureHealthIcon: String {
        switch controller.systemCaptureHealth {
        case .recovered: "checkmark.circle.fill"
        case .healthy, .stalled, .recovering, .failed: "exclamationmark.triangle.fill"
        }
    }

    private var systemCaptureHealthColor: Color {
        switch controller.systemCaptureHealth {
        case .recovered: .green
        case .healthy, .stalled, .recovering, .failed: .orange
        }
    }

    /// Audio is the primary artifact: a fresh install starts recording now,
    /// while the verified local model prepares in the background. The durable
    /// worker fills the complete transcript from the saved channels after Stop.
    var liveTranscriptStatusBanner: some View {
        Label {
            Text(liveTranscriptStatusMessage)
        } icon: {
            Image(systemName: controller.liveTranscriptState == .failed
                ? "exclamationmark.triangle.fill" : "waveform.badge.clock")
        }
        .font(.caption)
        .foregroundStyle(controller.liveTranscriptState == .failed ? .orange : .secondary)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(liveTranscriptStatusMessage)
        .accessibilityIdentifier("recording-transcript-deferred")
    }

    private var liveTranscriptStatusMessage: String {
        switch controller.liveTranscriptState {
        case .preparing:
            L10n.text(
                // swiftlint:disable:next line_length
                "Audio is safe. Live captions will start automatically when the local model is ready; Stop still creates the complete transcript.")
        case .failed:
            L10n.text(
                "Live captions could not start. Audio is safe; Stop will create the complete transcript.")
        case .idle, .available:
            ""
        }
    }

    /// Shown only when the mic stays quiet — the far-field-mic nudge (field
    /// bug jul 2026), out of the compact bar so it never crowds it.
    var micLowBanner: some View {
        Label(
            "Your voice sounds low — move closer or use headphones with a microphone",
            systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 20)
    }

    /// Shown when the incoming (system) channel stays near-silent — likely a
    /// call whose audio isn't reaching the tap (Bluetooth output, or the
    /// system-audio permission). Dismissable, since an in-person meeting has
    /// no incoming audio by design.
    var systemAudioBanner: some View {
        HStack(spacing: 8) {
            Label(
                // One-line UI copy.
                // swiftlint:disable:next line_length
                "Barely hearing the other participants — if this is a call, check your output device or system-audio permission.",
                systemImage: "speaker.slash.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Dismiss") { systemWarningDismissed = true }
                .buttonStyle(.plain)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

    /// Repeated ceiling hits mean the call source is likely already distorted.
    /// Portavoz reports the quality risk but never changes the call graph or
    /// rewrites the evidence that Refine will later review.
    var systemAudioClippingBanner: some View {
        HStack(spacing: 8) {
            Label(
                "The other participants' audio is clipping — transcript accuracy may be lower.",
                systemImage: "waveform.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Dismiss") { clippingWarningDismissed = true }
                .buttonStyle(.plain)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recording-system-audio-clipping-dismiss")
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recording-system-audio-clipping")
    }

    /// Shown when a Bluetooth output made Portavoz tap the meeting app's
    /// process directly so the call stays isolated from unrelated app audio
    /// (and still works on AirPods, where HFP silences the global tap).
    /// Informational; names the app(s).
    var appTapBanner: some View {
        HStack(spacing: 8) {
            Label(
                L10n.format(
                    "Capturing %@ directly; unrelated app audio stays out.",
                    controller.tappedMeetingApps.joined(separator: ", ")),
                systemImage: "airpods")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Got it") { appTapNoteDismissed = true }
                .buttonStyle(.plain)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

    /// Live translation needs a language pack Apple hasn't downloaded yet. We
    /// never let the system sheet pop up on its own mid-meeting — this banner
    /// makes the download a deliberate choice, and the fetch runs in the
    /// background once approved.
    var translationDownloadBanner: some View {
        HStack(spacing: 8) {
            Label(
                "Live translation needs a one-time language download.",
                systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Download") { controller.translationDownloadApproved = true }
                .buttonStyle(.plain)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
            Button("Not now") { controller.translationTarget = nil }
                .buttonStyle(.plain)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }

    var translationStatusBanner: some View {
        Label {
            Text(translationStatusMessage)
        } icon: {
            Image(systemName: controller.translationState == .failed
                ? "exclamationmark.triangle.fill" : "character.bubble")
        }
        .font(.caption)
        .foregroundStyle(controller.translationState == .failed ? .orange : .secondary)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("recording-live-translation-status")
    }

    private var translationStatusMessage: String {
        guard let key = controller.translationState.statusMessageKey else { return "" }
        return L10n.text(key)
    }
}

private extension RecordingView {
    @ViewBuilder
    private var recordingFailureActions: some View {
        if let context = controller.failureContext {
            switch context.recovery {
            case .retry:
                Button("Try again") {
                    Task { await controller.start(services: services, event: event) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("recording-retry")
            case .library:
                Button("Open Library") { route = nil }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("recording-open-library")
            case .supportDiagnostics:
                Button("Open support diagnostics") {
                    services.pendingSettingsCategory = .data
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("recording-open-support-diagnostics")
            }
        }
        Button("Back") { route = nil }
            .accessibilityIdentifier("recording-back")
    }

    private var preparingText: String {
        if case .downloading(let status) = services.modelsState {
            return status
        }
        return L10n.text("Preparing…")
    }

}
