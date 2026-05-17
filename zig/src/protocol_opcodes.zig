//! Generated protocol opcode constants.
//!
//! Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.

// Input

pub const OP_KEY_PRESS: u8 = 0x01;
pub const OP_RESIZE: u8 = 0x02;
pub const OP_READY: u8 = 0x03;
pub const OP_MOUSE_EVENT: u8 = 0x04;
pub const OP_CAPABILITIES_UPDATED: u8 = 0x05;
pub const OP_PASTE_EVENT: u8 = 0x06;
pub const OP_GUI_ACTION: u8 = 0x07;
pub const OP_LOG_MESSAGE: u8 = 0x60;

// Render

pub const OP_DRAW_TEXT: u8 = 0x10;
pub const OP_SET_CURSOR: u8 = 0x11;
pub const OP_CLEAR: u8 = 0x12;
pub const OP_BATCH_END: u8 = 0x13;
pub const OP_DEFINE_REGION: u8 = 0x14;
pub const OP_SET_CURSOR_SHAPE: u8 = 0x15;
pub const OP_SET_TITLE: u8 = 0x16;
pub const OP_SET_WINDOW_BG: u8 = 0x17;
pub const OP_CLEAR_REGION: u8 = 0x18;
pub const OP_DESTROY_REGION: u8 = 0x19;
pub const OP_SET_ACTIVE_REGION: u8 = 0x1A;
pub const OP_SCROLL_REGION: u8 = 0x1B;
pub const OP_DRAW_STYLED_TEXT: u8 = 0x1C;

// Config

pub const OP_SET_FONT: u8 = 0x50;
pub const OP_SET_FONT_FALLBACK: u8 = 0x51;
pub const OP_REGISTER_FONT: u8 = 0x52;

// Parser Commands

pub const OP_SET_LANGUAGE: u8 = 0x20;
pub const OP_PARSE_BUFFER: u8 = 0x21;
pub const OP_SET_HIGHLIGHT_QUERY: u8 = 0x22;
pub const OP_LOAD_GRAMMAR: u8 = 0x23;
pub const OP_SET_INJECTION_QUERY: u8 = 0x24;
pub const OP_QUERY_LANGUAGE_AT: u8 = 0x25;
pub const OP_EDIT_BUFFER: u8 = 0x26;
pub const OP_MEASURE_TEXT: u8 = 0x27;
pub const OP_SET_FOLD_QUERY: u8 = 0x28;
pub const OP_SET_INDENT_QUERY: u8 = 0x29;
pub const OP_REQUEST_INDENT: u8 = 0x2A;
pub const OP_SET_TEXTOBJECT_QUERY: u8 = 0x2B;
pub const OP_REQUEST_TEXTOBJECT: u8 = 0x2C;
pub const OP_CLOSE_BUFFER: u8 = 0x2D;
pub const OP_REQUEST_MATCH_ITEM: u8 = 0x2E;
pub const OP_REQUEST_STRUCTURAL_NAV: u8 = 0x2F;
pub const OP_SET_TAGS_QUERY: u8 = 0x40;

// Parser Responses

pub const OP_HIGHLIGHT_SPANS: u8 = 0x30;
pub const OP_HIGHLIGHT_NAMES: u8 = 0x31;
pub const OP_GRAMMAR_LOADED: u8 = 0x32;
pub const OP_LANGUAGE_AT_RESPONSE: u8 = 0x33;
pub const OP_INJECTION_RANGES: u8 = 0x34;
pub const OP_TEXT_WIDTH: u8 = 0x35;
pub const OP_FOLD_RANGES: u8 = 0x36;
pub const OP_INDENT_RESULT: u8 = 0x37;
pub const OP_TEXTOBJECT_RESULT: u8 = 0x38;
pub const OP_TEXTOBJECT_POSITIONS: u8 = 0x39;
pub const OP_CONCEAL_SPANS: u8 = 0x3A;
pub const OP_REQUEST_REPARSE: u8 = 0x3B;
pub const OP_MATCH_ITEM_RESULT: u8 = 0x3C;
pub const OP_NODE_INFO: u8 = 0x3D;
pub const OP_DOCUMENT_SYMBOLS: u8 = 0x3E;

// Gui Chrome

