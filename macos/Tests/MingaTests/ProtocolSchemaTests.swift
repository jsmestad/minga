/// Validates Swift opcode constants against the canonical protocol_schema.toml.

import Testing
import Foundation

private struct ProtocolSchema {
    let opcodes: [String: [String: UInt8]]
    let guiActions: [String: UInt8]
}

private enum SchemaError: Error {
    case invalidTOML
    case missingKey
}

private func loadSchema() throws -> ProtocolSchema {
    let thisFile = #filePath
    let macosDir = URL(fileURLWithPath: thisFile).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let projectRoot = macosDir.deletingLastPathComponent()
    let schemaURL = projectRoot.appendingPathComponent("docs/protocol_schema.toml")
    let text = try String(contentsOf: schemaURL, encoding: .utf8)
    return try parseSchema(text)
}

private func parseSchema(_ text: String) throws -> ProtocolSchema {
    var opcodes: [String: [String: UInt8]] = [:]
    var guiActions: [String: UInt8] = [:]
    var currentTable: String?
    var current: [String: String] = [:]

    func flush() throws {
        guard let table = currentTable else { return }
        guard let name = current["name"], let valueText = current["value"], let value = parseUInt8(valueText) else { throw SchemaError.invalidTOML }
        if table == "opcodes" {
            guard let category = current["category"] else { throw SchemaError.invalidTOML }
            opcodes[category, default: [:]][name] = value
        } else if table == "gui_actions" {
            guiActions[name] = value
        }
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line == "[[opcodes]]" || line == "[[gui_actions]]" {
            try flush()
            currentTable = line == "[[opcodes]]" ? "opcodes" : "gui_actions"
            current = [:]
            continue
        }
        guard let equals = line.firstIndex(of: "=") else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let rawValue = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        current[String(key)] = unquote(rawValue)
    }

    try flush()
    return ProtocolSchema(opcodes: opcodes, guiActions: guiActions)
}

private func unquote(_ value: String) -> String {
    if value.hasPrefix("\"") && value.hasSuffix("\"") {
        return String(value.dropFirst().dropLast())
    }
    return value
}

private func parseUInt8(_ value: String) -> UInt8? {
    if value.hasPrefix("0x") || value.hasPrefix("0X") {
        return UInt8(value.dropFirst(2), radix: 16)
    }
    return UInt8(value)
}

private func schemaValue(_ schema: ProtocolSchema, _ category: String, _ name: String) throws -> UInt8 {
    guard let value = schema.opcodes[category]?[name] else { throw SchemaError.missingKey }
    return value
}

private func guiActionValue(_ schema: ProtocolSchema, _ name: String) throws -> UInt8 {
    guard let value = schema.guiActions[name] else { throw SchemaError.missingKey }
    return value
}

private func expectOpcodes(_ schema: ProtocolSchema, _ category: String, _ expected: [(String, UInt8)]) throws {
    for (name, constant) in expected {
        #expect(try schemaValue(schema, category, name) == constant)
    }
}

private func expectGuiActions(_ schema: ProtocolSchema, _ expected: [(String, UInt8)]) throws {
    for (name, constant) in expected {
        #expect(try guiActionValue(schema, name) == constant)
    }
}

@Suite("Protocol Schema: Swift Constants Match")
struct ProtocolSchemaSwiftTests {
    @Test("Input opcode constants match schema")
    func inputOpcodes() throws {
        let schema = try loadSchema()
        try expectOpcodes(schema, "input", [("key_press", OP_KEY_PRESS), ("resize", OP_RESIZE), ("ready", OP_READY), ("mouse_event", OP_MOUSE_EVENT), ("capabilities_updated", OP_CAPABILITIES_UPDATED), ("paste_event", OP_PASTE_EVENT), ("gui_action", OP_GUI_ACTION), ("log_message", OP_LOG_MESSAGE)])
    }

