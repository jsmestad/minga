import Foundation
import Testing

/// A lexical source guard, not a line regex: nested calls and ternaries stay inside the argument.
@Suite("Chrome token source guardrails")
struct ChromeTokenGuardrailTests {
    private static let allowlist: [(path: String, reason: String)] = []

    @Test("chrome literals use the frontend scales with an empty ratchet")
    func chromeUsesTokens() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = root.appendingPathComponent("Sources/Views")
        let enumerator = try #require(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        var found: [String: [String]] = [:]
        var parameterNames: Set<String> = []
        var sources: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = String(url.path.dropFirst(views.path.count + 1))
            guard Self.isGuarded(path) else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            sources.append((path, source))
            parameterNames.formUnion(ChromeLiteralScanner.metricParameters(in: source))
        }
        for (path, source) in sources {
            let violations = ChromeLiteralScanner.violations(in: source, metricParameters: parameterNames)
            if !violations.isEmpty { found[path] = violations }
        }
        for failure in Self.ratchetFailures(found, allowlist: Self.allowlist) {
            Issue.record(Comment(rawValue: failure))
        }
        #expect(Self.allowlist.isEmpty)
    }

    private static func isGuarded(_ path: String) -> Bool {
        !path.hasPrefix("Editor/") && path != "Shared/ChromeTokens.swift"
    }

    private static func ratchetFailures(
        _ found: [String: [String]], allowlist: [(path: String, reason: String)]
    ) -> [String] {
        var failures: [String] = []
        var allowed: Set<String> = []
        for entry in allowlist {
            if entry.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("\(entry.path): allowlist reason is empty")
            }
            if !allowed.insert(entry.path).inserted { failures.append("\(entry.path): duplicate allowlist entry") }
            if found[entry.path] == nil { failures.append("\(entry.path): stale allowlist entry") }
        }
        for path in found.keys.sorted() where !allowed.contains(path) {
            failures += (found[path] ?? []).map { "\(path):\($0)" }
        }
        return failures
    }

    @Test("balanced arguments reject literals inside arithmetic, ternaries, and wrappers")
    func balancedFixtures() {
        let fixtures = [
            "view.padding(6)",
            "view.padding(.horizontal, pinned ? 0 : 5)",
            "HStack(spacing: pinned ? 8 : 12) {}",
            "view.padding(.leading, CGFloat(depth) * 16)",
            "view.padding(.leading, max(Spacing.xs, CGFloat(depth) * 16))",
            "HStack(spacing: min(Spacing.xs,\n CGFloat(6))) {}",
            "view.font(.system(size: flag ? 10.5 : 11.5, weight: .medium))",
            "view.font(.system(size: CGFloat(max(height, 12))))",
            "RoundedRectangle(cornerRadius: flag ? 0 : 3)",
            "view.cornerRadius(max(0, CGFloat(8)))",
            "let rowPadding: CGFloat = 6",
            "var contentInset: CGFloat = CGFloat(5)",
            "let localSpacing = 8",
            "let rowPadding: CGFloat = compact ? 5 : 10",
            "let rowPadding: CGFloat = max(\n6,\n8\n)",
            "let rowPadding: CGFloat = max(Spacing.sm,\ncompact ? 5 : 10\n)",
            "let rowPadding: CGFloat = height / 2 + 6",
            "func row(leadingPadding: CGFloat = 6) {}",
            "row(leadingPadding: max(Spacing.xs, CGFloat(10)))",
            "row(leadingPadding: -2)",
            "view.padding(0.0)",
            "view.padding(0x10)",
            "view.padding(1e-2)",
            "view.padding(1_000)",
            "view.padding(0 + 5)",
        ]
        for source in fixtures {
            #expect(!ChromeLiteralScanner.violations(in: source, metricParameters: ["leadingPadding"]).isEmpty,
                    Comment(rawValue: source))
        }
    }

    @Test("zero, named values, geometry, strings, comments, and unguarded frames remain legal")
    func legalFixtures() {
        let fixtures = [
            "HStack(spacing: 0) {}",
            "view.padding(0)",
            "view.padding(.leading, CGFloat(depth) * Spacing.xl)",
            "view.padding(.bottom, availableHeight - contentHeight)",
            "view.font(Typography.monospacedSmall)",
            "view.font(Typography.relative(to: editorFontSize, scale: 0.9))",
            "view.frame(width: 24, height: 48)",
            "RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)",
            "view.padding(/* nested /* 6 */ comment */ Spacing.md)",
            "// view.padding(6)\nview.padding(Spacing.sm)",
            "let label = #\"view.padding(6)\"#",
            "let label = \"\"\"\nHStack(spacing: 8)\n\"\"\"",
            "let sidebarWidth: CGFloat = 240",
            "row(leadingPadding: Spacing.lg)",
            "let spacing = count > 1 ? width / CGFloat(count - 1) : width / 2",
            "let spacing: CGFloat =\n count > 1\n ? width / CGFloat(count - 1)\n : width / 2",
            "let rowPadding: CGFloat = width * 0.55",
        ]
        for source in fixtures {
            #expect(ChromeLiteralScanner.violations(in: source, metricParameters: ["leadingPadding"]).isEmpty,
                    Comment(rawValue: source))
        }
        #expect(!Self.isGuarded("Editor/EditorScrollTrack.swift"))
        #expect(Self.isGuarded("EditorChrome/TabBarView.swift"))
        #expect(ChromeLiteralScanner.metricParameters(in: "func row(leadingPadding: CGFloat) {}").contains("leadingPadding"))
    }

    @Test("metric parameters preserve distinct external and internal names")
    func externallyLabeledMetricParameters() {
        let declarations = """
        func row(leadingPadding value: CGFloat) {}
        func badge(value contentInset: CGFloat) {}
        """
        let labels = ChromeLiteralScanner.metricParameters(in: declarations)
        #expect(labels.contains("leadingPadding"))
        #expect(labels.contains("value"))
        for call in ["row(leadingPadding: 6)", "badge(value: max(Spacing.sm, 8))"] {
            #expect(!ChromeLiteralScanner.violations(in: declarations + "\n" + call, metricParameters: labels).isEmpty)
        }
        #expect(ChromeLiteralScanner.violations(
            in: declarations + "\nrow(leadingPadding: Spacing.sm)", metricParameters: labels
        ).isEmpty)
    }

    @Test("allowlist entries cannot hide clean files or omit their reasons")
    func ratchetFixtures() {
        #expect(Self.ratchetFailures([:], allowlist: [("Clean.swift", "pending migration")]).count == 1)
        #expect(Self.ratchetFailures(["Row.swift": ["1: literal 6"]], allowlist: [("Row.swift", "")]).count == 1)
        #expect(Self.ratchetFailures(["Row.swift": ["1: literal 6"]], allowlist: []).count == 1)
    }
}

