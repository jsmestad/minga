import AppKit
import SwiftUI
import MingaUI

extension AgentPromptSurface {
    /// Uses the existing editor, never another renderer or input client.
    @MainActor
    init(editor: EditorNSView) {
        self.init { [weak editor] maximumHeight in
            AnyView(AgentPromptAperture(editor: editor, maximumHeight: maximumHeight))
        }
    }
}

/// A transparent placement and hit-test bridge injected at the app composition boundary.
private struct AgentPromptAperture: NSViewRepresentable {
    weak var editor: EditorNSView?
    let maximumHeight: CGFloat

    func makeNSView(context: Context) -> AgentPromptApertureNSView {
        AgentPromptApertureNSView(editor: editor, maximumHeight: maximumHeight)
    }

    func updateNSView(_ view: AgentPromptApertureNSView, context: Context) {
        view.editor = editor
        view.maximumHeight = maximumHeight
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: AgentPromptApertureNSView, coordinator: ()) {
        view.editor?.setAgentPromptPlacement(nil, owner: ObjectIdentifier(view))
    }
}

/// Returns the continuously mounted editor for pointer delivery, including AppKit's drag capture.
final class AgentPromptApertureNSView: NSView {
    weak var editor: EditorNSView?
    var maximumHeight: CGFloat

    init(editor: EditorNSView?, maximumHeight: CGFloat) {
        self.editor = editor
        self.maximumHeight = maximumHeight
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        publishPlacement()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        publishPlacement()
    }

    private func publishPlacement() {
        guard let editor, let window, editor.window === window,
              bounds.width > 0, bounds.height > 0, maximumHeight > 0 else { return }
        editor.setAgentPromptPlacement(
            AgentPromptPlacement(rect: convert(bounds, to: editor), maximumHeight: maximumHeight),
            owner: ObjectIdentifier(self)
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let editor, editor.window === window,
              bounds.contains(convert(point, from: superview)) else { return nil }
        return editor
    }
}
