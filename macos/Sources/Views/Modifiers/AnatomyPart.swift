import AppKit
import SwiftUI

/// Names a view after its part in `docs/design/anatomy.md`, so the storyboard renderer can measure it.
///
/// In the app the modifier changes nothing. While `AnatomyPartRecorder.shared` is set (only in PreviewHost's
/// storyboard mode), the view takes the part name as its accessibility identifier and reports its frame in window
/// points, its text and, for a text part, its first baseline. The storyboard renderer writes those facts next to each
/// macOS render: they are the macOS baseline and what the layout audit measures (#4036).
///
/// Name parts `<surface>.<part>` with the anatomy's words, for example `whichKey.entryKey` or `modeline.segment`.
extension View {
    /// Tags this view as one instance of an anatomy part. Pass `text` for a part that shows text, and the
    /// typography step it is set in, so the recorder can place its baseline.
    public func anatomyPart(_ name: String, text: String? = nil, font: Typography.Step? = nil,
                            monospaced: Bool = false) -> some View {
        modifier(AnatomyPartModifier(name: name, text: text, font: font, monospaced: monospaced))
    }
}

/// One measured instance of an anatomy part, in window points with a top-left origin.
public struct AnatomyPartFrame: Sendable, Equatable {
    public let name: String
    public let frame: CGRect
    public let text: String?
    /// The first text baseline, in window points, when the part shows text in a known step.
    public let baseline: CGFloat?
}

/// Collects part frames while the storyboard renderer draws one window.
@MainActor
public final class AnatomyPartRecorder {
    /// Set by the storyboard renderer before it builds a window; nil in the app, so tagged views record nothing.
    public static var shared: AnatomyPartRecorder?

    private var parts: [UUID: AnatomyPartFrame] = [:]

    public init() {}

    /// Every instance that is on screen now, top to bottom, then leading to trailing, then by name.
    public var frames: [AnatomyPartFrame] {
        parts.values.sorted {
            ($0.frame.minY, $0.frame.minX, $0.name) < ($1.frame.minY, $1.frame.minX, $1.name)
        }
    }

    func record(_ id: UUID, _ frame: AnatomyPartFrame) { parts[id] = frame }

    func forget(_ id: UUID) { parts[id] = nil }
}

private struct AnatomyPartModifier: ViewModifier {
    let name: String
    let text: String?
    let font: Typography.Step?
    let monospaced: Bool
    @State private var id = UUID()

    /// A single-line Text frame starts at the line top, so its first baseline sits one ascender below it.
    private func baseline(in frame: CGRect) -> CGFloat? {
        guard let font else { return nil }
        let face = monospaced
            ? NSFont.monospacedSystemFont(ofSize: font.rawValue, weight: .regular)
            : NSFont.systemFont(ofSize: font.rawValue)
        return frame.minY + face.ascender
    }

    func body(content: Content) -> some View {
        if let recorder = AnatomyPartRecorder.shared {
            content
                .accessibilityIdentifier(name)
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    recorder.record(id, AnatomyPartFrame(name: name, frame: frame, text: text, baseline: baseline(in: frame)))
                }
                .onDisappear { recorder.forget(id) }
        } else {
            content
        }
    }
}