private enum ChromeLiteralScanner {
    private struct Token {
        let text: String
        let line: Int
        let number: Bool
    }
    private static let closers = ["(": ")", "[": "]", "{": "}"]


    static func metricParameters(in source: String) -> Set<String> {
        let tokens = lex(source)
        var labels: Set<String> = []
        for index in tokens.indices {
            guard index + 2 < tokens.count,
                  tokens[index + 1].text == ":", tokens[index + 2].text == "CGFloat" else { continue }
            let internalName = tokens[index].text
            var externalName = internalName
            if index > 0, isIdentifier(tokens[index - 1].text),
               !["let", "var"].contains(tokens[index - 1].text) {
                externalName = tokens[index - 1].text
            }
            if externalName != "_", isMetric(internalName) || isMetric(externalName) {
                labels.insert(externalName)
            }
        }
        return labels
    }

    static func violations(in source: String, metricParameters: Set<String> = []) -> [String] {
        let tokens = lex(source)
        var guarded: Set<Int> = []
        for index in tokens.indices {
            let text = tokens[index].text
            if index + 1 < tokens.count, tokens[index + 1].text == "(",
               (text == "padding" || text == "cornerRadius"),
               index > 0, tokens[index - 1].text == "." {
                guarded.formUnion(argument(in: tokens, starting: index + 2, wholeCall: true))
            }
            if index + 1 < tokens.count, tokens[index + 1].text == ":",
               text == "spacing" || text == "cornerRadius" || metricParameters.contains(text) {
                // A declaration is not a labeled call argument. Its initializer is handled below.
                if index + 2 < tokens.count, tokens[index + 2].text != "CGFloat" {
                    guarded.formUnion(argument(in: tokens, starting: index + 2, wholeCall: false))
                } else if index + 3 < tokens.count, tokens[index + 3].text == "=",
                          index > 0, tokens[index - 1].text != "let", tokens[index - 1].text != "var" {
                    guarded.formUnion(argument(in: tokens, starting: index + 4, wholeCall: false))
                }
            }
            if text == "system", index + 1 < tokens.count, tokens[index + 1].text == "(" {
                let arguments = argument(in: tokens, starting: index + 2, wholeCall: true)
                if arguments.contains(where: { tokens[$0].text == "size" }) { guarded.formUnion(arguments) }
            }
            if text == "let" || text == "var", index + 1 < tokens.count, isMetric(tokens[index + 1].text) {
                var cursor = index + 2
                while cursor < tokens.count,
                      !["=", "{", "}", ";", "let", "var", "func"].contains(tokens[cursor].text) { cursor += 1 }
                if cursor < tokens.count, tokens[cursor].text == "=" {
                    let range = initializer(in: tokens, starting: cursor + 1)
                    guarded.formUnion(pointLiterals(in: tokens, range: range))
                }
            }
        }
        return guarded.sorted().compactMap { index in
            let token = tokens[index]
            guard token.number, token.text != "0" else { return nil }
            return "\(token.line): literal \(token.text); use Spacing, Typography, or Radius"
        }
    }

