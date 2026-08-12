import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI

/// D337/D338 — content-free review and opaque dismissal of offers durably
/// observed on real subject surfaces. Confirmation remains on the subject.
struct SkillProposalSection: View {
    let snapshot: SkillOfferReviewSnapshot?
    let isLoading: Bool
    let isMutating: Bool
    let loadFailed: Bool
    let dismissingOfferID: UUID?
    let dismissalFailedOfferID: UUID?
    let dismiss: (SkillOfferReviewItem) -> Void
    let retry: () -> Void

    var body: some View {
        if snapshot == nil, !loadFailed {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading proposed Skills…")
            }
            .accessibilityIdentifier("settings-skills-proposals-loading")
        } else if loadFailed {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Proposed Skills are unavailable",
                    systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        "settings-skills-proposals-error")
                Text("No proposal is shown until its durable explanation can be verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try again", action: retry)
                    .accessibilityIdentifier(
                        "settings-skills-proposals-retry")
                    .disabled(isLoading || isMutating)
            }
        } else if let offers = snapshot?.offers, offers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("No proposed Skills", systemImage: "sparkles")
                Text("Offers appear here only after a real meeting, commitment, or calendar surface proposes them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings-skills-proposals-empty")
        } else {
            ForEach(snapshot?.offers ?? []) { offer in
                offerRow(offer)
            }
            Text("This review stores no title, transcript, preview, destination, or recipient.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings-skills-proposals-privacy")
            Text("Open the original surface to review the exact preview and confirm. Nothing runs here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func offerRow(_ offer: SkillOfferReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .foregroundStyle(PVDesign.accent)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SkillReceiptPresentation.skillTitle(offer.skillID))
                        .font(.callout.weight(.medium))
                    Text(reasonText(offer.reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "settings-skill-proposal-why-\(offer.skillID)-\(offer.id.uuidString)")
                    Text(L10n.format(
                        "Uses: %@",
                        inputDataText(offer.inputDataClasses)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "settings-skill-proposal-data-\(offer.skillID)-\(offer.id.uuidString)")
                }
                Spacer(minLength: 8)
                offerDismissalControl(offer)
            }
            if dismissalFailedOfferID == offer.id {
                offerDismissalFailure(offer)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "settings-skill-proposal-\(offer.skillID)-\(offer.id.uuidString)")
    }

    private func offerDismissalControl(
        _ offer: SkillOfferReviewItem
    ) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(
                offer.lastObservedAt,
                format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if dismissingOfferID == offer.id {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Dismissing…")
                }
                .font(.caption)
                .accessibilityIdentifier(
                    dismissalIdentifier("progress", offer: offer))
            } else if dismissalFailedOfferID != offer.id {
                Button("Dismiss") { dismiss(offer) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.format(
                        "Dismiss %@",
                        SkillReceiptPresentation.skillTitle(offer.skillID)))
                    .accessibilityIdentifier(
                        dismissalIdentifier("action", offer: offer))
                    .disabled(isLoading || isMutating)
            }
        }
    }

    private func offerDismissalFailure(
        _ offer: SkillOfferReviewItem
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(
                "This proposal could not be dismissed. It remains available.",
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier(
                    dismissalIdentifier("error", offer: offer))
            Button("Try again") { dismiss(offer) }
                .font(.caption)
                .accessibilityIdentifier(
                    dismissalIdentifier("retry", offer: offer))
                .disabled(isLoading || isMutating)
        }
    }

    private func dismissalIdentifier(
        _ component: String,
        offer: SkillOfferReviewItem
    ) -> String {
        "settings-skill-proposal-dismiss-\(component)-\(offer.skillID)-\(offer.id.uuidString)"
    }

    private func reasonText(_ reason: SkillOfferReason) -> String {
        switch reason {
        case .meetingSummaryReady:
            L10n.text("A meeting summary is ready to use.")
        case .upcomingCalendarEvent:
            L10n.text("An upcoming calendar event can be prepared.")
        case .confirmedCommitment:
            L10n.text("A confirmed commitment can become a reminder.")
        }
    }

    private func inputDataText(
        _ dataClasses: Set<SkillInputDataClass>
    ) -> String {
        SkillInputDataClass.allCases
            .filter(dataClasses.contains)
            .map(inputDataName)
            .formatted(.list(type: .and))
    }

    private func inputDataName(_ dataClass: SkillInputDataClass) -> String {
        switch dataClass {
        case .meetingDetails: L10n.text("meeting details")
        case .meetingSummary: L10n.text("meeting summary")
        case .transcript: L10n.text("transcript")
        case .notes: L10n.text("notes")
        case .companionHistory: L10n.text("Companion history")
        case .commitment: L10n.text("confirmed commitment")
        case .calendarEvent: L10n.text("calendar event")
        case .selectedDestination: L10n.text("destination you select")
        }
    }
}
