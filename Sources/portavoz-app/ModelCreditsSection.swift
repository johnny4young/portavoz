import ModelStoreKit
import SwiftUI

/// Credits for the on-device models, as their licenses (CC-BY-4.0 among them) require.
struct ModelCreditsSection: View {
    var body: some View {
        Section {
            ForEach(ModelCatalog.credits) { credit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(credit.name)
                        .accessibilityIdentifier("settings-model-credit-\(credit.id)")
                    Text(verbatim: "\(credit.creator) · \(credit.license)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-model-credit-\(credit.id)-license")
                    Link(credit.source.host().map { $0 + credit.source.path() } ?? credit.source.absoluteString,
                         destination: credit.source)
                        .font(.caption)
                }
            }
        } header: {
            Text("Model credits")
        } footer: {
            Text("These models run on this Mac. Each keeps its own license.")
        }
    }
}
