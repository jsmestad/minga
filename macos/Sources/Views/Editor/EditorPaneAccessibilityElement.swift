import AppKit
import os

/// Virtual AppKit text area for one visible editor pane.
final class EditorPaneAccessibilityElement: NSAccessibilityElement {
    private struct Snapshot: Sendable {
        var projection: EditorAccessibilityProjection?
        var paneScreenFrame: CGRect
        var nativeKeyboardFocus: Bool
    }

    private final class OwnerReference: @unchecked Sendable {
        weak var owner: EditorNSView?

        init(owner: EditorNSView) {
            self.owner = owner
        }
    }

    private let ownerReference: OwnerReference
    private let snapshot: OSAllocatedUnfairLock<Snapshot>
    let identity: EditorAccessibilityIdentity

    @MainActor
    init(owner: EditorNSView, projection: EditorAccessibilityProjection) {
        ownerReference = OwnerReference(owner: owner)
        identity = projection.identity
        snapshot = OSAllocatedUnfairLock(initialState: Snapshot(
            projection: projection,
            paneScreenFrame: owner.accessibilityScreenRect(for: projection.frameInView),
            nativeKeyboardFocus: owner.accessibilityHasNativeKeyboardFocus
        ))
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityRole(.textArea)
        setAccessibilityRoleDescription("code editor pane")
        setAccessibilityIdentifier("minga.editor.\(identity.connectionID).\(identity.windowID).\(identity.generation)")
    }

    @MainActor
    func update(projection: EditorAccessibilityProjection, owner: EditorNSView) {
        let screenFrame = owner.accessibilityScreenRect(for: projection.frameInView)
        let nativeFocus = owner.accessibilityHasNativeKeyboardFocus
        snapshot.withLock {
            $0.projection = projection
            $0.paneScreenFrame = screenFrame
            $0.nativeKeyboardFocus = nativeFocus
        }
    }

    @MainActor
    func updateNativeKeyboardFocus(_ focused: Bool) {
        snapshot.withLock { $0.nativeKeyboardFocus = focused }
    }

    @MainActor
    func invalidate() {
        snapshot.withLock { $0.projection = nil }
    }

    override func accessibilityLabel() -> String? {
        currentProjection()?.label
    }

    override func accessibilityValue() -> Any? {
        currentProjection()?.value
    }

    override func accessibilityFrame() -> NSRect {
        guard let projection = currentProjection() else { return .zero }
        return screenRect(for: projection.frameInView)
    }

    override func accessibilityNumberOfCharacters() -> Int {
        currentProjection()?.value.utf16.count ?? 0
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    override func accessibilitySelectedText() -> String? {
        currentProjection()?.selectedText
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        guard let projection = currentProjection() else { return NSRange(location: NSNotFound, length: 0) }
        if let selected = projection.selectedRanges.first { return selected }
        if !projection.hasSelection, let insertion = projection.insertionRange { return insertion }
        return NSRange(location: NSNotFound, length: 0)
    }

    override func accessibilitySelectedTextRanges() -> [NSValue]? {
        guard let projection = currentProjection() else { return [] }
        if !projection.selectedRanges.isEmpty { return projection.selectedRanges.map(NSValue.init(range:)) }
        if !projection.hasSelection, let insertion = projection.insertionRange { return [NSValue(range: insertion)] }
        return []
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        currentProjection()?.insertionPointLineNumber ?? NSNotFound
    }

    override func accessibilityLine(for index: Int) -> Int {
        guard let projection = currentProjection() else { return NSNotFound }
        return projection.rows.firstIndex { NSLocationInRange(index, $0.valueRange) || index == NSMaxRange($0.valueRange) } ?? NSNotFound
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard let projection = currentProjection(), projection.rows.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        return projection.rows[line].valueRange
    }

    override func accessibilityString(for range: NSRange) -> String? {
        guard let projection = currentProjection(), range.location != NSNotFound, NSMaxRange(range) <= projection.value.utf16.count else { return nil }
        return (projection.value as NSString).substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map(NSAttributedString.init(string:))
    }

    override func accessibilityRange(for index: Int) -> NSRange {
        guard let projection = currentProjection(), index >= 0, index < projection.value.utf16.count else { return NSRange(location: NSNotFound, length: 0) }
        return (projection.value as NSString).rangeOfComposedCharacterSequence(at: index)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let projection = currentProjection(), let rect = projection.localRect(for: range) else { return .zero }
        return screenRect(for: rect)
    }

    override func accessibilityRange(for position: NSPoint) -> NSRange {
        let localPoint = localPoint(fromScreen: position)
        guard let projection = currentProjection(),
              let row = projection.rows.first(where: { localPoint.y >= $0.localOrigin.y && localPoint.y < $0.localOrigin.y + $0.cellHeight }) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let localColumn = Int(floor((localPoint.x - row.localOrigin.x) / max(row.cellWidth, 1)))
        let sourceColumn = row.sourceDisplayRange.lowerBound + localColumn
        guard sourceColumn >= row.sourceDisplayRange.lowerBound, sourceColumn <= row.sourceDisplayRange.upperBound else {
            return NSRange(location: NSNotFound, length: 0)
        }
        let sourceOffset = row.sourceMap.utf16Offset(at: sourceColumn)
        let location = row.valueRange.location + sourceOffset - row.exposedUTF16Range.lowerBound
        return NSRange(location: location, length: 0)
    }

    override func isAccessibilityFocused() -> Bool {
        snapshot.withLock {
            $0.projection?.isActivePane == true && $0.nativeKeyboardFocus
        }
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        guard accessibilityFocused else { return }
        let ownerReference = ownerReference
        let identity = identity
        Task { @MainActor in
            ownerReference.owner?.requestAccessibilityFocus(for: identity)
        }
    }

    private func currentProjection() -> EditorAccessibilityProjection? {
        snapshot.withLock { $0.projection }
    }

    private func screenRect(for localRect: CGRect) -> CGRect {
        snapshot.withLock { state in
            guard let projection = state.projection else { return .zero }
            let pane = projection.frameInView
            let screen = state.paneScreenFrame
            return CGRect(
                x: screen.minX + localRect.minX - pane.minX,
                y: screen.maxY - (localRect.maxY - pane.minY),
                width: localRect.width,
                height: localRect.height
            )
        }
    }

    private func localPoint(fromScreen screenPoint: CGPoint) -> CGPoint {
        snapshot.withLock { state in
            guard let projection = state.projection else { return .zero }
            return CGPoint(
                x: projection.frameInView.minX + screenPoint.x - state.paneScreenFrame.minX,
                y: projection.frameInView.minY + state.paneScreenFrame.maxY - screenPoint.y
            )
        }
    }
}
