import Foundation
import Testing

@Suite("GUI Observation source guardrails")
struct GUIObservationGuardrailTests {
    private struct ProductionSource {
        let path: String
        let contents: String
        let sanitized: String
    }

    private static let bannedTerms: Set<String> = [
        "GUIFrameVersion",
        "GUIFrameVersions",
        "GUIFrameChannel",
        "GUIFrameStore",
        "guiFrameVersion",
        "frameStore",
        "publishLocalIfChanged",
        "ObservableObject",
        "objectWillChange",
        "ObservationRegistrar",
    ]

    /// Every production `@Observable` type is classified here.
    private static let observationTypeAllowlist: [String: String] = [
        "Sources/AppState.swift#AppState": "application-owned observable state",
        "Sources/Extensions/FrontendExtensionRuntime.swift#FrontendExtensionRuntimeRegistry": "extension registry observable state",
        "Sources/Views/Agent/AgentChatState.swift#AgentChatState": "protocol presentation owner",
        "Sources/Views/Agent/AgentContextBarState.swift#AgentContextBarState": "protocol presentation owner",
        "Sources/Views/EditorChrome/BottomPanelState.swift#BottomPanelState": "protocol presentation owner",
        "Sources/Views/EditorChrome/BreadcrumbBar.swift#BreadcrumbState": "protocol presentation owner",
        "Sources/Views/EditorChrome/EmptyStateState.swift#EmptyStateState": "protocol presentation owner",
        "Sources/Views/EditorChrome/FeedbackState.swift#FeedbackState": "protocol presentation owner",
        "Sources/Views/EditorChrome/SearchState.swift#SearchState": "protocol presentation owner",
        "Sources/Views/EditorChrome/StatusBarState.swift#StatusBarState": "protocol presentation owner",
        "Sources/Views/EditorChrome/TabBarState.swift#TabBarState": "protocol presentation owner",
        "Sources/Views/EditorChrome/WorkspaceState.swift#WorkspaceState": "protocol presentation owner",
        "Sources/Views/Extensions/ExtensionOverlayState.swift#ExtensionOverlayState": "protocol presentation owner",
        "Sources/Views/Extensions/ExtensionPanelState.swift#ExtensionPanelState": "protocol presentation owner",
        "Sources/Views/Overlays/CompletionState.swift#CompletionState": "protocol presentation owner",
        "Sources/Views/Overlays/FloatPopupState.swift#FloatPopupState": "protocol presentation owner",
        "Sources/Views/Overlays/HoverPopupState.swift#HoverPopupState": "protocol presentation owner",
        "Sources/Views/Overlays/LatencyHUDState.swift#LatencyHUDState": "local diagnostics observable state",
        "Sources/Views/Overlays/MessagesContentState.swift#MessagesContentState": "protocol presentation owner",
        "Sources/Views/Overlays/MinibufferState.swift#MinibufferState": "protocol presentation owner",
        "Sources/Views/Overlays/NotificationCenterState.swift#NotificationCenterState": "protocol presentation owner",
        "Sources/Views/Overlays/PickerState.swift#PickerState": "protocol presentation owner",
        "Sources/Views/Overlays/ProtocolErrorState.swift#ProtocolErrorState": "protocol presentation owner",
        "Sources/Views/Overlays/ResyncState.swift#ResyncState": "protocol presentation owner",
        "Sources/Views/Overlays/SignatureHelpState.swift#SignatureHelpState": "protocol presentation owner",
        "Sources/Views/Overlays/WhichKeyState.swift#WhichKeyState": "protocol presentation owner",
        "Sources/Views/Settings/SettingsState.swift#SettingsState": "settings observable state",
        "Sources/Views/Shared/EditTimelineState.swift#EditTimelineState": "protocol presentation owner",
        "Sources/Views/Shared/GUIFramePresentationMetrics.swift#GUIFramePresentationMetrics": "observable native correlation tickets",
        "Sources/Views/Shared/GUIState.swift#GUIThemeBacking": "observable theme backing",
        "Sources/Views/Shared/GUIState.swift#GUIWindowContentBacking": "observable resident-window backing",
        "Sources/Views/Shared/GUIState.swift#GUIState": "aggregate observable state",
        "Sources/Views/Shared/ThemeColors.swift#ThemeColors": "observable theme slots",
        "Sources/Views/Sidebar/ChangeSummaryState.swift#ChangeSummaryState": "protocol presentation owner",
        "Sources/Views/Sidebar/FileTreeState.swift#FileTreeState": "protocol presentation owner",
        "Sources/Views/Sidebar/GitStatusState.swift#GitStatusState": "protocol presentation owner",
        "Sources/Views/Sidebar/ObservatoryState.swift#ObservatoryState": "protocol presentation owner",
        "Sources/Views/Sidebar/SidebarHostState.swift#SidebarHostState": "protocol presentation owner",
    ]

