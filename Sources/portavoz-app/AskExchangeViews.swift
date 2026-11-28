import ApplicationKit
import PortavozCore
import SwiftUI

extension PVDisplayStyle {
    /// The question an Ask page answers.
    static let askQuestion = PVDisplayStyle(size: 36, weight: 440, tracking: -0.018, relativeTo: .largeTitle)
}

/// "You asked · 3:16 PM", where the answer came from, then the question as the page title.
struct AskQuestionHeader<Source: View>: View {
    let question: String
    let askedAt: Date
    let answeredIn: Duration?
    let identifier: String
    @ViewBuilder let source: Source

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PVCardCaption(text: kicker, tint: PVDesign.ink3)
                source
                Spacer(minLength: 12)
                if let answeredIn {
                    Label(
                        L10n.format("answered on your Mac · %@", AskEvidencePresentation.answerTime(answeredIn)),
                        systemImage: PVSymbol.privacy)
                        .font(.subheadline)
                        .foregroundStyle(.ink3)
                        .lineLimit(1)
                        .accessibilityIdentifier("\(identifier)-receipt")
                }
            }
            Text(verbatim: question)
                .pvDisplay(.askQuestion)
                .foregroundStyle(PVDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
        }
    }

    private var kicker: String {
        let time = askedAt.formatted(.dateTime.hour().minute().locale(AppLanguage.current.locale))
        return L10n.format("You asked · %@", time)
    }
}

/// The answer with each `[n]` drawn as the numbered marker of its evidence row.
struct AskAnswerText: View {
    let pieces: [AskEvidencePresentation.Piece]

    var body: some View {
        pieces
            .reduce(Text(verbatim: "")) { text, piece in
                switch piece {
                case .text(let run): Text("\(text)\(Text(verbatim: run))")
                case .marker(let number): Text("\(text)\(Self.marker(number))")
                }
            }
    }

    /// A thin space, then the filled number in Portavoz green.
    private static func marker(_ number: Int) -> Text {
        let glyph = Text(Image(systemName: "\(number).circle.fill"))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(PVDesign.green)
        return Text("\(Text(verbatim: "\u{2009}"))\(glyph)")
    }
}

/// The generated answer on the green tint, with what it was drawn from and its two actions.
struct AskAnswerCard: View {
    let pieces: [AskEvidencePresentation.Piece]
    /// "Portavoz · from 3 voices in 3 meetings"; nil when Portavoz did not write the answer.
    let generatedFrom: String?
    let openCommitments: [CommitmentID]
    let copied: Bool
    let identifier: String
    let onCopy: () -> Void
    let onOpenCommitments: ([CommitmentID]) -> Void
    /// Why the engine did not write the answer, with its identifier.
    let status: (text: String, identifier: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AskAnswerText(pieces: pieces)
                .askAnswerText()
                // No label override: on selectable text it recurses in SwiftUI's
                // accessibility tree, and each numbered symbol already reads as its number.
                .accessibilityIdentifier("ask-answer-\(identifier)")
            if let status {
                Label(status.text, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(PVDesign.ink2)
                    .accessibilityIdentifier(status.identifier)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    source
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 8) {
                    source
                    HStack(spacing: 8) { actions }
                }
            }
        }
        .askAnswerSurface()
    }

    @ViewBuilder private var source: some View {
        if let generatedFrom {
            Label(generatedFrom, systemImage: ChipLabel.generatedSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PVDesign.green)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("ask-generated-from-\(identifier)")
        }
    }

    @ViewBuilder private var actions: some View {
        if !openCommitments.isEmpty {
            Button(AskEvidencePresentation.openCommitments(openCommitments.count)) {
                onOpenCommitments(openCommitments)
            }
            .buttonStyle(AskRaisedChipStyle())
            .accessibilityIdentifier("ask-open-commitments-\(identifier)")
        }
        Button(copied ? L10n.text("Copied") : L10n.text("Copy as Markdown"), action: onCopy)
            .buttonStyle(AskRaisedChipStyle())
            .accessibilityIdentifier("ask-copy-markdown-\(identifier)")
    }
}

extension View {
    /// The answer's reading size, set the same while it streams and once it lands.
    func askAnswerText() -> some View {
        font(.system(size: 18))
            .lineSpacing(6)
            .foregroundStyle(PVDesign.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// Portavoz's green tint under an answer.
    func askAnswerSurface() -> some View {
        padding(EdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PVDesign.greenBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A white chip on the answer's tint.
private struct AskRaisedChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(PVDesign.ink)
            .pvPill(PVDesign.raise)
            .fixedSize()
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// "Who said it": one row per quote, led by the person, with the moment marked on its meeting's strip.
struct AskWhoSaidIt: View {
    let rows: [AskEvidencePresentation.Row]
    let compact: Bool
    let identifier: String
    let onPlay: (AskCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Who said it")
                    .pvDisplay(.section)
                    .foregroundStyle(PVDesign.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(AskEvidencePresentation.moments(rows.count))
                    .font(.subheadline)
                    .foregroundStyle(.ink3)
            }
            .padding(.bottom, 8)
            ForEach(rows) { row in
                AskEvidenceRow(
                    row: row, compact: compact, identifier: "\(identifier)-\(row.number)",
                    onPlay: { onPlay(row.citation) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private struct AskEvidenceRow: View {
    static let stripWidth: CGFloat = 190

    let row: AskEvidencePresentation.Row
    let compact: Bool
    let identifier: String
    let onPlay: () -> Void

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .top, spacing: 12) {
                    number
                    VStack(alignment: .leading, spacing: 8) {
                        person
                        quote
                        moment
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    number.frame(width: 22, alignment: .leading)
                    person.frame(width: 92, alignment: .leading)
                    quote.frame(maxWidth: .infinity, alignment: .leading)
                    moment.frame(width: Self.stripWidth)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(PVDesign.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var number: some View {
        Text(verbatim: "\(row.number)")
            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
            .foregroundStyle(PVDesign.onInk)
            .frame(width: 18, height: 18)
            .background(PVDesign.green, in: Circle())
            .padding(.top, 2)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var person: some View {
        switch row.speaker {
        case .pending:
            Color.clear.frame(width: 1, height: 18)
        case .unknown:
            speaker(Text("Unknown speaker"), tint: .grey, isOpen: true, ink: PVDesign.ink3)
        case .voice(let name, let tint):
            speaker(Text(verbatim: name), tint: tint, isOpen: false, ink: PVDesign.ink)
        }
    }

    private func speaker(_ name: Text, tint: VoiceCast.Tint, isOpen: Bool, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            VoiceDot(tint: tint, size: 10, isOpen: isOpen)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            name
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifier)-speaker")
    }

    private var quote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "“\(row.citation.text)”")
                .pvDisplay(PVDisplayStyle.heard.sized(17))
                .lineSpacing(2)
                .foregroundStyle(PVDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(PVFont.timeCoded(row.meeting(), at: row.time, style: .subheadline))
                .font(.subheadline)
                .foregroundStyle(.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier)-meeting")
        }
    }

    private var moment: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if let strip = row.strip {
                VoiceStrip(strip, size: .card, progress: 0, mark: row.position)
                    .padding(.top, 8)
            }
            Button(action: onPlay) {
                Label("Play moment", systemImage: "play.fill")
                    .labelStyle(AskPlayLabelStyle())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PVDesign.ink2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityValue(Text(verbatim: "\(row.meeting()) · \(row.time)"))
            .accessibilityIdentifier("\(identifier)-play")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct AskPlayLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
