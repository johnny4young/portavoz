import SwiftUI

/// Settings section: audio capture options (echo cancellation, D24).
struct AudioSection: View {
    @AppStorage("aecEnabled") private var aecEnabled = true

    var body: some View {
        Section("Audio") {
            Toggle("Echo cancellation (recommended with speakers)", isOn: $aecEnabled)
            Text(
                // One-line UI help text.
                // swiftlint:disable:next line_length
                "Subtracts speaker output from the microphone so other participants do not appear as “Me”. With HEADPHONES there is no echo, so you can turn it off safely. Applies from the next recording. (If you sound distant on the call, it is usually the Mac built-in microphone picking you up from far away — nearby headset microphones such as AirPods usually sound much better.)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
