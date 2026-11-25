import CoreGraphics

/// What the transcript's scroll view reports after a layout or a scroll: where the view is, how tall it is, how tall the conversation is, and how many rows the conversation has.
struct TranscriptScrollGeometry: Equatable, Sendable {
    var offsetY: CGFloat
    var visibleHeight: CGFloat
    var contentHeight: CGFloat
    var rowCount: Int

    /// How far the bottom of the conversation is below the bottom of the view.
    var distanceFromBottom: CGFloat { contentHeight - (offsetY + visibleHeight) }
}

/// Decides whether the transcript keeps following the newest output.
///
/// The rule: the view follows new output until you scroll away from it. A scroll that moves the view up stops the follow, and reaching the bottom again resumes it. Output never stops it, however much arrives in one frame: a new message, or text that grows while Minga works, is Minga writing, not you scrolling. Opening a tool step while nothing is running is your own change, so the view holds still and offers Follow output.
enum TranscriptFollow {
    /// The outcome of one geometry change.
    enum Decision: Equatable, Sendable {
        /// Keep following. `catchUp` is true when the view must scroll to the bottom again.
        case following(catchUp: Bool)
        /// Hold the view still and offer Follow output.
        case holding
    }

    /// The view counts as at the bottom within this distance, so a short overscroll or a rounding step does not stop the follow.
    static let bottomSlack: CGFloat = 50

    /// The smallest upward move that counts. Offsets arrive rounded to whole points, so a slow scroll reports steps of exactly one point: each of them is a move, not rounding.
    static let scrollEpsilon: CGFloat = 1

    /// - Parameters:
    ///   - following: whether the view followed before this change.
    ///   - turnActive: whether Minga is working, so growth of the conversation is output.
    static func decide(following: Bool, turnActive: Bool, from old: TranscriptScrollGeometry, to new: TranscriptScrollGeometry) -> Decision {
        if new.distanceFromBottom <= bottomSlack { return .following(catchUp: false) }
        guard following else { return .holding }
        if old.offsetY - new.offsetY >= scrollEpsilon { return .holding }
        if new.visibleHeight < old.visibleHeight { return .following(catchUp: true) }
        guard new.contentHeight > old.contentHeight else { return .following(catchUp: false) }
        let outputArrived = turnActive || new.rowCount > old.rowCount
        return outputArrived ? .following(catchUp: true) : .holding
    }
}
