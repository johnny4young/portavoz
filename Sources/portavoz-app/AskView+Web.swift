import ApplicationKit
import PortavozCore
import SwiftUI

extension AskView {
    @ViewBuilder
    func webCitationLinks(
        _ citations: [AskWebCitation],
        identifierPrefix: String
    ) -> some View {
        ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
            VStack(alignment: .leading, spacing: 2) {
                Link(destination: citation.url) {
                    Label(citation.title, systemImage: "arrow.up.right.square")
                        .lineLimit(1)
                        .font(.caption)
                }
                .help(citation.text)
                .accessibilityIdentifier("\(identifierPrefix)-\(index)")
                Text(webDateDisclosure(citation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(
                        "\(identifierPrefix)-\(index)-freshness")
            }
        }
    }

    @ViewBuilder
    func webFailureNotice(_ failures: [AskWebSourceFailure]) -> some View {
        if !failures.isEmpty {
            Label(
                "One web source could not be read.",
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ask-web-source-failure")
        }
    }

    var webSourceStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Paste one public page. Portavoz will fetch only that address.",
                systemImage: "globe")
                .accessibilityIdentifier("ask-source-status-web")
            TextField(
                "https://example.com/article",
                text: Binding(
                    get: { model.state.webSourceDraft },
                    set: { model.updateWebSourceDraft($0) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ask-web-source-field")
            Toggle(
                "Allow this one web request",
                isOn: Binding(
                    get: { model.state.webConsentApproved },
                    set: { model.setWebConsentApproved($0) }))
                .disabled(!model.canApproveWebConsent)
                .accessibilityIdentifier("ask-web-consent")
            Label(
                webPrivacyDisclosure,
                systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ask-web-disclosure")
        }
    }

    var questionPlaceholder: String {
        model.state.sourceMode == .web
            ? L10n.text("Ask about this page…")
            : L10n.text("Ask about your meetings…")
    }

    private var webPrivacyDisclosure: String {
        L10n.text(Self.webPrivacyDisclosureKey)
    }

    private static let webPrivacyDisclosureKey =
        "Your question and meetings are not sent to the page. "
        + "The selected local answer engine receives only the downloaded excerpt."

    private func webDateDisclosure(_ citation: AskWebCitation) -> String {
        let freshness: String
        switch citation.freshness {
        case .recent:
            freshness = L10n.text("Fresh source")
        case .stale:
            freshness = L10n.text("Older source")
        case .unknown:
            freshness = L10n.text("Source date unavailable")
        }
        guard let date = citation.observedDate else { return freshness }
        let label = citation.observedDateKind == .lastModified
            ? L10n.text("Last modified")
            : L10n.text("Published")
        let bounded = citation.isExcerptTruncated
            ? " · \(L10n.text("Excerpt limited"))"
            : ""
        return "\(label) "
            + date.formatted(date: .abbreviated, time: .omitted)
            + " · \(freshness)\(bounded)"
    }
}
