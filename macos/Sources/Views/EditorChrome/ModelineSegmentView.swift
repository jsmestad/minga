/// Modeline segments: how the macOS modeline fits the BEAM's segments to its width and draws each one.

import AppKit
import SwiftUI
import MingaProtocol

/// Fits the BEAM's modeline segments to a width by applying their drop ranks.
///
/// Ranks apply in ascending order until the segments, one gap apart within each cluster and one gap between the clusters, fit. Every segment at the current rank goes at once; a segment with a compact form collapses to its state mark and compact text instead, and stays. Rank 0 never drops. The Go TUI applies the same rule (`fitModeline` in `render_chrome.go`).
public enum ModelineFit {
    /// One segment the modeline keeps: its index in the BEAM's order, and whether it shows its compact form.
    public struct Fitted: Identifiable, Equatable {
        public let id: Int
        public let segment: Wire.StatusBarSegment
        public let compact: Bool
    }

    /// The kept segments, split back into the left and right clusters.
    public struct Result: Equatable {
        public let left: [Fitted]
        public let right: [Fitted]

        /// Every kept segment's kind, left to right.
        public var kinds: [String] { (left + right).map(\.segment.kind) }
    }

    /// Applies drop ranks to `segments` (the left cluster's `leftCount` segments, then the right cluster's) until they fit in `width`.
    public static func fit(
        _ segments: [Wire.StatusBarSegment],
        leftCount: Int,
        width: CGFloat,
        gap: CGFloat,
        measure: (Wire.StatusBarSegment, Bool) -> CGFloat
    ) -> Result {
        var compact = Array(repeating: false, count: segments.count)
        var dropped = Array(repeating: false, count: segments.count)

        func total() -> CGFloat {
            var sum: CGFloat = 0
            var counts = (left: 0, right: 0)
            for (index, segment) in segments.enumerated() where !dropped[index] {
                sum += measure(segment, compact[index])
                if index < leftCount { counts.left += 1 } else { counts.right += 1 }
            }
            sum += CGFloat(max(counts.left - 1, 0) + max(counts.right - 1, 0)) * gap
            if counts.left > 0 && counts.right > 0 { sum += gap }
            return sum
        }

        let ranks = Set(segments.map(\.drop).filter { $0 > 0 }).sorted()
        for rank in ranks where total() > width {
            for (index, segment) in segments.enumerated() where segment.drop == rank {
                if segment.compact != nil {
                    compact[index] = true
                } else {
                    dropped[index] = true
                }
            }
        }

        var left: [Fitted] = []
        var right: [Fitted] = []
        for (index, segment) in segments.enumerated() where !dropped[index] {
            let kept = Fitted(id: index, segment: segment, compact: compact[index])
            if index < leftCount { left.append(kept) } else { right.append(kept) }
        }
        return Result(left: left, right: right)
    }
}

/// Text and mark widths of modeline segments, measured with the fonts `ModelineSegmentView` draws them in.
public enum ModelineMetrics {
    /// The width of one segment as `ModelineSegmentView` draws it, in its full or compact form.
    public static func width(_ segment: Wire.StatusBarSegment, compact: Bool) -> CGFloat {
        if segment.kind == "mode" {
            return textWidth(segment.text, weight: .semibold) + 2 * Spacing.sm
        }
        let words = compact ? (segment.compact ?? "") : segment.text
        let mark = ModelineSegmentView.hasMark(segment) ? ModelineSegmentView.markSize + (words.isEmpty ? 0 : Spacing.xs) : 0
        return mark + textWidth(words, weight: segment.isBold ? .semibold : .regular)
    }

    /// The width of `text` set in the modeline's `small` step.
    public static func textWidth(_ text: String, weight: NSFont.Weight = .regular, monospaced: Bool = false) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let size = Typography.Step.small.rawValue
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// One modeline segment: the mode pill, a state's mark and words, an error or warning count with its mark, or plain words.
///
/// A segment with a command is a button that runs it, the same command its key runs. The tooltip names what the segment means and its key ("1 task needs you · SPC a a"); VoiceOver reads the meaning as the label and the key as the hint.
struct ModelineSegmentView: View {
    let segment: Wire.StatusBarSegment
    let compact: Bool
    let mode: EditorMode
    let barHeight: CGFloat
    let sendAction: ViewActionHandler<StatusBarView.Action>?

