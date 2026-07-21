import ApplicationKit
import IntelligenceKit
import PortavozCore
import SwiftUI

/// Live recording: timer, streaming captions, then the processing states
/// until the meeting lands in the library.
struct RecordingView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @Binding var route: Route?
    /// Calendar event this recording came from (brief's "Record this
    /// meeting") — nil for a blank recording.
    let event: UpcomingEvent?
    /// Shared with the menu bar and the HUD (AppServices): the session
    /// must be visible and stoppable from outside this view.
    private var controller: RecordingController { services.recording }
    /// Log-viewer follow mode: captions auto-scroll while the user is at
    /// the bottom; scrolling away pauses the follow (so they can read
    /// back) and it resumes 10 s after the last manual scroll.
    @State private var noteDraft = ""
    /// Compact floating HUD (GAPS #4): recording without the full window.
    @State private var hud = RecordingHUDController()
    /// One-tap dismiss for the "no incoming audio" nudge (in-person meetings
    /// legitimately have a silent system channel).
    @State private var systemWarningDismissed = false
    /// One-tap dismiss for the "capturing app directly" note.
    @State private var appTapNoteDismissed = false

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
                if controller.systemCaptureHealth != .healthy {
                    systemCaptureHealthBanner
                }
                if !controller.tappedMeetingApps.isEmpty && !appTapNoteDismissed {
                    appTapBanner
                }
                if controller.liveTranscriptDeferred {
                    deferredTranscriptBanner
                }
                if controller.translationNeedsDownload {
                    translationDownloadBanner
                }
                captionsList
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 20)
                ScrollView {
                    VStack(spacing: 10) {
                        companionCardsPanel
                        notesPanel
                        if let live = controller.liveSummary {
                            liveSummaryPanel(live)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: 260)
                .padding(.bottom, 16)

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
        .task { await controller.start(services: services, event: event) }
        .onDisappear { hud.close() }
    }

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
        return "Preparing…"
    }

    /// The 4a top bar: recording dot + timer + mic meter on the left; the
    /// live controls (Translate, Companion, HUD) and the red Stop on the
    /// right — all in one compact row, so the words below own the space.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: controller.startedAt, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(controller.startedAt))
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .opacity(elapsed.isMultiple(of: 2) ? 1 : 0.35)
                        .animation(.easeInOut(duration: 0.6), value: elapsed)
                    Text(String(format: "%02d:%02d", max(0, elapsed) / 60, max(0, elapsed) % 60))
                        .font(.system(size: 24, weight: .medium).monospacedDigit())
                }
            }
            compactMeter
            Spacer()
            if #available(macOS 15.0, *) {
                Picker("Translate", selection: translationBinding) {
                    Text("No translation").tag(String?.none)
                    Text("→ Spanish").tag(String?.some("es"))
                    Text("→ English").tag(String?.some("en"))
                }
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            if services.companionAvailable {
                Toggle(isOn: companionBinding) {
                    Label("Companion", systemImage: "questionmark.bubble")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(L10n.text("Detects questions and suggests on-device answers. It never answers for you."))
            }
            Button(action: enterCompactMode) {
                Label("HUD", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .controlSize(.small)
            .help(L10n.text(
                "Floating mini panel with the timer and captions — records without covering your meeting"))
            Button {
                Task { await controller.stop(services: services) }
            } label: {
                Label("Stop", systemImage: "stop.circle.fill")
            }
            .controlSize(.small)
            .tint(.red)
            .keyboardShortcut(".")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// The compact mic meter for the top bar: icon + a short dB bar. The
    /// full "move closer" nudge lives in its own banner when the level
    /// stays low.
    private var compactMeter: some View {
        HStack(spacing: 6) {
            Button {
                controller.setMicMuted(!controller.micMuted)
            } label: {
                Image(
                    systemName: controller.micMuted
                        ? "mic.slash.fill" : (controller.micLevelLow ? "mic.fill" : "mic")
                )
                .foregroundStyle(
                    controller.micMuted ? .red : (controller.micLevelLow ? .orange : .secondary)
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("recording-mute-mic")
            .help(L10n.text(controller.micMuted
                    ? "Your mic is muted for Portavoz" : "Mute your mic for Portavoz"))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                GeometryReader { geometry in
                    Capsule()
                        .fill(controller.micLevelLow ? Color.orange : Color.green)
                        .frame(width: geometry.size.width * (controller.micMuted ? 0 : meterFraction))
                }
            }
            .frame(width: 90, height: 5)
            .opacity(controller.micMuted ? 0.4 : 1)
            .animation(.easeOut(duration: 0.15), value: controller.micLevel)
        }
    }

    /// Maps the linear mic level onto a −60…0 dBFS bar (0…1).
    private var meterFraction: CGFloat {
        let level = controller.micLevel
        guard level > 0.0001 else { return 0 }
        let decibels = 20 * log10(level)
        return CGFloat(max(0, min(1, (Double(decibels) + 60) / 60)))
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

    private var companionBinding: Binding<Bool> {
        Binding(
            get: { controller.companionEnabled },
            set: { controller.companionEnabled = $0 }
        )
    }

    private var translationBinding: Binding<String?> {
        Binding(
            get: { controller.translationTarget },
            set: { controller.translationTarget = $0 }
        )
    }

    /// The coauthoring input (D28): jot notes while the meeting happens.
    /// Each note is anchored to the current moment and woven into the final
    /// summary as intent — expanded with facts and marked as yours (▸).
    private var notesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your notes", systemImage: "square.and.pencil")
                .font(.headline)
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Add a note…", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .onSubmit(addNote)
                Button(action: addNote) {
                    Image(systemName: "arrow.up.circle.fill").imageScale(.large)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    noteDraft.trimmingCharacters(in: .whitespaces).isEmpty
                        ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(noteDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(L10n.text("Add note (⏎)"))
            }
            if !controller.contextItems.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        // Newest first — the note you just took is right there.
                        ForEach(controller.contextItems.reversed()) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("▸").foregroundStyle(.tint)
                                Text(stamp(item.timestamp))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text(item.content)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                Spacer(minLength: 2)
                                Button {
                                    controller.removeContextItem(item.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help(L10n.text("Remove note"))
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            Text("They guide the final summary: they are expanded with facts and marked as yours (▸).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func addNote() {
        let text = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        controller.addContextNote(text)
        noteDraft = ""
    }

    private func stamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func liveSummaryPanel(_ markdown: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label("Live summary", systemImage: "sparkles")
                    .font(.headline)
                MarkdownText(text: markdown)
                    .font(.callout)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Live captions as a Spotify-lyrics carousel (M11): the newest line
    /// sits low in the viewport (the frontier), older ones rise and fade
    /// above it. A bounded window keeps long recordings responsive.
    private var captionsList: some View {
        GeometryReader { geo in
            FocusedTranscriptView(
                segments: Array(controller.captions.suffix(150)),
                activeID: controller.captions.last?.id,
                height: geo.size.height,
                anchor: UnitPoint(x: 0.5, y: 0.82),
                followSignal: controller.captions.last?.endTime ?? 0
            ) { segment, active in
                captionRow(segment, active: active)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    /// One lyrics line (4a): a voice-colored pill + the words. The active
    /// (newest) line reads bigger; when it's YOURS it sits in an
    /// amber-tinted card — your voice is the only color with meaning.
    private func captionRow(_ segment: TranscriptSegment, active: Bool) -> some View {
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
                if let translated = controller.translations[segment.id] {
                    // The language bridge (6a-3): a secondary rail under the
                    // real line. Not amber — amber is reserved for YOUR voice
                    // (voices B); this reads as a quiet translation.
                    Text(translated)
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
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

    /// Ink for a non-me live pill: the speaker's stable voice hue once the
    /// diarizer names them (S1/S2 or a remembered voice), neutral for the
    /// generic "Them".
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

    /// The live speaker pill for a caption row. Mic rows are the user by
    /// hardware truth; system rows show the live diarizer's voice hint
    /// (S1/S2, or the user through the voiceprint) once a window covers
    /// them, and the generic "Them" until then.
    private func liveVoice(for segment: TranscriptSegment) -> (label: String, isMe: Bool) {
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
        Label {
            Text(systemCaptureHealthMessage)
        } icon: {
            Image(systemName: systemCaptureHealthIcon)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(systemCaptureHealthColor)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("recording-system-capture-health")
    }

    private var systemCaptureHealthMessage: String {
        switch controller.systemCaptureHealth {
        case .healthy:
            ""
        case .stalled, .recovering:
            L10n.text(
                "Remote audio stopped — reconnecting… Your microphone is still recording.")
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
    var deferredTranscriptBanner: some View {
        Label(
            "Audio is recording now. The complete transcript will appear after the local model finishes preparing.",
            systemImage: "waveform.badge.clock")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("recording-transcript-deferred")
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
}

// MARK: - Companion cards
//
// The live answer panel (D26), split out to keep the main view under
// the type-body cap.

extension RecordingView {
    /// The companion's answer cards (D26): question detected in the
    /// conversation → suggested answer. Read, copy or dismiss — never acts
    /// on its own.
    @ViewBuilder
    private var companionCardsPanel: some View {
        // Newest first, none dropped — the panel lives in a scroll view, so
        // older cards stay reachable instead of falling off after a few.
        ForEach(Array(controller.companionCards.reversed())) { card in
            companionCardView(card)
        }
    }

    private func companionCardView(_ card: CompanionCard) -> some View {
        let tint: Color = card.directed ? .orange : PVDesign.accent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(card.question, systemImage: "questionmark.bubble.fill")
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                Button {
                    controller.dismissCompanionCard(card.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            if !card.answer.isEmpty {
                Text(card.answer)
                    .font(.callout)
                    .textSelection(.enabled)
                    // Always take the ideal height inside the scroll — a
                    // compressed Text is what painted over the card footer.
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(companionCardTag(card))
                    .font(.caption2)
                    .foregroundStyle(card.directed ? tint : Color.secondary)
                Spacer()
                if !card.answer.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.answer, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .help(L10n.text("Copy response"))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }

    private func companionCardTag(_ card: CompanionCard) -> String {
        let base = card.kind == .context ? "from this meeting" : "knowledge · \(card.source)"
        if card.directed {
            return card.answer.isEmpty ? "asked you" : "asked you · \(base)"
        }
        return base
    }
}
