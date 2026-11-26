import SwiftUI

/// Settings › Data & privacy, while a 1.x library still holds dictation rows.
struct LegacyDictationDataSection: View {
    let model: LegacyDictationModel
    @State private var confirming = false

    var body: some View {
        if model.hasRows {
            Section("Dictation history") {
                Button("Delete dictation history and statistics", role: .destructive) { confirming = true }
                    .accessibilityIdentifier("settings-legacy-dictation-delete")
                if model.deleteFailed {
                    Text("Could not delete them. Try again.")
                        .font(.caption)
                        .accessibilityIdentifier("settings-legacy-dictation-delete-failed")
                }
            }
            .modifier(LegacyDictationDeleteConfirmation(
                isPresented: $confirming, model: model, identifier: "settings-legacy-dictation-delete-confirm"))
        }
    }
}

/// Shown once to a user who dictated in 1.x.
struct DictationMovedNoticeSheet: View {
    let model: LegacyDictationModel
    let dismiss: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(alignment: .top, spacing: PVDesign.space3) {
            SecreteoMark()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("Dictation moved to Secreteo")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PVDesign.ink)
                    .accessibilityIdentifier("dictation-moved-title")
                Text("Portavoz no longer dictates; global dictation is now its own app, Secreteo.")
                    .font(.callout)
                    .foregroundStyle(.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                if model.deleteFailed {
                    Text("Could not delete them. Try again.")
                        .font(.caption)
                        .cautionText()
                        .accessibilityIdentifier("dictation-moved-delete-failed")
                }
                if model.hasRows {
                    Button("Delete dictation history and statistics", role: .destructive) { confirming = true }
                        .buttonStyle(.plain)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(PVDesign.ink2)
                        .padding(.top, PVDesign.space2)
                        .accessibilityIdentifier("dictation-moved-delete")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Escape, not Return: a default-action button is always .pvPrimary.
            Button("OK", action: dismiss)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.pvSecondary)
                .controlSize(.small)
                .accessibilityIdentifier("dictation-moved-dismiss")
        }
        .padding(PVDesign.space4)
        .frame(width: 460)
        .modifier(LegacyDictationDeleteConfirmation(
            isPresented: $confirming, model: model, identifier: "dictation-moved-delete-confirm"))
    }
}

/// Secreteo's app mark: a copper squircle holding one parenthesis around
/// your amber voice. Drawn on its 120-unit icon grid.
private struct SecreteoMark: View {
    private static let copper = Gradient(colors: [0xC4673A, 0x7E3713].map { Color(nsColor: PVTone.srgb($0)) })
    private static let cream = Color(nsColor: PVTone.srgb(0xFFF4E6))

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 120
            context.scaleBy(x: scale, y: scale)
            let tile = Path(roundedRect: CGRect(x: 6, y: 6, width: 108, height: 108), cornerRadius: 27)
            context.fill(tile, with: .linearGradient(
                Self.copper,
                startPoint: CGPoint(x: 60, y: 6), endPoint: CGPoint(x: 60, y: 114)))
            context.stroke(
                Path(roundedRect: CGRect(x: 6.5, y: 6.5, width: 107, height: 107), cornerRadius: 26.5),
                with: .color(.white.opacity(0.16)), lineWidth: 1)
            var brackets = Path()
            brackets.move(to: CGPoint(x: 40, y: 30))
            brackets.addCurve(
                to: CGPoint(x: 40, y: 92), control1: CGPoint(x: 24, y: 46), control2: CGPoint(x: 24, y: 76))
            brackets.move(to: CGPoint(x: 80, y: 30))
            brackets.addCurve(
                to: CGPoint(x: 80, y: 92), control1: CGPoint(x: 96, y: 46), control2: CGPoint(x: 96, y: 76))
            let round = StrokeStyle(lineWidth: 7.5, lineCap: .round)
            context.stroke(brackets, with: .color(Self.cream), style: round)
            context.stroke(Self.bar(x: 60, from: 46, to: 76), with: .color(PVDesign.you), style: round)
            var echoes = Self.bar(x: 48.5, from: 56, to: 66)
            echoes.addPath(Self.bar(x: 71.5, from: 54, to: 68))
            context.stroke(
                echoes, with: .color(Self.cream.opacity(0.5)), style: StrokeStyle(lineWidth: 5.5, lineCap: .round))
        }
        .accessibilityHidden(true)
    }

    private static func bar(x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x, y: bottom))
        }
    }
}

private struct LegacyDictationDeleteConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let model: LegacyDictationModel
    let identifier: String

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete dictation history and statistics?", isPresented: $isPresented, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteAll() }
            }
            .accessibilityIdentifier(identifier)
        } message: {
            Text("This can't be undone.")
        }
    }
}
