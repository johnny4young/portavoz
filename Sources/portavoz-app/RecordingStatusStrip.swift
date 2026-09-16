import SwiftUI

/// One thing the live recording wants the user to know, ranked so the strip
/// can show the most important one and fold the rest behind a count.
struct RecordingNotice: Identifiable {
    enum Severity {
        case info
        case success
        case warning
        case error

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .success: PVSymbol.success
            case .warning: PVSymbol.warning
            case .error: PVSymbol.error
            }
        }

        var tint: Color {
            switch self {
            case .info: .secondary
            case .success: .green
            case .warning: .orange
            case .error: .red
            }
        }
    }

    struct Action {
        let title: String
        let identifier: String
        let prominent: Bool
        let perform: @MainActor () -> Void
    }

    let id: String
    let severity: Severity
    let message: String
    /// A symbol that says what the notice is about; the severity supplies
    /// the colour and, when nil, the glyph.
    let symbol: String?
    let actions: [Action]

    init(
        id: String,
        severity: Severity,
        message: String,
        symbol: String? = nil,
        actions: [Action] = []
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.symbol = symbol
        self.actions = actions
    }
}

/// The seven stacked recording banners became one strip: the highest-ranked
/// notice with at most two actions, and a count that opens the rest. Each
/// notice keeps its own accessibility identifier so journeys and assistive
/// technology address the same thing wherever it renders.
struct RecordingStatusStrip: View {
    let notices: [RecordingNotice]

    @State private var showsSecondary = false

    var body: some View {
        if let primary = notices.first {
            HStack(spacing: 10) {
                noticeRow(primary)
                Spacer(minLength: 4)
                if notices.count > 1 {
                    secondaryButton
                }
            }
            .padding(.horizontal, 20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recording-status-strip")
        }
    }

    private var secondaryButton: some View {
        Button {
            showsSecondary.toggle()
        } label: {
            Text(L10n.format("%d more", notices.count - 1))
                .font(.caption2.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("recording-status-more")
        .popover(isPresented: $showsSecondary, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(notices.dropFirst()) { notice in
                    noticeRow(notice)
                }
            }
            .padding(16)
            .frame(width: 360, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("recording-status-secondary")
        }
    }

    private func noticeRow(_ notice: RecordingNotice) -> some View {
        HStack(spacing: 8) {
            Label {
                Text(notice.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: notice.symbol ?? notice.severity.symbol)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(notice.severity.tint)
            // The row carries the message as its own label and still exposes
            // the text child, so both label and static-text lookups read it.
            .accessibilityLabel(notice.message)
            .accessibilityIdentifier(notice.id)
            ForEach(notice.actions, id: \.identifier) { action in
                Button(action.title, action: action.perform)
                    .buttonStyle(.plain)
                    .font(.caption2.weight(action.prominent ? .semibold : .medium))
                    .foregroundStyle(action.prominent ? notice.severity.tint : Color.secondary)
                    .accessibilityIdentifier(action.identifier)
            }
        }
    }
}
