import ApplicationKit
import SwiftUI

enum MeetingDetailExportAction {
    case recap
    case markdown
    case pdf
    case srt
    case vtt
    case meetingBundle(includeAudio: Bool)
    case gist
}

struct MeetingDetailActionValues {
    let isRefining: Bool
    let hasAudio: Bool
    let hasSummary: Bool
    let hasCorrections: Bool
    let includeCorrectionProvenance: Bool
    let skillOffers: [MeetingSkillOffer]
}

struct MeetingDetailActionActions {
    let startRefine: @MainActor () -> Void
    let startSpanishRefine: @MainActor () -> Void
    let startEnglishRefine: @MainActor () -> Void
    let cancelRefine: @MainActor () -> Void
    let setIncludeCorrectionProvenance: @MainActor (Bool) -> Void
    let export: @MainActor (MeetingDetailExportAction) -> Void
    let deleteMeeting: @MainActor () -> Void
    let openSkillOffer: @MainActor (MeetingSkillOffer) -> Void
    let dismissSkillOffer: @MainActor (MeetingSkillOffer) -> Void
    let loadSkillOffers: @MainActor () -> Void
}

/// Refine, export, publishing, and deletion controls for one reviewed meeting.
///
/// The section renders capabilities only. Route mutation and application work
/// remain explicit actions owned above this presentation boundary.
struct MeetingDetailActionSection: View {
    let values: MeetingDetailActionValues
    let actions: MeetingDetailActionActions

    var body: some View {
        HStack(spacing: 8) {
            SkillOfferMenu(
                offers: values.skillOffers,
                hasSummary: values.hasSummary,
                open: actions.openSkillOffer,
                dismiss: actions.dismissSkillOffer,
                load: actions.loadSkillOffers)
            refineControl
            exportMenu
            deleteButton
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-actions")
    }

    @ViewBuilder
    private var refineControl: some View {
        if values.isRefining {
            Button(role: .destructive, action: actions.cancelRefine) {
                refineLabel(isRefining: true)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityIdentifier("detail-refine")
            .accessibilityValue("cancel")
            .help(L10n.text("Cancel refine"))
        } else {
            Menu {
                Button("Re-transcribe in Spanish", action: actions.startSpanishRefine)
                Button("Re-transcribe in English", action: actions.startEnglishRefine)
            } label: {
                refineLabel(isRefining: false)
            } primaryAction: {
                actions.startRefine()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!values.hasAudio)
            .accessibilityIdentifier("detail-refine")
            .accessibilityValue("refine")
            .help(L10n.text(
                // One-line UI help.
                // swiftlint:disable:next line_length
                "Re-transcribe with Whisper (maximum quality) and present the result as a draft — nothing is applied without your confirmation. Use the menu to force a language."))
        }
    }

    private var exportMenu: some View {
        Menu {
            Button("Share a recap…") { actions.export(.recap) }
                .accessibilityIdentifier("detail-share-recap")
                .disabled(!values.hasSummary)
            Divider()
            Button("Export Markdown…") { actions.export(.markdown) }
            Button("Export PDF…") { actions.export(.pdf) }
            Button("Export subtitles (SRT)…") { actions.export(.srt) }
                .accessibilityIdentifier("detail-export-srt")
            Button("Export subtitles (VTT)…") { actions.export(.vtt) }
                .accessibilityIdentifier("detail-export-vtt")
            Toggle(
                "Include correction provenance",
                isOn: Binding(
                    get: { values.includeCorrectionProvenance },
                    set: { include in
                        actions.setIncludeCorrectionProvenance(include)
                    }))
                .disabled(!values.hasCorrections)
                .accessibilityIdentifier(
                    values.includeCorrectionProvenance
                        ? "detail-export-correction-provenance-on"
                        : "detail-export-correction-provenance-off")
                .accessibilityLabel(
                    Text("Include correction provenance")
                        + Text(verbatim: ", ")
                        + (values.includeCorrectionProvenance
                            ? Text("On")
                            : Text("Off")))
            Button("Export meeting file (.portavoz)…") {
                actions.export(.meetingBundle(includeAudio: false))
            }
            Button("Export meeting file with audio…") {
                actions.export(.meetingBundle(includeAudio: true))
            }
            Divider()
            Button("Publish as Gist…") { actions.export(.gist) }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13))
                .foregroundStyle(PVDesign.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(PVDesign.accent.opacity(0.16)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("detail-export-menu")
        .help(L10n.text("Export or share this meeting"))
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: actions.deleteMeeting) {
            Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.quaternary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .help(L10n.text("Move this meeting to Recently deleted"))
    }

    private func refineLabel(isRefining: Bool) -> some View {
        Group {
            if isRefining {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
            } else {
                Image(systemName: "wand.and.stars").font(.system(size: 13))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
        .background(Circle().fill(.quaternary.opacity(0.5)))
    }
}
