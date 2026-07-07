import PortavozCore
import SwiftUI

/// Live recording: timer, streaming captions, then the processing states
/// until the meeting lands in the library.
struct RecordingView: View {
    @Environment(AppServices.self) private var services
    @Binding var route: Route?
    @State private var controller = RecordingController()

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
                    if let live = controller.liveSummary {
                        liveSummaryPanel(live)
                    }
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
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var translationBinding: Binding<String?> {
        Binding(
            get: { controller.translationTarget },
            set: { controller.translationTarget = $0 }
        )
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
        .frame(width: 300)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private var captionsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy + a bounded window: every delta mutates the array and
                // an eager 200-row layout per second froze long recordings.
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.captions.suffix(150)) { segment in
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
                        .id(segment.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            // endTime moves both when a row grows (coalescer) and on append.
            .onChange(of: controller.captions.last?.endTime) { _, _ in
                if let last = controller.captions.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
