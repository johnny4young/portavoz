import ApplicationKit
import PortavozCore
import SwiftUI

/// Q12/D316 — the proposal moment, at zero vertical cost. Meeting Detail's
/// column is deliberately packed (the artifacts viewport is height-ratcheted),
/// so proposals surface as a badged menu beside the document actions instead
/// of a banner: nothing here executes anything, opening an offer is the only
/// road to the confirmation sheet, and dismissing is durable and terminal.
struct SkillOfferMenu: View {
    let offers: [MeetingSkillOffer]
    let hasSummary: Bool
    let open: @MainActor (MeetingSkillOffer) -> Void
    let dismiss: @MainActor (MeetingSkillOffer) -> Void
    let load: @MainActor () -> Void

    var body: some View {
        if offers.isEmpty {
            // The empty state must still occupy the view tree: SwiftUI never
            // installs an empty ViewBuilder branch, and this anchor is what
            // loads the offers in the first place. `onAppear` alone loses a
            // race the full suite exposed: detail sections stream in, so the
            // first load can run before the summary exists — `onChange`
            // re-fires the load the moment the summary lands. Re-entering
            // the empty state (all offers dismissed) re-installs the anchor,
            // which is a harmless idempotent reload.
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .onAppear(perform: load)
                .onChange(of: hasSummary) { _, _ in load() }
        } else {
            Menu {
                ForEach(offers) { offer in
                    Button(openTitle(for: offer)) { open(offer) }
                        .accessibilityIdentifier(
                            "skill-offer-\(offer.kind.rawValue)")
                }
                Divider()
                ForEach(offers) { offer in
                    Button(dismissTitle(for: offer)) { dismiss(offer) }
                        .accessibilityIdentifier(
                            "skill-offer-dismiss-\(offer.kind.rawValue)")
                }
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(PVDesign.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(PVDesign.accent.opacity(0.16)))
                    .overlay(alignment: .topTrailing) {
                        Text("\(offers.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(PVDesign.accent))
                    }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.text("Skill suggestions"))
            .accessibilityIdentifier("skill-offer-menu")
            .help(L10n.text(
                // Keep the catalog key as one literal: LocalizationTests deliberately
                // scans call-site prose rather than evaluating Swift concatenation.
                "Things Portavoz can prepare from this meeting — always previewed and always confirmed by you."))
        }
    }

    private func openTitle(for offer: MeetingSkillOffer) -> String {
        switch offer.kind {
        case .recapDraft: L10n.text("Draft the recap…")
        case .emailRecapDraft: L10n.text("Open an email recap draft…")
        case .packageExport: L10n.text("Export a text-only package…")
        }
    }

    private func dismissTitle(for offer: MeetingSkillOffer) -> String {
        switch offer.kind {
        case .recapDraft: L10n.text("Don't suggest the recap again")
        case .emailRecapDraft: L10n.text("Don't suggest the email draft again")
        case .packageExport: L10n.text("Don't suggest the export again")
        }
    }
}
