import ApplicationKit
import PortavozCore
import SwiftUI

/// First-run guided setup (GAPS #6): why-local welcome, guided permissions,
/// model download with the hardware recommendation, and optional voice
/// enrollment. Shows once (`hasOnboarded`); existing libraries skip it
/// silently — their user already knows the app.
struct OnboardingView: View {
    @Environment(AppServices.self) private var services
    let onFinish: () -> Void

    @State private var step = 0
    @State private var micGranted = false
    @State private var calendarConnected = false
    @State private var providerRecommendation: LocalSummaryProviderRecommendation?
    @State private var downloadingModels = false
    @State private var modelsReady = false
    @State private var enrolling = false
    @State private var enrolled = false
    @State private var enrollMessage: String?
    @State private var listen = FirstListenController()

    private let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)
            footer
        }
        .frame(width: 520, height: 520)
        .task {
            providerRecommendation = await services
                .discoverLocalSummaryProviders().recommendation
        }
        .onChange(of: step) { previous, current in
            if previous == 0, current != 0 {
                listen.cancel()
            }
        }
        .onDisappear { listen.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: firstListen
        case 1: duringMeeting
        case 2: permissions
        case 3: models
        default: voice
        }
    }

    // MARK: - During the meeting

    /// Step 1 — what Portavoz does while you talk, in three lines and one
    /// example, so Apuntador, Radar and Automations are not a surprise later.
    private var duringMeeting: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("During the meeting")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("onboarding-during-meeting")
            Text("Three things Portavoz does while you talk. Nothing runs without you.")
                .font(.title3)
                .foregroundStyle(.secondary)
            featureRow(
                symbol: PVSymbol.apuntador,
                title: L10n.text("Apuntador"),
                detail: L10n.text(
                    "Hears the questions the meeting asks you and drafts an answer from what was said.")
            ) {
                Toggle("", isOn: apuntadorBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(L10n.text("Apuntador"))
                    .accessibilityIdentifier("onboarding-apuntador-toggle")
            }
            featureRow(
                symbol: PVSymbol.radar,
                title: L10n.text("Radar"),
                detail: L10n.text(
                    "Turns “I’ll send it Friday” into a commitment you confirm, with its source.")
            ) { EmptyView() }
            featureRow(
                symbol: PVSymbol.automations,
                title: L10n.text("Automations"),
                detail: L10n.text(
                    "Offers a recap, an email draft or an export after the meeting. You review, then it runs.")
            ) { EmptyView() }
            exampleCard
        }
    }

    private var apuntadorBinding: Binding<Bool> {
        Binding(
            get: { services.recording.companionEnabled },
            set: { services.recording.companionEnabled = $0 })
    }

    private func featureRow<Trailing: View>(
        symbol: String, title: String, detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(PVDesign.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    /// One Apuntador card the way it will look mid-meeting, so the first real
    /// one is recognised, not explained.
    private var exampleCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Example", systemImage: PVSymbol.apuntador)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PVDesign.accent)
            Text("They asked: “When do we ship the report?”")
                .font(.callout.weight(.semibold))
            Text("Friday, after the review — said at 12:40.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PVDesign.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(PVDesign.accent.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding-example-card")
    }

    // MARK: - Steps

    /// Step 0 — the value proposition, demonstrated instead of described: the
    /// user says a sentence and watches Portavoz transcribe it live, on-device,
    /// before a single model has downloaded (6a-4).
    private var firstListen: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The identifier lives on the title, not the container: a container
            // `.accessibilityIdentifier` stamps ALL its descendants on macOS,
            // which would clobber the button's and caption's own ids.
            Text("Your first listen")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("onboarding-first-listen")
            Text("Say a sentence, anything about your day. Portavoz transcribes it live.")
                .font(.title3)
                .foregroundStyle(.secondary)

            FirstListenWaveform(level: listen.level, active: listen.phase == .listening)
                .frame(height: 56)
                .padding(.vertical, 4)

            firstListenBody
        }
    }

    @ViewBuilder private var firstListenBody: some View {
        switch listen.phase {
        case .idle:
            Button {
                listen.start()
            } label: {
                Label("Listen for 10 seconds", systemImage: "mic.fill")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(PVDesign.accent)
            .accessibilityIdentifier("onboarding-first-listen-button")
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Warming up the on-device listener…").foregroundStyle(.secondary)
            }
        case .listening:
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.format("Listening… %d s", listen.secondsLeft))
                    .font(.callout).foregroundStyle(.secondary)
                captionCard(listen.hasCaption ? listen.caption : L10n.text("Go ahead, speak…"))
            }
        case .done:
            firstListenResult
        case .captionsUnavailable:
            VStack(alignment: .leading, spacing: 8) {
                Label("Got it.", systemImage: PVSymbol.success)
                    .foregroundStyle(.green)
                Text("Live captions need macOS 26. Recording still works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout).foregroundStyle(.secondary)
                Button("Try again") { listen.start() }
            }
        }
    }

    private var firstListenResult: some View {
        VStack(alignment: .leading, spacing: 10) {
            if listen.hasCaption {
                captionCard(listen.caption)
                Label(L10n.format("%d words heard.", listen.wordCount), systemImage: PVSymbol.success)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Got it.", systemImage: PVSymbol.success)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button("Listen again") { listen.start() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(PVDesign.accent)
        }
    }

    /// The caption shown the way live meetings show your voice: an amber card,
    /// so the "your voice is amber" language is taught here first.
    private func captionCard(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(VoicePalette.me.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(VoicePalette.me.opacity(0.4), lineWidth: 1))
            .accessibilityIdentifier("onboarding-first-listen-caption")
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
        // The first listen already prompted for the mic — reflect that here.
        .onAppear {
            micGranted = services.microphonePermissionGranted
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("On-device models").font(.largeTitle.bold())
            Text("Models download once (about 1 GB) and work offline.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if modelsReady {
                    Image(systemName: PVSymbol.success).foregroundStyle(.green)
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
            if let providerRecommendation {
                Divider()
                Label(
                    providerRecommendation.localizedHeadline,
                    systemImage: PVSymbol.generate)
                    .font(.callout.weight(.medium))
                ForEach(providerRecommendation.localizedReasons, id: \.self) { reason in
                    Text("• \(reason)").font(.caption).foregroundStyle(.secondary)
                }
                Text("You can change the summary engine anytime in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Whether the first-listen captured enough audio to enroll from directly
    /// (≥ 4 s), so the user needn't speak a second time.
    private var canReuseFirstListen: Bool {
        LocalVoiceSample(
            samples: listen.capturedSamples,
            sampleRate: listen.capturedSampleRate
        ).duration >= LocalVoiceSample.minimumEnrollmentDuration
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your voice (optional)").font(.largeTitle.bold())
            // Two-sentence explainer.
            // swiftlint:disable:next line_length
            Text("A short voice sample lets Portavoz tag your interventions as “Me” on any microphone or channel. You can enroll or redo it later in Settings.")
                .foregroundStyle(.secondary)
            if enrolled {
                HStack(spacing: 10) {
                    Image(systemName: PVSymbol.success).foregroundStyle(.green)
                    Text("Voice enrolled").font(.callout)
                }
            } else if enrolling {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("One moment…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if canReuseFirstListen {
                        Button("Use my first listen") { enrollVoice(reusingFirstListen: true) }
                            .buttonStyle(.borderedProminent)
                            .tint(PVDesign.accent)
                            .accessibilityIdentifier("onboarding-voice-reuse")
                        Text("Reuses what you just said — no need to speak again.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Record a fresh 12 seconds") { enrollVoice(reusingFirstListen: false) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("onboarding-voice-record-fresh")
                    } else {
                        Button("Enroll my voice") { enrollVoice(reusingFirstListen: false) }
                            .buttonStyle(.borderedProminent)
                            .tint(PVDesign.accent)
                            .accessibilityIdentifier("onboarding-voice-enroll")
                    }
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
                .accessibilityIdentifier("onboarding-skip")
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Button(step == lastStep ? L10n.text("Start using Portavoz") : L10n.text("Continue")) {
                if step == lastStep { finish() } else { step += 1 }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(enrolling)
            .accessibilityIdentifier("onboarding-continue")
        }
        .padding(20)
        .background(.bar)
    }

    private func permissionRow(
        icon: String, title: String, detail: String,
        done: Bool, action: (() -> Void)?, actionLabel: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(PVDesign.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if done {
                Image(systemName: PVSymbol.success).foregroundStyle(.green)
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
        Task { @MainActor in
            micGranted = await services.requestMicrophonePermission()
        }
    }

    private func requestCalendar() {
        Task { @MainActor in
            calendarConnected = await services.requestOnboardingCalendarAccess()
        }
    }

    private func downloadModels() {
        downloadingModels = true
        Task { @MainActor in
            defer { downloadingModels = false }
            modelsReady = (try? await services.loadEnginesIfNeeded()) != nil
        }
    }

    /// Voiceprint enrollment → saved; each fresh diarization session samples
    /// it without reloading the reusable Core ML weights. `reusingFirstListen`
    /// skips the second recording and derives the print from the 10 s the user
    /// already spoke in step 0 (6a-4).
    private func enrollVoice(reusingFirstListen: Bool) {
        enrolling = true
        enrollMessage = nil
        Task { @MainActor in
            defer { enrolling = false }
            do {
                if reusingFirstListen {
                    _ = try await services.enrollLocalVoice(from: LocalVoiceSample(
                        samples: listen.capturedSamples,
                        sampleRate: listen.capturedSampleRate))
                } else {
                    _ = try await services.recordAndEnrollLocalVoice(
                        seconds: 12,
                        mode: .raw)
                }
                enrolled = true
            } catch {
                enrollMessage = L10n.format("Could not enroll: %@", UseCaseErrorMessages.describe(error))
            }
        }
    }

    private func finish() {
        onFinish()
    }
}

/// A row of bars that breathe with the microphone level — the onboarding
/// first-listen's visual heartbeat. Idle bars pulse gently; while listening
/// they rise with the captured level and glow in the user's amber.
private struct FirstListenWaveform: View {
    let level: Double
    let active: Bool

    private let barCount = 27

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(active
                            ? AnyShapeStyle(VoicePalette.me)
                            : AnyShapeStyle(Color.secondary.opacity(0.35)))
                        .frame(width: 4, height: height(index, phase: phase))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func height(_ index: Int, phase: Double) -> CGFloat {
        // A gentle idle ripple, plus the live level shaped into a soft hill so
        // the middle bars react most.
        let idle = 0.5 + 0.5 * sin(phase * 2 + Double(index) * 0.5)
        let bell = sin(Double(index) / Double(barCount - 1) * .pi)
        let amplitude = active ? (0.2 + level * bell) : (0.10 + 0.06 * idle)
        return CGFloat(8 + amplitude * 40)
    }
}
