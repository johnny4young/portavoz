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
                captionsList
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
                Text(String(format: "%02d:%02d", max(0, elapsed) / 60, max(0, elapsed) % 60))
                    .font(.system(size: 40, weight: .medium).monospacedDigit())
            }
            Label("Grabando mic + audio del sistema — todo queda en tu Mac", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var captionsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.captions.suffix(200)) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(segment.channel == .microphone ? "Yo" : "Ellos")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    segment.channel == .microphone ? Color.accentColor : .secondary)
                                .frame(width: 40, alignment: .trailing)
                            Text(segment.text)
                                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                        }
                        .id(segment.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .onChange(of: controller.captions.count) { _, _ in
                if let last = controller.captions.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
