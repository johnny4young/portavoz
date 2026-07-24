import SwiftUI
import TranscriptionKit

/// The deterministic tier of the dictation dictionary as Settings UI: a
/// quick-add row plus the current rules. Rules persist immediately on
/// every change — the controller re-reads them per delivery, so there is
/// no sync call to forget.
struct DictationDictionaryEditor: View {
    @State private var rules: [DictationReplacement] = DictationTextRules.decode(
        replacements: UserDefaults.standard.string(
            forKey: DictationController.replacementsKey) ?? "")
    @State private var newTrigger = ""
    @State private var newReplacement = ""

    var body: some View {
        LabeledContent("Text replacements") {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    TextField(L10n.text("Heard"), text: $newTrigger)
                        .frame(width: 110)
                        .accessibilityIdentifier("settings-dictation-dict-trigger")
                    TextField(L10n.text("Type instead"), text: $newReplacement)
                        .frame(width: 110)
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
                // Triggers are unique (`add` de-duplicates), so they are the
                // stable row identity — an index would misattribute rows
                // after a mid-list delete.
                ForEach(rules, id: \.trigger) { rule in
                    HStack(spacing: 6) {
                        Text(rule.trigger)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(rule.replacement)
                            .fontWeight(.medium)
                        Button {
                            rules.removeAll { $0.trigger == rule.trigger }
                            persist()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("Remove replacement"))
                    }
                    .font(.callout)
                }
            }
        }
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
        rules.removeAll {
            $0.trigger.compare(
                rule.trigger, options: [.caseInsensitive]) == .orderedSame
        }
        rules.append(rule)
        persist()
        newTrigger = ""
        newReplacement = ""
    }

    private func persist() {
        UserDefaults.standard.set(
            DictationTextRules.encode(rules),
            forKey: DictationController.replacementsKey)
    }
}
