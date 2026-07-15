import AudioCaptureKit
import SwiftUI

/// Settings section: audio capture options — which microphone to record from,
/// what to capture for the other side, and echo cancellation (D24).
struct AudioSection: View {
    @AppStorage("aecEnabled") private var aecEnabled = true
    @AppStorage("preferredInputUID") private var preferredInputUID = "default"
    @AppStorage("captureMode") private var captureMode = "auto"
    @State private var inputs: [AudioInputDevice] = []

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

            Toggle("Echo cancellation (recommended with speakers)", isOn: $aecEnabled)
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Subtracts speaker output from the microphone so other participants do not appear as “Me”. With HEADPHONES there is no echo, so you can turn it off safely. Applies from the next recording. (If you sound distant on the call, it is usually the Mac built-in microphone picking you up from far away — nearby headset microphones such as AirPods usually sound much better.)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onAppear { inputs = (try? AudioDeviceCatalog.inputDevices()) ?? [] }
    }
}
