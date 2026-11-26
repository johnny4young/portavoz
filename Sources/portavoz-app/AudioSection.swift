import ApplicationKit
import SwiftUI

/// Settings section: audio capture options — which microphone to record from,
/// what to capture for the other side, and the call-safe capture invariant.
struct AudioSection: View {
    @Environment(AppServices.self) private var services
    @AppStorage(MicrophoneInputSelection.preferenceKey) private var preferredInputUID =
        MicrophoneInputSelection.systemDefault
    @AppStorage("captureMode") private var captureMode = "auto"
    @State private var inputs: [AudioInputOption] = []

    var body: some View {
        Section("Audio") {
            Picker("Microphone", selection: $preferredInputUID) {
                Text("System default").tag(MicrophoneInputSelection.systemDefault)
                ForEach(inputs) { device in
                    Text(device.name).tag(device.uid)
                }
                if preferredInputUID != MicrophoneInputSelection.systemDefault,
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
            Text("What to record besides your mic: Automatic captures the active meeting app or system audio.")
            .font(.caption)
            .foregroundStyle(.ink3)

            HStack {
                Label("Call-safe capture", systemImage: "checkmark.shield")
                Spacer()
                Text("Always on")
                    .foregroundStyle(PVDesign.ok)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-call-safe-capture")
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Portavoz leaves macOS voice processing to your meeting app and never enables call-audio ducking while it records. Duplicate speaker bleed is removed from the transcript after capture."
            )
            .font(.caption)
            .foregroundStyle(.ink3)
        }
        .task { inputs = await services.audioInputOptions() }
    }
}
