import SwiftUI

// The base controls Portavoz shares in shape with Secreteo (D646): 8 pt
// rounded buttons, capsule chips and status pills, outlined and tinted cards.

// MARK: Buttons

/// Ink primary, raised secondary, or the red Stop. Height follows the
/// control size; focus keeps the system ring (D643).
struct PVButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, stop }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        PVButtonBody(kind: kind, configuration: configuration)
    }
}

extension ButtonStyle where Self == PVButtonStyle {
    static var pvPrimary: PVButtonStyle { PVButtonStyle(kind: .primary) }
    static var pvSecondary: PVButtonStyle { PVButtonStyle(kind: .secondary) }
    static var pvStop: PVButtonStyle { PVButtonStyle(kind: .stop) }
}

private struct PVButtonBody: View {
    let kind: PVButtonStyle.Kind
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PVDesign.radiusSmall, style: .continuous)
        let compact = controlSize == .small || controlSize == .mini
        let (foreground, background) = colors
        configuration.label
            .font(compact ? .callout.weight(.semibold) : .body.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 13)
            .frame(minHeight: height)
            .background {
                if kind == .secondary {
                    shape.fill(background).overlay { shape.strokeBorder(PVDesign.line2, lineWidth: 0.5) }
                } else {
                    shape.fill(background).shadow(color: .black.opacity(isEnabled ? 0.2 : 0), radius: 1, y: 1)
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
    }

    private var height: CGFloat {
        switch controlSize {
        case .mini, .small: 24
        case .large: 32
        case .extraLarge: 36
        default: 30
        }
    }

    private var colors: (Color, Color) {
        switch kind {
        case .primary: (PVDesign.onInk, PVDesign.ink)
        case .secondary: (PVDesign.ink, PVDesign.raise)
        case .stop: (PVDesign.onNow, PVDesign.now)
        }
    }
}

private struct RecordDot: View {
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(PVDesign.now)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A Record button label: the red dot, then the title.
struct RecordLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 7) {
            RecordDot()
            Text(title)
        }
    }
}

// MARK: Pills

private struct PVPillShape: ViewModifier {
    let background: Color
    let trailing: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.leading, 9)
            .padding(.trailing, trailing)
            .frame(minHeight: 22)
            .background(background, in: Capsule())
    }
}

extension View {
    /// The family chip shape: 22 pt capsule, 11 pt semibold label. A chip
    /// that ends in a small button passes a tighter trailing inset.
    func pvPill(_ background: Color, trailing: CGFloat = 9) -> some View {
        modifier(PVPillShape(background: background, trailing: trailing))
    }
}

/// A voice: dot, name and optional talk share. You wear the amber tint; an
/// unnamed voice has an open dot on a dashed outline until it is named.
struct VoiceChip: View {
    enum Voice: Equatable {
        case you
        case named(Color)
        case unnamed(Color)
    }

    let voice: Voice
    let name: String
    var share: Double?
    var isLinked = false

    var body: some View {
        HStack(spacing: 6) {
            dot
            Text(label)
            if isLinked {
                Image(systemName: PVSymbol.success)
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(voice == .you ? PVDesign.youInk : PVDesign.ink)
        .pvPill(background)
        .overlay {
            if case .unnamed = voice {
                Capsule().strokeBorder(PVDesign.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
    }

    private var label: String {
        guard let share else { return name }
        return "\(name) · \(share.formatted(.percent.precision(.fractionLength(0))))"
    }

    @ViewBuilder
    private var dot: some View {
        switch voice {
        case .you:
            Circle().fill(PVDesign.you).frame(width: 8, height: 8)
        case .named(let hue):
            Circle().fill(hue).frame(width: 8, height: 8)
        case .unnamed(let hue):
            Circle().strokeBorder(hue, lineWidth: 1.6).frame(width: 8, height: 8)
        }
    }

    private var background: Color {
        switch voice {
        case .you: PVDesign.youBg
        case .named: PVDesign.line
        case .unnamed: .clear
        }
    }
}

/// Live state in red, the only red text in the app: "Recording 12:04" on the
/// red tint, or the solid "Now 3:15" playhead label.
struct StatusPill: View {
    enum Kind { case recording, now }

    let kind: Kind
    let text: String

    var body: some View {
        switch kind {
        case .recording:
            HStack(spacing: 6) {
                RecordDot(size: 8)
                Text(text).monospacedDigit()
            }
            .foregroundStyle(PVDesign.now)
            .pvPill(PVDesign.nowBg)
        case .now:
            Text(text)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(PVDesign.onNow)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(PVDesign.now, in: Capsule())
        }
    }
}

// MARK: Cards

enum PVCardStyle {
    /// Commitments and other records: card fill, hairline outline; secondary
    /// text uses ink 3.
    case outlined
    /// Text Portavoz generated: green tint, no outline; secondary text uses
    /// ink 2 and tertiary ink 3, both above 4.5:1 on the tint.
    case generated
}

extension View {
    /// A full-width card; the content leads from the top-left corner.
    func pvCard(_ style: PVCardStyle, padding: CGFloat = PVDesign.space3) -> some View {
        let shape = RoundedRectangle(cornerRadius: PVDesign.radiusTile, style: .continuous)
        let generated = style == .generated
        return foregroundStyle(PVDesign.ink, generated ? PVDesign.ink2 : PVDesign.ink3, PVDesign.ink3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(padding)
            .background(generated ? PVDesign.greenBg : PVDesign.card, in: shape)
            .overlay {
                if !generated { shape.strokeBorder(PVDesign.line, lineWidth: 1) }
            }
    }
}

/// The small uppercase line that names what a card holds.
struct PVCardCaption: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(tint)
    }
}

// MARK: Segmented control and checkbox

struct PVSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let accessibilityIdentifier: String

    var id: Value { value }
}

/// Tabs on a tinted track; the selected segment is raised. Each segment is
/// its own button so feature tests can address it by identifier.
struct PVSegmentedControl<Value: Hashable>: View {
    let segments: [PVSegment<Value>]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(2)
        .background(PVDesign.line, in: RoundedRectangle(cornerRadius: PVDesign.radiusSmall))
        .accessibilityElement(children: .contain)
    }

    private func segmentButton(_ segment: PVSegment<Value>) -> some View {
        let selected = segment.value == selection
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Button {
            selection = segment.value
        } label: {
            Text(segment.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(selected ? PVDesign.ink : PVDesign.ink2)
                .padding(.horizontal, 11)
                .frame(minHeight: 24)
                .background {
                    if selected {
                        shape.fill(PVDesign.raise)
                            .overlay { shape.strokeBorder(PVDesign.line2, lineWidth: 0.5) }
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(segment.accessibilityIdentifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A 15 pt rounded box: ink outline, ink fill with a paper tick when on.
struct PVCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                box(isOn: configuration.isOn)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(verbatim: configuration.isOn ? "1" : "0"))
    }

    private func box(isOn: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        return ZStack {
            if isOn {
                shape.fill(PVDesign.ink)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(PVDesign.onInk)
            } else {
                shape.strokeBorder(PVDesign.ink3, lineWidth: 1.4)
            }
        }
        .frame(width: 15, height: 15)
        .alignmentGuide(.firstTextBaseline) { $0.height * 0.8 }
    }
}

extension ToggleStyle where Self == PVCheckboxToggleStyle {
    static var pvCheckbox: PVCheckboxToggleStyle { PVCheckboxToggleStyle() }
}
