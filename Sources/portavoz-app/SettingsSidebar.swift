import SwiftUI

/// The Settings navigation, styled to the design system (2a): a deep-glass
/// column of two-line items (icon + title + one-line preview), an indigo→
/// violet gradient on the selected row, a search field on top, and the
/// "all local" seal pinned at the bottom — one click from its receipts.
struct SettingsSidebar: View {
    @Binding var category: SettingsCategory?
    @Binding var query: String
    @Environment(AppServices.self) private var services
    @Environment(\.colorScheme) private var colorScheme

    private var filtered: [SettingsCategory] {
        SettingsCategory.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filtered) { item in
                        navRow(item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
            localSeal
        }
        .background { AuroraSidebarBackground() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private func navRow(_ item: SettingsCategory) -> some View {
        let on = category == item
        return Button {
            category = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(on ? Color.white : .secondary)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                    Text(item.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(on ? Color.white.opacity(0.65) : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(on ? Color.white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(
                            colors: [PVDesign.accent, PVDesign.brandViolet],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-category-\(item.rawValue)")
    }

    /// The standing privacy seal: local by design, one click from the ledger.
    private var localSeal: some View {
        Button {
            category = services.meetingSync.status.isEnabled ? .sync : .data
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    services.meetingSync.status.isEnabled ? "Private iCloud sync" : "Local-first",
                    systemImage: services.meetingSync.status.isEnabled ? "checkmark.icloud" : "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        services.meetingSync.status.isEnabled ? Color.accentColor : Color.green)
                Text(services.meetingSync.status.isEnabled
                    ? "Meeting text syncs privately. Audio and device-only data stay here."
                    : "Nothing auto-uploads. Check the receipts in \u{201C}Your data\u{201D}.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.green.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-privacy-seal")
        .padding(10)
    }
}
