import AVFoundation
import AudioCaptureKit
import DiarizationKit
import IntegrationsKit
import IntelligenceKit
import PortavozCore
import SwiftUI

/// First-run guided setup (GAPS #6): why-local welcome, guided permissions,
/// model download with the hardware recommendation, and optional voice
/// enrollment. Shows once (`hasOnboarded`); existing libraries skip it
/// silently — their user already knows the app.
struct OnboardingView: View {
    @Environment(AppServices.self) private var services
    @Binding var isPresented: Bool

    @State private var step = 0
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var calendarConnected = false
    @State private var advice: EngineAdvice?
    @State private var downloadingModels = false
    @State private var modelsReady = false
    @State private var enrolling = false
    @State private var enrolled = false
    @State private var enrollMessage: String?

    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)
            footer
        }
        .frame(width: 520, height: 480)
        .task { advice = HardwareRecommender.advise(await services.currentHardwareProfile()) }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: permissions
        case 2: models
        default: voice
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("Welcome to Portavoz").font(.largeTitle.bold())
            Text("Your meetings, 100% on your Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
            bullet("lock.shield", "Nothing leaves this Mac — transcription, voices and summaries run on-device.")
            bullet("person.2.wave.2", "It tells apart every voice, including yours.")
            bullet("doc.text.magnifyingglass", "Every meeting becomes searchable notes with action items.")
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions").font(.largeTitle.bold())
            Text("Portavoz records locally; macOS asks for each permission once.")
                .foregroundStyle(.secondary)
            permissionRow(
                icon: "mic", title: L10n.text("Microphone"),
                detail: L10n.text("Your side of the meeting."),
                done: micGranted, action: requestMicrophone,
                actionLabel: L10n.text("Allow"))
            permissionRow(
                icon: "speaker.wave.2", title: L10n.text("System audio"),
                detail: L10n.text("The other participants. macOS will ask on your first recording."),
                done: false, action: nil, actionLabel: "")
            permissionRow(
                icon: "calendar", title: L10n.text("Calendar (optional)"),
                detail: L10n.text("Pre-meeting briefs and speaker name suggestions."),
                done: calendarConnected, action: requestCalendar,
                actionLabel: L10n.text("Connect"))
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On-device models").font(.largeTitle.bold())
            Text("Transcription and voice models download once (~1 GB, integrity-verified) and then work offline.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if modelsReady {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Models ready").font(.callout)
                } else if downloadingModels {
                    ProgressView().controlSize(.small)
                    Text(modelsStatus).font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Download now") { downloadModels() }
                    Text("Or skip — they download on your first recording.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let advice {
                Divider()
                Label(advice.headline, systemImage: "wand.and.stars.inverse")
                    .font(.callout.weight(.medium))
                ForEach(advice.reasons, id: \.self) { reason in
                    Text("• \(reason)").font(.caption).foregroundStyle(.secondary)
                }
                Text("You can change the summary engine anytime in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your voice (optional)").font(.largeTitle.bold())
            // Two-sentence explainer.
            // swiftlint:disable:next line_length
            Text("A 12-second sample lets Portavoz tag your interventions as “Me” on any microphone or channel. You can enroll or redo it later in Settings.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if enrolled {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Voice enrolled").font(.callout)
                } else if enrolling {
                    ProgressView().controlSize(.small)
                    Text("Listening… speak normally for 12 seconds.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Enroll my voice") { enrollVoice() }
                }
            }
            if let enrollMessage {
                Text(enrollMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Chrome

    private var footer: some View {
        HStack {
            Button("Skip setup") { finish() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Button(step == lastStep ? L10n.text("Start using Portavoz") : L10n.text("Continue")) {
                if step == lastStep { finish() } else { step += 1 }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(enrolling)
        }
        .padding(20)
        .background(.bar)
    }

    private func bullet(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.indigo).frame(width: 22)
            Text(text)
        }
    }

    private func permissionRow(
        icon: String, title: String, detail: String,
        done: Bool, action: (() -> Void)?, actionLabel: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.indigo).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let action {
                Button(actionLabel, action: action).controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modelsStatus: String {
        if case .downloading(let status) = services.modelsState { return status }
        return L10n.text("Preparing models…")
    }

    // MARK: - Actions

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in micGranted = granted }
        }
    }

    private func requestCalendar() {
        Task { @MainActor in
            calendarConnected = await CalendarAttendeeSource.requestAccess()
        }
    }

    private func downloadModels() {
        downloadingModels = true
        Task { @MainActor in
            defer { downloadingModels = false }
            modelsReady = (try? await services.loadEnginesIfNeeded()) != nil
        }
    }

    /// Same flow as Settings: 12 s of mic → voiceprint saved; the
    /// diarizer reloads with it on the next recording.
    private func enrollVoice() {
        enrolling = true
        enrollMessage = nil
        Task { @MainActor in
            defer { enrolling = false }
            do {
                try await services.loadEnginesIfNeeded()
                guard let diarizer = services.diarizer else { return }
                let microphone = MicrophoneSource(voiceProcessing: false)
                let stream = try await microphone.start()
                var samples: [Float] = []
                var sampleRate = 16_000.0
                let deadline = Date().addingTimeInterval(12)
                for try await chunk in stream {
                    samples.append(contentsOf: chunk.samples)
                    sampleRate = chunk.sampleRate
                    if Date() >= deadline { break }
                }
                await microphone.stop()
                let voiceprint = try await diarizer.extractVoiceprint(
                    fromSamples: samples, sampleRate: sampleRate)
                try VoiceprintStore().save(voiceprint)
                services.invalidateDiarizer()
                enrolled = true
            } catch {
                enrollMessage = L10n.format("Could not enroll: %@", error.localizedDescription)
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasOnboarded")
        isPresented = false
    }
}