pub const OP_GUI_TAB_BAR: u8 = 0x71;
pub const OP_GUI_WHICH_KEY: u8 = 0x72;
pub const OP_GUI_COMPLETION: u8 = 0x73;
pub const OP_GUI_THEME: u8 = 0x74;
pub const OP_GUI_BREADCRUMB: u8 = 0x75;
pub const OP_GUI_STATUS_BAR: u8 = 0x76;
pub const OP_GUI_PICKER: u8 = 0x77;
pub const OP_GUI_AGENT_CHAT: u8 = 0x78;
pub const OP_GUI_GUTTER_SEP: u8 = 0x79;
pub const OP_GUI_CURSORLINE: u8 = 0x7A;
pub const OP_GUI_GUTTER: u8 = 0x7B;
pub const OP_GUI_BOTTOM_PANEL: u8 = 0x7C;
pub const OP_GUI_PICKER_PREVIEW: u8 = 0x7D;
pub const OP_GUI_TOOL_MANAGER: u8 = 0x7E;
pub const OP_GUI_MINIBUFFER: u8 = 0x7F;
pub const OP_CLIPBOARD_WRITE: u8 = 0x90;
pub const OP_GUI_INDENT_GUIDES: u8 = 0x91;
pub const OP_GUI_LINE_SPACING: u8 = 0x92;
pub const OP_GUI_FILE_TREE: u8 = 0x93;
pub const OP_GUI_FILE_TREE_SELECTION: u8 = 0x94;
pub const OP_GUI_CURSOR_ANIMATION: u8 = 0x95;

// Gui Semantic

pub const OP_GUI_WINDOW_CONTENT: u8 = 0x80;
pub const OP_GUI_HOVER_POPUP: u8 = 0x81;
pub const OP_GUI_SIGNATURE_HELP: u8 = 0x82;
pub const OP_GUI_FLOAT_POPUP: u8 = 0x83;
pub const OP_GUI_SPLIT_SEPARATORS: u8 = 0x84;
pub const OP_GUI_GIT_STATUS: u8 = 0x85;
pub const OP_GUI_AGENT_GROUPS: u8 = 0x86;
pub const OP_GUI_BOARD: u8 = 0x87;
pub const OP_GUI_AGENT_CONTEXT: u8 = 0x88;
pub const OP_GUI_CHANGE_SUMMARY: u8 = 0x89;
pub const OP_GUI_HOVER_ACTION: u8 = 0x96;

// GUI action sub-opcodes.