    private static func isMetric(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["padding", "spacing", "inset", "radius"].contains(where: lower.contains)
    }
    private static func isIdentifier(_ text: String) -> Bool {
        text.first?.isLetter == true || text.first == "_"
    }

    /// A declaration ends at an unbalanced delimiter or a new statement, not an inner newline.
    private static func initializer(in tokens: [Token], starting start: Int) -> Range<Int> {
        var stack: [String] = []
        var cursor = start
        let continuation: Set<String> = [".", "?", ":", "+", "-", "*", "/", "%", "&", "|", "^", "=", "<", ">", "!"]
        while cursor < tokens.count {
            let text = tokens[cursor].text
            if stack.isEmpty {
                if [",", ";", "}"].contains(text) { break }
                if cursor > start, tokens[cursor].line > tokens[cursor - 1].line,
                   !continuation.contains(tokens[cursor - 1].text),
                   !continuation.contains(text), text != "(" { break }
            }
            if let closer = closers[text] {
                stack.append(closer)
            } else if stack.last == text {
                stack.removeLast()
            }
            cursor += 1
        }
        return start..<cursor
    }

    /// Counts and ratios are scalar geometry. Ternary result branches and wrapper arguments
    /// remain point-valued, including when their literals follow an identifier or a newline.
    private static func pointLiterals(in tokens: [Token], range: Range<Int>) -> Set<Int> {
        var result: Set<Int> = []
        var start = range.lowerBound
        var cursor = start
        while cursor < range.upperBound {
            let text = tokens[cursor].text
            if closers[text] != nil {
                cursor = balancedEnd(in: tokens, starting: cursor, limit: range.upperBound)
            } else if text == "," {
                result.formUnion(pointLiterals(in: tokens, range: start..<cursor))
                start = cursor + 1
                cursor += 1
            } else {
                cursor += 1
            }
        }
        if start != range.lowerBound {
            result.formUnion(pointLiterals(in: tokens, range: start..<range.upperBound))
            return result
        }
        cursor = start
        while cursor < range.upperBound {
            let text = tokens[cursor].text
            if closers[text] != nil {
                cursor = balancedEnd(in: tokens, starting: cursor, limit: range.upperBound)
            } else if text == "?" {
                let question = cursor
                var depth = 1
                cursor += 1
                while cursor < range.upperBound {
                    if closers[tokens[cursor].text] != nil {
                        cursor = balancedEnd(in: tokens, starting: cursor, limit: range.upperBound)
                        continue
                    }
                    if tokens[cursor].text == "?" { depth += 1 }
                    if tokens[cursor].text == ":" {
                        depth -= 1
                        if depth == 0 {
                            result.formUnion(pointLiterals(in: tokens, range: (question + 1)..<cursor))
                            result.formUnion(pointLiterals(in: tokens, range: (cursor + 1)..<range.upperBound))
                            return result
                        }
                    }
                    cursor += 1
                }
            } else {
                cursor += 1
            }
        }
        cursor = start
        while cursor < range.upperBound {
            let text = tokens[cursor].text
            if text == "/" {
                cursor = scalarOperandEnd(in: tokens, starting: cursor + 1, limit: range.upperBound)
            } else if closers[text] != nil {
                let end = balancedEnd(in: tokens, starting: cursor, limit: range.upperBound)
                result.formUnion(pointLiterals(in: tokens, range: (cursor + 1)..<max(cursor + 1, end - 1)))
                cursor = end
            } else {
                if tokens[cursor].number {
                    let value = Double(text.replacingOccurrences(of: "_", with: ""))
                    let multiplier = (cursor > start && tokens[cursor - 1].text == "*") ||
                        (cursor + 1 < range.upperBound && tokens[cursor + 1].text == "*")
                    if !(multiplier && value.map { $0 > 0 && $0 < 1 } == true) { result.insert(cursor) }
                }
                cursor += 1
            }
        }
        return result
    }