    /// Path-qualified declarations make both a new ignored owner and a new ignored rendered field fail.
    private static let ignoredDeclarationAllowlist: [String: String] = [
        "Sources/Extensions/FrontendExtensionRuntime.swift: @ObservationIgnored private var decoders: [String: Decoder] = [:]": "decoder registry storage, not rendered state",
        "Sources/Extensions/FrontendExtensionRuntime.swift: @ObservationIgnored private var viewBuilders: [String: ViewBuilder] = [:]": "view-builder registry storage, not rendered state",
        "Sources/Views/Agent/AgentChatState.swift: @ObservationIgnored private var hasTranscript: Bool = false": "protocol readiness cache, not rendered state",
        "Sources/Views/EditorChrome/FeedbackState.swift: @ObservationIgnored private var holdTask: Task<Void, Never>?": "task lifecycle handle, not rendered state",
        "Sources/Views/EditorChrome/FeedbackState.swift: @ObservationIgnored private var lastMessage = \"\"": "feedback timing cache; rendered fields remain observed",
        "Sources/Views/EditorChrome/FeedbackState.swift: @ObservationIgnored private var showTask: Task<Void, Never>?": "task lifecycle handle, not rendered state",
        "Sources/Views/EditorChrome/FeedbackState.swift: @ObservationIgnored private var spinnerOnTime: ContinuousClock.Instant?": "timing bookkeeping, not rendered state",
        "Sources/Views/Shared/GUIFramePresentationMetrics.swift: @ObservationIgnored private let log = OSLog(subsystem: \"com.minga.editor\", category: \"GUIFramePresentation\")": "telemetry logging handle, not rendered state",
        "Sources/Views/Shared/GUIFramePresentationMetrics.swift: @ObservationIgnored private var samples: [Sample] = []": "debug telemetry sample buffer, not rendered state",
        "Sources/Views/Shared/GUIState.swift: @ObservationIgnored private let themeBacking = GUIThemeBacking()": "stable dependency reference; backing fields are observed",
        "Sources/Views/Shared/GUIState.swift: @ObservationIgnored private let windowContentBacking: GUIWindowContentBacking": "stable dependency reference; backing fields are observed",
        "Sources/Views/Shared/GUIState.swift: @ObservationIgnored public lazy private(set) var editorInput = EditorHostInput(": "stable host dependency bundle, not rendered state",
        "Sources/Views/Shared/GUIState.swift: @ObservationIgnored public lazy private(set) var editorOverlayInput = EditorOverlayHostInput(": "stable host dependency bundle, not rendered state",
        "Sources/Views/Shared/GUIState.swift: @ObservationIgnored public lazy private(set) var shellInput = ShellHostInput(": "stable host dependency bundle, not rendered state",
        "Sources/Views/Shared/GUIState.swift: @ObservationIgnored public lazy private(set) var windowOverlayInput = WindowOverlayHostInput(": "stable host dependency bundle, not rendered state",
        "Sources/Views/Sidebar/SidebarHostState.swift: @ObservationIgnored private var warnedUnknownKinds: Set<String> = []": "diagnostic de-duplication cache, not rendered state",
    ]

