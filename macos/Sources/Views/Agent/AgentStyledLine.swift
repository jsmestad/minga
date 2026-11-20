import SwiftUI
import MingaProtocol

/// One line of styled runs from the transcript, shared by assistant replies,
/// Markdown blocks, and tool call results.
struct AgentStyledLine: View {
    let runs: [Wire.StyledTextRun]
    let baseFontSize: CGFloat
    let monospaced: Bool
    var allowHorizontalScroll: Bool = true

    @Environment(\.themeColors) private var theme

    var body: some View {
        if runs.isEmpty || (runs.count == 1 && runs[0].text.isEmpty) {
            Text(" ")
                .font(Typography.relative(to: baseFontSize, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.clear)
        } else if allowHorizontalScroll && shouldScrollHorizontally {
            ScrollView(.horizontal) {
                Text(buildAttributedString(runs, baseFontSize: baseFontSize, monospaced: monospaced))
                    .font(Typography.relative(to: baseFontSize, design: monospaced ? .monospaced : .default))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else {
            Text(buildAttributedString(runs, baseFontSize: baseFontSize, monospaced: monospaced))
                .font(Typography.relative(to: baseFontSize, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
        }
    }

    private func buildAttributedString(_ runs: [Wire.StyledTextRun], baseFontSize: CGFloat = 13, monospaced: Bool = false) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var attr = AttributedString(run.text)
            let fg = Color(
                red: Double(run.fgR) / 255.0,
                green: Double(run.fgG) / 255.0,
                blue: Double(run.fgB) / 255.0
            )
            // Only apply foreground if not all zeros (default/unstyled)
            if run.fgR != 0 || run.fgG != 0 || run.fgB != 0 {
                attr.foregroundColor = fg
            } else {
                attr.foregroundColor = theme.agentTextFg
            }
            // Apply background if non-zero
            if run.bgR != 0 || run.bgG != 0 || run.bgB != 0 {
                attr.backgroundColor = Color(
                    red: Double(run.bgR) / 255.0,
                    green: Double(run.bgG) / 255.0,
                    blue: Double(run.bgB) / 255.0
                )
            }
            let runMonospaced = monospaced || run.code
            let design: Font.Design = runMonospaced ? .monospaced : .default
            if run.bold && run.italic {
                attr.font = Typography.relative(to: baseFontSize, weight: .bold, design: design).italic()
            } else if run.bold {
                attr.font = Typography.relative(to: baseFontSize, weight: .bold, design: design)
            } else if run.italic {
                attr.font = Typography.relative(to: baseFontSize, design: design).italic()
            } else if runMonospaced {
                attr.font = Typography.relative(to: baseFontSize, design: .monospaced)
            }
            if run.underline {
                attr.underlineStyle = .single
            }
            if let url = safeLinkURL(run.linkURL) {
                attr.link = url
            }
            result += attr
        }
        return result
    }

    private var shouldScrollHorizontally: Bool {
        let textRuns = runs.filter { !$0.text.isEmpty }
        return !textRuns.isEmpty && textRuns.allSatisfy(\.code)
    }

    private func safeLinkURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        case "mailto":
            guard !url.path.isEmpty else { return nil }
            return url
        default:
            return nil
        }
    }
}
