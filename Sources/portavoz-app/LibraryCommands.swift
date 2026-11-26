import SwiftUI

/// What the focused main window exposes to the menu bar.
struct LibraryCommandActions {
    let navigate: (Route) -> Void
    let focusSearch: () -> Void
}

extension FocusedValues {
    @Entry var libraryCommands: LibraryCommandActions?
}

/// Menu-bar owned, so the shortcuts work while the sidebar is collapsed.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryCommands) private var actions

    var body: some Commands {
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Divider()
            destination("Today", key: "1", route: .library)
            destination("Ask", key: "2", route: .ask)
            destination("Insights", key: "3", route: .insights)
            destination("Radar", key: "4", route: .commitments(nil))
        }
        CommandGroup(after: .textEditing) {
            Button("Search all meetings…") { actions?.focusSearch() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
        }
    }

    private func destination(
        _ title: LocalizedStringKey, key: KeyEquivalent, route: Route
    ) -> some View {
        Button(title) { actions?.navigate(route) }
            .keyboardShortcut(key)
            .disabled(actions == nil)
    }
}
