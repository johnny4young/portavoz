import ApplicationKit
import SwiftUI

struct SettingsTransferSection: View {
    @Environment(AppServices.self) private var services
    @State private var model = SettingsTransferModel()

    var body: some View {
        Section("Portable preferences") {
            HStack {
                Button {
                    Task { await model.export(using: services) }
                } label: {
                    Label("Export preferences…", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings-export-preferences")
                Button {
                    Task { await model.importFile(using: services) }
                } label: {
                    Label("Import preferences…", systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("settings-import-preferences")
            }
            .disabled(model.isWorking || model.review != nil)
            if model.isWorking {
                ProgressView("Preparing preferences…")
                    .controlSize(.small)
            }
            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .accessibilityIdentifier("settings-preferences-status")
            }
            Text("Move language, vocabulary and text preferences. Review every change before applying it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                "Files may include private vocabulary. Permissions, secrets and feature activation never transfer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: Binding(
            get: { model.review != nil },
            set: { if !$0, model.review != nil { model.cancelReview() } }
        )) {
            if let review = model.review {
                SettingsTransferReviewSheet(
                    review: review, status: model.status,
                    cancel: { model.cancelReview() }, apply: { model.apply(using: services) })
            }
        }
        .onDisappear { model.cancelReview() }
    }
}

private struct SettingsTransferReviewSheet: View {
    let review: PortableSettingsReview
    let status: String?
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review preferences")
                .font(.title2.bold())
                .accessibilityIdentifier("settings-preferences-review")
            Text("Vocabulary and replacements are merged. Other listed values replace your current preferences.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(PortableSettingsKey.allCases, id: \.self) { key in
                        if let value = review.changes[key] {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(key.transferLabel).font(.headline)
                                Text("Current value").font(.caption).foregroundStyle(.secondary)
                                Text(display(review.before[key]))
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("settings-preferences-before-" + key.rawValue)
                                Text("After import").font(.caption).foregroundStyle(.secondary)
                                Text(display(value))
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("settings-preferences-change-" + key.rawValue)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.trailing, 12)
            }
            if let status {
                Text(status)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-preferences-review-status")
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings-preferences-cancel")
                Button("Apply preferences", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings-preferences-apply")
            }
        }
        .padding(24)
        .frame(width: 540, height: 480)
    }

    private func display(_ value: PortableSettingsValue?) -> String {
        switch value {
        case .text(let text): text.isEmpty ? L10n.text("Empty") : text
        case .flag(let flag): if flag { L10n.text("On") } else { L10n.text("Off") }
        case nil: L10n.text("Empty")
        }
    }
}

private extension PortableSettingsKey {
    var transferLabel: String {
        switch self {
        case .interfaceLanguage: L10n.text("Interface language")
        case .recognitionLanguage: L10n.text("Recognition language")
        case .summaryLanguage: L10n.text("Summary language")
        case .menuBarVisible: L10n.text("Menu bar visibility")
        case .titleTemplate: L10n.text("Meeting title template")
        case .vocabulary: L10n.text("Custom vocabulary")
        case .dictationLanguage: L10n.text("Dictation language")
        case .removeFillers: L10n.text("Remove hesitation fillers")
        case .replacements: L10n.text("Dictation replacements")
        }
    }
}
