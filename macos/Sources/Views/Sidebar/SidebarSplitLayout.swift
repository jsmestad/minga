import SwiftUI

/// Places the sidebar column and the content beside it, and narrows the sidebar before the content becomes unreadable.
///
/// The leading subview (activity bar, sidebar and resize handle, or their toolbar counterparts) takes its ideal width when the container has room.
/// When the container is narrower than that ideal plus `contentMinimum`, the leading subview gives up width down to its own minimum, so the content keeps `contentMinimum`.
/// The layout only changes the presented width. Whether the sidebar is visible stays a BEAM decision, and the user's chosen width is kept for when the window widens again.
///
/// The toolbar row and the body row use the same layout with leading subviews of equal minimum and ideal widths, so the sidebar header stays aligned with the sidebar below it.
struct SidebarSplitLayout: Layout {
    let contentMinimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let leadingWidth = leadingWidth(proposal: proposal, leading: subviews[0])
        let leadingSize = subviews[0].sizeThatFits(ProposedViewSize(width: leadingWidth, height: proposal.height))
        let trailingSize = subviews[1].sizeThatFits(ProposedViewSize(width: proposal.width.map { max($0 - leadingWidth, 0) }, height: proposal.height))
        return CGSize(width: leadingWidth + trailingSize.width, height: max(leadingSize.height, trailingSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let leadingWidth = leadingWidth(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), leading: subviews[0])
        let trailingWidth = max(bounds.width - leadingWidth, 0)
        // Vertically centered, as the HStack this layout replaces placed them.
        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: leadingWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + leadingWidth, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: trailingWidth, height: bounds.height)
        )
    }

    private func leadingWidth(proposal: ProposedViewSize, leading: LayoutSubview) -> CGFloat {
        let ideal = leading.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).width
        guard let available = proposal.width else { return ideal }
        let minimum = leading.sizeThatFits(ProposedViewSize(width: 0, height: proposal.height)).width
        return SidebarSizing.presentedLeadingWidth(available: available, ideal: ideal, minimum: minimum, contentMinimum: contentMinimum)
    }
}
