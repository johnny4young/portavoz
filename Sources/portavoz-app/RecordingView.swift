import IntelligenceKit
import PortavozCore
import SwiftUI

/// Live recording: timer, streaming captions, then the processing states
/// until the meeting lands in the library.
struct RecordingView: View {
    @Environment(AppServices.self) private var services
    @Binding var route: Route?
    @State private var controller = RecordingController()
    /// Log-viewer follow mode: captions auto-scroll while the user is at
    /// the bottom; scrolling away pauses the follow (so they can read
    /// back) and it resumes 10 s after the last manual scroll.
    @State private var noteDraft = ""

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
                    // La columna derecha siempre está: las notas son un input
                    // primario (D28), no algo que aparece solo si hay tarjetas.
                    VStack(spacing: 10) {
                        notesPanel
                        companionCardsPanel
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
                    Label("Detener", systemImage: "stop.circle.fill")
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
                    Label("Algo falló", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Volver") { route = nil }
                }
                Spacer()
            }
        }
        .navigationTitle("Grabación")
        .liveTranslation(controller)
        .task { await controller.start(services: services) }
    }

    private var preparingText: String {
        if case .downloading(let status) = services.modelsState {
            return status
        }
        return "Preparando…"
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
                Label("Grabando mic + audio del sistema — todo queda en tu Mac", systemImage: "waveform")
                if #available(macOS 15.0, *) {
                    Picker("Traducir", selection: translationBinding) {
                        Text("Sin traducción").tag(String?.none)
                        Text("→ Español").tag(String?.some("es"))
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
                        "Detecta preguntas en la conversación y sugiere respuestas on-device. Nunca responde por ti."
                    )
                }
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
                Text("Se te oye bajo — acércate o usa audífonos con micrófono")
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
            Label("Tus notas", systemImage: "square.and.pencil")
                .font(.headline)
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Anota algo…", text: $noteDraft, axis: .vertical)
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
                .help("Añadir la nota (⏎)")
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
                                .help("Quitar la nota")
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            Text("Guían el resumen final: se expanden con datos y se marcan como tuyas (▸).")
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
                Label("Resumen en vivo", systemImage: "sparkles")
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
                    .help("Copiar la respuesta")
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
        let base = card.kind == .context ? "de esta reunión" : "conocimiento · \(card.source)"
        if card.directed {
            return card.answer.isEmpty ? "te preguntaron" : "te preguntaron · \(base)"
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(segment.channel == .microphone ? "Yo" : "Ellos")
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    segment.channel == .microphone ? Color.accentColor : .secondary)
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
}
