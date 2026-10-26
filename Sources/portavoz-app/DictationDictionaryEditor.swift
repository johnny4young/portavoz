import SwiftUI
import TranscriptionKit

/// The deterministic tier of the dictation dictionary as Settings UI: a
/// quick-add row plus the current rules, grouped by the spelling they type.
/// Rules persist immediately on every change; the controller snapshots them
/// when the next session starts. Literal mode leaves the rules configured but
/// does not apply them.
struct DictationDictionaryEditor: View {
    /// Read live: a correction learned from the dictation strip must not be lost
    /// when this editor saves its next change.
    @AppStorage(DictationController.replacementsKey) private var stored = ""
    @State private var newTrigger = ""
    @State private var newReplacement = ""
    @FocusState private var focusesTrigger: Bool

    private var rules: [DictationReplacement] { DictationTextRules.decode(replacements: stored) }

    var body: some View {
        LabeledContent("Text replacements") {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    TextField(
                        "",
                        text: $newTrigger,
                        prompt: Text(L10n.text("Heard")))
                        .frame(width: 110)
                        .focused($focusesTrigger)
                        .accessibilityLabel(L10n.text("Heard"))
                        .accessibilityIdentifier("settings-dictation-dict-trigger")
                    TextField(
                        "",
                        text: $newReplacement,
                        prompt: Text(L10n.text("Type instead")))
                        .frame(width: 110)
                        .accessibilityLabel(L10n.text("Type instead"))
                        .accessibilityIdentifier("settings-dictation-dict-replacement")
                    Button {
                        add()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedTrigger.isEmpty || trimmedReplacement.isEmpty)
                    .accessibilityLabel(L10n.text("Add replacement"))
                    .accessibilityIdentifier("settings-dictation-dict-add")
                }
                // Replacements group the heard forms, and each heard form is
                // unique, so both are stable identities across deletes.
                ForEach(DictationTextRules.terms(rules), id: \.replacement) { term in
                    termRow(term)
                }
            }
        }
    }

    private func termRow(_ term: DictationTerm) -> some View {
        HStack(spacing: 6) {
            ForEach(term.heard, id: \.self) { heard in
                HStack(spacing: 2) {
                    Text(heard)
                    Button {
                        remove(heard)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.format("Remove “%@”", heard))
                    .accessibilityIdentifier("settings-dictation-dict-remove")
                }
            }
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(term.replacement)
                .fontWeight(.medium)
            Button {
                newReplacement = term.replacement
                newTrigger = ""
                focusesTrigger = true
            } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.format("Add another way “%@” is heard", term.replacement))
            .accessibilityLabel(L10n.format("Add another way “%@” is heard", term.replacement))
            .accessibilityIdentifier("settings-dictation-dict-add-heard")
        }
        .font(.callout)
    }

    private var trimmedTrigger: String {
        newTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedReplacement: String {
        newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let rule = DictationReplacement(
            trigger: trimmedTrigger, replacement: trimmedReplacement)
        guard !rule.trigger.isEmpty, !rule.replacement.isEmpty else { return }
        // Re-adding an existing trigger updates it instead of stacking a
        // dead duplicate the matcher would never reach.
        persist(rules.filter {
            $0.trigger.compare(rule.trigger, options: [.caseInsensitive]) != .orderedSame
        } + [rule])
        newTrigger = ""
        newReplacement = ""
    }

    private func remove(_ heard: String) {
        persist(rules.filter { $0.trigger != heard })
    }

    private func persist(_ rules: [DictationReplacement]) {
        stored = DictationTextRules.encode(rules)
    }
}