    private static func balancedEnd(in tokens: [Token], starting start: Int, limit: Int) -> Int {
        var stack: [String] = []
        var cursor = start
        while cursor < limit {
            let text = tokens[cursor].text
            if let closer = closers[text] { stack.append(closer) }
            else if stack.last == text {
                stack.removeLast()
                if stack.isEmpty { return cursor + 1 }
            }
            cursor += 1
        }
        return cursor
    }

    private static func scalarOperandEnd(in tokens: [Token], starting start: Int, limit: Int) -> Int {
        var cursor = start
        while cursor < limit, ["+", "-", "!"].contains(tokens[cursor].text) { cursor += 1 }
        if cursor < limit, closers[tokens[cursor].text] != nil {
            return balancedEnd(in: tokens, starting: cursor, limit: limit)
        }
        cursor = min(cursor + 1, limit)
        while cursor < limit {
            if tokens[cursor].text == ".", cursor + 1 < limit { cursor += 2 }
            else if tokens[cursor].text == "(" {
                cursor = balancedEnd(in: tokens, starting: cursor, limit: limit)
            } else { break }
        }
        return cursor
    }


    /// Walks a full balanced call, or one balanced labeled expression, without stopping at inner commas.
    private static func argument(in tokens: [Token], starting start: Int, wholeCall: Bool) -> Range<Int> {
        var stack: [String] = []
        var cursor = start
        while cursor < tokens.count {
            let text = tokens[cursor].text
            if stack.isEmpty && (text == ")" || (!wholeCall && text == ",")) { break }
            if let closer = closers[text] {
                stack.append(closer)
            } else if stack.last == text {
                stack.removeLast()
            }
            cursor += 1
        }
        return start..<cursor
    }

    /// Drops nested comments and Swift strings (ordinary, raw, and multiline), retaining source lines.
    private static func lex(_ source: String) -> [Token] {
        let chars = Array(source)
        var tokens: [Token] = []
        var index = 0
        var line = 1
        func at(_ offset: Int) -> Character? { offset < chars.count ? chars[offset] : nil }
        while index < chars.count {
            let char = chars[index]
            if char.isWhitespace {
                if char == "\n" { line += 1 }
                index += 1
                continue
            }
            if char == "/", at(index + 1) == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "/", at(index + 1) == "*" {
                var depth = 1
                index += 2
                while index < chars.count, depth > 0 {
                    if chars[index] == "\n" { line += 1 }
                    if chars[index] == "/", at(index + 1) == "*" { depth += 1; index += 2 }
                    else if chars[index] == "*", at(index + 1) == "/" { depth -= 1; index += 2 }
                    else { index += 1 }
                }
                continue
            }
            var quote = index
            while at(quote) == "#" { quote += 1 }
            if at(quote) == "\"" {
                let hashes = quote - index
                let multiline = at(quote + 1) == "\"" && at(quote + 2) == "\""
                let quoteCount = multiline ? 3 : 1
                index = quote + quoteCount
                while index < chars.count {
                    if chars[index] == "\n" { line += 1 }
                    if chars[index] == "\\", hashes == 0 {
                        index += 1
                        if at(index) == "\n" { line += 1 }
                        index = min(index + 1, chars.count)
                        continue
                    }
                    let end = index + quoteCount + hashes
                    if end <= chars.count,
                       chars[index..<(index + quoteCount)].allSatisfy({ $0 == "\"" }),
                       chars[(index + quoteCount)..<end].allSatisfy({ $0 == "#" }) {
                        index = end
                        break
                    }
                    index += 1
                }
                continue
            }
            let start = index
            let tokenLine = line
            if char.isNumber {
                index += 1
                while index < chars.count {
                    let current = chars[index]
                    if current.isLetter || current.isNumber || current == "_" { index += 1 }
                    else if current == ".", at(index + 1)?.isNumber == true { index += 1 }
                    else if (current == "+" || current == "-"),
                            "eEpP".contains(chars[index - 1]) { index += 1 }
                    else { break }
                }
                tokens.append(Token(text: String(chars[start..<index]), line: tokenLine, number: true))
            } else if char.isLetter || char == "_" || char == "$" {
                index += 1
                while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
                    index += 1
                }
                tokens.append(Token(text: String(chars[start..<index]), line: tokenLine, number: false))
            } else {
                tokens.append(Token(text: String(char), line: tokenLine, number: false))
                index += 1
            }
        }
        return tokens
    }
}
