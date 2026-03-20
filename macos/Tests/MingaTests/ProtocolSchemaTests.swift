/// Validates Swift opcode constants against the canonical protocol_schema.json.
///
/// This is the Swift half of the cross-language schema validation. The Elixir
/// side has its own test that validates against the same JSON file. If either
/// language's constants drift from the schema, the test fails.
///
/// The schema file is at docs/protocol_schema.json in the project root.

import Testing
import Foundation

/// Loads the protocol schema JSON and returns the parsed dictionary.
private func loadSchema() throws -> [String: Any] {
    // Navigate from the test binary to the project root.
    // In Xcode, the test binary runs from DerivedData; we need the source tree.
    // Walk up from the current file's compile-time path.
    let thisFile = #filePath
    // thisFile = .../macos/Tests/MingaTests/ProtocolSchemaTests.swift
    // Project root = 3 directories up from macos/
    let macosDir = URL(fileURLWithPath: thisFile)
        .deletingLastPathComponent()  // MingaTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // macos
    let projectRoot = macosDir.deletingLastPathComponent()
    let schemaURL = projectRoot.appendingPathComponent("docs/protocol_schema.json")

    let data = try Data(contentsOf: schemaURL)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SchemaError.invalidJSON
    }
    return json
}

private enum SchemaError: Error { case invalidJSON, missingKey }

/// Extracts the hex value for a named opcode from a schema section.
private func schemaHex(_ section: [String: Any], _ name: String) throws -> UInt8 {
    guard let entry = section[name] as? [String: Any],
          let hexStr = entry["hex"] as? String else {
        throw SchemaError.missingKey
    }
    // Parse "0x70" -> 0x70
    let stripped = hexStr.hasPrefix("0x") ? String(hexStr.dropFirst(2)) : hexStr
    guard let value = UInt8(stripped, radix: 16) else {
        throw SchemaError.invalidJSON
    }
    return value
}

@Suite("Protocol Schema: Swift Constants Match")
struct ProtocolSchemaSwiftTests {

    @Test("Render opcode constants match schema")
    func renderOpcodes() throws {
        let schema = try loadSchema()
        guard let opcodes = schema["opcodes"] as? [String: Any],
              let render = opcodes["render"] as? [String: Any] else { return }

        #expect(try schemaHex(render, "draw_text") == OP_DRAW_TEXT)
        #expect(try schemaHex(render, "set_cursor") == OP_SET_CURSOR)
        #expect(try schemaHex(render, "clear") == OP_CLEAR)
        #expect(try schemaHex(render, "batch_end") == OP_BATCH_END)
        #expect(try schemaHex(render, "define_region") == OP_DEFINE_REGION)
        #expect(try schemaHex(render, "set_cursor_shape") == OP_SET_CURSOR_SHAPE)
        #expect(try schemaHex(render, "set_title") == OP_SET_TITLE)
        #expect(try schemaHex(render, "set_window_bg") == OP_SET_WINDOW_BG)
        #expect(try schemaHex(render, "clear_region") == OP_CLEAR_REGION)
        #expect(try schemaHex(render, "destroy_region") == OP_DESTROY_REGION)
        #expect(try schemaHex(render, "set_active_region") == OP_SET_ACTIVE_REGION)
        #expect(try schemaHex(render, "draw_styled_text") == OP_DRAW_STYLED_TEXT)
    }

    @Test("GUI chrome opcode constants match schema")
    func guiChromeOpcodes() throws {
        let schema = try loadSchema()
        guard let opcodes = schema["opcodes"] as? [String: Any],
              let chrome = opcodes["gui_chrome"] as? [String: Any] else { return }

        #expect(try schemaHex(chrome, "gui_file_tree") == OP_GUI_FILE_TREE)
        #expect(try schemaHex(chrome, "gui_tab_bar") == OP_GUI_TAB_BAR)
        #expect(try schemaHex(chrome, "gui_which_key") == OP_GUI_WHICH_KEY)
        #expect(try schemaHex(chrome, "gui_completion") == OP_GUI_COMPLETION)
        #expect(try schemaHex(chrome, "gui_theme") == OP_GUI_THEME)
        #expect(try schemaHex(chrome, "gui_breadcrumb") == OP_GUI_BREADCRUMB)
        #expect(try schemaHex(chrome, "gui_status_bar") == OP_GUI_STATUS_BAR)
        #expect(try schemaHex(chrome, "gui_picker") == OP_GUI_PICKER)
        #expect(try schemaHex(chrome, "gui_agent_chat") == OP_GUI_AGENT_CHAT)
        #expect(try schemaHex(chrome, "gui_gutter_sep") == OP_GUI_GUTTER_SEP)
        #expect(try schemaHex(chrome, "gui_cursorline") == OP_GUI_CURSORLINE)
        #expect(try schemaHex(chrome, "gui_gutter") == OP_GUI_GUTTER)
        #expect(try schemaHex(chrome, "gui_bottom_panel") == OP_GUI_BOTTOM_PANEL)
        #expect(try schemaHex(chrome, "gui_picker_preview") == OP_GUI_PICKER_PREVIEW)
        #expect(try schemaHex(chrome, "gui_tool_manager") == OP_GUI_TOOL_MANAGER)
    }

