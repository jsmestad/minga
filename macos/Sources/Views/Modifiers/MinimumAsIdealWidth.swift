import SwiftUI

/// Reports a child's minimum width as its ideal width, and otherwise lays it out unchanged.
///
/// `ViewThatFits` picks the first child whose ideal width fits. A row of truncating labels has a wide ideal width, so a long project or branch name would make `ViewThatFits` drop the row even though the labels could truncate to fit.
/// Wrapping each candidate row makes `ViewThatFits` choose by whether the row can fit at all.
struct MinimumAsIdealWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: proposal.width ?? 0, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension View {
    /// Lets `ViewThatFits` choose this candidate whenever its minimum width fits, not only its ideal width.
    func minimumAsIdealWidth() -> some View {
        MinimumAsIdealWidth { self }
    }
}
