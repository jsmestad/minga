/// Curated SF Symbol grid for workspace icon customization.
///
/// Shows ~60 symbols organized in categories relevant to code/project
/// contexts. Type-to-filter search at the top. Selecting an icon
/// dismisses the popover and sends the choice to the BEAM.

import SwiftUI

public struct WorkspaceIconPicker: View {
    public init(currentIcon: String, accentColor: Color, onSelect: @escaping (String) -> Void) {
        self.currentIcon = currentIcon
        self.accentColor = accentColor
        self.onSelect = onSelect
    }
    public let currentIcon: String
    public let accentColor: Color
    @Environment(\.themeColors) private var theme
    @Environment(\.editorFocusPolicy) private var focusPolicy
    public let onSelect: (String) -> Void

    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool

    private static let categories: [(String, [String])] = [
        ("General", [
            "folder", "doc", "doc.on.doc", "tray.full",
            "archivebox", "shippingbox", "bookmark",
            "tag", "flag", "pin", "star"
        ]),
        ("Code", [
            "chevron.left.forwardslash.chevron.right", "terminal",
            "cpu", "memorychip", "server.rack",
            "network", "externaldrive", "curlybraces",
            "function", "number"
        ]),
        ("Tools", [
            "hammer", "wrench", "screwdriver", "gearshape",
            "paintbrush", "pencil", "scissors", "wand.and.stars",
            "ant", "ladybug"
        ]),
        ("Search & Analyze", [
            "magnifyingglass", "doc.text.magnifyingglass",
            "chart.bar", "chart.line.uptrend.xyaxis",
            "scope", "binoculars",
            "eye", "lightbulb"
        ]),
        ("Communication", [
            "bubble.left", "bubble.left.and.bubble.right",
            "envelope", "paperplane", "megaphone",
            "bell", "bolt", "brain"
        ])
    ]

    private var filteredCategories: [(String, [String])] {
        guard !searchText.isEmpty else { return Self.categories }
        let query = searchText.lowercased()
        return Self.categories.compactMap { name, icons in
            let filtered = icons.filter { $0.localizedCaseInsensitiveContains(query) }
            return filtered.isEmpty ? nil : (name, filtered)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(Typography.font(.small))
                TextField("Search icons", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Typography.font(.body))
                    .focused($searchFocused)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(filteredCategories, id: \.0) { category, icons in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(category)
                                .font(Typography.font(.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, Spacing.xs)

                            LazyVGrid(
                                columns: Array(repeating: GridItem(.fixed(32), spacing: Spacing.hairline), count: 6),
                                spacing: Spacing.hairline
                            ) {
                                ForEach(icons, id: \.self) { icon in
                                    iconButton(icon)
                                }
                            }
                        }
                    }
                }
                .padding(Spacing.md)
            }
            .frame(width: 220, height: 280)
        }
        .onAppear { focusPolicy?.beginLocalTextEditing(.workspaceIconSearch) }
        .onChange(of: focusPolicy?.focusOwnerState.localTextEditing, initial: true) { _, editing in
            searchFocused = editing == .workspaceIconSearch
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused { focusPolicy?.endLocalTextEditing(.workspaceIconSearch) }
        }
        .onDisappear { focusPolicy?.endLocalTextEditing(.workspaceIconSearch) }
    }

    @ViewBuilder
    private func iconButton(_ icon: String) -> some View {
        let isSelected = icon == currentIcon
        Button(action: { onSelect(icon) }) {
            Image(systemName: icon)
                .font(Typography.font(.title))
                .foregroundStyle(isSelected ? accentColor : .primary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .fill(isSelected ? accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon)
    }
}