pub const GUI_ACTION_SELECT_TAB: u8 = 0x01;
pub const GUI_ACTION_CLOSE_TAB: u8 = 0x02;
pub const GUI_ACTION_FILE_TREE_CLICK: u8 = 0x03;
pub const GUI_ACTION_FILE_TREE_TOGGLE: u8 = 0x04;
pub const GUI_ACTION_COMPLETION_SELECT: u8 = 0x05;
pub const GUI_ACTION_BREADCRUMB_CLICK: u8 = 0x06;
pub const GUI_ACTION_TOGGLE_PANEL: u8 = 0x07;
pub const GUI_ACTION_NEW_TAB: u8 = 0x08;
pub const GUI_ACTION_PANEL_SWITCH_TAB: u8 = 0x09;
pub const GUI_ACTION_PANEL_DISMISS: u8 = 0x0A;
pub const GUI_ACTION_PANEL_RESIZE: u8 = 0x0B;
pub const GUI_ACTION_OPEN_FILE: u8 = 0x0C;
pub const GUI_ACTION_FILE_TREE_NEW_FILE: u8 = 0x0D;
pub const GUI_ACTION_FILE_TREE_NEW_FOLDER: u8 = 0x0E;
pub const GUI_ACTION_FILE_TREE_COLLAPSE_ALL: u8 = 0x0F;
pub const GUI_ACTION_FILE_TREE_REFRESH: u8 = 0x10;
pub const GUI_ACTION_TOOL_INSTALL: u8 = 0x11;
pub const GUI_ACTION_TOOL_UNINSTALL: u8 = 0x12;
pub const GUI_ACTION_TOOL_UPDATE: u8 = 0x13;
pub const GUI_ACTION_TOOL_DISMISS: u8 = 0x14;
pub const GUI_ACTION_AGENT_TOOL_TOGGLE: u8 = 0x15;
pub const GUI_ACTION_EXECUTE_COMMAND: u8 = 0x16;
pub const GUI_ACTION_MINIBUFFER_SELECT: u8 = 0x17;
pub const GUI_ACTION_GIT_STAGE_FILE: u8 = 0x18;
pub const GUI_ACTION_GIT_UNSTAGE_FILE: u8 = 0x19;
pub const GUI_ACTION_GIT_DISCARD_FILE: u8 = 0x1A;
pub const GUI_ACTION_GIT_STAGE_ALL: u8 = 0x1B;
pub const GUI_ACTION_GIT_UNSTAGE_ALL: u8 = 0x1C;
pub const GUI_ACTION_GIT_COMMIT: u8 = 0x1D;
pub const GUI_ACTION_GIT_OPEN_FILE: u8 = 0x1E;
pub const GUI_ACTION_AGENT_GROUP_RENAME: u8 = 0x1F;
pub const GUI_ACTION_AGENT_GROUP_SET_ICON: u8 = 0x20;
pub const GUI_ACTION_AGENT_GROUP_CLOSE: u8 = 0x21;
pub const GUI_ACTION_SPACE_LEADER_CHORD: u8 = 0x22;
pub const GUI_ACTION_SPACE_LEADER_RETRACT: u8 = 0x23;
pub const GUI_ACTION_FIND_PASTEBOARD_SEARCH: u8 = 0x24;
pub const GUI_ACTION_BOARD_SELECT_CARD: u8 = 0x25;
pub const GUI_ACTION_BOARD_CLOSE_CARD: u8 = 0x26;
pub const GUI_ACTION_BOARD_REORDER: u8 = 0x27;
pub const GUI_ACTION_BOARD_DISPATCH_AGENT: u8 = 0x28;
pub const GUI_ACTION_AGENT_APPROVE: u8 = 0x29;
pub const GUI_ACTION_AGENT_REQUEST_CHANGES: u8 = 0x2A;
pub const GUI_ACTION_AGENT_DISMISS: u8 = 0x2B;
pub const GUI_ACTION_CHANGE_SUMMARY_CLICK: u8 = 0x2C;
pub const GUI_ACTION_FILE_TREE_EDIT_CONFIRM: u8 = 0x2D;
pub const GUI_ACTION_FILE_TREE_EDIT_CANCEL: u8 = 0x2E;
pub const GUI_ACTION_SCROLL_TO_LINE: u8 = 0x2F;
pub const GUI_ACTION_FILE_TREE_DELETE: u8 = 0x30;
pub const GUI_ACTION_FILE_TREE_RENAME: u8 = 0x31;
pub const GUI_ACTION_FILE_TREE_DUPLICATE: u8 = 0x32;
pub const GUI_ACTION_FILE_TREE_MOVE: u8 = 0x33;
pub const GUI_ACTION_SYSTEM_WILL_SLEEP: u8 = 0x34;
pub const GUI_ACTION_SYSTEM_DID_WAKE: u8 = 0x35;
pub const GUI_ACTION_CMD_COPY: u8 = 0x36;
pub const GUI_ACTION_CMD_CUT: u8 = 0x37;
pub const GUI_ACTION_GIT_PUSH: u8 = 0x38;
pub const GUI_ACTION_GIT_PULL: u8 = 0x39;
pub const GUI_ACTION_GIT_FETCH: u8 = 0x3A;
pub const GUI_ACTION_GIT_COMMIT_AMEND: u8 = 0x3B;
pub const GUI_ACTION_GIT_PULL_AND_RETRY: u8 = 0x3C;
pub const GUI_ACTION_FILE_TREE_OPEN_IN_SPLIT: u8 = 0x3D;
pub const GUI_ACTION_TAB_COPY_PATH: u8 = 0x3E;
pub const GUI_ACTION_HOVER_OPEN_ACTION: u8 = 0x3F;
pub const GUI_ACTION_FILE_TREE_DROP: u8 = 0x40;
pub const GUI_ACTION_FOLD_TOGGLE_AT_LINE: u8 = 0x41;
pub const GUI_ACTION_GIT_OPEN_DIFF: u8 = 0x42;
