/// GUI theme color slot IDs.
///
/// These name the slots in the `guiTheme` (0x70) opcode payload. They are
/// public so both the app renderer and the MingaUI preview framework can map
/// a slot ID to a semantic color role. Non-color protocol constants stay in
/// `ProtocolConstants.swift` (app-internal).

// GUI theme color slot IDs
public let GUI_COLOR_EDITOR_BG: UInt8 = 0x01
public let GUI_COLOR_EDITOR_FG: UInt8 = 0x02
public let GUI_COLOR_TREE_BG: UInt8 = 0x03
public let GUI_COLOR_TREE_FG: UInt8 = 0x04
public let GUI_COLOR_TREE_SELECTION_BG: UInt8 = 0x05
public let GUI_COLOR_TREE_DIR_FG: UInt8 = 0x06
public let GUI_COLOR_TREE_ACTIVE_FG: UInt8 = 0x07
public let GUI_COLOR_TREE_HEADER_BG: UInt8 = 0x08
public let GUI_COLOR_TREE_HEADER_FG: UInt8 = 0x09
public let GUI_COLOR_TREE_SEPARATOR_FG: UInt8 = 0x0A
public let GUI_COLOR_TREE_GIT_MODIFIED: UInt8 = 0x0B
public let GUI_COLOR_TREE_GIT_STAGED: UInt8 = 0x0C
public let GUI_COLOR_TREE_GIT_UNTRACKED: UInt8 = 0x0D
public let GUI_COLOR_TREE_SELECTION_FG: UInt8 = 0x0E
public let GUI_COLOR_TREE_GUIDE_FG: UInt8 = 0x0F
public let GUI_COLOR_TAB_BG: UInt8 = 0x10
public let GUI_COLOR_TAB_ACTIVE_BG: UInt8 = 0x11
public let GUI_COLOR_TAB_ACTIVE_FG: UInt8 = 0x12
public let GUI_COLOR_TAB_INACTIVE_FG: UInt8 = 0x13
public let GUI_COLOR_TAB_MODIFIED_FG: UInt8 = 0x14
public let GUI_COLOR_TAB_SEPARATOR_FG: UInt8 = 0x15
public let GUI_COLOR_TAB_CLOSE_HOVER_FG: UInt8 = 0x16
public let GUI_COLOR_TAB_ATTENTION_FG: UInt8 = 0x17
public let GUI_COLOR_POPUP_BG: UInt8 = 0x20
public let GUI_COLOR_POPUP_FG: UInt8 = 0x21
public let GUI_COLOR_POPUP_BORDER: UInt8 = 0x22
public let GUI_COLOR_POPUP_SEL_BG: UInt8 = 0x23
public let GUI_COLOR_POPUP_SEL_FG: UInt8 = 0x2A
public let GUI_COLOR_POPUP_KEY_FG: UInt8 = 0x24
public let GUI_COLOR_POPUP_GROUP_FG: UInt8 = 0x25
public let GUI_COLOR_POPUP_DESC_FG: UInt8 = 0x26
public let GUI_COLOR_BREADCRUMB_BG: UInt8 = 0x27
public let GUI_COLOR_BREADCRUMB_FG: UInt8 = 0x28
public let GUI_COLOR_BREADCRUMB_SEPARATOR_FG: UInt8 = 0x29
public let GUI_COLOR_MODELINE_BAR_BG: UInt8 = 0x30
public let GUI_COLOR_MODELINE_BAR_FG: UInt8 = 0x31
public let GUI_COLOR_MODELINE_INFO_BG: UInt8 = 0x32
public let GUI_COLOR_MODELINE_INFO_FG: UInt8 = 0x33
public let GUI_COLOR_MODE_NORMAL_BG: UInt8 = 0x34
public let GUI_COLOR_MODE_NORMAL_FG: UInt8 = 0x35
public let GUI_COLOR_MODE_INSERT_BG: UInt8 = 0x36
public let GUI_COLOR_MODE_INSERT_FG: UInt8 = 0x37
public let GUI_COLOR_MODE_VISUAL_BG: UInt8 = 0x38
public let GUI_COLOR_MODE_VISUAL_FG: UInt8 = 0x39
public let GUI_COLOR_STATUSBAR_ACCENT_FG: UInt8 = 0x3A
public let GUI_COLOR_ACCENT: UInt8 = 0x40

// Gutter + Git color slots
public let GUI_COLOR_GUTTER_FG: UInt8 = 0x50
public let GUI_COLOR_GUTTER_CURRENT_FG: UInt8 = 0x51
public let GUI_COLOR_GUTTER_ERROR_FG: UInt8 = 0x52
public let GUI_COLOR_GUTTER_WARNING_FG: UInt8 = 0x53
public let GUI_COLOR_GUTTER_INFO_FG: UInt8 = 0x54
public let GUI_COLOR_GUTTER_HINT_FG: UInt8 = 0x55
public let GUI_COLOR_GUTTER_FOLD_FG: UInt8 = 0x62
public let GUI_COLOR_GIT_ADDED_FG: UInt8 = 0x56
public let GUI_COLOR_GIT_MODIFIED_FG: UInt8 = 0x57
public let GUI_COLOR_GIT_DELETED_FG: UInt8 = 0x58
public let GUI_COLOR_HIGHLIGHT_READ_BG: UInt8 = 0x59
public let GUI_COLOR_HIGHLIGHT_WRITE_BG: UInt8 = 0x5A
public let GUI_COLOR_SELECTION_BG: UInt8 = 0x5B

// Agent status color slots (shared across tab bar badges, chat header, etc.)
public let GUI_COLOR_AGENT_STATUS_IDLE: UInt8 = 0x5C
public let GUI_COLOR_AGENT_STATUS_WORKING: UInt8 = 0x5D
public let GUI_COLOR_AGENT_STATUS_ITERATING: UInt8 = 0x5E
public let GUI_COLOR_AGENT_STATUS_NEEDS_YOU: UInt8 = 0x5F
public let GUI_COLOR_AGENT_STATUS_DONE: UInt8 = 0x60
public let GUI_COLOR_AGENT_STATUS_ERRORED: UInt8 = 0x61

// Agent chat theme color slots (populated from Theme.Agent on BEAM side)
public let GUI_COLOR_AGENT_PANEL_BG: UInt8 = 0xA0
public let GUI_COLOR_AGENT_HEADER_BG: UInt8 = 0xA1
public let GUI_COLOR_AGENT_HEADER_FG: UInt8 = 0xA2
public let GUI_COLOR_AGENT_USER_BORDER: UInt8 = 0xA3
public let GUI_COLOR_AGENT_USER_LABEL: UInt8 = 0xA4
public let GUI_COLOR_AGENT_ASSISTANT_BORDER: UInt8 = 0xA5
public let GUI_COLOR_AGENT_ASSISTANT_LABEL: UInt8 = 0xA6
public let GUI_COLOR_AGENT_INPUT_BORDER: UInt8 = 0xA7
public let GUI_COLOR_AGENT_INPUT_BG: UInt8 = 0xA8
public let GUI_COLOR_AGENT_INPUT_PLACEHOLDER: UInt8 = 0xA9
public let GUI_COLOR_AGENT_TEXT_FG: UInt8 = 0xAA
public let GUI_COLOR_AGENT_TOOL_BORDER: UInt8 = 0xAB
public let GUI_COLOR_AGENT_TOOL_HEADER: UInt8 = 0xAC
public let GUI_COLOR_AGENT_CODE_BG: UInt8 = 0xAD
public let GUI_COLOR_AGENT_CODE_BORDER: UInt8 = 0xAE
