import ApplicationKit
import PortavozCore
import SwiftUI

/// Q12/D316 — the proposal moment, at zero vertical cost: proposals surface
/// as a counted pill in the meeting toolbar instead of a banner. Nothing here
/// executes anything, opening an offer is the only road to the confirmation
/// sheet, and dismissing is durable and terminal.
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
                Label(countTitle, systemImage: PVSymbol.automations)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(PVDesign.green)
                    .pvPill(PVDesign.greenBg)
                    .contentShape(Capsule())
            }
            // A plain button menu keeps the pill; the toolbar strips a borderless one.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(L10n.text("Automations"))
            .accessibilityIdentifier("skill-offer-menu")
            .help(L10n.text(
                // Keep the catalog key as one literal: LocalizationTests deliberately
                // scans call-site prose rather than evaluating Swift concatenation.
                "See what Portavoz can prepare from this meeting. You confirm each one."))
        }
    }

    private var countTitle: String {
        offers.count == 1
            ? L10n.text("1 automation")
            : L10n.format("%d automations", offers.count)
    }

    private func openTitle(for offer: MeetingSkillOffer) -> String {
        switch offer.kind {
        case .recapDraft: L10n.text("Draft the recap…")
        case .emailRecapDraft: L10n.text("Open an email recap draft…")
        case .secretGistPublish: L10n.text("Publish a secret Gist…")
        case .packageExport: L10n.text("Export a text-only package…")
        }
    }

    private func dismissTitle(for offer: MeetingSkillOffer) -> String {
        switch offer.kind {
        case .recapDraft: L10n.text("Don't suggest the recap again")
        case .emailRecapDraft: L10n.text("Don't suggest the email draft again")
        case .secretGistPublish: L10n.text("Don't suggest the Gist again")
        case .packageExport: L10n.text("Don't suggest the export again")
        }
    }
}