    @Test("production Swift stays free of synthetic invalidation")
    func productionSwiftRejectsSyntheticInvalidation() throws {
        var violations: [String] = []

        for source in try productionSources() {
            let identifiers = Set(identifierTokens(in: source.sanitized))
            for term in Self.bannedTerms.intersection(identifiers).sorted() {
                violations.append("\(source.path): banned identifier `\(term)`")
            }
            for read in try discardedCorrelationReads(in: source.sanitized) {
                violations.append("\(source.path): invalidation-only discarded read `\(read)`")
            }
            for call in try revisionDrivenIdentityCalls(in: source.sanitized, original: source.contents) {
                violations.append("\(source.path): revision/frame-token identity `\(call)`")
            }
        }

        record(violations)
    }

    @Test("every production Observation type and ignored declaration is classified")
    func globalObservationInventoryIsExact() throws {
        let sources = try productionSources()
        let actualObservable = try Set(sources.flatMap(observableDeclarations(in:)))
        #expect(actualObservable == Set(Self.observationTypeAllowlist.keys))
        #expect(Self.observationTypeAllowlist.count == 38)

        let actualIgnored = occurrenceCounts(sources.flatMap(ignoredDeclarations(in:)))
        let expectedIgnored = Dictionary(uniqueKeysWithValues: Self.ignoredDeclarationAllowlist.keys.map { ($0, 1) })
        #expect(actualIgnored == expectedIgnored)

        let attributeFixture = ProductionSource(
            path: "Fixture.swift",
            contents: "@Observable @MainActor final class InlineOwner {}\n@Observable\n@MainActor\nfinal class StackedOwner {}",
            sanitized: "@Observable @MainActor final class InlineOwner {}\n@Observable\n@MainActor\nfinal class StackedOwner {}"
        )
        #expect(try observableDeclarations(in: attributeFixture) == [
            "Fixture.swift#InlineOwner", "Fixture.swift#StackedOwner"
        ])

        let duplicateIgnored = ProductionSource(
            path: "Fixture.swift",
            contents: "@ObservationIgnored private var cache = 0\n@ObservationIgnored private var cache = 0",
            sanitized: "@ObservationIgnored private var cache = 0\n@ObservationIgnored private var cache = 0"
        )
        #expect(occurrenceCounts(ignoredDeclarations(in: duplicateIgnored)).values.first == 2)
    }

    @Test("committed correlation types and accessors stay inside owned boundaries")
    func committedCorrelationBoundaries() throws {
        let allowedPaths: [String: Set<String>] = [
            "GUICommittedFrame": [
                "Sources/Views/Shared/GUIFrameCorrelation.swift",
                "Sources/Views/Shared/GUIFramePresentationMetrics.swift",
                "Sources/Renderer/CommandDispatcher.swift",
                "Sources/Renderer/CoreTextMetalRenderer.swift",
                "Sources/Views/Editor/EditorNSView.swift",
            ],
            "GUIFrameImpact": [
                "Sources/Views/Shared/GUIFrameCorrelation.swift",
                "Sources/Views/Shared/GUIFramePresentationMetrics.swift",
                "Sources/Renderer/CommandDispatcher.swift",
                "Sources/Renderer/PreparedFrameTransaction.swift",
            ],
            "pendingFrame": [
                "Sources/Views/Shared/GUIFramePresentationMetrics.swift",
            ],
            "pendingEditorFrame": [
                "Sources/Views/Shared/GUIFramePresentationMetrics.swift",
                "Sources/Renderer/CommandDispatcher.swift",
            ],
            "pendingPresentationFrame": [
                "Sources/Renderer/CommandDispatcher.swift",
                "Sources/Views/Editor/EditorNSView.swift",
            ],
            "presentationFrame": [
                "Sources/Views/Shared/GUIFramePresentationMetrics.swift",
                "Sources/Renderer/CoreTextMetalRenderer.swift",
                "Sources/Views/Editor/EditorNSView.swift",
            ],
        ]
        var violations: [String] = []

        let sources = try productionSources()
        for source in sources {
            let identifiers = Set(identifierTokens(in: source.sanitized))
            for term in allowedPaths.keys.sorted()
            where identifiers.contains(term) && !allowedPaths[term, default: []].contains(source.path) {
                violations.append("\(source.path): `\(term)` is outside its correlation boundary")
            }
        }

        let exactAccessorOccurrences: [String: [String: Int]] = [
            "pendingFrame": ["Sources/Views/Shared/GUIFramePresentationMetrics.swift": 2],
            "pendingEditorFrame": [
                "Sources/Views/Shared/GUIFramePresentationMetrics.swift": 1,
                "Sources/Renderer/CommandDispatcher.swift": 1,
            ],
            "pendingPresentationFrame": [
                "Sources/Renderer/CommandDispatcher.swift": 1,
                "Sources/Views/Editor/EditorNSView.swift": 1,
            ],
        ]
        for (accessor, expected) in exactAccessorOccurrences {
            let actual = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
                let count = identifierTokens(in: source.sanitized).count { $0 == accessor }
                return count == 0 ? nil : (source.path, count)
            })
            if actual != expected {
                violations.append("`\(accessor)` occurrences changed: \(actual)")
            }
        }

        record(violations)
    }

    @Test("stable semantic identity remains allowed while formatting cannot bypass the policy")
    func stableIdentityAllowances() throws {
        let allowed = ##"""
        // view.id(frameID)
        /* view.id(frameSequence); ObservableObject */
        let ordinary = "view.id(frameSequence)"
        let raw = #"view.id(currentGeneration)"#
        let multiline = """
        view.id(renderGeneration)
        """
        let rawMultiline = #"""
        view.id(frameToken)
        """#
        rows.id(item.id)
        rows.id(entry.id)
        rows.id(index)
        rows.id("bottom-anchor")
        rows.id(item.generation)
        rows.id(model.generation)
        let MyObservableObjectFactory = 1
        """##
        let sanitizedAllowed = sanitizeSwiftSource(allowed)
        #expect(try revisionDrivenIdentityCalls(in: sanitizedAllowed).isEmpty)
        #expect(!Set(identifierTokens(in: sanitizedAllowed)).contains("ObservableObject"))

        let rejected = """
        view.id(revision)
        view.id(state.presentationRevision)
        view.id(frameToken)
        view.id(committed.frameSeq)
        view.id(generation)
        view.id(generation + 1)
        view.id(
            state.presentationRevision
        )
        view
            .id(
                frameID
            )
        view.id(
            frameSequence
        )
        view.id(currentGeneration)
        view.id(renderGeneration)
        view.`id`(frameToken)
        let identity = state.presentationRevision
        view.id(identity)
        view.id("\\(frameToken)")
        view.id(#"\\#(revision)"#)
        view.id("\\(revision /* ( */)")
        """
        #expect(try revisionDrivenIdentityCalls(in: sanitizeSwiftSource(rejected), original: rejected).count == 16)

        let discarded = """
        let _ = frameToken
        _ = generation
        let _ =
            frameSequence
        _ =
            currentGeneration
        // _ = renderGeneration
        let example = "_ = frameID"
        """
        #expect(try discardedCorrelationReads(in: sanitizeSwiftSource(discarded)).count == 4)
        #expect(try discardedCorrelationReads(in: sanitizeSwiftSource("_ = item.id")).isEmpty)
    }

    @Test("presentation metrics observe pending correlation and ignore only classified telemetry infrastructure")
    func metricsSourcePolicy() throws {
        let source = try source(at: "Sources/Views/Shared/GUIFramePresentationMetrics.swift")
        #expect(source.sanitized.contains("@MainActor\n@Observable\npublic final class GUIFramePresentationMetrics"))
        #expect(source.sanitized.contains("private var pending: [GUIFrameImpact: Pending] = [:]"))
        #expect(source.sanitized.contains("expectedFrame: metrics.pendingFrame(domain: domain)"))
        #expect(source.sanitized.contains("func frameNativeDrawProbe("))
        #expect(identifierTokens(in: source.sanitized).count { $0 == "pending" } == 13)
    }

    private func productionSources() throws -> [ProductionSource] {
        let sourcesRoot = Self.macosRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Unable to enumerate production Swift sources at \(sourcesRoot.path)")
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { urls.append(url) }
        }
        let sortedURLs = urls.sorted { $0.path < $1.path }
        #expect(!sortedURLs.isEmpty)
        return try sortedURLs.map { url in
            let relativePath = String(url.path.dropFirst(Self.macosRoot.path.count + 1))
            let contents = try String(contentsOf: url, encoding: .utf8)
            return ProductionSource(
                path: relativePath,
                contents: contents,
                sanitized: sanitizeSwiftSource(contents)
            )
        }
    }

    private func source(at path: String) throws -> ProductionSource {
        let url = Self.macosRoot.appendingPathComponent(path)
        let contents = try String(contentsOf: url, encoding: .utf8)
        return ProductionSource(path: path, contents: contents, sanitized: sanitizeSwiftSource(contents))
    }

    private func observableDeclarations(in source: ProductionSource) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: #"@Observable(?:(?:\s+@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)|(?:\s+(?:public|private|fileprivate|internal|package|final)))*\s+(?:class|struct|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        )
        let range = NSRange(source.sanitized.startIndex..<source.sanitized.endIndex, in: source.sanitized)
        return regex.matches(in: source.sanitized, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: source.sanitized) else { return nil }
            return "\(source.path)#\(source.sanitized[nameRange])"
        }
    }

    private func ignoredDeclarations(in source: ProductionSource) -> [String] {
        let originalLines = source.contents.split(separator: "\n", omittingEmptySubsequences: false)
        let sanitizedLines = source.sanitized.split(separator: "\n", omittingEmptySubsequences: false)
        return zip(originalLines, sanitizedLines).compactMap { original, sanitized in
            guard identifierTokens(in: String(sanitized)).contains("ObservationIgnored") else { return nil }
            return "\(source.path): \(original.trimmingCharacters(in: .whitespaces))"
        }
    }

    private func discardedCorrelationReads(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: #"\b(?:let\s+)?_\s*=\s*([A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)"#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let expressionRange = Range(match.range(at: 1), in: source),
                  containsCorrelationIdentity(in: String(source[expressionRange])),
                  let readRange = Range(match.range, in: source) else { return nil }
            return source[readRange].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
    }

    private func revisionDrivenIdentityCalls(in source: String, original: String? = nil) throws -> [String] {
        let aliases = try correlationAliases(in: source)
        let regex = try NSRegularExpression(pattern: #"\.\s*`?id`?\s*\("#)
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.matches(in: source, range: fullRange).compactMap { match in
            guard let matchRange = Range(match.range, in: source) else { return nil }
            let open = source.index(before: matchRange.upperBound)
            let argumentStart = source.index(after: open)
            var cursor = argumentStart
            var depth = 1
            while cursor < source.endIndex, depth > 0 {
                if source[cursor] == "(" { depth += 1 }
                if source[cursor] == ")" { depth -= 1 }
                cursor = source.index(after: cursor)
            }
            guard depth == 0 else { return nil }
            let close = source.index(before: cursor)
            let argumentRange = argumentStart..<close
            let argument = String(source[argumentRange])
            let interpolationViolation = original.flatMap { correspondingSlice(argumentRange, from: source, in: $0) }
                .map { interpolationBodies(in: String($0)) }
                .map { bodies in
                    bodies.contains { body in
                        let sanitizedBody = sanitizeSwiftSource(body)
                        return containsCorrelationIdentity(in: sanitizedBody)
                            || identifierTokens(in: sanitizedBody).contains(where: aliases.contains)
                    }
                } ?? false
            guard containsCorrelationIdentity(in: argument)
                    || identifierTokens(in: argument).contains(where: aliases.contains)
                    || interpolationViolation else { return nil }
            let callRange = matchRange.lowerBound..<cursor
            let reported = original.flatMap { correspondingSlice(callRange, from: source, in: $0) }
                .map(String.init) ?? String(source[callRange])
            return reported.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
    }

    private func correspondingSlice(
        _ range: Range<String.Index>,
        from sanitized: String,
        in original: String
    ) -> Substring? {
        guard let lowerUTF8 = range.lowerBound.samePosition(in: sanitized.utf8),
              let upperUTF8 = range.upperBound.samePosition(in: sanitized.utf8) else { return nil }
        let lowerOffset = sanitized.utf8.distance(from: sanitized.utf8.startIndex, to: lowerUTF8)
        let upperOffset = sanitized.utf8.distance(from: sanitized.utf8.startIndex, to: upperUTF8)
        guard let originalLower = String.Index(
            original.utf8.index(original.utf8.startIndex, offsetBy: lowerOffset),
            within: original
        ), let originalUpper = String.Index(
            original.utf8.index(original.utf8.startIndex, offsetBy: upperOffset),
            within: original
        ) else { return nil }
        return original[originalLower..<originalUpper]
    }

    private func interpolationBodies(in source: String) -> [String] {
        let bytes = Array(source.utf8)
        var bodies: [String] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 92 else {
                index += 1
                continue
            }
            var markerEnd = index + 1
            while markerEnd < bytes.count, bytes[markerEnd] == 35 { markerEnd += 1 }
            guard markerEnd < bytes.count, bytes[markerEnd] == 40 else {
                index += 1
                continue
            }
            let bodyStart = markerEnd + 1
            guard let bodyEnd = interpolationBodyEnd(in: bytes, startingAt: bodyStart) else { break }
            let body = String(decoding: bytes[bodyStart..<bodyEnd], as: UTF8.self)
            bodies.append(body)
            bodies.append(contentsOf: interpolationBodies(in: body))
            index = bodyEnd + 1
        }
        return bodies
    }

    private func interpolationBodyEnd(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var cursor = start
        var depth = 1
        while cursor < bytes.count {
            if cursor + 1 < bytes.count, bytes[cursor] == 47, bytes[cursor + 1] == 47 {
                cursor += 2
                while cursor < bytes.count, bytes[cursor] != 10, bytes[cursor] != 13 { cursor += 1 }
                continue
            }
            if cursor + 1 < bytes.count, bytes[cursor] == 47, bytes[cursor + 1] == 42 {
                cursor = blockCommentEnd(in: bytes, startingAt: cursor + 2)
                continue
            }
            if let end = stringLiteralEnd(in: bytes, startingAt: cursor) {
                cursor = end
                continue
            }
            if bytes[cursor] == 40 { depth += 1 }
            if bytes[cursor] == 41 {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += 1
        }
        return nil
    }

    private func blockCommentEnd(in bytes: [UInt8], startingAt start: Int) -> Int {
        var cursor = start
        var depth = 1
        while cursor < bytes.count, depth > 0 {
            if cursor + 1 < bytes.count, bytes[cursor] == 47, bytes[cursor + 1] == 42 {
                depth += 1
                cursor += 2
            } else if cursor + 1 < bytes.count, bytes[cursor] == 42, bytes[cursor + 1] == 47 {
                depth -= 1
                cursor += 2
            } else {
                cursor += 1
            }
        }
        return cursor
    }

    private func stringLiteralEnd(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var hashCount = 0
        while start + hashCount < bytes.count, bytes[start + hashCount] == 35 { hashCount += 1 }
        let quoteIndex = start + hashCount
        guard quoteIndex < bytes.count, bytes[quoteIndex] == 34 else { return nil }
        let multiline = quoteIndex + 2 < bytes.count
            && bytes[quoteIndex + 1] == 34
            && bytes[quoteIndex + 2] == 34
        let quoteCount = multiline ? 3 : 1
        var cursor = quoteIndex + quoteCount
        while cursor < bytes.count {
            let hasQuotes = cursor + quoteCount <= bytes.count
                && bytes[cursor..<(cursor + quoteCount)].allSatisfy { $0 == 34 }
            let hashesStart = cursor + quoteCount
            let hasHashes = hashesStart + hashCount <= bytes.count
                && bytes[hashesStart..<(hashesStart + hashCount)].allSatisfy { $0 == 35 }
            if hasQuotes, hasHashes {
                if hashCount > 0 || !quoteIsEscaped(in: bytes, at: cursor) {
                    return hashesStart + hashCount
                }
            }
            cursor += 1
        }
        return bytes.count
    }

    private func quoteIsEscaped(in bytes: [UInt8], at offset: Int) -> Bool {
        var cursor = offset
        var slashCount = 0
        while cursor > 0, bytes[cursor - 1] == 92 {
            slashCount += 1
            cursor -= 1
        }
        return !slashCount.isMultiple(of: 2)
    }

    private func correlationAliases(in source: String) throws -> Set<String> {
        let regex = try NSRegularExpression(
            pattern: #"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\n]+)"#
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var aliases: Set<String> = []
        var changed = true
        while changed {
            changed = false
            for match in regex.matches(in: source, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: source),
                      let valueRange = Range(match.range(at: 2), in: source) else { continue }
                let name = String(source[nameRange])
                let value = String(source[valueRange])
                let aliasesCorrelation = identifierTokens(in: value).contains(where: aliases.contains)
                if containsCorrelationIdentity(in: value) || aliasesCorrelation {
                    changed = aliases.insert(name).inserted || changed
                }
            }
        }
        return aliases
    }

    private func occurrenceCounts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { counts, value in counts[value, default: 0] += 1 }
    }

    private func containsCorrelationIdentity(in expression: String) -> Bool {
        let identifiers = identifierTokens(in: expression).map { $0.lowercased() }
        guard !identifiers.isEmpty else { return false }
        if identifiers.contains(where: {
            $0 == "frameid"
                || $0 == "framesequence"
                || $0 == "frameseq"
                || $0 == "currentgeneration"
                || $0 == "rendergeneration"
                || $0 == "committedframe"
                || $0 == "revision"
                || $0.hasSuffix("revision")
                || $0.hasSuffix("frameversion")
                || $0.hasSuffix("frametoken")
        }) {
            return true
        }
        let compact = expression.filter { !$0.isWhitespace }
        return compact.range(of: #"(?:^|[^.A-Za-z0-9_])generation\b"#, options: .regularExpression) != nil
    }

    private func identifierTokens(in source: String) -> [String] {
        source.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
    }

    /// Blanks comments and all Swift string forms while retaining byte positions and newlines.
    private func sanitizeSwiftSource(_ source: String) -> String {
        let bytes = Array(source.utf8)
        var result = bytes
        var index = 0

        func blank(_ range: Range<Int>) {
            for offset in range where result[offset] != 10 && result[offset] != 13 {
                result[offset] = 32
            }
        }

        func isEscapedQuote(at offset: Int) -> Bool {
            var cursor = offset
            var slashCount = 0
            while cursor > 0, bytes[cursor - 1] == 92 {
                slashCount += 1
                cursor -= 1
            }
            return !slashCount.isMultiple(of: 2)
        }

        while index < bytes.count {
            if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 47 {
                let start = index
                index += 2
                while index < bytes.count, bytes[index] != 10, bytes[index] != 13 { index += 1 }
                blank(start..<index)
                continue
            }
            if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 42 {
                let start = index
                var depth = 1
                index += 2
                while index < bytes.count, depth > 0 {
                    if index + 1 < bytes.count, bytes[index] == 47, bytes[index + 1] == 42 {
                        depth += 1
                        index += 2
                    } else if index + 1 < bytes.count, bytes[index] == 42, bytes[index + 1] == 47 {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                blank(start..<index)
                continue
            }

            var hashCount = 0
            while index + hashCount < bytes.count, bytes[index + hashCount] == 35 { hashCount += 1 }
            let quoteIndex = index + hashCount
            guard quoteIndex < bytes.count, bytes[quoteIndex] == 34 else {
                index += 1
                continue
            }

            let start = index
            let isMultiline = quoteIndex + 2 < bytes.count
                && bytes[quoteIndex + 1] == 34
                && bytes[quoteIndex + 2] == 34
            let quoteCount = isMultiline ? 3 : 1
            index = quoteIndex + quoteCount
            while index < bytes.count {
                let hasQuotes = index + quoteCount <= bytes.count
                    && bytes[index..<(index + quoteCount)].allSatisfy { $0 == 34 }
                let hashesStart = index + quoteCount
                let hasHashes = hashesStart + hashCount <= bytes.count
                    && bytes[hashesStart..<(hashesStart + hashCount)].allSatisfy { $0 == 35 }
                if hasQuotes, hasHashes, hashCount > 0 || !isEscapedQuote(at: index) {
                    index = hashesStart + hashCount
                    break
                }
                index += 1
            }
            blank(start..<index)
        }

        return String(decoding: result, as: UTF8.self)
    }

    private func record(_ violations: [String]) {
        guard !violations.isEmpty else { return }
        Issue.record(Comment(rawValue: violations.sorted().joined(separator: "\n")))
    }

    private static let macosRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