    @Environment(\.themeColors) private var theme

    /// The side of a state, error or warning mark.
    static let markSize: CGFloat = Typography.Step.micro.rawValue

    /// True when the segment draws a mark before its words.
    static func hasMark(_ segment: Wire.StatusBarSegment) -> Bool {
        segment.state != nil || segment.kind == "errors" || segment.kind == "warnings"
    }

    var body: some View {
        if segment.command.isEmpty {
            content
                .help(tooltip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        } else {
            Button(action: { sendAction?(.executeCommand(name: segment.command)) }) {
                content
            }
            .buttonStyle(.plain)
            .help(tooltip)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(segment.key.isEmpty ? "" : "Press \(segment.key)")
            .pointingHandCursor()
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if segment.kind == "mode" {
                modePill
            } else {
                HStack(spacing: Spacing.xs) {
                    mark
                    if !words.isEmpty {
                        Text(words)
                            .font(Typography.font(.small, weight: segment.isBold ? .semibold : .regular))
                            .foregroundStyle(foreground)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .frame(height: barHeight)
        .contentShape(Rectangle())
        .anatomyPart("modeline.segment", text: "\(segment.kind): \(words)")
    }

    private var modePill: some View {
        let (bg, fg) = modeColors
        return Text(segment.text)
            .font(Typography.font(.small, weight: .semibold))
            .foregroundStyle(fg)
            .anatomyPart("modeline.modeText", text: segment.text, font: .small)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.hairline)
            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(bg))
            .anatomyPart("modeline.modePill", text: segment.text)
    }

    @ViewBuilder
    private var mark: some View {
        if let state = segment.state {
            StateMark(state: state)
                .frame(width: Self.markSize, height: Self.markSize)
        } else if segment.kind == "errors" {
            Image(systemName: "xmark.circle.fill")
                .font(Typography.font(.micro))
                .foregroundStyle(theme.roleColor(.failure))
        } else if segment.kind == "warnings" {
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.font(.micro))
                .foregroundStyle(theme.roleColor(.warning))
        }
    }

    private var words: String {
        compact ? (segment.compact ?? "") : segment.text
    }

    /// A state segment draws in its state's role; others in the colour the BEAM resolved from its role.
    private var foreground: Color {
        if let state = segment.state { return theme.stateColor(state) }
        return color(segment.fgColor)
    }

    private var modeColors: (Color, Color) {
        switch mode {
        case .normal: return (theme.modeNormalBg, theme.modeNormalFg)
        case .insert: return (theme.modeInsertBg, theme.modeInsertFg)
        case .visual: return (theme.modeVisualBg, theme.modeVisualFg)
        case .command, .operatorPending, .search, .replace, .unknown:
            return (theme.modelineInfoBg, theme.modelineInfoFg)
        }
    }

    private var tooltip: String {
        let meaning = segment.label.isEmpty ? segment.text : segment.label
        return segment.key.isEmpty ? meaning : "\(meaning) · \(segment.key)"
    }

    private var accessibilityLabel: String {
        segment.label.isEmpty ? segment.text : segment.label
    }

    private func color(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

/// A state's mark, drawn by its token shape in its token role: the orbit, the halo dot, the hollow dot, the diamond or the solid dot (docs/design/marks.md). The orbit turns only while Reduce Motion is off.
public struct StateMark: View {
    public let state: SpineState
    @Environment(\.themeColors) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: SpineState) {
        self.state = state
    }

    public var body: some View {
        let color = theme.stateColor(state)
        Group {
            switch state.shape {
            case .orbit:
                TimelineView(.animation(paused: reduceMotion)) { context in
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(color, style: StrokeStyle(lineWidth: Spacing.pixel * 1.5, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                }
            case .haloDot:
                ZStack {
                    Circle().stroke(color.opacity(0.45), lineWidth: Spacing.pixel)
                    Circle().fill(color).padding(Spacing.hairline)
                }
            case .hollowDot:
                Circle().stroke(color, lineWidth: Spacing.pixel * 1.5)
            case .diamond:
                Rectangle().fill(color).rotationEffect(.degrees(45)).padding(Spacing.pixel)
            case .solidDot:
                Circle().fill(color)
            }
        }
        .accessibilityLabel(state.accessibilityLabel)
    }
}
