import ApplicationKit
import Foundation
import PortavozCore
import SwiftUI

/// D337 — read-only, content-free review of offers durably observed on real
/// subject surfaces. Workflow actions deliberately remain a later slice.
struct SkillProposalSection: View {
    let snapshot: SkillOfferReviewSnapshot?
    let isLoading: Bool
    let isMutating: Bool
    let loadFailed: Bool
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
            Text(
                offer.lastObservedAt,
                format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "settings-skill-proposal-\(offer.skillID)-\(offer.id.uuidString)")
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
