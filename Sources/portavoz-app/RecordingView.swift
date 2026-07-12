import IntegrationsKit
import IntelligenceKit
import PortavozCore
import SwiftUI

/// Live recording: timer, streaming captions, then the processing states
/// until the meeting lands in the library.
struct RecordingView: View {
    @Environment(AppServices.self) private var services
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
                header
                HStack(alignment: .top, spacing: 12) {
                    captionsList
                    // The right column is always present: notes are an input
                    // primario (D28), no algo que aparece solo si hay tarjetas.
                    // Notes + cards scroll: without it, three cards with long
                    // answers compress the stack until texts overlap (field
                    // bug, Jul 10). The live summary keeps its own scroll.
                    VStack(spacing: 10) {
                        ScrollView {
                            VStack(spacing: 10) {
                                notesPanel
                                companionCardsPanel
                            }
                        }
                        if let live = controller.liveSummary {
                            liveSummaryPanel(live)
                        }
                    }
                    .frame(width: 300)
                }
                .padding(.horizontal, 20)
                Button {
                    Task { await controller.stop(services: services) }
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .frame(minWidth: 160)
                }
                .controlSize(.large)
                .keyboardShortcut(".")
                .padding(.bottom, 20)

            case .processing(let step):
                Spacer()
                ProgressView()
                Text(step).foregroundStyle(.secondary)
                Spacer()

            case .done(let meetingID):
                Color.clear.onAppear { route = .meeting(meetingID) }

            case .failed(let message):
                Spacer()
                ContentUnavailableView {
                    Label("Something went wrong", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Back") { route = nil }
                }
                Spacer()
            }
        }
        .navigationTitle("Recording")
        .liveTranslation(controller)
        .task { await controller.start(services: services, event: event) }
        .onDisappear { hud.close() }
    }

    private var preparingText: String {
        if case .downloading(let status) = services.modelsState {
            return status
        }
        return "Preparing…"
    }

    private var header: some View {
        VStack(spacing: 4) {
            TimelineView(.periodic(from: controller.startedAt, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(controller.startedAt))
                HStack(spacing: 10) {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        .opacity(elapsed.isMultiple(of: 2) ? 1 : 0.35)
                        .animation(.easeInOut(duration: 0.6), value: elapsed)
                    Text(String(format: "%02d:%02d", max(0, elapsed) / 60, max(0, elapsed) % 60))
                        .font(.system(size: 40, weight: .medium).monospacedDigit())
                }
            }
            HStack(spacing: 12) {
                Label("Recording mic + system audio — everything stays on your Mac", systemImage: "waveform")
                if #available(macOS 15.0, *) {
                    Picker("Translate", selection: translationBinding) {
                        Text("No translation").tag(String?.none)
                        Text("→ Spanish").tag(String?.some("es"))
                        Text("→ English").tag(String?.some("en"))
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if #available(macOS 26.0, *) {
                    Toggle(isOn: companionBinding) {
                        Label("Companion", systemImage: "questionmark.bubble")
                    }
                    .toggleStyle(.checkbox)
                    .help(
                        // One-line UI help.
                        // swiftlint:disable:next line_length
                        "Detects questions in the conversation and suggests on-device answers. It never answers for you."
                    )
                }
                Button(action: enterCompactMode) {
                    Label("Compact view", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.plain)
                .help("Floating mini panel with the timer and captions — records without covering your meeting")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            micMeter
        }
        .padding(.top, 24)
    }

    /// Live mic-input meter (field bug jul 2026: the built-in far-field mic
    /// captured the user at ≤ -45 dBFS and sounded distant to the call). The
    /// bar is on a dB scale so speech levels are visible; a sustained-low
    /// reading nudges the user to move closer or use a headset mic.
    private var micMeter: some View {
        HStack(spacing: 8) {
            Image(systemName: controller.micLevelLow ? "mic.fill" : "mic")
                .foregroundStyle(controller.micLevelLow ? .orange : .secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                GeometryReader { geometry in
                    Capsule()
                        .fill(controller.micLevelLow ? Color.orange : Color.green)
                        .frame(width: geometry.size.width * meterFraction)
                }
            }
            .frame(width: 120, height: 6)
            .animation(.easeOut(duration: 0.15), value: controller.micLevel)
            if controller.micLevelLow {
                Text("Your voice sounds low — move closer or use headphones with a microphone")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
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
            onStop: { Task { await controller.stop(services: services) } }))
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
                .help("Add note (⏎)")
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
                                .help("Remove note")
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

    /// The companion's answer cards (D26): question detected in the
    /// conversation → suggested answer. Read, copy or dismiss — never acts
    /// on its own.
    @ViewBuilder
    private var companionCardsPanel: some View {
        ForEach(controller.companionCards.suffix(3)) { card in
            companionCardView(card)
        }
    }

    private func companionCardView(_ card: CompanionCard) -> some View {
        let tint: Color = card.directed ? .orange : .accentColor
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
                    .help("Copy response")
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
            ) { segment, _ in
                captionRow(segment)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func captionRow(_ segment: TranscriptSegment) -> some View {
        let voice = liveVoice(for: segment)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(voice.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(voice.isMe ? VoicePalette.me : .secondary)
                .frame(width: 40, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(segment.text)
                    .foregroundStyle(segment.isFinal ? .primary : .secondary)
                if let translated = controller.translations[segment.id] {
                    Text(translated)
                        .font(.callout)
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
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