    @Test("Render opcode constants match schema")
    func renderOpcodes() throws {
        let schema = try loadSchema()
        try expectOpcodes(schema, "render", [("draw_text", OP_DRAW_TEXT), ("set_cursor", OP_SET_CURSOR), ("clear", OP_CLEAR), ("batch_end", OP_BATCH_END), ("define_region", OP_DEFINE_REGION), ("set_cursor_shape", OP_SET_CURSOR_SHAPE), ("set_title", OP_SET_TITLE), ("set_window_bg", OP_SET_WINDOW_BG), ("clear_region", OP_CLEAR_REGION), ("destroy_region", OP_DESTROY_REGION), ("set_active_region", OP_SET_ACTIVE_REGION), ("scroll_region", OP_SCROLL_REGION), ("draw_styled_text", OP_DRAW_STYLED_TEXT)])
    }

    @Test("Config opcode constants match schema")
    func configOpcodes() throws {
        let schema = try loadSchema()
        try expectOpcodes(schema, "config", [("set_font", OP_SET_FONT), ("set_font_fallback", OP_SET_FONT_FALLBACK), ("register_font", OP_REGISTER_FONT)])
    }

    @Test("Parser command opcode constants match schema")
    func parserCommandOpcodes() throws {
        let schema = try loadSchema()
        try expectOpcodes(schema, "parser_commands", [("set_language", OP_SET_LANGUAGE), ("parse_buffer", OP_PARSE_BUFFER), ("set_highlight_query", OP_SET_HIGHLIGHT_QUERY), ("load_grammar", OP_LOAD_GRAMMAR), ("set_injection_query", OP_SET_INJECTION_QUERY), ("query_language_at", OP_QUERY_LANGUAGE_AT), ("edit_buffer", OP_EDIT_BUFFER), ("measure_text", OP_MEASURE_TEXT), ("set_fold_query", OP_SET_FOLD_QUERY), ("set_indent_query", OP_SET_INDENT_QUERY), ("request_indent", OP_REQUEST_INDENT), ("set_textobject_query", OP_SET_TEXTOBJECT_QUERY), ("request_textobject", OP_REQUEST_TEXTOBJECT), ("close_buffer", OP_CLOSE_BUFFER), ("request_match_item", OP_REQUEST_MATCH_ITEM), ("request_structural_nav", OP_REQUEST_STRUCTURAL_NAV), ("set_tags_query", OP_SET_TAGS_QUERY)])
    }

    @Test("Parser response opcode constants match schema")
    func parserResponseOpcodes() throws {
        let schema = try loadSchema()
        try expectOpcodes(schema, "parser_responses", [("highlight_spans", OP_HIGHLIGHT_SPANS), ("highlight_names", OP_HIGHLIGHT_NAMES), ("grammar_loaded", OP_GRAMMAR_LOADED), ("language_at_response", OP_LANGUAGE_AT_RESPONSE), ("injection_ranges", OP_INJECTION_RANGES), ("text_width", OP_TEXT_WIDTH), ("fold_ranges", OP_FOLD_RANGES), ("indent_result", OP_INDENT_RESULT), ("textobject_result", OP_TEXTOBJECT_RESULT), ("textobject_positions", OP_TEXTOBJECT_POSITIONS), ("conceal_spans", OP_CONCEAL_SPANS), ("request_reparse", OP_REQUEST_REPARSE), ("match_item_result", OP_MATCH_ITEM_RESULT), ("node_info", OP_NODE_INFO), ("document_symbols", OP_DOCUMENT_SYMBOLS)])
    }

