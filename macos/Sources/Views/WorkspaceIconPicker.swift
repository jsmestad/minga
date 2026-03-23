/// Curated SF Symbol grid for workspace icon customization.
///
/// Shows ~60 symbols organized in categories relevant to code/project
/// contexts. Type-to-filter search at the top. Selecting an icon
/// dismisses the popover and sends the choice to the BEAM.

import SwiftUI

struct WorkspaceIconPicker: View {
    let currentIcon: String
    let accentColor: Color
    let theme: ThemeColors
    let onSelect: (String) -> Void

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Search icons", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredCategories, id: \.0) { category, icons in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            LazyVGrid(
                                columns: Array(repeating: GridItem(.fixed(32), spacing: 2), count: 6),
                                spacing: 2
                            ) {
                                ForEach(icons, id: \.self) { icon in
                                    iconButton(icon)
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 220, height: 280)
        }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private func iconButton(_ icon: String) -> some View {
        let isSelected = icon == currentIcon
        Button(action: { onSelect(icon) }) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? accentColor : .primary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? accentColor.opacity(0.15) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon)
    }
}
