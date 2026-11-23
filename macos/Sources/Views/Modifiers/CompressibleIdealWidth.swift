import SwiftUI

/// Sizes one child at its ideal width, capped at `maximum`, and lets it shrink
/// to its own minimum when the container offers less.
///
/// `.frame(maxWidth:).fixedSize(horizontal: true, vertical: false)` gives the
/// same width when there is room, but it can never compress, so it forces its
/// container (and ultimately the window content) wider than the window.
struct CompressibleIdealWidth: Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(childProposal(proposal, child: child))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func childProposal(_ proposal: ProposedViewSize, child: LayoutSubview) -> ProposedViewSize {
        let ideal = min(child.sizeThatFits(.unspecified).width, maximum)
        let width = proposal.width.map { min($0, ideal) } ?? ideal
        return ProposedViewSize(width: width, height: proposal.height)
    }
}

extension View {
    /// Takes the ideal width up to `maximum`, but compresses instead of overflowing a narrow container.
    func compressibleIdealWidth(maximum: CGFloat) -> some View {
        CompressibleIdealWidth(maximum: maximum) { self }
    }
}
