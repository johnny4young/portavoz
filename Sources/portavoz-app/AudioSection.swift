import ApplicationKit
import SwiftUI

/// Settings section: audio capture options — which microphone to record from,
/// what to capture for the other side, and the call-safe capture invariant.
struct AudioSection: View {
    @Environment(AppServices.self) private var services
    @AppStorage("preferredInputUID") private var preferredInputUID = "default"
    @AppStorage("captureMode") private var captureMode = "auto"
    @State private var inputs: [AudioInputOption] = []

    var body: some View {
        Section("Audio") {
            Picker("Microphone", selection: $preferredInputUID) {
                Text("System default").tag("default")
                ForEach(inputs) { device in
                    Text(device.name).tag(device.uid)
                }
                if preferredInputUID != "default",
                    !inputs.contains(where: { $0.uid == preferredInputUID }) {
                    Text("Unavailable — using system default").tag(preferredInputUID)
                }
            }
            .accessibilityIdentifier("settings-mic-device")

            Picker("Capture the other side", selection: $captureMode) {
                Text("Automatic").tag("auto")
                Text("The meeting app").tag("app")
                Text("All system audio").tag("system")
            }
            .accessibilityIdentifier("settings-capture-mode")
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "What Portavoz records besides your mic. Automatic captures your system audio, switching to recognized meeting apps on AirPods. Pick “The meeting app” to always record recognized call apps (Zoom, Meet, Teams, supported browsers) even without AirPods; their audio helpers are included, unrelated apps are not. If none is found, Portavoz falls back to all system audio."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Label("Call-safe capture", systemImage: "checkmark.shield")
                Spacer()
                Text("Always on")
                    .foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-call-safe-capture")
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Portavoz leaves macOS voice processing to your meeting app and never enables call-audio ducking while it records. Duplicate speaker bleed is removed from the transcript after capture."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .task { inputs = await services.audioInputOptions() }
    }
}
