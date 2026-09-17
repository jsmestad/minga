import MingaProtocol
import Testing

@Suite("Semantic Protocol Types")
struct SemanticProtocolTypesTests {
    @Test("Agent statuses preserve every known and unknown wire value")
    func agentStatuses() {
        let known: [(UInt8, AgentStatus)] = [
            (0, .idle),
            (1, .thinking),
            (2, .executingTool),
            (3, .error),
            (4, .planning)
        ]

        for (rawValue, expected) in known {
            let status = AgentStatus(rawValue: rawValue)
            #expect(status == expected)
            #expect(status.rawValue == rawValue)
        }

        #expect(AgentStatus(rawValue: 0xFE) == .unknown(rawValue: 0xFE))
        #expect(AgentStatus(rawValue: 0xFE).rawValue == 0xFE)
    }

    @Test("Context-card statuses preserve future values")
    func cardStatuses() {
        let known: [(UInt8, CardStatus)] = [
            (0, .idle),
            (1, .working),
            (2, .iterating),
            (3, .needsYou),
            (4, .done),
            (5, .errored)
        ]

        for (rawValue, expected) in known {
            let status = CardStatus(rawValue: rawValue)
            #expect(status == expected)
            #expect(status.rawValue == rawValue)
        }

        let unknown = CardStatus(rawValue: 0xFD)
        #expect(unknown == .unknown(rawValue: 0xFD))
        #expect(unknown.rawValue == 0xFD)
        #expect(unknown.label == "Unknown")
    }

    @Test("Editor and prompt mode mappings remain distinct")
    func editorAndPromptModes() {
        let editorModes: [(UInt8, EditorMode)] = [
            (0, .normal),
            (1, .insert),
            (2, .visual),
            (3, .command),
            (4, .operatorPending),
            (5, .search),
            (6, .replace)
        ]
        let promptModes: [(UInt8, PromptMode)] = [
            (0, .normal),
            (1, .insert),
            (2, .visual),
            (3, .visualLine),
            (4, .operatorPending)
        ]

        for (rawValue, expected) in editorModes {
            #expect(EditorMode(rawValue: rawValue) == expected)
            #expect(expected.rawValue == rawValue)
        }
        for (rawValue, expected) in promptModes {
            #expect(PromptMode(rawValue: rawValue) == expected)
            #expect(expected.rawValue == rawValue)
        }

        #expect(EditorMode(rawValue: 3) == .command)
        #expect(PromptMode(rawValue: 3) == .visualLine)
        #expect(EditorMode(rawValue: 0xFC) == .unknown(rawValue: 0xFC))
        #expect(PromptMode(rawValue: 0xFC) == .unknown(rawValue: 0xFC))
    }

    @Test("Editor content and minibuffer modes preserve known and future values")
    func editorContentAndMinibufferModes() {
        #expect(EditorContentKind(rawValue: 0) == .buffer)
        #expect(EditorContentKind(rawValue: 1) == .agent)
        #expect(EditorContentKind(rawValue: 9) == .unknown(rawValue: 9))

        let minibufferModes: [(UInt8, MinibufferMode)] = [
            (0, .command),
            (1, .searchForward),
            (2, .searchBackward),
            (3, .searchPrompt),
            (4, .eval),
            (5, .substituteConfirm),
            (6, .extensionConfirm),
            (7, .describeKey),
            (8, .deleteConfirm),
            (9, .branchDeleteConfirm),
            (10, .textPrompt)
        ]

        for (rawValue, expected) in minibufferModes {
            #expect(MinibufferMode(rawValue: rawValue) == expected)
            #expect(expected.rawValue == rawValue)
        }

        let unknown = MinibufferMode(rawValue: 0xFB)
        #expect(unknown == .unknown(rawValue: 0xFB))
        #expect(!unknown.acceptsTextInput)
        #expect(unknown.presentsActionKeys)
    }

    @Test("Completion kinds preserve the sparse protocol mapping")
    func completionKinds() {
        let known: [(UInt8, CompletionKind)] = [
            (1, .function),
            (2, .method),
            (3, .variable),
            (4, .field),
            (5, .module),
            (7, .keyword),
            (8, .snippet),
            (9, .constant),
            (11, .struct),
            (12, .enum)
        ]

        for (rawValue, expected) in known {
            #expect(CompletionKind(rawValue: rawValue) == expected)
            #expect(expected.rawValue == rawValue)
        }

        #expect(CompletionKind(rawValue: 6) == .unknown(rawValue: 6))
        #expect(CompletionKind(rawValue: 0xFF).rawValue == 0xFF)
    }