    @Test("GUI chrome opcode constants match schema")
    func guiChromeOpcodes() throws {
        let schema = try loadSchema()
        try expectOpcodes(schema, "gui_chrome", [("gui_tab_bar", OP_GUI_TAB_BAR), ("gui_which_key", OP_GUI_WHICH_KEY), ("gui_completion", OP_GUI_COMPLETION), ("gui_theme", OP_GUI_THEME), ("gui_breadcrumb", OP_GUI_BREADCRUMB), ("gui_status_bar", OP_GUI_STATUS_BAR), ("gui_picker", OP_GUI_PICKER), ("gui_agent_chat", OP_GUI_AGENT_CHAT), ("gui_gutter_sep", OP_GUI_GUTTER_SEP), ("gui_cursorline", OP_GUI_CURSORLINE), ("gui_gutter", OP_GUI_GUTTER), ("gui_bottom_panel", OP_GUI_BOTTOM_PANEL), ("gui_picker_preview", OP_GUI_PICKER_PREVIEW), ("gui_tool_manager", OP_GUI_TOOL_MANAGER), ("gui_minibuffer", OP_GUI_MINIBUFFER), ("clipboard_write", OP_CLIPBOARD_WRITE), ("gui_indent_guides", OP_GUI_INDENT_GUIDES), ("gui_line_spacing", OP_GUI_LINE_SPACING), ("gui_file_tree", OP_GUI_FILE_TREE), ("gui_file_tree_selection", OP_GUI_FILE_TREE_SELECTION), ("gui_cursor_animation", OP_GUI_CURSOR_ANIMATION)])
    }

    @Test("GUI semantic opcodes match schema")
    func guiSemanticOpcodes() throws {
        let schema = try loadSchema()
        try expectOpcodes(schema, "gui_semantic", [("gui_window_content", OP_GUI_WINDOW_CONTENT), ("gui_hover_popup", OP_GUI_HOVER_POPUP), ("gui_signature_help", OP_GUI_SIGNATURE_HELP), ("gui_float_popup", OP_GUI_FLOAT_POPUP), ("gui_split_separators", OP_GUI_SPLIT_SEPARATORS), ("gui_git_status", OP_GUI_GIT_STATUS), ("gui_workspaces", OP_GUI_WORKSPACES), ("gui_notifications", OP_GUI_NOTIFICATIONS), ("gui_board", OP_GUI_BOARD), ("gui_agent_context", OP_GUI_AGENT_CONTEXT), ("gui_change_summary", OP_GUI_CHANGE_SUMMARY), ("gui_hover_action", OP_GUI_HOVER_ACTION), ("gui_config_state", OP_GUI_CONFIG_STATE)])
    }

