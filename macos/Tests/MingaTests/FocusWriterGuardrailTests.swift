import Foundation
import Testing

@Suite("Focus writer discipline")
struct FocusWriterGuardrailTests {
    @Test("every focus writer has an explicit reason and exact site budget")
    func writerSites() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        // Native fields have no exemptions. Workspace text leases are local
        // presentation, not BEAM surfaces; each declaration and binding is counted.
        let permitted: [(path: String, pattern: String, count: Int, reason: String)] = [
            ("Views/Editor/EditorFocusPolicy.swift", #"\bmakeFirstResponder\s*\("#, 1, "Sole AppKit owner applier"),
            ("Views/Editor/EditorFocusPolicy.swift", #"\binitialFirstResponder\s*="#, 2, "Applier sets and detach clears the initial responder"),
            ("Views/EditorChrome/WorkspaceHeaderView.swift", "@FocusState", 1, "Workspace rename holds a frontend-local text lease"),
            ("Views/EditorChrome/WorkspaceHeaderView.swift", #"\.focused\s*\("#, 1, "Binds the leased workspace rename field"),
            ("Views/EditorChrome/WorkspaceIndicatorView.swift", "@FocusState", 1, "Compact workspace rename holds a frontend-local text lease"),
            ("Views/EditorChrome/WorkspaceIndicatorView.swift", #"\.focused\s*\("#, 1, "Binds the compact leased rename field"),
            ("Views/EditorChrome/WorkspaceIconPicker.swift", "@FocusState", 1, "Native icon popover search holds a frontend-local text lease"),
            ("Views/EditorChrome/WorkspaceIconPicker.swift", #"\.focused\s*\("#, 1, "Binds the leased native popover search"),
            ("Views/Editor/EditorNSView.swift", #"override\s+func\s+becomeFirstResponder\s*\("#, 1, "Refreshes accessibility and cursor presentation"),
            ("Views/Editor/EditorNSView.swift", #"override\s+func\s+resignFirstResponder\s*\("#, 1, "Ends editor IME composition and cursor presentation")
        ]
        let patterns = Set(permitted.map(\.pattern))
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var seen: [String: [String: Int]] = [:]
        for case let file as URL in files where file.pathExtension == "swift" {
            let path = String(file.path.dropFirst(root.path.count + 1))
            let source = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern)
                let count = regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
                if count > 0 {
                    seen[path, default: [:]][pattern] = count
                    let site = permitted.first { $0.path == path && $0.pattern == pattern }
                    #expect(site != nil, "Unpermitted focus writer: \(path) \(pattern)")
                    #expect(count == site?.count, "Focus writer budget changed: \(path) \(pattern)")
                }
            }
        }
        for site in permitted {
            #expect(!site.reason.isEmpty)
            #expect(seen[site.path]?[site.pattern] == site.count, "Stale focus exemption: \(site.path) \(site.reason)")
        }
    }
}
