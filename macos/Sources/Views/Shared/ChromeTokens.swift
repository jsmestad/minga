import SwiftUI

/// Frontend-owned chrome gaps. Editor cells and scroll tracks keep their own metrics.
public enum Spacing {
    /// 1pt: optical separation for compact badges and rules.
    public static let pixel: CGFloat = 1
    /// 2pt: badge internals and tight vertical rhythm.
    public static let hairline: CGFloat = 2
    /// 4pt: tight inline groups.
    public static let xs: CGFloat = 4
    /// 6pt: compact row gaps and vertical control padding.
    public static let sm: CGFloat = 6
    /// 8pt: default control gaps and insets.
    public static let md: CGFloat = 8
    /// 12pt: comfortable rows and panel insets.
    public static let lg: CGFloat = 12
    /// 16pt: separation between groups.
    public static let xl: CGFloat = 16
    /// 20pt: section padding.
    public static let xxl: CGFloat = 20
    /// 24pt: spacious empty-state and dialog insets.
    public static let panel: CGFloat = 24
    /// 32pt: major section breaks.
    public static let section: CGFloat = 32
}

/// Chrome text sizes and shared styles, independent of theme and editor state.
public enum Typography {
    /// Named point sizes, including display-only symbols that must not shrink to body text.
    public enum Step: CGFloat, Sendable {
        case tiny = 7
        case symbol = 8
        case micro = 9
        case caption = 10
        case small = 11
        case body = 12
        case emphasis = 13
        case title = 14
        case toolbar = 15
        case heading = 16
        case illustration = 20
        case action = 24
    }

    /// Builds a chrome font with explicit size, weight, and design.
    public static func font(_ size: Step, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size.rawValue, weight: weight, design: design)
    }

    /// Key columns and candidate rows share this compact monospaced style.
    public static let monospacedSmall = font(.small, weight: .medium, design: .monospaced)

    /// Keeps runtime editor-relative text sizing explicit without assigning it a chrome step.
    public static func relative(to pointSize: CGFloat, scale: CGFloat = 1, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: pointSize * scale, weight: weight, design: design)
    }
}

/// Chrome corner treatments, unrelated to scroll-thumb geometry.
public enum Radius {
    /// 1pt: a narrow active-row accent, not a rounded card.
    public static let accent: CGFloat = 1
    /// 4pt: compact rows, badges, and fields.
    public static let sm: CGFloat = 4
    /// 6pt: small panels and controls.
    public static let md: CGFloat = 6
    /// 8pt: overlays and cards.
    public static let lg: CGFloat = 8
    /// 12pt: large cards and prompt capsules.
    public static let xl: CGFloat = 12
}