    @Test("GUI action sub-opcode constants match schema")
    func guiActionOpcodes() throws {
        let schema = try loadSchema()
        try expectGuiActions(schema, [("select_tab", GUI_ACTION_SELECT_TAB), ("close_tab", GUI_ACTION_CLOSE_TAB), ("file_tree_click", GUI_ACTION_FILE_TREE_CLICK), ("file_tree_toggle", GUI_ACTION_FILE_TREE_TOGGLE), ("completion_select", GUI_ACTION_COMPLETION_SELECT), ("breadcrumb_click", GUI_ACTION_BREADCRUMB_CLICK), ("toggle_panel", GUI_ACTION_TOGGLE_PANEL), ("new_tab", GUI_ACTION_NEW_TAB), ("panel_switch_tab", GUI_ACTION_PANEL_SWITCH_TAB), ("panel_dismiss", GUI_ACTION_PANEL_DISMISS), ("panel_resize", GUI_ACTION_PANEL_RESIZE), ("open_file", GUI_ACTION_OPEN_FILE), ("file_tree_new_file", GUI_ACTION_FILE_TREE_NEW_FILE), ("file_tree_new_folder", GUI_ACTION_FILE_TREE_NEW_FOLDER), ("file_tree_collapse_all", GUI_ACTION_FILE_TREE_COLLAPSE_ALL), ("file_tree_refresh", GUI_ACTION_FILE_TREE_REFRESH), ("tool_install", GUI_ACTION_TOOL_INSTALL), ("tool_uninstall", GUI_ACTION_TOOL_UNINSTALL), ("tool_update", GUI_ACTION_TOOL_UPDATE), ("tool_dismiss", GUI_ACTION_TOOL_DISMISS), ("agent_tool_toggle", GUI_ACTION_AGENT_TOOL_TOGGLE), ("execute_command", GUI_ACTION_EXECUTE_COMMAND), ("minibuffer_select", GUI_ACTION_MINIBUFFER_SELECT), ("git_stage_file", GUI_ACTION_GIT_STAGE_FILE), ("git_unstage_file", GUI_ACTION_GIT_UNSTAGE_FILE), ("git_discard_file", GUI_ACTION_GIT_DISCARD_FILE), ("git_stage_all", GUI_ACTION_GIT_STAGE_ALL), ("git_unstage_all", GUI_ACTION_GIT_UNSTAGE_ALL), ("git_commit", GUI_ACTION_GIT_COMMIT), ("git_open_file", GUI_ACTION_GIT_OPEN_FILE), ("workspace_rename", GUI_ACTION_WORKSPACE_RENAME), ("workspace_set_icon", GUI_ACTION_WORKSPACE_SET_ICON), ("workspace_close", GUI_ACTION_WORKSPACE_CLOSE), ("space_leader_chord", GUI_ACTION_SPACE_LEADER_CHORD), ("space_leader_retract", GUI_ACTION_SPACE_LEADER_RETRACT), ("find_pasteboard_search", GUI_ACTION_FIND_PASTEBOARD_SEARCH), ("board_select_card", GUI_ACTION_BOARD_SELECT_CARD), ("board_close_card", GUI_ACTION_BOARD_CLOSE_CARD), ("board_reorder", GUI_ACTION_BOARD_REORDER), ("board_dispatch_agent", GUI_ACTION_BOARD_DISPATCH_AGENT), ("agent_approve", GUI_ACTION_AGENT_APPROVE), ("agent_request_changes", GUI_ACTION_AGENT_REQUEST_CHANGES), ("agent_dismiss", GUI_ACTION_AGENT_DISMISS), ("change_summary_click", GUI_ACTION_CHANGE_SUMMARY_CLICK), ("file_tree_edit_confirm", GUI_ACTION_FILE_TREE_EDIT_CONFIRM), ("file_tree_edit_cancel", GUI_ACTION_FILE_TREE_EDIT_CANCEL), ("scroll_to_line", GUI_ACTION_SCROLL_TO_LINE), ("file_tree_delete", GUI_ACTION_FILE_TREE_DELETE), ("file_tree_rename", GUI_ACTION_FILE_TREE_RENAME), ("file_tree_duplicate", GUI_ACTION_FILE_TREE_DUPLICATE), ("file_tree_move", GUI_ACTION_FILE_TREE_MOVE), ("system_will_sleep", GUI_ACTION_SYSTEM_WILL_SLEEP), ("system_did_wake", GUI_ACTION_SYSTEM_DID_WAKE), ("cmd_copy", GUI_ACTION_CMD_COPY), ("cmd_cut", GUI_ACTION_CMD_CUT), ("git_push", GUI_ACTION_GIT_PUSH), ("git_pull", GUI_ACTION_GIT_PULL), ("git_fetch", GUI_ACTION_GIT_FETCH), ("git_commit_amend", GUI_ACTION_GIT_COMMIT_AMEND), ("git_pull_and_retry", GUI_ACTION_GIT_PULL_AND_RETRY), ("file_tree_open_in_split", GUI_ACTION_FILE_TREE_OPEN_IN_SPLIT), ("tab_copy_path", GUI_ACTION_TAB_COPY_PATH), ("hover_open_action", GUI_ACTION_HOVER_OPEN_ACTION), ("file_tree_drop", GUI_ACTION_FILE_TREE_DROP), ("fold_toggle_at_line", GUI_ACTION_FOLD_TOGGLE_AT_LINE), ("git_open_diff", GUI_ACTION_GIT_OPEN_DIFF), ("config_update", GUI_ACTION_CONFIG_UPDATE), ("config_query", GUI_ACTION_CONFIG_QUERY), ("notification_dismiss", GUI_ACTION_NOTIFICATION_DISMISS), ("notification_action", GUI_ACTION_NOTIFICATION_ACTION), ("power_thermal_state", GUI_ACTION_POWER_THERMAL_STATE), ("tab_reorder", GUI_ACTION_TAB_REORDER)])
    }
}
