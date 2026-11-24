/// The modeline: the one place Minga's state is always visible.
///
/// The BEAM sends ordered segments with drop ranks (`Wire.StatusBarSegment`). This view measures the width it has (ADR-0001) and applies the ranks, lowest first, until the row fits. Mode, needs-you, the file name, change position, errors and persistent problems never drop. Each segment is a button that does what its key does, with a tooltip naming its meaning and key, and a VoiceOver label and hint. See docs/design/surfaces.md (Modeline) and docs/design/anatomy.md (Modeline segments).

import SwiftUI
import MingaProtocol

public struct StatusBarView: View {
    public enum Action: Equatable, Sendable {
        case executeCommand(name: String)
        case togglePanel(panel: UInt8)
        case reviewBack(generation: UInt32, itemID: String)
        case reviewLatest(generation: UInt32, itemID: String)
        case reviewKeepMine(generation: UInt32, itemID: String)
        case reviewUseAgentVersion(generation: UInt32, itemID: String)
    }

    public init(state: StatusBarState, feedbackState: FeedbackState? = nil, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.feedbackState = feedbackState
        self.sendAction = sendAction
    }
    public let state: StatusBarState
    public var feedbackState: FeedbackState?
    @Environment(\.themeColors) private var theme

    public let sendAction: ViewActionHandler<Action>?

    private let barHeight: CGFloat = 24

