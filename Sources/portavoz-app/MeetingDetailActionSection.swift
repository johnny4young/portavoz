import ApplicationKit
import SwiftUI

/// The current translations an export may use, and the one it will.
struct MeetingDetailExportTranslation {
    let languages: [String]
    let chosen: String?
    let choose: @MainActor (String?) -> Void
}

extension MeetingDetailFlowState {
    func exportTranslation(for detail: MeetingReviewReadModel) -> MeetingDetailExportTranslation {
        let state = MeetingTranscriptTranslationState(detail)
        return MeetingDetailExportTranslation(
            languages: state.languages.filter(state.isCurrent),
            chosen: exportTranslationLanguage,
            choose: { [weak self] in self?.exportTranslationLanguage = $0 })
    }
}

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
    /// Removable silent tail; nil hides the action.
    let trailingSilence: TimeInterval?
    let canCompressAudio: Bool
    let isCompressingAudio: Bool
    let hasSummary: Bool
    let hasCorrections: Bool
    let includeCorrectionProvenance: Bool
    let exportTranslation: MeetingDetailExportTranslation
    let skillOffers: [MeetingSkillOffer]
}

struct MeetingDetailActionActions {
    let startRefine: @MainActor () -> Void
    let startSpanishRefine: @MainActor () -> Void
    let startEnglishRefine: @MainActor () -> Void
    let cancelRefine: @MainActor () -> Void
    let setIncludeCorrectionProvenance: @MainActor (Bool) -> Void
    let export: @MainActor (MeetingDetailExportAction) -> Void
    let renameMeeting: @MainActor () -> Void
    let askToTrimSilence: @MainActor () -> Void
    let compressAudio: @MainActor () -> Void
    let deleteMeeting: @MainActor () -> Void
    let openSkillOffer: @MainActor (MeetingSkillOffer) -> Void
    let dismissSkillOffer: @MainActor (MeetingSkillOffer) -> Void
    let loadSkillOffers: @MainActor () -> Void
}

/// The meeting's window toolbar: automations, re-transcribe, share and More.
///
/// The section renders capabilities only. Route mutation and application work
/// remain explicit actions owned above this presentation boundary.
struct MeetingDetailActionSection: View {
    let values: MeetingDetailActionValues
    let actions: MeetingDetailActionActions

    var body: some View {
        HStack(spacing: 4) {
            SkillOfferMenu(
                offers: values.skillOffers,
                hasSummary: values.hasSummary,
                open: actions.openSkillOffer,
                dismiss: actions.dismissSkillOffer,
                load: actions.loadSkillOffers)
                .padding(.trailing, 4)
            refineControl
            exportMenu
            moreMenu
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail-actions")
        // A translation that goes out of date stops being what the export sends.
        .onChange(of: values.exportTranslation.languages) { _, current in
            if let chosen = values.exportTranslation.chosen, !current.contains(chosen) {
                values.exportTranslation.choose(nil)
            }
        }
    }

    @ViewBuilder
    private var refineControl: some View {
        if values.isRefining {
            Button(role: .destructive, action: actions.cancelRefine) {
                toolbarGlyph("xmark")
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(L10n.text("Cancel refine"))
            .accessibilityIdentifier("detail-refine")
            .accessibilityValue("cancel")
            .help(L10n.text("Cancel refine"))
        } else {
            Menu {
                Button("Re-transcribe in Spanish", action: actions.startSpanishRefine)
                Button("Re-transcribe in English", action: actions.startEnglishRefine)
            } label: {
                toolbarGlyph(PVSymbol.retry)
            } primaryAction: {
                actions.startRefine()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!values.hasAudio)
            .accessibilityLabel(L10n.text("Re-transcribe"))
            .accessibilityIdentifier("detail-refine")
            .accessibilityValue("refine")
            .help(L10n.text(
                // One-line UI help.
                "Re-transcribe with Whisper and review the draft before applying it."))
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
                "Include edit history",
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
                .accessibilityLabel(Text("Include edit history"))
                .accessibilityValue(values.includeCorrectionProvenance ? Text("On") : Text("Off"))
            if !values.exportTranslation.languages.isEmpty {
                transcriptLanguageMenu
            }
            Button("Export meeting file (.portavoz)…") {
                actions.export(.meetingBundle(includeAudio: false))
            }
            Button("Export meeting file with audio…") {
                actions.export(.meetingBundle(includeAudio: true))
            }
            Divider()
            Button("Publish as Gist…") { actions.export(.gist) }
        } label: {
            toolbarGlyph("square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.text("Share"))
        .accessibilityIdentifier("detail-export-menu")
        .help(L10n.text("Export or share this meeting"))
    }

    /// Applies to Markdown, PDF, subtitles and Gist; meeting files keep the original.
    private var transcriptLanguageMenu: some View {
        Menu("Transcript language") {
            languageButton(nil, title: L10n.text("Original"), identifier: "detail-export-translation-original")
            ForEach(values.exportTranslation.languages, id: \.self) { code in
                languageButton(
                    code, title: MeetingTranscriptTranslationControls.name(code),
                    identifier: "detail-export-translation-\(code)")
            }
        }
        .accessibilityIdentifier("detail-export-translation")
    }

    private func languageButton(_ code: String?, title: String, identifier: String) -> some View {
        Button {
            values.exportTranslation.choose(code)
        } label: {
            if values.exportTranslation.chosen == code {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private var moreMenu: some View {
        Menu {
            Button("Rename…", action: actions.renameMeeting)
                .accessibilityIdentifier("detail-rename")
            if let trailingSilence = values.trailingSilence {
                Button(L10n.format(
                    "Remove %@ of silence at the end…",
                    MeetingDetailAudioTrimState.formatted(trailingSilence)),
                    action: actions.askToTrimSilence)
                .accessibilityIdentifier("detail-trim-silence")
            }
            if values.canCompressAudio || values.isCompressingAudio {
                Button(
                    values.isCompressingAudio ? "Compressing…" : "Compress audio (AAC)",
                    action: actions.compressAudio)
                    .disabled(!values.canCompressAudio)
                    .help("Converts audio to AAC to save disk space, with no audible loss for speech")
                    .accessibilityIdentifier("detail-compress-audio")
            }
            Divider()
            Button("Move to Recently deleted", role: .destructive, action: actions.deleteMeeting)
                .accessibilityIdentifier("detail-delete")
        } label: {
            toolbarGlyph("ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.text("More"))
        .accessibilityIdentifier("detail-more-menu")
        .help(L10n.text("More"))
    }

    private func toolbarGlyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14))
            .foregroundStyle(PVDesign.ink2)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}
