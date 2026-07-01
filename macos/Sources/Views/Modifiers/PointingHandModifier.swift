import SwiftUI

public struct PointingHandModifier: ViewModifier {
    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
    public var isEnabled: Bool = true
    @State private var isHovered = false
    @State private var didPushCursor = false

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovered = hovering
                syncCursor()
            }
            .onChange(of: isEnabled) { _, _ in
                syncCursor()
            }
            .onDisappear {
                if didPushCursor {
                    NSCursor.pop()
                    didPushCursor = false
                }
            }
    }

    private func syncCursor() {
        let shouldPush = isHovered && isEnabled

        if shouldPush && !didPushCursor {
            NSCursor.pointingHand.push()
            didPushCursor = true
        } else if !shouldPush && didPushCursor {
            NSCursor.pop()
            didPushCursor = false
        }
    }
}

extension View {
    public func pointingHandCursor(isEnabled: Bool = true) -> some View {
        modifier(PointingHandModifier(isEnabled: isEnabled))
    }
}