    @Test("Message metadata preserves known and future values")
    func messageMetadata() {
        let levels: [(UInt8, MessageLevel)] = [
            (0, .debug),
            (1, .info),
            (2, .warning),
            (3, .error)
        ]
        let subsystems: [(UInt8, MessageSubsystem)] = [
            (0, .editor),
            (1, .lsp),
            (2, .parser),
            (3, .git),
            (4, .render),
            (5, .agent),
            (6, .zig),
            (7, .gui)
        ]

        for (rawValue, expected) in levels {
            #expect(MessageLevel(rawValue: rawValue) == expected)
            #expect(expected.rawValue == rawValue)
        }
        for (rawValue, expected) in subsystems {
            #expect(MessageSubsystem(rawValue: rawValue) == expected)
            #expect(expected.rawValue == rawValue)
        }

        #expect(MessageLevel(rawValue: 8) == .unknown(rawValue: 8))
        #expect(MessageSubsystem(rawValue: 8) == .unknown(rawValue: 8))
    }

    @Test("Workspace enums preserve known and future values")
    func workspaceEnums() {
        #expect(WorkspaceKind(rawValue: 0) == .manual)
        #expect(WorkspaceKind(rawValue: 1) == .agent)
        #expect(WorkspaceKind(rawValue: 2) == .unknown(rawValue: 2))

        let modes: [(UInt8, WorkspaceViewMode)] = [
            (0, .editor),
            (1, .agent),
            (2, .fileTree),
            (3, .other)
        ]
        for (rawValue, expected) in modes {
            #expect(WorkspaceViewMode(rawValue: rawValue) == expected)
            #expect(expected.rawValue == rawValue)
        }
        #expect(WorkspaceViewMode(rawValue: 4) == .unknown(rawValue: 4))

        #expect(WorkspaceTabKind(rawValue: 0) == .file)
        #expect(WorkspaceTabKind(rawValue: 1) == .agent)
        #expect(WorkspaceTabKind(rawValue: 2) == .unknown(rawValue: 2))
    }

    @Test("Option sets expose known options while retaining unknown bits")
    func optionSets() {
        let status = StatusBarFlags(rawValue: 0x8D)
        #expect(status.contains(.hasLSP))
        #expect(status.contains(.dirty))
        #expect(status.contains(.safeMode))
        #expect(status.unknownBits == 0x80)
        #expect(status.rawValue == 0x8D)

        let workspace = WorkspaceFlags(rawValue: 0x81)
        #expect(workspace.contains(.hasAttention))
        #expect(workspace.unknownBits == 0x80)

        let entry = WorkspaceEntryFlags(rawValue: 0x8003)
        #expect(entry.contains(.attention))
        #expect(entry.contains(.closeable))
        #expect(entry.unknownBits == 0x8000)

        let tab = WorkspaceTabFlags(rawValue: 0x8045)
        #expect(tab.contains(.dirty))
        #expect(tab.contains(.draft))
        #expect(tab.contains(.ephemeral))
        #expect(tab.unknownBits == 0x8000)
    }

    @Test("Legacy tab flags interpret kind-scoped bits without data loss")
    func legacyTabFlags() {
        let file = TabFlags(rawValue: 0xF3)
        #expect(file.contains(.active))
        #expect(file.contains(.dirty))
        #expect(file.isEphemeralFile)
        #expect(file.contains(.pinned))
        #expect(file.unknownBits == 0x60)
        #expect(file.rawValue == 0xF3)

        let agent = TabFlags(rawValue: 0xBC)
        #expect(agent.contains(.agent))
        #expect(agent.contains(.attention))
        #expect(agent.agentStatus == .error)
        #expect(agent.contains(.pinned))
        #expect(!agent.isEphemeralFile)
        #expect(agent.unknownBits == 0)

        let futureAgentStatus = TabFlags(rawValue: 0x7C)
        #expect(futureAgentStatus.agentStatus == .unknown(rawValue: 7))
        #expect(futureAgentStatus.rawValue == 0x7C)
    }

    @Test("Wire view models decode semantic fields at construction")
    func wireViewModels() {
        let completion = Wire.CompletionItem(kind: 7, label: "when", detail: "keyword")
        #expect(completion.kind == .keyword)

        let message = Wire.MessageEntry(
            streamInstance: 3,
            id: 4,
            level: 9,
            subsystem: 10,
            timestampSecs: 0,
            filePath: "",
            text: "future"
        )
        #expect(message.level == .unknown(rawValue: 9))
        #expect(message.subsystem == .unknown(rawValue: 10))

        let workspace = Wire.WorkspaceEntry(
            id: 1,
            kind: 9,
            status: 8,
            flags: 0x8003,
            colorR: 0,
            colorG: 0,
            colorB: 0,
            tabCount: 0,
            draftCount: 0,
            conflictCount: 0,
            runningBackgroundCount: 0,
            label: "Future",
            icon: ""
        )
        #expect(workspace.kind == .unknown(rawValue: 9))
        #expect(workspace.status == .unknown(rawValue: 8))
        #expect(workspace.flags.rawValue == 0x8003)
    }
}
