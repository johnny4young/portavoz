import SwiftUI

/// The bundled display typeface and the notices its SIL OFL 1.1 license asks for.
struct TypefaceCreditsSection: View {
    static let noticesURL = URL(string: "https://github.com/johnny4young/portavoz/blob/main/THIRD_PARTY_NOTICES.md")!

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: PVFont.family)
                    .accessibilityIdentifier("settings-typeface-credit")
                Text(verbatim: "The Fraunces Project Authors · SIL Open Font License 1.1")
                    .font(.caption)
                    .foregroundStyle(.ink3)
                    .accessibilityIdentifier("settings-typeface-credit-license")
                Link("Third-party notices", destination: Self.noticesURL)
                    .font(.caption)
                    .accessibilityIdentifier("settings-third-party-notices")
            }
        } header: {
            Text("Typeface")
        }
    }
}