    public var body: some View {
        GeometryReader { proxy in
            if let review = state.review {
                reviewStatus(review, width: proxy.size.width)
            } else {
                modelineRow(width: proxy.size.width)
            }
        }
        .frame(height: barHeight)
        .anatomyPart("modeline")
        .background(theme.modelineBarBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    // MARK: - Segments

    /// The segments the modeline keeps at `width`: the BEAM's order with its drop ranks applied, after room for the echo text and pending keys.
    public func fittedSegments(width: CGFloat) -> ModelineFit.Result {
        let budget = max(0, width - 2 * Spacing.sm - echoWidth(in: width) - pendingWidth)
        return ModelineFit.fit(
            state.modelineLeftSegments + state.modelineRightSegments,
            leftCount: state.modelineLeftSegments.count,
            width: budget,
            gap: Spacing.md,
            measure: ModelineMetrics.width
        )
    }

    /// The left cluster at the leading inset, the echo text between, then pending keys and the right cluster at the trailing inset.
    private func modelineRow(width: CGFloat) -> some View {
        let fitted = fittedSegments(width: width)
        let echo = echoWidth(in: width)

        return HStack(spacing: 0) {
            cluster(fitted.left)
            Spacer(minLength: Spacing.md)
            if echo > 0 {
                // The spacers on either side take the echo's two gaps, so the text gets the rest.
                centerSegment
                    .frame(maxWidth: max(0, echo - 2 * Spacing.md))
                    .clipped()
                Spacer(minLength: Spacing.md)
            }
            if !state.pendingKeys.isEmpty {
                showcmdBadge
                    .padding(.trailing, Spacing.md)
            }
            cluster(fitted.right)
        }
        .padding(.horizontal, Spacing.sm)
        .frame(width: width, height: barHeight, alignment: .leading)
        .clipped()
    }

    private func cluster(_ fitted: [ModelineFit.Fitted]) -> some View {
        HStack(spacing: Spacing.md) {
            ForEach(fitted) { kept in
                ModelineSegmentView(segment: kept.segment, compact: kept.compact, mode: state.mode, barHeight: barHeight, sendAction: sendAction)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Room for the echo text: what it needs, at most a third of the bar, nothing when there is no text.
    private func echoWidth(in width: CGFloat) -> CGFloat {
        guard hasCenterStatus else { return 0 }
        return min(ModelineMetrics.textWidth(centerText) + 2 * Spacing.md, width * 0.34)
    }

    private var pendingWidth: CGFloat {
        state.pendingKeys.isEmpty ? 0 : ModelineMetrics.textWidth(state.pendingKeys, monospaced: true) + Spacing.md
    }

    private var hasCenterStatus: Bool {
        state.isRecordingMacro || !state.message.isEmpty || !state.diagnosticHint.isEmpty
    }

    private var centerText: String {
        if state.isRecordingMacro, let reg = state.macroRegister { return "recording @\(String(reg))" }
        return state.message.isEmpty ? state.diagnosticHint : state.message
    }

    @ViewBuilder
    private var showcmdBadge: some View {
        Text(state.pendingKeys)
            .font(Typography.font(.small, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(theme.modelineBarFg.opacity(0.45))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help("Pending keys: \(state.pendingKeys)")
            .accessibilityLabel("Pending keys \(state.pendingKeys)")
    }


    /// Protected Review chrome bypasses the bounded generic modeline groups.
    /// The compact form fits the supported 160pt minimum without hiding any action.
    private func reviewStatus(_ review: StatusBarUpdate.Review, width: CGFloat) -> some View {
        let compact = width < (review.conflictIndex != nil ? 520 : 420)
        let tight = width < 240
        return HStack(spacing: Spacing.xs) {
            if let index = review.conflictIndex {
                let current = tight ? "C\(index)" : "Conflict \(index)"
                let stale = tight ? "S\(index)" : "Stale conflict \(index)"
                ZStack(alignment: .leading) {
                    Text(stale).hidden()
                    Text(review.freshness == .stale ? stale : current)
                }
                .font(Typography.font(.caption))
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(review.freshness == .stale ? "Stale conflict \(index)" : "Conflict \(index) selected")
            } else {
                ReviewFreshnessLabel(freshness: review.freshness, compact: compact)
            }
            ReviewButtons(review: review, compact: compact, sendAction: sendAction, tight: tight)
            if width >= 560 {
                Text(review.path)
                    .font(Typography.font(.small))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.leading, review.conflictIndex != nil ? Spacing.md : 0)
        .foregroundStyle(theme.modelineBarFg)
        .frame(width: width, height: barHeight, alignment: .leading)
    }

    /// Reserves the same intrinsic width when a background write changes freshness.
    public struct ReviewFreshnessLabel: View {
        public let freshness: StatusBarUpdate.Review.Freshness
        public let compact: Bool

        public init(freshness: StatusBarUpdate.Review.Freshness, compact: Bool) {
            self.freshness = freshness
            self.compact = compact
        }

        public var body: some View {
            ZStack(alignment: .leading) {
                Text(compact ? "RO · Current" : "Read-only · Current").hidden()
                Text(compact
                     ? (freshness == .stale ? "RO · Stale" : "RO · Current")
                     : (freshness == .stale ? "Read-only · Stale" : "Read-only · Current"))
            }
            .font(Typography.font(.caption))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(freshness == .stale ? "Read-only Review, stale" : "Read-only Review, current")
        }
    }

    /// Each rendered Button closes over this value snapshot, never mutable selection.
    public struct ReviewButtons: View {
        public let review: StatusBarUpdate.Review
        public let compact: Bool
        public let sendAction: ViewActionHandler<Action>?
        private let tight: Bool

        public init(review: StatusBarUpdate.Review, compact: Bool, sendAction: ViewActionHandler<Action>?, tight: Bool = false) {
            self.review = review
            self.compact = compact
            self.sendAction = sendAction
            self.tight = tight
        }

        public var body: some View {
            HStack(spacing: 0) {
                if review.conflictIndex != nil {
                    conflictButtons
                }
                reviewButton("Back to chat", symbol: "arrow.uturn.backward", accessibility: "Back to chat") {
                    sendAction?(.reviewBack(generation: review.generation, itemID: review.itemID))
                }
                reviewButton("Review latest", symbol: "arrow.clockwise", accessibility: "Review latest changes in \(review.path)") {
                    sendAction?(.reviewLatest(generation: review.generation, itemID: review.itemID))
                }
                .disabled(review.freshness != .stale || sendAction == nil)
                .opacity(review.freshness == .stale ? 1 : 0.4)
                reviewButton("Help", symbol: "questionmark.circle", accessibility: "Agent help") {
                    sendAction?(.executeCommand(name: "agent_toggle_help"))
                }
            }
            .fixedSize()
        }

        /// Conflict decisions name the BEAM-authored key for the active editing model.
        private var conflictButtons: some View {
            HStack(spacing: 0) {
                reviewButton(compact ? "Keep mine" : Self.withKey("Keep mine", review.keepMineKey), symbol: nil, accessibility: Self.withKey("Keep my version", review.keepMineKey), key: review.keepMineKey) {
                    sendAction?(.reviewKeepMine(generation: review.generation, itemID: review.itemID))
                }
                reviewButton(compact ? "Use Agent" : Self.withKey("Use Agent version", review.useAgentKey), symbol: nil, accessibility: Self.withKey("Use Agent version", review.useAgentKey), key: review.useAgentKey) {
                    sendAction?(.reviewUseAgentVersion(generation: review.generation, itemID: review.itemID))
                }
            }
            .disabled(review.freshness == .stale)
            .opacity(review.freshness == .stale ? 0.4 : 1)
        }

        static func withKey(_ title: String, _ key: String) -> String {
            key.isEmpty ? title : "\(title) (\(key))"
        }

        private func reviewButton(_ title: String, symbol: String?, accessibility: String, key: String? = nil, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Group {
                    // A one-character key (Vim) stands in for the title; a chord does not fit.
                    if tight, let key, key.count == 1 {
                        Text(key)
                            .frame(width: 24, height: 24)
                    } else if compact, let symbol {
                        Image(systemName: symbol)
                            .frame(width: 24, height: 24)
                    } else {
                        Text(title)
                            .padding(.horizontal, compact ? Spacing.xs : Spacing.sm)
                            .frame(height: 24)
                    }
                }
                .font(Typography.font(.small))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sendAction == nil)
            .focusable(false)
            .accessibilityLabel(accessibility)
            .help(accessibility)
        }
    }

    // MARK: - Center segment (transient indicators)

    @ViewBuilder
    private var centerSegment: some View {
        if state.isRecordingMacro, let reg = state.macroRegister {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                Text("recording @\(String(reg))")
                    .font(Typography.font(.small))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.8))
            }
        } else if !state.message.isEmpty {
            HStack(spacing: Spacing.xs) {
                if feedbackState?.showingSpinner == true, FeedbackState.isInflight(state.message) {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                        .transition(.opacity)
                }
                Text(state.message)
                    .font(Typography.font(.small))
                    .foregroundStyle(theme.modelineBarFg.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if !state.diagnosticHint.isEmpty {
            Text(state.diagnosticHint)
                .font(Typography.font(.small))
                .foregroundStyle(theme.modelineBarFg.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

public enum StatusBarModelineFont {
    public static func containsPrivateUseGlyph(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            isPrivateUseScalar(scalar.value)
        }
    }

    private static func isPrivateUseScalar(_ value: UInt32) -> Bool {
        (value >= 0xE000 && value <= 0xF8FF) ||
            (value >= 0xF0000 && value <= 0xFFFFD) ||
            (value >= 0x100000 && value <= 0x10FFFD)
    }
}

// MARK: - Previews

private func statusBarPreviewState(mode: PreviewFixtures.PreviewMode = .normal) -> StatusBarState {
    let state = StatusBarState()
    state.update(from: PreviewFixtures.statusBarUpdate(agentVisible: false, mode: mode))
    return state
}

private func statusBarAgentPreviewState() -> StatusBarState {
    let state = StatusBarState()
    state.update(from: PreviewFixtures.statusBarUpdate(agentVisible: true, mode: .normal))
    return state
}

#Preview("Status Bar – Normal", traits: .mingaChrome) {
    StatusBarView(state: statusBarPreviewState(mode: .normal), sendAction: { _ in })
        .frame(width: 800, height: 28)
}

#Preview("Status Bar – Insert", traits: .mingaChrome) {
    StatusBarView(state: statusBarPreviewState(mode: .insert), sendAction: { _ in })
        .frame(width: 800, height: 28)
}

#Preview("Status Bar – Agent Running", traits: .mingaChrome) {
    StatusBarView(state: statusBarAgentPreviewState(), sendAction: { _ in })
        .frame(width: 800, height: 28)
}