    @Test("Input opcode constants match schema")
    func inputOpcodes() throws {
        let schema = try loadSchema()
        guard let opcodes = schema["opcodes"] as? [String: Any],
              let input = opcodes["input"] as? [String: Any] else { return }

        #expect(try schemaHex(input, "key_press") == OP_KEY_PRESS)
        #expect(try schemaHex(input, "resize") == OP_RESIZE)
        #expect(try schemaHex(input, "ready") == OP_READY)
        #expect(try schemaHex(input, "mouse_event") == OP_MOUSE_EVENT)
        #expect(try schemaHex(input, "paste_event") == OP_PASTE_EVENT)
        #expect(try schemaHex(input, "gui_action") == OP_GUI_ACTION)
        #expect(try schemaHex(input, "log_message") == OP_LOG_MESSAGE)
    }

    @Test("GUI action sub-opcode constants match schema")
    func guiActionOpcodes() throws {
        let schema = try loadSchema()
        guard let actions = schema["gui_actions"] as? [String: Any] else { return }

        #expect(try schemaHex(actions, "select_tab") == GUI_ACTION_SELECT_TAB)
        #expect(try schemaHex(actions, "close_tab") == GUI_ACTION_CLOSE_TAB)
        #expect(try schemaHex(actions, "file_tree_click") == GUI_ACTION_FILE_TREE_CLICK)
        #expect(try schemaHex(actions, "file_tree_toggle") == GUI_ACTION_FILE_TREE_TOGGLE)
        #expect(try schemaHex(actions, "completion_select") == GUI_ACTION_COMPLETION_SELECT)
        #expect(try schemaHex(actions, "breadcrumb_click") == GUI_ACTION_BREADCRUMB_CLICK)
        #expect(try schemaHex(actions, "toggle_panel") == GUI_ACTION_TOGGLE_PANEL)
        #expect(try schemaHex(actions, "new_tab") == GUI_ACTION_NEW_TAB)
        #expect(try schemaHex(actions, "panel_switch_tab") == GUI_ACTION_PANEL_SWITCH_TAB)
        #expect(try schemaHex(actions, "panel_dismiss") == GUI_ACTION_PANEL_DISMISS)
        #expect(try schemaHex(actions, "panel_resize") == GUI_ACTION_PANEL_RESIZE)
        #expect(try schemaHex(actions, "open_file") == GUI_ACTION_OPEN_FILE)
        #expect(try schemaHex(actions, "file_tree_new_file") == GUI_ACTION_FILE_TREE_NEW_FILE)
        #expect(try schemaHex(actions, "file_tree_new_folder") == GUI_ACTION_FILE_TREE_NEW_FOLDER)
        #expect(try schemaHex(actions, "file_tree_collapse_all") == GUI_ACTION_FILE_TREE_COLLAPSE_ALL)
        #expect(try schemaHex(actions, "file_tree_refresh") == GUI_ACTION_FILE_TREE_REFRESH)
        #expect(try schemaHex(actions, "tool_install") == GUI_ACTION_TOOL_INSTALL)
        #expect(try schemaHex(actions, "tool_uninstall") == GUI_ACTION_TOOL_UNINSTALL)
        #expect(try schemaHex(actions, "tool_update") == GUI_ACTION_TOOL_UPDATE)
        #expect(try schemaHex(actions, "tool_dismiss") == GUI_ACTION_TOOL_DISMISS)
    }

    @Test("GUI window content opcode matches schema")
    func guiWindowContentOpcode() throws {
        let schema = try loadSchema()
        guard let opcodes = schema["opcodes"] as? [String: Any],
              let semantic = opcodes["gui_semantic"] as? [String: Any] else { return }

        #expect(try schemaHex(semantic, "gui_window_content") == OP_GUI_WINDOW_CONTENT)
    }
}
