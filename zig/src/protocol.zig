/// Port protocol encoder/decoder for BEAM ↔ Zig communication.
///
/// Messages use a simple binary format with 1-byte opcodes:
///
/// Input events (Zig → BEAM):
///   0x01 key_press:    codepoint:u32, modifiers:u8
///   0x02 resize:       width:u16, height:u16
///   0x03 ready:        width:u16, height:u16
///   0x04 mouse_event:  row:i16, col:i16, button:u8, modifiers:u8, event_type:u8
///   0x06 paste_event:  text_len:u16, text:u8[text_len]
///   0x07 gui_action:   action:u8, payload
///
/// Render commands (BEAM → frontend), transport survivors only. The
/// cell-paradigm opcodes (draw_text, set_cursor, clear, region commands,
/// draw_styled_text) were retired in protocol_version 2 with the Zig renderer:
///   0x10 begin_frame:      frame_seq:u32, base_frame_seq:u32, generation:u32
///   0x11 commit_frame:     frame_seq:u32, input_seq:u32
///   0x15 set_cursor_shape: shape:u8
///
/// The 4-byte length prefix is handled by Erlang's {:packet, 4} and
/// is NOT included in encode/decode here.
const std = @import("std");

const opcodes = @import("generated/protocol_opcodes.zig");
const generated_command_size = @import("generated/protocol_command_size.zig");

// BEGIN GENERATED OPCODE EXPORTS. Regenerate with `mix protocol.gen`. Do not edit by hand.
// Input
pub const OP_KEY_PRESS = opcodes.OP_KEY_PRESS;
pub const OP_RESIZE = opcodes.OP_RESIZE;
pub const OP_READY = opcodes.OP_READY;
pub const OP_MOUSE_EVENT = opcodes.OP_MOUSE_EVENT;
pub const OP_CAPABILITIES_UPDATED = opcodes.OP_CAPABILITIES_UPDATED;
pub const OP_PASTE_EVENT = opcodes.OP_PASTE_EVENT;
pub const OP_GUI_ACTION = opcodes.OP_GUI_ACTION;
pub const OP_REQUEST_KEYFRAME = opcodes.OP_REQUEST_KEYFRAME;
pub const OP_SCROLL_BATCH = opcodes.OP_SCROLL_BATCH;
pub const OP_FRAME_APPLIED = opcodes.OP_FRAME_APPLIED;
pub const OP_FRAME_REJECTED = opcodes.OP_FRAME_REJECTED;
pub const OP_WINDOW_REF_MISS = opcodes.OP_WINDOW_REF_MISS;
pub const OP_LOG_MESSAGE = opcodes.OP_LOG_MESSAGE;

// Render
pub const OP_BEGIN_FRAME = opcodes.OP_BEGIN_FRAME;
pub const OP_COMMIT_FRAME = opcodes.OP_COMMIT_FRAME;
pub const OP_SET_CURSOR_SHAPE = opcodes.OP_SET_CURSOR_SHAPE;
pub const OP_SET_TITLE = opcodes.OP_SET_TITLE;
pub const OP_SET_WINDOW_BG = opcodes.OP_SET_WINDOW_BG;
pub const OP_SET_LINK_CURSOR = opcodes.OP_SET_LINK_CURSOR;
pub const OP_PROTOCOL_ERROR = opcodes.OP_PROTOCOL_ERROR;

// Config
pub const OP_SET_FONT = opcodes.OP_SET_FONT;
pub const OP_SET_FONT_FALLBACK = opcodes.OP_SET_FONT_FALLBACK;
pub const OP_REGISTER_FONT = opcodes.OP_REGISTER_FONT;

// Parser Commands
pub const OP_SET_LANGUAGE = opcodes.OP_SET_LANGUAGE;
pub const OP_PARSE_BUFFER = opcodes.OP_PARSE_BUFFER;
pub const OP_SET_HIGHLIGHT_QUERY = opcodes.OP_SET_HIGHLIGHT_QUERY;
pub const OP_LOAD_GRAMMAR = opcodes.OP_LOAD_GRAMMAR;
pub const OP_SET_INJECTION_QUERY = opcodes.OP_SET_INJECTION_QUERY;
pub const OP_QUERY_LANGUAGE_AT = opcodes.OP_QUERY_LANGUAGE_AT;
pub const OP_EDIT_BUFFER = opcodes.OP_EDIT_BUFFER;
pub const OP_MEASURE_TEXT = opcodes.OP_MEASURE_TEXT;
pub const OP_SET_FOLD_QUERY = opcodes.OP_SET_FOLD_QUERY;
pub const OP_SET_INDENT_QUERY = opcodes.OP_SET_INDENT_QUERY;
pub const OP_REQUEST_INDENT = opcodes.OP_REQUEST_INDENT;
pub const OP_SET_TEXTOBJECT_QUERY = opcodes.OP_SET_TEXTOBJECT_QUERY;
pub const OP_REQUEST_TEXTOBJECT = opcodes.OP_REQUEST_TEXTOBJECT;
pub const OP_CLOSE_BUFFER = opcodes.OP_CLOSE_BUFFER;
pub const OP_REQUEST_MATCH_ITEM = opcodes.OP_REQUEST_MATCH_ITEM;
pub const OP_REQUEST_STRUCTURAL_NAV = opcodes.OP_REQUEST_STRUCTURAL_NAV;
pub const OP_SET_TAGS_QUERY = opcodes.OP_SET_TAGS_QUERY;

// Parser Responses
pub const OP_HIGHLIGHT_SPANS = opcodes.OP_HIGHLIGHT_SPANS;
pub const OP_HIGHLIGHT_NAMES = opcodes.OP_HIGHLIGHT_NAMES;
pub const OP_GRAMMAR_LOADED = opcodes.OP_GRAMMAR_LOADED;
pub const OP_LANGUAGE_AT_RESPONSE = opcodes.OP_LANGUAGE_AT_RESPONSE;
pub const OP_INJECTION_RANGES = opcodes.OP_INJECTION_RANGES;
pub const OP_TEXT_WIDTH = opcodes.OP_TEXT_WIDTH;
pub const OP_FOLD_RANGES = opcodes.OP_FOLD_RANGES;
pub const OP_INDENT_RESULT = opcodes.OP_INDENT_RESULT;
pub const OP_TEXTOBJECT_RESULT = opcodes.OP_TEXTOBJECT_RESULT;
pub const OP_TEXTOBJECT_POSITIONS = opcodes.OP_TEXTOBJECT_POSITIONS;
pub const OP_CONCEAL_SPANS = opcodes.OP_CONCEAL_SPANS;
pub const OP_REQUEST_REPARSE = opcodes.OP_REQUEST_REPARSE;
pub const OP_MATCH_ITEM_RESULT = opcodes.OP_MATCH_ITEM_RESULT;
pub const OP_NODE_INFO = opcodes.OP_NODE_INFO;
pub const OP_DOCUMENT_SYMBOLS = opcodes.OP_DOCUMENT_SYMBOLS;

// Gui Chrome
pub const OP_GUI_TAB_BAR = opcodes.OP_GUI_TAB_BAR;
pub const OP_GUI_WHICH_KEY = opcodes.OP_GUI_WHICH_KEY;
pub const OP_GUI_COMPLETION = opcodes.OP_GUI_COMPLETION;
pub const OP_GUI_THEME = opcodes.OP_GUI_THEME;
pub const OP_GUI_BREADCRUMB = opcodes.OP_GUI_BREADCRUMB;
pub const OP_GUI_STATUS_BAR = opcodes.OP_GUI_STATUS_BAR;
pub const OP_GUI_PICKER = opcodes.OP_GUI_PICKER;
pub const OP_GUI_AGENT_CHAT = opcodes.OP_GUI_AGENT_CHAT;
pub const OP_GUI_GUTTER_SEP = opcodes.OP_GUI_GUTTER_SEP;
pub const OP_GUI_CURSORLINE = opcodes.OP_GUI_CURSORLINE;
pub const OP_GUI_GUTTER = opcodes.OP_GUI_GUTTER;
pub const OP_GUI_BOTTOM_PANEL = opcodes.OP_GUI_BOTTOM_PANEL;
pub const OP_GUI_PICKER_PREVIEW = opcodes.OP_GUI_PICKER_PREVIEW;
pub const OP_GUI_MINIBUFFER = opcodes.OP_GUI_MINIBUFFER;
pub const OP_CLIPBOARD_WRITE = opcodes.OP_CLIPBOARD_WRITE;
pub const OP_GUI_INDENT_GUIDES = opcodes.OP_GUI_INDENT_GUIDES;
pub const OP_GUI_LINE_SPACING = opcodes.OP_GUI_LINE_SPACING;
pub const OP_GUI_FILE_TREE = opcodes.OP_GUI_FILE_TREE;
pub const OP_GUI_FILE_TREE_SELECTION = opcodes.OP_GUI_FILE_TREE_SELECTION;
pub const OP_GUI_CURSOR_ANIMATION = opcodes.OP_GUI_CURSOR_ANIMATION;

// Gui Semantic
pub const OP_GUI_WINDOW_CONTENT = opcodes.OP_GUI_WINDOW_CONTENT;
pub const OP_GUI_HOVER_POPUP = opcodes.OP_GUI_HOVER_POPUP;
pub const OP_GUI_SIGNATURE_HELP = opcodes.OP_GUI_SIGNATURE_HELP;
pub const OP_GUI_FLOAT_POPUP = opcodes.OP_GUI_FLOAT_POPUP;
pub const OP_GUI_SPLIT_SEPARATORS = opcodes.OP_GUI_SPLIT_SEPARATORS;
pub const OP_GUI_GIT_STATUS = opcodes.OP_GUI_GIT_STATUS;
pub const OP_GUI_AGENT_TRANSCRIPT = opcodes.OP_GUI_AGENT_TRANSCRIPT;
pub const OP_GUI_AGENT_CONTEXT = opcodes.OP_GUI_AGENT_CONTEXT;
pub const OP_GUI_CHANGE_SUMMARY = opcodes.OP_GUI_CHANGE_SUMMARY;
pub const OP_GUI_HOVER_ACTION = opcodes.OP_GUI_HOVER_ACTION;
pub const OP_GUI_CONFIG_STATE = opcodes.OP_GUI_CONFIG_STATE;
pub const OP_GUI_WORKSPACES = opcodes.OP_GUI_WORKSPACES;
pub const OP_GUI_NOTIFICATIONS = opcodes.OP_GUI_NOTIFICATIONS;
pub const OP_GUI_OBSERVATORY = opcodes.OP_GUI_OBSERVATORY;
pub const OP_GUI_EDIT_TIMELINE = opcodes.OP_GUI_EDIT_TIMELINE;
pub const OP_GUI_EXTENSION_OVERLAY = opcodes.OP_GUI_EXTENSION_OVERLAY;
pub const OP_GUI_EXTENSION_PANEL = opcodes.OP_GUI_EXTENSION_PANEL;
pub const OP_GUI_SEARCH_STATE = opcodes.OP_GUI_SEARCH_STATE;
pub const OP_GUI_SIDEBARS = opcodes.OP_GUI_SIDEBARS;
pub const OP_GUI_WINDOW_OVERLAY_DELTA = opcodes.OP_GUI_WINDOW_OVERLAY_DELTA;
pub const OP_GUI_WINDOW_VIEWPORT_DELTA = opcodes.OP_GUI_WINDOW_VIEWPORT_DELTA;
pub const OP_GUI_WINDOW_ROWS_DELTA = opcodes.OP_GUI_WINDOW_ROWS_DELTA;
pub const OP_GUI_EXTENSION_RUNTIME = opcodes.OP_GUI_EXTENSION_RUNTIME;
pub const OP_GUI_SURFACE_LAYOUT = opcodes.OP_GUI_SURFACE_LAYOUT;
pub const OP_GUI_EMPTY_STATE = opcodes.OP_GUI_EMPTY_STATE;

pub const GUI_ACTION_SELECT_TAB = opcodes.GUI_ACTION_SELECT_TAB;
pub const GUI_ACTION_CLOSE_TAB = opcodes.GUI_ACTION_CLOSE_TAB;
pub const GUI_ACTION_FILE_TREE_CLICK = opcodes.GUI_ACTION_FILE_TREE_CLICK;
pub const GUI_ACTION_FILE_TREE_TOGGLE = opcodes.GUI_ACTION_FILE_TREE_TOGGLE;
pub const GUI_ACTION_COMPLETION_SELECT = opcodes.GUI_ACTION_COMPLETION_SELECT;
pub const GUI_ACTION_BREADCRUMB_CLICK = opcodes.GUI_ACTION_BREADCRUMB_CLICK;
pub const GUI_ACTION_TOGGLE_PANEL = opcodes.GUI_ACTION_TOGGLE_PANEL;
pub const GUI_ACTION_NEW_TAB = opcodes.GUI_ACTION_NEW_TAB;
pub const GUI_ACTION_PANEL_SWITCH_TAB = opcodes.GUI_ACTION_PANEL_SWITCH_TAB;
pub const GUI_ACTION_PANEL_DISMISS = opcodes.GUI_ACTION_PANEL_DISMISS;
pub const GUI_ACTION_PANEL_RESIZE = opcodes.GUI_ACTION_PANEL_RESIZE;
pub const GUI_ACTION_OPEN_FILE = opcodes.GUI_ACTION_OPEN_FILE;
pub const GUI_ACTION_FILE_TREE_NEW_FILE = opcodes.GUI_ACTION_FILE_TREE_NEW_FILE;
pub const GUI_ACTION_FILE_TREE_NEW_FOLDER = opcodes.GUI_ACTION_FILE_TREE_NEW_FOLDER;
pub const GUI_ACTION_FILE_TREE_COLLAPSE_ALL = opcodes.GUI_ACTION_FILE_TREE_COLLAPSE_ALL;
pub const GUI_ACTION_FILE_TREE_REFRESH = opcodes.GUI_ACTION_FILE_TREE_REFRESH;
pub const GUI_ACTION_AGENT_TOOL_TOGGLE = opcodes.GUI_ACTION_AGENT_TOOL_TOGGLE;
pub const GUI_ACTION_EXECUTE_COMMAND = opcodes.GUI_ACTION_EXECUTE_COMMAND;
pub const GUI_ACTION_MINIBUFFER_SELECT = opcodes.GUI_ACTION_MINIBUFFER_SELECT;
pub const GUI_ACTION_GIT_STAGE_FILE = opcodes.GUI_ACTION_GIT_STAGE_FILE;
pub const GUI_ACTION_GIT_UNSTAGE_FILE = opcodes.GUI_ACTION_GIT_UNSTAGE_FILE;
pub const GUI_ACTION_GIT_DISCARD_FILE = opcodes.GUI_ACTION_GIT_DISCARD_FILE;
pub const GUI_ACTION_GIT_STAGE_ALL = opcodes.GUI_ACTION_GIT_STAGE_ALL;
pub const GUI_ACTION_GIT_UNSTAGE_ALL = opcodes.GUI_ACTION_GIT_UNSTAGE_ALL;
pub const GUI_ACTION_GIT_COMMIT = opcodes.GUI_ACTION_GIT_COMMIT;
pub const GUI_ACTION_GIT_OPEN_FILE = opcodes.GUI_ACTION_GIT_OPEN_FILE;
pub const GUI_ACTION_WORKSPACE_RENAME = opcodes.GUI_ACTION_WORKSPACE_RENAME;
pub const GUI_ACTION_WORKSPACE_SET_ICON = opcodes.GUI_ACTION_WORKSPACE_SET_ICON;
pub const GUI_ACTION_WORKSPACE_CLOSE = opcodes.GUI_ACTION_WORKSPACE_CLOSE;
pub const GUI_ACTION_SPACE_LEADER_CHORD = opcodes.GUI_ACTION_SPACE_LEADER_CHORD;
pub const GUI_ACTION_SPACE_LEADER_RETRACT = opcodes.GUI_ACTION_SPACE_LEADER_RETRACT;
pub const GUI_ACTION_FIND_PASTEBOARD_SEARCH = opcodes.GUI_ACTION_FIND_PASTEBOARD_SEARCH;
pub const GUI_ACTION_AGENT_APPROVE = opcodes.GUI_ACTION_AGENT_APPROVE;
pub const GUI_ACTION_AGENT_REQUEST_CHANGES = opcodes.GUI_ACTION_AGENT_REQUEST_CHANGES;
pub const GUI_ACTION_AGENT_DISMISS = opcodes.GUI_ACTION_AGENT_DISMISS;
pub const GUI_ACTION_CHANGE_SUMMARY_CLICK = opcodes.GUI_ACTION_CHANGE_SUMMARY_CLICK;
pub const GUI_ACTION_FILE_TREE_EDIT_CONFIRM = opcodes.GUI_ACTION_FILE_TREE_EDIT_CONFIRM;
pub const GUI_ACTION_FILE_TREE_EDIT_CANCEL = opcodes.GUI_ACTION_FILE_TREE_EDIT_CANCEL;
pub const GUI_ACTION_SCROLL_TO_LINE = opcodes.GUI_ACTION_SCROLL_TO_LINE;
pub const GUI_ACTION_FILE_TREE_DELETE = opcodes.GUI_ACTION_FILE_TREE_DELETE;
pub const GUI_ACTION_FILE_TREE_RENAME = opcodes.GUI_ACTION_FILE_TREE_RENAME;
pub const GUI_ACTION_FILE_TREE_DUPLICATE = opcodes.GUI_ACTION_FILE_TREE_DUPLICATE;
pub const GUI_ACTION_FILE_TREE_MOVE = opcodes.GUI_ACTION_FILE_TREE_MOVE;
pub const GUI_ACTION_SYSTEM_WILL_SLEEP = opcodes.GUI_ACTION_SYSTEM_WILL_SLEEP;
pub const GUI_ACTION_SYSTEM_DID_WAKE = opcodes.GUI_ACTION_SYSTEM_DID_WAKE;
pub const GUI_ACTION_CMD_COPY = opcodes.GUI_ACTION_CMD_COPY;
pub const GUI_ACTION_CMD_CUT = opcodes.GUI_ACTION_CMD_CUT;
pub const GUI_ACTION_GIT_PUSH = opcodes.GUI_ACTION_GIT_PUSH;
pub const GUI_ACTION_GIT_PULL = opcodes.GUI_ACTION_GIT_PULL;
pub const GUI_ACTION_GIT_FETCH = opcodes.GUI_ACTION_GIT_FETCH;
pub const GUI_ACTION_GIT_COMMIT_AMEND = opcodes.GUI_ACTION_GIT_COMMIT_AMEND;
pub const GUI_ACTION_GIT_PULL_AND_RETRY = opcodes.GUI_ACTION_GIT_PULL_AND_RETRY;
pub const GUI_ACTION_FILE_TREE_OPEN_IN_SPLIT = opcodes.GUI_ACTION_FILE_TREE_OPEN_IN_SPLIT;
pub const GUI_ACTION_TAB_COPY_PATH = opcodes.GUI_ACTION_TAB_COPY_PATH;
pub const GUI_ACTION_HOVER_OPEN_ACTION = opcodes.GUI_ACTION_HOVER_OPEN_ACTION;
pub const GUI_ACTION_FILE_TREE_DROP = opcodes.GUI_ACTION_FILE_TREE_DROP;
pub const GUI_ACTION_FOLD_TOGGLE_AT_LINE = opcodes.GUI_ACTION_FOLD_TOGGLE_AT_LINE;
pub const GUI_ACTION_GIT_OPEN_DIFF = opcodes.GUI_ACTION_GIT_OPEN_DIFF;
pub const GUI_ACTION_CONFIG_UPDATE = opcodes.GUI_ACTION_CONFIG_UPDATE;
pub const GUI_ACTION_CONFIG_QUERY = opcodes.GUI_ACTION_CONFIG_QUERY;
pub const GUI_ACTION_NOTIFICATION_DISMISS = opcodes.GUI_ACTION_NOTIFICATION_DISMISS;
pub const GUI_ACTION_NOTIFICATION_ACTION = opcodes.GUI_ACTION_NOTIFICATION_ACTION;
pub const GUI_ACTION_POWER_THERMAL_STATE = opcodes.GUI_ACTION_POWER_THERMAL_STATE;
pub const GUI_ACTION_TAB_REORDER = opcodes.GUI_ACTION_TAB_REORDER;
pub const GUI_ACTION_TAB_PIN = opcodes.GUI_ACTION_TAB_PIN;
pub const GUI_ACTION_TAB_UNPIN = opcodes.GUI_ACTION_TAB_UNPIN;
pub const GUI_ACTION_TAB_MOVE_LEFT = opcodes.GUI_ACTION_TAB_MOVE_LEFT;
pub const GUI_ACTION_TAB_MOVE_RIGHT = opcodes.GUI_ACTION_TAB_MOVE_RIGHT;
pub const GUI_ACTION_OBSERVATORY_INSPECT = opcodes.GUI_ACTION_OBSERVATORY_INSPECT;
pub const GUI_ACTION_FONT_SIZE_ADJUST = opcodes.GUI_ACTION_FONT_SIZE_ADJUST;
pub const GUI_ACTION_TIMELINE_NAVIGATE = opcodes.GUI_ACTION_TIMELINE_NAVIGATE;
pub const GUI_ACTION_EXTENSION_PANEL_ACTION = opcodes.GUI_ACTION_EXTENSION_PANEL_ACTION;
pub const GUI_ACTION_SEARCH_QUERY = opcodes.GUI_ACTION_SEARCH_QUERY;
pub const GUI_ACTION_SEARCH_NEXT = opcodes.GUI_ACTION_SEARCH_NEXT;
pub const GUI_ACTION_SEARCH_PREV = opcodes.GUI_ACTION_SEARCH_PREV;
pub const GUI_ACTION_SEARCH_REPLACE = opcodes.GUI_ACTION_SEARCH_REPLACE;
pub const GUI_ACTION_SEARCH_REPLACE_ALL = opcodes.GUI_ACTION_SEARCH_REPLACE_ALL;
pub const GUI_ACTION_SEARCH_DISMISS = opcodes.GUI_ACTION_SEARCH_DISMISS;
pub const GUI_ACTION_SIDEBAR_ACTION = opcodes.GUI_ACTION_SIDEBAR_ACTION;
pub const GUI_ACTION_EXTENSION_ACTION = opcodes.GUI_ACTION_EXTENSION_ACTION;
pub const GUI_ACTION_FLOAT_POPUP_DISMISS = opcodes.GUI_ACTION_FLOAT_POPUP_DISMISS;
pub const GUI_ACTION_SYSTEM_WILL_UNMOUNT = opcodes.GUI_ACTION_SYSTEM_WILL_UNMOUNT;
pub const GUI_ACTION_EMPTY_STATE_ACTIVATE = opcodes.GUI_ACTION_EMPTY_STATE_ACTIVATE;
pub const GUI_ACTION_CHAT_SCROLLED_AWAY_FROM_BOTTOM = opcodes.GUI_ACTION_CHAT_SCROLLED_AWAY_FROM_BOTTOM;
pub const GUI_ACTION_CHAT_RETURNED_TO_BOTTOM = opcodes.GUI_ACTION_CHAT_RETURNED_TO_BOTTOM;
pub const GUI_ACTION_PICKER_QUERY_CHANGED = opcodes.GUI_ACTION_PICKER_QUERY_CHANGED;
// END GENERATED OPCODE EXPORTS.

// Log levels
pub const LOG_LEVEL_ERR: u8 = 0;
pub const LOG_LEVEL_WARN: u8 = 1;
pub const LOG_LEVEL_INFO: u8 = 2;
pub const LOG_LEVEL_DEBUG: u8 = 3;

// ── Cursor shapes ──

pub const CURSOR_BLOCK: u8 = 0x00;
pub const CURSOR_BEAM: u8 = 0x01;
pub const CURSOR_UNDERLINE: u8 = 0x02;

// ── Modifier flags ──

pub const MOD_SHIFT: u8 = 0x01;
pub const MOD_CTRL: u8 = 0x02;
pub const MOD_ALT: u8 = 0x04;
pub const MOD_SUPER: u8 = 0x08;

// ── Mouse button values (matching libvaxis Mouse.Button enum) ──

pub const MOUSE_LEFT: u8 = 0x00;
pub const MOUSE_MIDDLE: u8 = 0x01;
pub const MOUSE_RIGHT: u8 = 0x02;
pub const MOUSE_NONE: u8 = 0x03;
pub const MOUSE_WHEEL_UP: u8 = 0x40;
pub const MOUSE_WHEEL_DOWN: u8 = 0x41;
pub const MOUSE_WHEEL_RIGHT: u8 = 0x42;
pub const MOUSE_WHEEL_LEFT: u8 = 0x43;

// ── Mouse event types ──

pub const MOUSE_PRESS: u8 = 0x00;
pub const MOUSE_RELEASE: u8 = 0x01;
pub const MOUSE_MOTION: u8 = 0x02;
pub const MOUSE_DRAG: u8 = 0x03;

// ── Frontend capability constants ──

pub const CAPS_VERSION: u8 = 1;

pub const FRONTEND_TUI: u8 = 0;
pub const FRONTEND_NATIVE_GUI: u8 = 1;
pub const FRONTEND_WEB: u8 = 2;

pub const COLOR_MONO: u8 = 0;
pub const COLOR_256: u8 = 1;
pub const COLOR_RGB: u8 = 2;

pub const UNICODE_WCWIDTH: u8 = 0;
pub const UNICODE_15: u8 = 1;

pub const IMAGE_NONE: u8 = 0;
pub const IMAGE_KITTY: u8 = 1;
pub const IMAGE_SIXEL: u8 = 2;
pub const IMAGE_NATIVE: u8 = 3;

pub const FLOAT_EMULATED: u8 = 0;
pub const FLOAT_NATIVE: u8 = 1;

pub const TEXT_MONOSPACE: u8 = 0;
pub const TEXT_PROPORTIONAL: u8 = 1;

// ── Region roles ──

pub const REGION_EDITOR: u8 = 0;
pub const REGION_MODELINE: u8 = 1;
pub const REGION_MINIBUFFER: u8 = 2;
pub const REGION_GUTTER: u8 = 3;
pub const REGION_POPUP: u8 = 4;
pub const REGION_PANEL: u8 = 5;
pub const REGION_BORDER: u8 = 6;

// ── Highlight types (shared between renderer and parser) ──

/// A syntax highlight span: a byte range tagged with a capture ID.
pub const Span = struct {
    start_byte: u32,
    end_byte: u32,
    capture_id: u16,
    pattern_index: u16,
    /// Priority layer: 0 = outer language, 1+ = injection depth.
    /// Higher layers win when spans overlap at the same byte position.
    /// Serialized in the port protocol as u16.
    layer: u16 = 0,
};

/// An injection language region: a byte range mapped to a language name.
pub const InjectionRange = struct {
    start_byte: u32,
    end_byte: u32,
    language: []const u8,
};

/// A tree-sitter document symbol extracted from a tags.scm @definition capture.
pub const DocumentSymbol = struct {
    kind: u8,
    name: []const u8,
    start_row: u32,
    start_col: u32,
    end_row: u32,
    end_col: u32,
};

pub const SYMBOL_FUNCTION: u8 = 0;
pub const SYMBOL_MODULE: u8 = 1;
pub const SYMBOL_METHOD: u8 = 2;
pub const SYMBOL_INTERFACE: u8 = 3;
pub const SYMBOL_TEST: u8 = 4;

/// Frontend capabilities, reported in the extended ready event and
/// capabilities_updated events.
pub const Capabilities = struct {
    frontend_type: u8 = FRONTEND_TUI,
    color_depth: u8 = COLOR_RGB,
    unicode_width: u8 = UNICODE_WCWIDTH,
    image_support: u8 = IMAGE_NONE,
    float_support: u8 = FLOAT_EMULATED,
    text_rendering: u8 = TEXT_MONOSPACE,
};

// ── Attribute flags ──

pub const ATTR_BOLD: u8 = 0x01;
pub const ATTR_UNDERLINE: u8 = 0x02;
pub const ATTR_ITALIC: u8 = 0x04;
pub const ATTR_REVERSE: u8 = 0x08;
pub const ATTR_STRIKETHROUGH: u16 = 0x10;
// Underline style occupies bits 5-7 of the extended u16 attrs:
// 0b000 = line (default), 0b001 = curl, 0b010 = dashed, 0b011 = dotted, 0b100 = double
pub const UL_STYLE_SHIFT: u4 = 5;
pub const UL_STYLE_MASK: u16 = 0x07 << UL_STYLE_SHIFT;

// ── Decoded types ──

pub const CursorShape = enum(u8) {
    block = CURSOR_BLOCK,
    beam = CURSOR_BEAM,
    underline = CURSOR_UNDERLINE,
};

pub const RenderCommand = union(enum) {
    // The cell-paradigm render commands (draw_text, draw_styled_text, set_cursor,
    // clear, define_region, clear_region, destroy_region, set_active_region,
    // scroll_region) were retired in protocol_version 2 along with the Zig
    // renderer (#2223). The parser decodes only the transport survivors and its
    // own parser commands; any other opcode yields error.UnknownOpcode, which
    // the command loop breaks on (render opcodes never reach the parser stream).
    set_cursor_shape: CursorShape,
    set_title: []const u8,
    // Frame transaction markers (#2219). begin_frame opens a frame; commit_frame
    // closes it (carrying the echoed input correlation seq formerly on batch_end).
    // The parser decodes them only as transport survivors; it does not render.
    begin_frame: void,
    commit_frame: void,
    // Incremental content sync
    edit_buffer: EditBuffer,
    // Text measurement
    measure_text: MeasureText,
    // Default background color for cells that don't specify one.
    set_default_bg: u24,
    // No-op (command was decoded and skipped; GUI-only opcodes, etc.)
    noop: void,
    // Highlight commands
    set_language: SetLanguage,
    parse_buffer: ParseBuffer,
    set_highlight_query: SetHighlightQuery,
    set_injection_query: SetInjectionQuery,
    set_fold_query: SetFoldQuery,
    set_indent_query: SetIndentQuery,
    request_indent: RequestIndent,
    set_textobject_query: SetTextobjectQuery,
    request_textobject: RequestTextobject,
    request_match_item: RequestMatchItem,
    request_structural_nav: RequestStructuralNav,
    set_tags_query: SetTagsQuery,
    load_grammar: LoadGrammar,
    query_language_at: QueryLanguageAt,
    close_buffer: u32, // buffer_id
};

/// A single edit delta for incremental content sync.
pub const EditDelta = struct {
    start_byte: u32,
    old_end_byte: u32,
    new_end_byte: u32,
    start_row: u32,
    start_col: u32,
    old_end_row: u32,
    old_end_col: u32,
    new_end_row: u32,
    new_end_col: u32,
    inserted_text: []const u8,
};

/// An edit_buffer command containing one or more edit deltas.
pub const EditBuffer = struct {
    buffer_id: u32 = 0,
    version: u32,
    edits: []const EditDelta,
};

pub const MeasureText = struct {
    request_id: u32,
    text: []const u8,
};

pub const QueryLanguageAt = struct {
    buffer_id: u32 = 0,
    request_id: u32,
    byte_offset: u32,
};

pub const ParseBuffer = struct {
    buffer_id: u32 = 0,
    version: u32,
    source: []const u8,
};

pub const SetLanguage = struct {
    buffer_id: u32 = 0,
    name: []const u8,
};

pub const SetHighlightQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetInjectionQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetFoldQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetIndentQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetTextobjectQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const SetTagsQuery = struct {
    buffer_id: u32 = 0,
    source: []const u8,
};

pub const RequestIndent = struct {
    buffer_id: u32 = 0,
    request_id: u32,
    line: u32,
};

pub const RequestTextobject = struct {
    buffer_id: u32 = 0,
    request_id: u32,
    row: u32,
    col: u32,
    capture_name: []const u8,
};

pub const RequestMatchItem = struct {
    buffer_id: u32 = 0,
    request_id: u32,
    row: u32,
    col: u32,
};

pub const StructuralNavAction = enum(u8) {
    parent = 0,
    first_child = 1,
    next_sibling = 2,
    prev_sibling = 3,
};

pub const RequestStructuralNav = struct {
    buffer_id: u32 = 0,
    request_id: u32,
    row: u32,
    col: u32,
    action: StructuralNavAction,
};

pub const LoadGrammar = struct {
    name: []const u8,
    path: []const u8,
};

pub const DecodeError = error{
    UnknownOpcode,
    Malformed,
};

// ── Encoding (Zig → BEAM) ──

/// Encodes a key_press event into the provided buffer.
/// Returns the number of bytes written (always 6).
pub fn encodeKeyPress(buf: []u8, codepoint: u32, modifiers: u8) !usize {
    if (buf.len < 6) return error.Malformed;
    buf[0] = OP_KEY_PRESS;
    std.mem.writeInt(u32, buf[1..5], codepoint, .big);
    buf[5] = modifiers;
    return 6;
}

/// Encodes a resize event into the provided buffer.
/// Returns the number of bytes written (always 5).
pub fn encodeResize(buf: []u8, width: u16, height: u16) !usize {
    if (buf.len < 5) return error.Malformed;
    buf[0] = OP_RESIZE;
    std.mem.writeInt(u16, buf[1..3], width, .big);
    std.mem.writeInt(u16, buf[3..5], height, .big);
    return 5;
}

/// Encodes a ready event into the provided buffer.
/// If `caps` is non-null, encodes the extended format with capability fields (13 bytes).
/// Otherwise encodes the short format (5 bytes).
pub fn encodeReady(buf: []u8, width: u16, height: u16) !usize {
    if (buf.len < 5) return error.Malformed;
    buf[0] = OP_READY;
    std.mem.writeInt(u16, buf[1..3], width, .big);
    std.mem.writeInt(u16, buf[3..5], height, .big);
    return 5;
}

/// Encodes a ready event with capabilities into the provided buffer.
/// Extended format: opcode(1) + width(2) + height(2) + caps_version(1) + caps_len(1) + caps(6) = 13 bytes.
pub fn encodeReadyWithCaps(buf: []u8, width: u16, height: u16, caps: Capabilities) !usize {
    const total = 13;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_READY;
    std.mem.writeInt(u16, buf[1..3], width, .big);
    std.mem.writeInt(u16, buf[3..5], height, .big);
    buf[5] = CAPS_VERSION;
    buf[6] = 6; // caps_len: 6 fields
    buf[7] = caps.frontend_type;
    buf[8] = caps.color_depth;
    buf[9] = caps.unicode_width;
    buf[10] = caps.image_support;
    buf[11] = caps.float_support;
    buf[12] = caps.text_rendering;
    return total;
}

/// Encodes a capabilities_updated event (opcode 0x05).
/// Same payload as the caps portion of extended ready: version(1) + len(1) + fields(6) = 8 bytes.
pub fn encodeCapabilitiesUpdated(buf: []u8, caps: Capabilities) !usize {
    const total = 9;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_CAPABILITIES_UPDATED;
    buf[1] = CAPS_VERSION;
    buf[2] = 6;
    buf[3] = caps.frontend_type;
    buf[4] = caps.color_depth;
    buf[5] = caps.unicode_width;
    buf[6] = caps.image_support;
    buf[7] = caps.float_support;
    buf[8] = caps.text_rendering;
    return total;
}

/// Encodes a mouse event into the provided buffer.
/// Returns the number of bytes written (always 9).
/// The click_count field is 1 for single click, 2 for double, 3 for triple.
/// The Zig TUI always sends 1; the BEAM does multi-click detection for TUI events.
/// GUI frontends (Swift) send the native click count.
pub fn encodeMouseEvent(buf: []u8, row: i16, col: i16, button: u8, modifiers: u8, event_type: u8, click_count: u8) !usize {
    if (buf.len < 9) return error.Malformed;
    buf[0] = OP_MOUSE_EVENT;
    std.mem.writeInt(i16, buf[1..3], row, .big);
    std.mem.writeInt(i16, buf[3..5], col, .big);
    buf[5] = button;
    buf[6] = modifiers;
    buf[7] = event_type;
    buf[8] = click_count;
    return 9;
}

/// Encodes a semantic GUI action with no payload.
pub fn encodeGuiAction(buf: []u8, action: u8) !usize {
    if (buf.len < 2) return error.Malformed;
    buf[0] = OP_GUI_ACTION;
    buf[1] = action;
    return 2;
}

/// Encodes a semantic GUI action with a u16 payload.
pub fn encodeGuiActionU16(buf: []u8, action: u8, value: u16) !usize {
    if (buf.len < 4) return error.Malformed;
    buf[0] = OP_GUI_ACTION;
    buf[1] = action;
    std.mem.writeInt(u16, buf[2..4], value, .big);
    return 4;
}

/// Encodes a semantic GUI action with a u32 payload.
pub fn encodeGuiActionU32(buf: []u8, action: u8, value: u32) !usize {
    if (buf.len < 6) return error.Malformed;
    buf[0] = OP_GUI_ACTION;
    buf[1] = action;
    std.mem.writeInt(u32, buf[2..6], value, .big);
    return 6;
}

/// Encodes fold_toggle_at_line: window_id:u16, buffer_line:u32.
pub fn encodeGuiActionFoldToggle(buf: []u8, window_id: u16, buffer_line: u32) !usize {
    if (buf.len < 8) return error.Malformed;
    buf[0] = OP_GUI_ACTION;
    buf[1] = GUI_ACTION_FOLD_TOGGLE_AT_LINE;
    std.mem.writeInt(u16, buf[2..4], window_id, .big);
    std.mem.writeInt(u32, buf[4..8], buffer_line, .big);
    return 8;
}

/// Encodes a paste_event into an allocator-owned buffer.
/// Layout: opcode(1) + text_len(2, big-endian) + text(text_len).
/// The text is UTF-8 encoded. Maximum text length is 65535 bytes (u16 max).
/// Returns the allocated slice containing the encoded message.
/// Caller owns the returned memory.
pub fn encodePasteEvent(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const text_len: u16 = @intCast(@min(text.len, std.math.maxInt(u16)));
    const total: usize = 1 + 2 + text_len;
    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_PASTE_EVENT;
    std.mem.writeInt(u16, buf[1..3], text_len, .big);
    @memcpy(buf[3..][0..text_len], text[0..text_len]);
    return buf;
}

/// Writes a length-prefixed message to the writer.
/// Adds a 4-byte big-endian length header before the payload.
pub fn writeMessage(writer: anytype, payload: []const u8) !void {
    const len: u32 = @intCast(payload.len);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, len, .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(payload);
}

// ── Encoding: highlight responses (Zig → BEAM) ──

/// Encodes highlight_spans: opcode(1) + buffer_id(4) + version(4) + count(4) + spans(count * 14)
/// Each span: start_byte:u32, end_byte:u32, capture_id:u16, pattern_index:u16, layer:u16
pub fn encodeHighlightSpans(allocator: std.mem.Allocator, buffer_id: u32, version: u32, spans: []const Span) ![]u8 {
    const header_size = 1 + 4 + 4 + 4; // opcode + buffer_id + version + count
    const span_size = 14; // 4 + 4 + 2 + 2 + 2
    const total = header_size + spans.len * span_size;
    const buf = try allocator.alloc(u8, total);

    buf[0] = OP_HIGHLIGHT_SPANS;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u32, buf[5..9], version, .big);
    std.mem.writeInt(u32, buf[9..13], @intCast(spans.len), .big);

    for (spans, 0..) |span, i| {
        const off = header_size + i * span_size;
        std.mem.writeInt(u32, buf[off..][0..4], span.start_byte, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], span.end_byte, .big);
        std.mem.writeInt(u16, buf[off + 8 ..][0..2], span.capture_id, .big);
        std.mem.writeInt(u16, buf[off + 10 ..][0..2], span.pattern_index, .big);
        std.mem.writeInt(u16, buf[off + 12 ..][0..2], span.layer, .big);
    }

    return buf;
}

/// Encodes conceal_spans: opcode(1) + buffer_id(4) + version(4) + count(4) +
/// (start_byte:4 + end_byte:4 + replacement_len:2 + replacement) for each.
pub fn encodeConcealSpans(
    allocator: std.mem.Allocator,
    buffer_id: u32,
    version: u32,
    spans: []const @import("highlighter.zig").ConcealSpan,
) ![]u8 {
    const header_size = 1 + 4 + 4 + 4; // opcode + buffer_id + version + count
    var total: usize = header_size;
    for (spans) |span| {
        total += 4 + 4 + 2 + span.replacement.len; // start + end + rep_len + rep
    }

    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_CONCEAL_SPANS;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u32, buf[5..9], version, .big);
    std.mem.writeInt(u32, buf[9..13], @intCast(spans.len), .big);

    var off: usize = header_size;
    for (spans) |span| {
        std.mem.writeInt(u32, buf[off..][0..4], span.start_byte, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], span.end_byte, .big);
        std.mem.writeInt(u16, buf[off + 8 ..][0..2], @intCast(span.replacement.len), .big);
        @memcpy(buf[off + 10 .. off + 10 + span.replacement.len], span.replacement);
        off += 10 + span.replacement.len;
    }

    return buf;
}

/// Encodes highlight_names: opcode(1) + buffer_id(4) + count(2) + (name_len:2 + name) for each
pub fn encodeHighlightNames(allocator: std.mem.Allocator, buffer_id: u32, names: []const []const u8) ![]u8 {
    var total: usize = 1 + 4 + 2; // opcode + buffer_id + count
    for (names) |name| {
        total += 2 + name.len;
    }

    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_HIGHLIGHT_NAMES;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u16, buf[5..7], @intCast(names.len), .big);

    var off: usize = 7;
    for (names) |name| {
        std.mem.writeInt(u16, buf[off..][0..2], @intCast(name.len), .big);
        @memcpy(buf[off + 2 .. off + 2 + name.len], name);
        off += 2 + name.len;
    }

    return buf;
}

/// Encodes document_symbols: opcode(1) + buffer_id(4) + version(4) + count(4) + entries.
/// Each entry: kind(1) + name_len(2) + name + start_row(4) + start_col(4) + end_row(4) + end_col(4).
pub fn encodeDocumentSymbols(allocator: std.mem.Allocator, buffer_id: u32, version: u32, symbols: []const DocumentSymbol) ![]u8 {
    const header_size = 1 + 4 + 4 + 4;
    var total: usize = header_size;
    for (symbols) |symbol| {
        total += 1 + 2 + @min(symbol.name.len, std.math.maxInt(u16)) + 4 + 4 + 4 + 4;
    }

    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_DOCUMENT_SYMBOLS;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u32, buf[5..9], version, .big);
    std.mem.writeInt(u32, buf[9..13], @intCast(symbols.len), .big);

    var off: usize = header_size;
    for (symbols) |symbol| {
        const name_len: u16 = @intCast(@min(symbol.name.len, std.math.maxInt(u16)));
        const name_len_usize: usize = @intCast(name_len);
        buf[off] = symbol.kind;
        std.mem.writeInt(u16, buf[off + 1 ..][0..2], name_len, .big);
        @memcpy(buf[off + 3 .. off + 3 + name_len_usize], symbol.name[0..name_len_usize]);
        off += 3 + name_len_usize;
        std.mem.writeInt(u32, buf[off..][0..4], symbol.start_row, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], symbol.start_col, .big);
        std.mem.writeInt(u32, buf[off + 8 ..][0..4], symbol.end_row, .big);
        std.mem.writeInt(u32, buf[off + 12 ..][0..4], symbol.end_col, .big);
        off += 16;
    }

    return buf;
}

/// Encodes grammar_loaded: opcode(1) + success:u8 + name_len:2 + name
pub fn encodeGrammarLoaded(buf: []u8, success: bool, name: []const u8) !usize {
    const total = 4 + name.len;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_GRAMMAR_LOADED;
    buf[1] = if (success) 1 else 0;
    std.mem.writeInt(u16, buf[2..4], @intCast(name.len), .big);
    @memcpy(buf[4 .. 4 + name.len], name);
    return total;
}

/// Encodes request_reparse: opcode(1) + buffer_id:u32
/// Wire format: `<0x3B, buffer_id:32>`
/// Sent when the parser detects stale edit deltas and needs the BEAM
/// to resend the full buffer content via parse_buffer.
pub fn encodeRequestReparse(buf: []u8, buffer_id: u32) !usize {
    const total = 5;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_REQUEST_REPARSE;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    return total;
}

/// Encodes log_message: opcode(1) + level:u8 + msg_len:u16 + msg
/// Wire format: `<0x60, level:8, msg_len:16, msg:binary>`
pub fn encodeLogMessage(buf: []u8, level: u8, msg: []const u8) !usize {
    const msg_len = @min(msg.len, std.math.maxInt(u16));
    const total = 4 + msg_len;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_LOG_MESSAGE;
    buf[1] = level;
    std.mem.writeInt(u16, buf[2..4], @intCast(msg_len), .big);
    @memcpy(buf[4 .. 4 + msg_len], msg[0..msg_len]);
    return total;
}

// ── Decoding (BEAM → Zig) ──

/// Decodes a render command from a binary payload.
pub fn decodeCommand(data: []const u8) DecodeError!RenderCommand {
    if (data.len == 0) return error.Malformed;

    const opcode = data[0];
    const rest = data[1..];

    switch (opcode) {
        OP_BEGIN_FRAME => {
            if (rest.len < 12) return error.Malformed;
            return .begin_frame;
        },
        OP_COMMIT_FRAME => {
            if (rest.len < 8) return error.Malformed;
            return .commit_frame;
        },
        OP_SET_CURSOR_SHAPE => {
            if (rest.len < 1) return error.Malformed;
            switch (rest[0]) {
                inline CURSOR_BLOCK, CURSOR_BEAM, CURSOR_UNDERLINE => |v| return .{ .set_cursor_shape = @enumFromInt(v) },
                else => return error.Malformed,
            }
        },
        OP_SET_TITLE => {
            if (rest.len < 2) return error.Malformed;
            const title_len = std.mem.readInt(u16, rest[0..2], .big);
            if (rest.len < 2 + title_len) return error.Malformed;
            return .{ .set_title = rest[2 .. 2 + title_len] };
        },
        OP_SET_WINDOW_BG => {
            // r:1, g:1, b:1 = 3 bytes. Sets the default bg for cells with bg=0.
            if (rest.len < 3) return error.Malformed;
            const rgb: u24 = @as(u24, rest[0]) << 16 | @as(u24, rest[1]) << 8 | @as(u24, rest[2]);
            return .{ .set_default_bg = rgb };
        },
        OP_SET_LANGUAGE => {
            // buffer_id:4, name_len:2, name
            if (rest.len < 6) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const name_len = std.mem.readInt(u16, rest[4..6], .big);
            if (rest.len < 6 + name_len) return error.Malformed;
            return .{ .set_language = .{
                .buffer_id = buffer_id,
                .name = rest[6 .. 6 + name_len],
            } };
        },
        OP_PARSE_BUFFER => {
            // buffer_id:4, version:4, source_len:4, source
            if (rest.len < 12) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const version = std.mem.readInt(u32, rest[4..8], .big);
            const source_len = std.mem.readInt(u32, rest[8..12], .big);
            if (rest.len < 12 + source_len) return error.Malformed;
            return .{ .parse_buffer = .{
                .buffer_id = buffer_id,
                .version = version,
                .source = rest[12 .. 12 + source_len],
            } };
        },
        OP_SET_HIGHLIGHT_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_highlight_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_SET_INJECTION_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_injection_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_SET_FOLD_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_fold_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_SET_INDENT_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_indent_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_REQUEST_INDENT => {
            // buffer_id:4, request_id:4, line:4
            if (rest.len < 12) return error.Malformed;
            return .{ .request_indent = .{
                .buffer_id = std.mem.readInt(u32, rest[0..4], .big),
                .request_id = std.mem.readInt(u32, rest[4..8], .big),
                .line = std.mem.readInt(u32, rest[8..12], .big),
            } };
        },
        OP_SET_TEXTOBJECT_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_textobject_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_REQUEST_TEXTOBJECT => {
            // buffer_id:4, request_id:4, row:4, col:4, name_len:2, name
            if (rest.len < 18) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const name_len = std.mem.readInt(u16, rest[16..18], .big);
            if (rest.len < 18 + name_len) return error.Malformed;
            return .{ .request_textobject = .{
                .buffer_id = buffer_id,
                .request_id = std.mem.readInt(u32, rest[4..8], .big),
                .row = std.mem.readInt(u32, rest[8..12], .big),
                .col = std.mem.readInt(u32, rest[12..16], .big),
                .capture_name = rest[18 .. 18 + name_len],
            } };
        },
        OP_REQUEST_MATCH_ITEM => {
            // buffer_id:4, request_id:4, row:4, col:4
            if (rest.len < 16) return error.Malformed;
            return .{ .request_match_item = .{
                .buffer_id = std.mem.readInt(u32, rest[0..4], .big),
                .request_id = std.mem.readInt(u32, rest[4..8], .big),
                .row = std.mem.readInt(u32, rest[8..12], .big),
                .col = std.mem.readInt(u32, rest[12..16], .big),
            } };
        },
        OP_REQUEST_STRUCTURAL_NAV => {
            // buffer_id:4, request_id:4, row:4, col:4, action:1
            if (rest.len < 17) return error.Malformed;
            return .{ .request_structural_nav = .{
                .buffer_id = std.mem.readInt(u32, rest[0..4], .big),
                .request_id = std.mem.readInt(u32, rest[4..8], .big),
                .row = std.mem.readInt(u32, rest[8..12], .big),
                .col = std.mem.readInt(u32, rest[12..16], .big),
                .action = try decodeStructuralNavAction(rest[16]),
            } };
        },
        OP_SET_TAGS_QUERY => {
            // buffer_id:4, query_len:4, query
            if (rest.len < 8) return error.Malformed;
            const buffer_id = std.mem.readInt(u32, rest[0..4], .big);
            const query_len = std.mem.readInt(u32, rest[4..8], .big);
            if (rest.len < 8 + query_len) return error.Malformed;
            return .{ .set_tags_query = .{
                .buffer_id = buffer_id,
                .source = rest[8 .. 8 + query_len],
            } };
        },
        OP_LOAD_GRAMMAR => {
            // name_len:2, name, path_len:2, path
            if (rest.len < 2) return error.Malformed;
            const name_len = std.mem.readInt(u16, rest[0..2], .big);
            if (rest.len < 2 + name_len + 2) return error.Malformed;
            const name = rest[2 .. 2 + name_len];
            const path_off = 2 + name_len;
            const path_len = std.mem.readInt(u16, rest[path_off..][0..2], .big);
            if (rest.len < path_off + 2 + path_len) return error.Malformed;
            return .{ .load_grammar = .{
                .name = name,
                .path = rest[path_off + 2 .. path_off + 2 + path_len],
            } };
        },
        OP_QUERY_LANGUAGE_AT => {
            // buffer_id:4, request_id:4, byte_offset:4
            if (rest.len < 12) return error.Malformed;
            return .{ .query_language_at = .{
                .buffer_id = std.mem.readInt(u32, rest[0..4], .big),
                .request_id = std.mem.readInt(u32, rest[4..8], .big),
                .byte_offset = std.mem.readInt(u32, rest[8..12], .big),
            } };
        },
        OP_EDIT_BUFFER => {
            // Variable-length command. Decoded via decodeEditBuffer() with an allocator.
            // Here we just validate the header and return the buffer_id + version + empty edits.
            if (rest.len < 10) return error.Malformed;
            return .{ .edit_buffer = .{
                .buffer_id = std.mem.readInt(u32, rest[0..4], .big),
                .version = std.mem.readInt(u32, rest[4..8], .big),
                .edits = &.{},
            } };
        },
        OP_CLOSE_BUFFER => {
            // buffer_id:4
            if (rest.len < 4) return error.Malformed;
            return .{ .close_buffer = std.mem.readInt(u32, rest[0..4], .big) };
        },
        OP_MEASURE_TEXT => {
            // request_id:4, text_len:2, text
            if (rest.len < 6) return error.Malformed;
            const request_id = std.mem.readInt(u32, rest[0..4], .big);
            const text_len = std.mem.readInt(u16, rest[4..6], .big);
            if (rest.len < 6 + text_len) return error.Malformed;
            return .{ .measure_text = .{
                .request_id = request_id,
                .text = rest[6 .. 6 + text_len],
            } };
        },
        OP_SET_FONT => {
            // size:2, weight:1, ligatures:1, name_len:2 = 6 bytes after opcode
            if (rest.len < 6) return error.Malformed;
            const name_len = std.mem.readInt(u16, rest[4..6], .big);
            if (rest.len < 6 + name_len) return error.Malformed;
            // TUI ignores font config.
            return .noop;
        },
        OP_REGISTER_FONT => {
            // font_id:1, name_len:2, name:bytes
            if (rest.len < 3) return error.Malformed;
            const name_len = std.mem.readInt(u16, rest[1..3], .big);
            if (rest.len < 3 + name_len) return error.Malformed;
            // TUI ignores font registration.
            return .noop;
        },
        OP_SET_FONT_FALLBACK => {
            // count:1, then count * (name_len:2, name:bytes)
            if (rest.len < 1) return error.Malformed;
            const count = rest[0];
            var offset: usize = 1;
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (rest.len < offset + 2) return error.Malformed;
                const name_len: usize = std.mem.readInt(u16, rest[offset..][0..2], .big);
                offset += 2 + name_len;
                if (rest.len < offset) return error.Malformed;
            }
            // TUI ignores font fallback.
            return .noop;
        },
        else => switch (generated_command_size.commandSize(data).status) {
            .sized, .custom => return .noop,
            .incomplete => return error.Malformed,
            .unknown => return error.UnknownOpcode,
        },
    }
}

fn decodeStructuralNavAction(action: u8) !StructuralNavAction {
    return switch (action) {
        0 => .parent,
        1 => .first_child,
        2 => .next_sibling,
        3 => .prev_sibling,
        else => error.Malformed,
    };
}

/// Returns the byte size of the first command in `payload`.
///
/// Used when iterating a batch message containing multiple concatenated
/// commands.  The caller advances its offset by this value after decoding
/// each command.
///
/// Fixed sizes:
///   0x10 begin_frame:     13 bytes (opcode + frame_seq:4 + base_frame_seq:4 + generation:4)
///   0x11 commit_frame:     9 bytes (opcode + frame_seq:4 + input_seq:4)
///   0x15 set_cursor_shape: 2 bytes (opcode + shape:1)
pub fn commandSize(payload: []const u8) usize {
    if (payload.len == 0) return 0;

    const generated = generated_command_size.commandSize(payload);
    return switch (generated.status) {
        .sized => generated.size,
        .custom => customCommandSize(payload),
        .incomplete => payload.len,
        .unknown => parserCommandSize(payload) orelse 1,
    };
}

fn customCommandSize(payload: []const u8) usize {
    if (payload.len == 0) return 0;
    const decoded_size = switch (payload[0]) {
        OP_SET_FONT => blk: {
            // opcode(1) + size(2) + weight(1) + ligatures(1) + name_len(2) + name
            if (payload.len < 7) break :blk payload.len;
            const name_len: usize = std.mem.readInt(u16, payload[5..7], .big);
            break :blk 7 + name_len;
        },
        OP_REGISTER_FONT => blk: {
            // opcode(1) + font_id(1) + name_len(2) + name
            if (payload.len < 4) break :blk payload.len;
            const name_len: usize = std.mem.readInt(u16, payload[2..4], .big);
            break :blk 4 + name_len;
        },
        OP_SET_FONT_FALLBACK => blk: {
            // opcode(1) + count(1), then count * (name_len:2, name:bytes)
            if (payload.len < 2) break :blk payload.len;
            const count = payload[1];
            var offset: usize = 2;
            var i: u8 = 0;
            while (i < count) : (i += 1) {
                if (payload.len < offset + 2) break :blk payload.len;
                const name_len: usize = std.mem.readInt(u16, payload[offset..][0..2], .big);
                offset += 2 + name_len;
            }
            break :blk offset;
        },
        OP_GUI_TAB_BAR => guiTabBarSize(payload),
        OP_GUI_WHICH_KEY => guiWhichKeySize(payload),
        OP_GUI_COMPLETION => guiCompletionSize(payload),
        OP_GUI_THEME => guiThemeSize(payload),
        OP_GUI_BREADCRUMB => guiBreadcrumbSize(payload),
        OP_GUI_FILE_TREE => len32CommandSize(payload),
        OP_GUI_FILE_TREE_SELECTION => len16CommandSize(payload),
        OP_GUI_GUTTER => sectionedGuiSize(payload),
        OP_GUI_INDENT_GUIDES => len16CommandSize(payload),
        OP_GUI_WINDOW_CONTENT => len32CommandSize(payload),
        OP_GUI_WINDOW_OVERLAY_DELTA => guiWindowOverlayDeltaSize(payload),
        OP_GUI_WINDOW_VIEWPORT_DELTA => sectionedGuiSize(payload),
        OP_GUI_WINDOW_ROWS_DELTA => sectionedGuiSize(payload),
        OP_GUI_PICKER => sectionedGuiSize(payload),
        OP_GUI_PICKER_PREVIEW => guiPickerPreviewSize(payload),
        OP_GUI_HOVER_POPUP => guiHoverPopupSize(payload),
        OP_GUI_SIGNATURE_HELP => guiSignatureHelpSize(payload),
        OP_GUI_FLOAT_POPUP => guiFloatPopupSize(payload),
        OP_GUI_GIT_STATUS => guiGitStatusSize(payload),
        OP_GUI_BOTTOM_PANEL => guiBottomPanelSize(payload),
        OP_GUI_SPLIT_SEPARATORS => guiSplitSeparatorsSize(payload),
        OP_GUI_SEARCH_STATE => len16CommandSize(payload),
        OP_GUI_CHANGE_SUMMARY => guiChangeSummarySize(payload),
        OP_GUI_NOTIFICATIONS => len16CommandSize(payload),
        OP_GUI_EDIT_TIMELINE => len16CommandSize(payload),
        OP_GUI_EXTENSION_OVERLAY => len16CommandSize(payload),
        OP_GUI_EXTENSION_PANEL => len16CommandSize(payload),
        OP_GUI_OBSERVATORY => len32CommandSize(payload),
        OP_GUI_SIDEBARS => len32CommandSize(payload),
        OP_GUI_AGENT_CONTEXT => guiAgentContextSize(payload),
        OP_GUI_CURSORLINE => fixedCommandSize(payload, 6),
        OP_GUI_GUTTER_SEP => fixedCommandSize(payload, 6),
        OP_GUI_LINE_SPACING => len16CommandSize(payload),
        OP_GUI_CURSOR_ANIMATION => len16CommandSize(payload),
        OP_GUI_CONFIG_STATE => len16CommandSize(payload),
        OP_GUI_HOVER_ACTION => len16CommandSize(payload),
        OP_GUI_AGENT_CHAT => sectionedGuiSize(payload),
        OP_GUI_MINIBUFFER => guiMinibufferSize(payload),
        OP_GUI_WORKSPACES => len16CommandSize(payload),
        else => parserCommandSize(payload) orelse 1,
    };
    return @min(decoded_size, payload.len);
}

fn guiTabBarSize(payload: []const u8) usize {
    if (payload.len < 3) return payload.len;
    const count = payload[2];
    var offset: usize = 3;
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        if (payload.len < offset + 8) return payload.len;
        const icon_len: usize = payload[offset + 7];
        offset += 8;
        if (payload.len < offset + icon_len + 2) return payload.len;
        offset += icon_len;
        const label_len: usize = std.mem.readInt(u16, payload[offset..][0..2], .big);
        offset += 2;
        if (payload.len < offset + label_len + 4) return payload.len;
        offset += label_len + 4;
    }
    return offset;
}

fn fixedCommandSize(payload: []const u8, size: usize) usize {
    return if (payload.len < size) payload.len else size;
}

fn guiWhichKeySize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;

    var offset: usize = 2;
    _ = readString16Size(payload, &offset) orelse return payload.len;
    if (payload.len < offset + 4) return payload.len;
    offset += 2;
    const binding_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var i: u16 = 0;
    while (i < binding_count) : (i += 1) {
        if (payload.len < offset + 1) return payload.len;
        offset += 1;
        if (!readString8Size(payload, &offset)) return payload.len;
        _ = readString16Size(payload, &offset) orelse return payload.len;
        if (!readString8Size(payload, &offset)) return payload.len;
    }

    return offset;
}

fn guiCompletionSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;
    if (payload.len < 10) return payload.len;

    var offset: usize = 8;
    const item_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var i: u16 = 0;
    while (i < item_count) : (i += 1) {
        if (payload.len < offset + 1) return payload.len;
        offset += 1;
        _ = readString16Size(payload, &offset) orelse return payload.len;
        _ = readString16Size(payload, &offset) orelse return payload.len;
    }

    // Trailing selected-item documentation (string16), present whenever
    // visible == 1 (#2322). Skipping it would desync every following
    // command in the batch.
    _ = readString16Size(payload, &offset) orelse return payload.len;

    return offset;
}

fn guiThemeSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    return @min(2 + @as(usize, payload[1]) * 4, payload.len);
}

fn guiChangeSummarySize(payload: []const u8) usize {
    if (payload.len < 6) return payload.len;
    const count = std.mem.readInt(u16, payload[4..][0..2], .big);
    var offset: usize = 6;
    var index: u16 = 0;
    while (index < count) : (index += 1) {
        _ = readString16Size(payload, &offset) orelse return payload.len;
        if (payload.len < offset + 9) return payload.len;
        offset += 9;
    }
    return offset;
}

fn guiAgentContextSize(payload: []const u8) usize {
    if (payload.len < 4) return payload.len;
    const task_len: usize = std.mem.readInt(u16, payload[2..][0..2], .big);
    return @min(4 + task_len + 10, payload.len);
}

fn guiBreadcrumbSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;

    var offset: usize = 2;
    var i: u8 = 0;
    while (i < payload[1]) : (i += 1) {
        _ = readString16Size(payload, &offset) orelse return payload.len;
    }

    return offset;
}

fn sectionedGuiSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;

    var offset: usize = 2;
    var i: u8 = 0;
    while (i < payload[1]) : (i += 1) {
        if (payload.len < offset + 3) return payload.len;
        const section_len: usize = std.mem.readInt(u16, payload[offset + 1 ..][0..2], .big);
        offset += 3;
        if (payload.len < offset + section_len) return payload.len;
        offset += section_len;
    }

    return offset;
}

fn guiWindowOverlayDeltaSize(payload: []const u8) usize {
    if (payload.len < 13) return payload.len;
    var offset: usize = 13;
    if (payload[7] & 0x02 != 0) {
        if (payload.len < offset + 5) return payload.len;
        offset += 5;
    }
    return offset;
}

fn len32CommandSize(payload: []const u8) usize {
    if (payload.len < 5) return payload.len;
    const payload_len: usize = std.mem.readInt(u32, payload[1..][0..4], .big);
    return @min(5 + payload_len, payload.len);
}

fn len16CommandSize(payload: []const u8) usize {
    if (payload.len < 3) return payload.len;
    const payload_len: usize = std.mem.readInt(u16, payload[1..][0..2], .big);
    return @min(3 + payload_len, payload.len);
}

fn guiPickerPreviewSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;
    if (payload.len < 4) return payload.len;

    var offset: usize = 2;
    const line_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var line_index: u16 = 0;
    while (line_index < line_count) : (line_index += 1) {
        if (payload.len < offset + 1) return payload.len;
        const segment_count = payload[offset];
        offset += 1;

        var segment_index: u8 = 0;
        while (segment_index < segment_count) : (segment_index += 1) {
            if (payload.len < offset + 4) return payload.len;
            offset += 4;
            _ = readString16Size(payload, &offset) orelse return payload.len;
        }
    }

    return offset;
}

fn guiHoverPopupSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;
    if (payload.len < 11) return payload.len;

    var offset: usize = 9;
    const line_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var line_index: u16 = 0;
    while (line_index < line_count) : (line_index += 1) {
        if (payload.len < offset + 3) return payload.len;
        offset += 1;
        const segment_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
        offset += 2;

        var segment_index: u16 = 0;
        while (segment_index < segment_count) : (segment_index += 1) {
            if (payload.len < offset + 1) return payload.len;
            const style = payload[offset];
            offset += 1;
            if (style == 13) {
                if (payload.len < offset + 4) return payload.len;
                offset += 4;
            }
            _ = readString16Size(payload, &offset) orelse return payload.len;
        }
    }

    return offset;
}

fn guiSignatureHelpSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;
    if (payload.len < 9) return payload.len;

    var offset: usize = 8;
    const signature_count = payload[offset];
    offset += 1;

    var signature_index: u8 = 0;
    while (signature_index < signature_count) : (signature_index += 1) {
        _ = readString16Size(payload, &offset) orelse return payload.len;
        _ = readString16Size(payload, &offset) orelse return payload.len;
        if (payload.len < offset + 1) return payload.len;
        const parameter_count = payload[offset];
        offset += 1;

        var parameter_index: u8 = 0;
        while (parameter_index < parameter_count) : (parameter_index += 1) {
            _ = readString16Size(payload, &offset) orelse return payload.len;
            _ = readString16Size(payload, &offset) orelse return payload.len;
        }
    }

    return offset;
}

fn guiFloatPopupSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;
    if (payload.len < 8) return payload.len;

    var offset: usize = 6;
    _ = readString16Size(payload, &offset) orelse return payload.len;
    if (payload.len < offset + 2) return payload.len;
    const line_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var line_index: u16 = 0;
    while (line_index < line_count) : (line_index += 1) {
        _ = readString16Size(payload, &offset) orelse return payload.len;
    }

    return offset;
}

fn guiGitStatusSize(payload: []const u8) usize {
    if (payload.len < 9) return payload.len;

    var offset: usize = 7;
    _ = readString16Size(payload, &offset) orelse return payload.len;
    if (payload.len < offset + 2) return payload.len;
    const entry_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var entry_index: u16 = 0;
    while (entry_index < entry_count) : (entry_index += 1) {
        if (payload.len < offset + 6) return payload.len;
        offset += 6;
        _ = readString16Size(payload, &offset) orelse return payload.len;
    }

    if (payload.len < offset + 1) return payload.len;
    if (payload[offset] == 0) {
        offset += 1;
    } else {
        if (payload.len < offset + 3) return payload.len;
        offset += 3;
        _ = readString16Size(payload, &offset) orelse return payload.len;
    }

    _ = readString16Size(payload, &offset) orelse return payload.len;
    _ = readString16Size(payload, &offset) orelse return payload.len;
    if (payload.len < offset + 2) return payload.len;
    return offset + 2;
}

fn guiBottomPanelSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;
    if (payload.len < 6) return payload.len;

    var offset: usize = 6;
    const tab_count = payload[5];
    var tab_index: u8 = 0;
    while (tab_index < tab_count) : (tab_index += 1) {
        if (payload.len < offset + 1) return payload.len;
        offset += 1;
        if (!readString8Size(payload, &offset)) return payload.len;
    }

    if (payload.len < offset + 6) return payload.len;
    const entry_count = std.mem.readInt(u16, payload[offset + 4 ..][0..2], .big);
    offset += 6;

    var entry_index: u16 = 0;
    while (entry_index < entry_count) : (entry_index += 1) {
        if (payload.len < offset + 10) return payload.len;
        offset += 10;
        _ = readString16Size(payload, &offset) orelse return payload.len;
        _ = readString16Size(payload, &offset) orelse return payload.len;
    }

    return offset;
}

fn guiSplitSeparatorsSize(payload: []const u8) usize {
    if (payload.len < 5) return payload.len;

    const vertical_count = payload[4];
    var offset: usize = 5 + @as(usize, vertical_count) * 6;
    if (payload.len < offset + 1) return payload.len;
    const horizontal_count = payload[offset];
    offset += 1;

    var horizontal_index: u8 = 0;
    while (horizontal_index < horizontal_count) : (horizontal_index += 1) {
        if (payload.len < offset + 6) return payload.len;
        offset += 6;
        _ = readString16Size(payload, &offset) orelse return payload.len;
    }

    return offset;
}

fn guiMinibufferSize(payload: []const u8) usize {
    if (payload.len < 2) return payload.len;
    if (payload[1] == 0) return 2;
    if (payload.len < 8) return payload.len;

    var offset: usize = 5;
    const prompt_len: usize = payload[offset];
    offset += 1;
    if (payload.len < offset + prompt_len + 2) return payload.len;
    offset += prompt_len;

    const input_len: usize = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;
    if (payload.len < offset + input_len + 2) return payload.len;
    offset += input_len;

    const context_len: usize = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;
    if (payload.len < offset + context_len + 6) return payload.len;
    offset += context_len + 2;

    const candidate_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 4;

    var i: u16 = 0;
    while (i < candidate_count) : (i += 1) {
        if (payload.len < offset + 1) return payload.len;
        offset += 1;
        const label_len = readString16Size(payload, &offset) orelse return payload.len;
        _ = label_len;
        const description_len = readString16Size(payload, &offset) orelse return payload.len;
        _ = description_len;
        const annotation_len = readString16Size(payload, &offset) orelse return payload.len;
        _ = annotation_len;
        if (payload.len < offset + 1) return payload.len;
        const match_count: usize = payload[offset];
        offset += 1;
        if (payload.len < offset + match_count * 2) return payload.len;
        offset += match_count * 2;
    }

    return offset;
}

fn readString8Size(payload: []const u8, offset: *usize) bool {
    if (payload.len < offset.* + 1) return false;
    const len: usize = payload[offset.*];
    offset.* += 1;
    if (payload.len < offset.* + len) return false;
    offset.* += len;
    return true;
}

fn readString16Size(payload: []const u8, offset: *usize) ?usize {
    if (payload.len < offset.* + 2) return null;
    const len: usize = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    if (payload.len < offset.* + len) return null;
    offset.* += len;
    return len;
}

fn parserCommandSize(payload: []const u8) ?usize {
    if (payload.len == 0) return 0;
    const decoded_size = switch (payload[0]) {
        OP_SET_LANGUAGE => blk: {
            // opcode(1) + buffer_id(4) + name_len(2) + name
            if (payload.len < 7) break :blk payload.len;
            const name_len: usize = std.mem.readInt(u16, payload[5..7], .big);
            break :blk 7 + name_len;
        },
        OP_PARSE_BUFFER => blk: {
            // opcode(1) + buffer_id(4) + version(4) + source_len(4) + source
            if (payload.len < 13) break :blk payload.len;
            const source_len: usize = std.mem.readInt(u32, payload[9..13], .big);
            break :blk 13 + source_len;
        },
        OP_SET_HIGHLIGHT_QUERY, OP_SET_INJECTION_QUERY, OP_SET_FOLD_QUERY, OP_SET_INDENT_QUERY, OP_SET_TEXTOBJECT_QUERY, OP_SET_TAGS_QUERY => blk: {
            // opcode(1) + buffer_id(4) + query_len(4) + query
            if (payload.len < 9) break :blk payload.len;
            const query_len: usize = std.mem.readInt(u32, payload[5..9], .big);
            break :blk 9 + query_len;
        },
        OP_LOAD_GRAMMAR => blk: {
            if (payload.len < 3) break :blk payload.len;
            const name_len: usize = std.mem.readInt(u16, payload[1..3], .big);
            const path_off: usize = 3 + name_len;
            if (payload.len < path_off + 2) break :blk payload.len;
            const path_len: usize = std.mem.readInt(u16, payload[path_off..][0..2], .big);
            break :blk path_off + 2 + path_len;
        },
        OP_QUERY_LANGUAGE_AT => 13, // opcode(1) + buffer_id(4) + request_id(4) + byte_offset(4)
        OP_REQUEST_INDENT => 13, // opcode(1) + buffer_id(4) + request_id(4) + line(4)
        OP_REQUEST_TEXTOBJECT => blk: {
            // opcode(1) + buffer_id(4) + request_id(4) + row(4) + col(4) + name_len(2) + name
            if (payload.len < 19) break :blk payload.len;
            const nl: usize = std.mem.readInt(u16, payload[17..19], .big);
            break :blk 19 + nl;
        },
        OP_REQUEST_MATCH_ITEM => 17, // opcode(1) + buffer_id(4) + request_id(4) + row(4) + col(4)
        OP_REQUEST_STRUCTURAL_NAV => 18, // opcode(1) + buffer_id(4) + request_id(4) + row(4) + col(4) + action(1)
        OP_CLOSE_BUFFER => 5, // opcode(1) + buffer_id(4)
        OP_EDIT_BUFFER => blk: {
            // opcode(1) + buffer_id(4) + version(4) + edit_count(2) + variable per edit
            if (payload.len < 11) break :blk payload.len;
            const edit_count = std.mem.readInt(u16, payload[9..11], .big);
            var off: usize = 11;
            for (0..edit_count) |_| {
                // 9 × u32 fields + text_len:u32 = 40 bytes header per edit
                if (off + 40 > payload.len) break :blk payload.len;
                const text_len: usize = std.mem.readInt(u32, payload[off + 36 ..][0..4], .big);
                off += 40 + text_len;
            }
            break :blk off;
        },
        OP_MEASURE_TEXT => blk: {
            if (payload.len < 7) break :blk payload.len;
            const text_len: usize = std.mem.readInt(u16, payload[5..7], .big);
            break :blk 7 + text_len;
        },
        else => return null,
    };
    return @min(decoded_size, payload.len);
}

/// Fully decodes an edit_buffer command payload (after the opcode byte).
/// Returns the buffer_id, version, and an allocated slice of EditDelta structs.
/// Caller owns the returned slice and must free it.
pub fn decodeEditBuffer(data: []const u8, alloc: std.mem.Allocator) !struct { buffer_id: u32, version: u32, edits: []EditDelta } {
    if (data.len < 10) return error.Malformed;
    const buffer_id = std.mem.readInt(u32, data[0..4], .big);
    const version = std.mem.readInt(u32, data[4..8], .big);
    const edit_count = std.mem.readInt(u16, data[8..10], .big);

    const edits = try alloc.alloc(EditDelta, edit_count);
    errdefer alloc.free(edits);

    var off: usize = 10;
    for (0..edit_count) |i| {
        if (off + 40 > data.len) return error.Malformed;
        edits[i] = .{
            .start_byte = std.mem.readInt(u32, data[off..][0..4], .big),
            .old_end_byte = std.mem.readInt(u32, data[off + 4 ..][0..4], .big),
            .new_end_byte = std.mem.readInt(u32, data[off + 8 ..][0..4], .big),
            .start_row = std.mem.readInt(u32, data[off + 12 ..][0..4], .big),
            .start_col = std.mem.readInt(u32, data[off + 16 ..][0..4], .big),
            .old_end_row = std.mem.readInt(u32, data[off + 20 ..][0..4], .big),
            .old_end_col = std.mem.readInt(u32, data[off + 24 ..][0..4], .big),
            .new_end_row = std.mem.readInt(u32, data[off + 28 ..][0..4], .big),
            .new_end_col = std.mem.readInt(u32, data[off + 32 ..][0..4], .big),
            .inserted_text = blk: {
                const text_len = std.mem.readInt(u32, data[off + 36 ..][0..4], .big);
                if (off + 40 + text_len > data.len) return error.Malformed;
                break :blk data[off + 40 .. off + 40 + text_len];
            },
        };
        const text_len = std.mem.readInt(u32, data[off + 36 ..][0..4], .big);
        off += 40 + text_len;
    }

    return .{ .buffer_id = buffer_id, .version = version, .edits = edits };
}

/// Encodes a text_width response: opcode(1) + request_id(4) + width(2) = 7 bytes.
pub fn encodeTextWidth(buf: []u8, request_id: u32, width: u16) !usize {
    if (buf.len < 7) return error.Malformed;
    buf[0] = OP_TEXT_WIDTH;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    std.mem.writeInt(u16, buf[5..7], width, .big);
    return 7;
}

/// Encodes a language_at_response: opcode(1) + request_id(4) + name_len(2) + name
pub fn encodeLanguageAtResponse(buf: []u8, request_id: u32, language: ?[]const u8) !usize {
    const name = language orelse "";
    const total = 7 + name.len;
    if (buf.len < total) return error.Malformed;
    buf[0] = OP_LANGUAGE_AT_RESPONSE;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    std.mem.writeInt(u16, buf[5..7], @intCast(name.len), .big);
    if (name.len > 0) {
        @memcpy(buf[7 .. 7 + name.len], name);
    }
    return total;
}

/// Encodes injection_ranges: opcode(1) + count(2) + (start_byte:4, end_byte:4, name_len:2, name) for each
pub fn encodeInjectionRanges(allocator: std.mem.Allocator, buffer_id: u32, ranges: []const InjectionRange) ![]u8 {
    var total: usize = 1 + 4 + 2; // opcode + buffer_id + count
    for (ranges) |r| {
        total += 4 + 4 + 2 + r.language.len;
    }
    const buf = try allocator.alloc(u8, total);
    buf[0] = OP_INJECTION_RANGES;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u16, buf[5..7], @intCast(ranges.len), .big);

    var off: usize = 7;
    for (ranges) |r| {
        std.mem.writeInt(u32, buf[off..][0..4], r.start_byte, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], r.end_byte, .big);
        std.mem.writeInt(u16, buf[off + 8 ..][0..2], @intCast(r.language.len), .big);
        @memcpy(buf[off + 10 .. off + 10 + r.language.len], r.language);
        off += 10 + r.language.len;
    }

    return buf;
}

/// A fold range for protocol encoding: start_line .. end_line (0-indexed).
pub const FoldRange = struct {
    start_line: u32,
    end_line: u32,
};

/// Encodes fold_ranges: opcode(1) + buffer_id(4) + version(4) + count(4) + (start_line:4, end_line:4) for each
pub fn encodeFoldRanges(allocator: std.mem.Allocator, buffer_id: u32, version: u32, ranges: []const FoldRange) ![]u8 {
    const header_size = 1 + 4 + 4 + 4; // opcode + buffer_id + version + count
    const range_size = 8; // start_line:4 + end_line:4
    const total = header_size + ranges.len * range_size;
    const buf = try allocator.alloc(u8, total);

    buf[0] = OP_FOLD_RANGES;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u32, buf[5..9], version, .big);
    std.mem.writeInt(u32, buf[9..13], @intCast(ranges.len), .big);

    for (ranges, 0..) |r, i| {
        const off = header_size + i * range_size;
        std.mem.writeInt(u32, buf[off..][0..4], r.start_line, .big);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], r.end_line, .big);
    }

    return buf;
}

/// Text object result (shared between protocol and highlighter).
pub const TextobjectResult = struct {
    start_row: u32,
    start_col: u32,
    end_row: u32,
    end_col: u32,
};

/// Encodes textobject_result: opcode(1) + request_id(4) + found(1) + start_row(4) + start_col(4) + end_row(4) + end_col(4) = 22 bytes
pub fn encodeTextobjectResult(buf: *[22]u8, request_id: u32, result: ?TextobjectResult) usize {
    buf[0] = OP_TEXTOBJECT_RESULT;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    if (result) |r| {
        buf[5] = 1; // found
        std.mem.writeInt(u32, buf[6..10], r.start_row, .big);
        std.mem.writeInt(u32, buf[10..14], r.start_col, .big);
        std.mem.writeInt(u32, buf[14..18], r.end_row, .big);
        std.mem.writeInt(u32, buf[18..22], r.end_col, .big);
        return 22;
    } else {
        buf[5] = 0; // not found
        return 6;
    }
}

/// Match item result (shared between protocol and highlighter).
pub const MatchItemResult = struct {
    row: u32,
    col: u32,
};

/// Encodes match_item_result: opcode(1) + request_id(4) + found(1) + row(4) + col(4) = 14 bytes
pub fn encodeMatchItemResult(buf: *[14]u8, request_id: u32, result: ?MatchItemResult) usize {
    buf[0] = OP_MATCH_ITEM_RESULT;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    if (result) |r| {
        buf[5] = 1;
        std.mem.writeInt(u32, buf[6..10], r.row, .big);
        std.mem.writeInt(u32, buf[10..14], r.col, .big);
        return 14;
    } else {
        buf[5] = 0;
        return 6;
    }
}

/// Structural navigation result (shared between protocol and highlighter).
pub const StructuralNavResult = struct {
    start_row: u32,
    start_col: u32,
    end_row: u32,
    end_col: u32,
    type_name: []const u8,
};

/// Encodes node_info: opcode(1) + request_id(4) + found(1) + start_row(4) + start_col(4) + end_row(4) + end_col(4) + type_len(2) + type
pub fn encodeNodeInfo(buf: *[280]u8, request_id: u32, result: ?StructuralNavResult) usize {
    buf[0] = OP_NODE_INFO;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    if (result) |r| {
        const type_len = @min(r.type_name.len, 255);
        buf[5] = 1;
        std.mem.writeInt(u32, buf[6..10], r.start_row, .big);
        std.mem.writeInt(u32, buf[10..14], r.start_col, .big);
        std.mem.writeInt(u32, buf[14..18], r.end_row, .big);
        std.mem.writeInt(u32, buf[18..22], r.end_col, .big);
        std.mem.writeInt(u16, buf[22..24], @intCast(type_len), .big);
        @memcpy(buf[24 .. 24 + type_len], r.type_name[0..type_len]);
        return 24 + type_len;
    } else {
        buf[5] = 0;
        return 6;
    }
}

/// A single textobject position for the proactive position cache.
pub const TextobjectEntry = struct {
    type_id: u8,
    row: u32,
    col: u32,
};

/// Encodes textobject_positions: opcode(1) + buffer_id(4) + version(4) + count(4) + [type_id(1) + row(4) + col(4)] * count
pub fn encodeTextobjectPositions(allocator: std.mem.Allocator, buffer_id: u32, version: u32, entries: []const TextobjectEntry) ![]u8 {
    const entry_size: usize = 9; // type_id(1) + row(4) + col(4)
    const header_size: usize = 13; // opcode(1) + buffer_id(4) + version(4) + count(4)
    const total_size = header_size + entries.len * entry_size;

    const buf = try allocator.alloc(u8, total_size);
    buf[0] = OP_TEXTOBJECT_POSITIONS;
    std.mem.writeInt(u32, buf[1..5], buffer_id, .big);
    std.mem.writeInt(u32, buf[5..9], version, .big);
    std.mem.writeInt(u32, buf[9..13], @intCast(entries.len), .big);

    var pos: usize = header_size;
    for (entries) |e| {
        buf[pos] = e.type_id;
        std.mem.writeInt(u32, buf[pos + 1 ..][0..4], e.row, .big);
        std.mem.writeInt(u32, buf[pos + 5 ..][0..4], e.col, .big);
        pos += entry_size;
    }

    return buf;
}

/// Encodes indent_result: opcode(1) + request_id(4) + line(4) + indent_level(4, signed)
pub fn encodeIndentResult(buf: *[13]u8, request_id: u32, line: u32, indent_level: i32) usize {
    buf[0] = OP_INDENT_RESULT;
    std.mem.writeInt(u32, buf[1..5], request_id, .big);
    std.mem.writeInt(u32, buf[5..9], line, .big);
    std.mem.writeInt(i32, buf[9..13], indent_level, .big);
    return 13;
}

/// Reads a 4-byte big-endian length header from the reader.
/// Returns the message length, or null on EOF.
pub fn readMessageLength(reader: anytype) !?u32 {
    var len_buf: [4]u8 = undefined;
    const bytes_read = try reader.readAll(&len_buf);
    if (bytes_read == 0) return null;
    if (bytes_read < 4) return error.Malformed;
    return std.mem.readInt(u32, &len_buf, .big);
}

// ── Tests ──

test "encode and verify key_press" {
    var buf: [6]u8 = undefined;
    const len = try encodeKeyPress(&buf, 97, 0); // 'a', no mods
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(@as(u8, OP_KEY_PRESS), buf[0]);
    try std.testing.expectEqual(@as(u32, 97), std.mem.readInt(u32, buf[1..5], .big));
    try std.testing.expectEqual(@as(u8, 0), buf[5]);
}

test "encode key_press with modifiers" {
    var buf: [6]u8 = undefined;
    const mods = MOD_CTRL | MOD_SHIFT;
    _ = try encodeKeyPress(&buf, 99, mods); // 'c' + ctrl + shift
    try std.testing.expectEqual(@as(u8, mods), buf[5]);
}

test "encode and verify ready" {
    var buf: [5]u8 = undefined;
    const len = try encodeReady(&buf, 80, 24);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(@as(u8, OP_READY), buf[0]);
    try std.testing.expectEqual(@as(u16, 80), std.mem.readInt(u16, buf[1..3], .big));
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, buf[3..5], .big));
}

test "encode and verify resize" {
    var buf: [5]u8 = undefined;
    _ = try encodeResize(&buf, 120, 40);
    try std.testing.expectEqual(@as(u8, OP_RESIZE), buf[0]);
}

test "decode generation-aware begin_frame command" {
    const data = [_]u8{ OP_BEGIN_FRAME, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 3 };
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .begin_frame);
}

test "reject legacy truncated begin_frame command" {
    const data = [_]u8{ OP_BEGIN_FRAME, 0, 0, 0, 7, 0, 0, 0, 0 };
    try std.testing.expectError(error.Malformed, decodeCommand(&data));
}

test "decode commit_frame command" {
    const data = [_]u8{ OP_COMMIT_FRAME, 0, 0, 0, 7, 0, 0, 0, 5 };
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .commit_frame);
}

test "decode set_window_bg as set_default_bg" {
    const data = [_]u8{ OP_SET_WINDOW_BG, 0x28, 0x2C, 0x34 };
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .set_default_bg);
    try std.testing.expectEqual(@as(u24, 0x282C34), cmd.set_default_bg);
}

test "decode set_window_bg truncated returns malformed" {
    const data = [_]u8{ OP_SET_WINDOW_BG, 0x28, 0x2C };
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode font config commands as noops" {
    const set_font = [_]u8{ OP_SET_FONT, 0x00, 0x0E, 0x04, 0x01, 0x00, 0x05 } ++ "Menlo".*;
    const register_font = [_]u8{ OP_REGISTER_FONT, 0x01, 0x00, 0x05 } ++ "Menlo".*;
    const set_fallback = [_]u8{ OP_SET_FONT_FALLBACK, 0x01, 0x00, 0x05 } ++ "Menlo".*;

    try std.testing.expect((try decodeCommand(&set_font)) == .noop);
    try std.testing.expect((try decodeCommand(&register_font)) == .noop);
    try std.testing.expect((try decodeCommand(&set_fallback)) == .noop);
}

test "decode set_cursor_shape block" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_BLOCK };
    const cmd = try decodeCommand(&data);
    try std.testing.expect(cmd == .set_cursor_shape);
    try std.testing.expectEqual(CursorShape.block, cmd.set_cursor_shape);
}

test "decode set_cursor_shape beam" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_BEAM };
    const cmd = try decodeCommand(&data);
    try std.testing.expectEqual(CursorShape.beam, cmd.set_cursor_shape);
}

test "decode set_cursor_shape underline" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_UNDERLINE };
    const cmd = try decodeCommand(&data);
    try std.testing.expectEqual(CursorShape.underline, cmd.set_cursor_shape);
}

test "decode set_cursor_shape truncated returns malformed" {
    const data = [_]u8{OP_SET_CURSOR_SHAPE}; // missing shape byte
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode set_cursor_shape invalid value returns malformed" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, 0xFF }; // invalid shape
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode gui_observatory as noop in TUI" {
    const data = [_]u8{ OP_GUI_OBSERVATORY, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03 };
    try std.testing.expect((try decodeCommand(&data)) == .noop);
}

test "decode gui_sidebars as noop in TUI" {
    const data = [_]u8{ OP_GUI_SIDEBARS, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03 };
    try std.testing.expect((try decodeCommand(&data)) == .noop);
}

test "all generated GUI render opcodes are accounted for by TUI semantic noops" {
    inline for (.{
        &[_]u8{ OP_GUI_TAB_BAR, 0, 0 },
        &[_]u8{ OP_GUI_WHICH_KEY, 0 },
        &[_]u8{ OP_GUI_COMPLETION, 0 },
        &[_]u8{ OP_GUI_THEME, 0 },
        &[_]u8{ OP_GUI_BREADCRUMB, 0 },
        &[_]u8{ OP_GUI_STATUS_BAR, 0 },
        &[_]u8{ OP_GUI_PICKER, 0 },
        &[_]u8{ OP_GUI_AGENT_CHAT, 0 },
        &[_]u8{ OP_GUI_GUTTER_SEP, 0, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_CURSORLINE, 0xFF, 0xFF, 0, 0, 0 },
        &[_]u8{ OP_GUI_GUTTER, 0 },
        &[_]u8{ OP_GUI_BOTTOM_PANEL, 0 },
        &[_]u8{ OP_GUI_PICKER_PREVIEW, 0 },
        &[_]u8{ OP_GUI_MINIBUFFER, 0 },
        &[_]u8{ OP_GUI_WINDOW_CONTENT, 0, 0, 0, 1, 0 },
        &[_]u8{ OP_GUI_HOVER_POPUP, 0 },
        &[_]u8{ OP_GUI_SIGNATURE_HELP, 0 },
        &[_]u8{ OP_GUI_FLOAT_POPUP, 0 },
        &[_]u8{ OP_GUI_SPLIT_SEPARATORS, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_GIT_STATUS, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_AGENT_CONTEXT, 0, 0 },
        &[_]u8{ OP_GUI_CHANGE_SUMMARY, 0 },
        &[_]u8{ OP_GUI_HOVER_ACTION, 0, 1, 0 },
        &[_]u8{ OP_GUI_CONFIG_STATE, 0, 0 },
        &[_]u8{ OP_GUI_WORKSPACES, 0, 6, 2, 0, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_NOTIFICATIONS, 0, 3, 0, 0, 0 },
        &[_]u8{ OP_GUI_OBSERVATORY, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_EDIT_TIMELINE, 0, 4, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_EXTENSION_OVERLAY, 0, 2, 0, 0 },
        &[_]u8{ OP_GUI_EXTENSION_PANEL, 0, 1, 0 },
        &[_]u8{ OP_GUI_EXTENSION_RUNTIME, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_SEARCH_STATE, 0, 6, 0, 0, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_SIDEBARS, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_WINDOW_OVERLAY_DELTA, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_WINDOW_VIEWPORT_DELTA, 0 },
        &[_]u8{ OP_GUI_WINDOW_ROWS_DELTA, 0 },
        &[_]u8{ OP_GUI_INDENT_GUIDES, 0, 6, 0, 1, 2, 0xFF, 0xFF, 0 },
        &[_]u8{ OP_GUI_LINE_SPACING, 0, 2, 0, 100 },
        &[_]u8{ OP_GUI_FILE_TREE, 0, 0, 0, 0 },
        &[_]u8{ OP_GUI_FILE_TREE_SELECTION, 0, 1, 0 },
        &[_]u8{ OP_GUI_CURSOR_ANIMATION, 0, 1, 0 },
    }) |packet| {
        try std.testing.expectEqual(packet.len, commandSize(packet));
        try std.testing.expect((try decodeCommand(packet)) == .noop);
    }
}

test "decode truncated gui_observatory returns malformed" {
    const data = [_]u8{ OP_GUI_OBSERVATORY, 0x00, 0x00, 0x00, 0x03, 0x01 };
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode truncated gui_sidebars returns malformed" {
    const data = [_]u8{ OP_GUI_SIDEBARS, 0x00, 0x00, 0x00, 0x03, 0x01 };
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode unknown opcode returns error" {
    const data = [_]u8{0x6F};
    const result = decodeCommand(&data);
    try std.testing.expectError(error.UnknownOpcode, result);
}

test "decode empty data returns malformed" {
    const result = decodeCommand(&[_]u8{});
    try std.testing.expectError(error.Malformed, result);
}

// ── Encoding: buffer too small ────────────────────────────────────────────────

// ── Mouse event encoding ──────────────────────────────────────────────────────

test "encodeMouseEvent byte layout: left click press at (5, 10)" {
    var buf: [9]u8 = undefined;
    const len = try encodeMouseEvent(&buf, 5, 10, MOUSE_LEFT, 0, MOUSE_PRESS, 1);
    try std.testing.expectEqual(@as(usize, 9), len);
    try std.testing.expectEqual(OP_MOUSE_EVENT, buf[0]);
    try std.testing.expectEqual(@as(i16, 5), std.mem.readInt(i16, buf[1..3], .big));
    try std.testing.expectEqual(@as(i16, 10), std.mem.readInt(i16, buf[3..5], .big));
    try std.testing.expectEqual(MOUSE_LEFT, buf[5]);
    try std.testing.expectEqual(@as(u8, 0), buf[6]);
    try std.testing.expectEqual(MOUSE_PRESS, buf[7]);
    try std.testing.expectEqual(@as(u8, 1), buf[8]);
}

test "encodeMouseEvent with click_count 2 (double-click)" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, MOUSE_PRESS, 2);
    try std.testing.expectEqual(@as(u8, 2), buf[8]);
}

test "encodeMouseEvent with wheel_up" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_WHEEL_UP, 0, MOUSE_PRESS, 1);
    try std.testing.expectEqual(MOUSE_WHEEL_UP, buf[5]);
}

test "encodeMouseEvent with wheel_down" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_WHEEL_DOWN, 0, MOUSE_PRESS, 1);
    try std.testing.expectEqual(MOUSE_WHEEL_DOWN, buf[5]);
}

test "encodeMouseEvent with drag event type" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 8, 15, MOUSE_LEFT, 0, MOUSE_DRAG, 1);
    try std.testing.expectEqual(MOUSE_DRAG, buf[7]);
}

test "encodeMouseEvent with release event type" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, MOUSE_RELEASE, 1);
    try std.testing.expectEqual(MOUSE_RELEASE, buf[7]);
}

test "encodeMouseEvent with modifiers" {
    var buf: [9]u8 = undefined;
    const mods = MOD_CTRL | MOD_SHIFT;
    _ = try encodeMouseEvent(&buf, 2, 4, MOUSE_LEFT, mods, MOUSE_PRESS, 1);
    try std.testing.expectEqual(mods, buf[6]);
}

test "encodeMouseEvent with negative coordinates" {
    var buf: [9]u8 = undefined;
    _ = try encodeMouseEvent(&buf, -1, -5, MOUSE_LEFT, 0, MOUSE_PRESS, 1);
    try std.testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, buf[1..3], .big));
    try std.testing.expectEqual(@as(i16, -5), std.mem.readInt(i16, buf[3..5], .big));
}

test "encodeMouseEvent buffer too small returns error" {
    var buf: [8]u8 = undefined; // needs 9
    const result = encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, MOUSE_PRESS, 1);
    try std.testing.expectError(error.Malformed, result);
}

test "encodeMouseEvent all button types" {
    var buf: [9]u8 = undefined;
    const buttons = [_]u8{ MOUSE_LEFT, MOUSE_MIDDLE, MOUSE_RIGHT, MOUSE_NONE, MOUSE_WHEEL_UP, MOUSE_WHEEL_DOWN, MOUSE_WHEEL_RIGHT, MOUSE_WHEEL_LEFT };
    for (buttons) |b| {
        _ = try encodeMouseEvent(&buf, 0, 0, b, 0, MOUSE_PRESS, 1);
        try std.testing.expectEqual(b, buf[5]);
    }
}

test "encodeMouseEvent all event types" {
    var buf: [9]u8 = undefined;
    const types = [_]u8{ MOUSE_PRESS, MOUSE_RELEASE, MOUSE_MOTION, MOUSE_DRAG };
    for (types) |t| {
        _ = try encodeMouseEvent(&buf, 0, 0, MOUSE_LEFT, 0, t, 1);
        try std.testing.expectEqual(t, buf[7]);
    }
}

test "encodeKeyPress buffer too small returns error" {
    var buf: [5]u8 = undefined; // needs 6
    const result = encodeKeyPress(&buf, 65, 0);
    try std.testing.expectError(error.Malformed, result);
}

test "encodeReady buffer too small returns error" {
    var buf: [4]u8 = undefined; // needs 5
    const result = encodeReady(&buf, 80, 24);
    try std.testing.expectError(error.Malformed, result);
}

test "encodeResize buffer too small returns error" {
    var buf: [4]u8 = undefined; // needs 5
    const result = encodeResize(&buf, 80, 24);
    try std.testing.expectError(error.Malformed, result);
}

// ── Encoding: paste event ─────────────────────────────────────────────────────

test "encodePasteEvent basic text" {
    const allocator = std.testing.allocator;
    const text = "hello\nworld\nline 3";
    const buf = try encodePasteEvent(allocator, text);
    defer allocator.free(buf);

    // opcode
    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    // text_len (big-endian u16)
    const text_len = std.mem.readInt(u16, buf[1..3], .big);
    try std.testing.expectEqual(@as(u16, @intCast(text.len)), text_len);
    // text payload
    try std.testing.expectEqualStrings(text, buf[3..]);
}

test "encodePasteEvent empty text" {
    const allocator = std.testing.allocator;
    const buf = try encodePasteEvent(allocator, "");
    defer allocator.free(buf);

    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    const text_len = std.mem.readInt(u16, buf[1..3], .big);
    try std.testing.expectEqual(@as(u16, 0), text_len);
    try std.testing.expectEqual(@as(usize, 3), buf.len);
}

test "encodePasteEvent unicode text" {
    const allocator = std.testing.allocator;
    const text = "こんにちは\n🎉 emoji\n中文";
    const buf = try encodePasteEvent(allocator, text);
    defer allocator.free(buf);

    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    const text_len = std.mem.readInt(u16, buf[1..3], .big);
    try std.testing.expectEqual(@as(u16, @intCast(text.len)), text_len);
    try std.testing.expectEqualStrings(text, buf[3..]);
}

test "encodePasteEvent single line (no newline)" {
    const allocator = std.testing.allocator;
    const text = "just a single line paste";
    const buf = try encodePasteEvent(allocator, text);
    defer allocator.free(buf);

    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    try std.testing.expectEqualStrings(text, buf[3..]);
}

test "encodePasteEvent large text (near u16 max)" {
    const allocator = std.testing.allocator;
    // Create a text just under the u16 max (65535 bytes)
    const large_text = try allocator.alloc(u8, 60000);
    defer allocator.free(large_text);
    @memset(large_text, 'A');
    // Add some newlines for realism
    large_text[100] = '\n';
    large_text[200] = '\n';
    large_text[300] = '\n';

    const buf = try encodePasteEvent(allocator, large_text);
    defer allocator.free(buf);

    try std.testing.expectEqual(OP_PASTE_EVENT, buf[0]);
    const text_len = std.mem.readInt(u16, buf[1..3], .big);
    try std.testing.expectEqual(@as(u16, 60000), text_len);
    try std.testing.expectEqualSlices(u8, large_text, buf[3..]);
}

// ── Encoding: special values ──────────────────────────────────────────────────

test "encodeKeyPress with max unicode codepoint (0x10FFFF)" {
    var buf: [6]u8 = undefined;
    const len = try encodeKeyPress(&buf, 0x10FFFF, 0);
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(@as(u8, OP_KEY_PRESS), buf[0]);
    try std.testing.expectEqual(@as(u32, 0x10FFFF), std.mem.readInt(u32, buf[1..5], .big));
    try std.testing.expectEqual(@as(u8, 0), buf[5]);
}

test "encodeKeyPress with all modifier flags combined" {
    var buf: [6]u8 = undefined;
    const all_mods = MOD_SHIFT | MOD_CTRL | MOD_ALT | MOD_SUPER;
    const len = try encodeKeyPress(&buf, 65, all_mods);
    try std.testing.expectEqual(@as(usize, 6), len);
    try std.testing.expectEqual(all_mods, buf[5]);
}

test "encodeReady with large terminal dimensions (500x200)" {
    var buf: [5]u8 = undefined;
    const len = try encodeReady(&buf, 500, 200);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(@as(u8, OP_READY), buf[0]);
    try std.testing.expectEqual(@as(u16, 500), std.mem.readInt(u16, buf[1..3], .big));
    try std.testing.expectEqual(@as(u16, 200), std.mem.readInt(u16, buf[3..5], .big));
}

test "encodeResize with minimum dimensions (1x1)" {
    var buf: [5]u8 = undefined;
    const len = try encodeResize(&buf, 1, 1);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(@as(u8, OP_RESIZE), buf[0]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[1..3], .big));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[3..5], .big));
}

// ── writeMessage ──────────────────────────────────────────────────────────────

test "writeMessage writes correct 4-byte big-endian length prefix" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeMessage(&aw.writer, "hello");
    const written = aw.written();
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, written[0..4], .big));
    try std.testing.expectEqualSlices(u8, "hello", written[4..9]);
}

test "writeMessage with empty payload writes length 0" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeMessage(&aw.writer, "");
    const written = aw.written();
    try std.testing.expectEqual(@as(usize, 4), written.len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, written[0..4], .big));
}

// ── readMessageLength ─────────────────────────────────────────────────────────

const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readAll(self: *SliceReader, buf: []u8) !usize {
        const available = self.data[self.pos..];
        const n = @min(buf.len, available.len);
        @memcpy(buf[0..n], available[0..n]);
        self.pos += n;
        return n;
    }
};

test "readMessageLength returns correct value for known bytes" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x2A };
    var reader = SliceReader{ .data = &data };
    const result = try readMessageLength(&reader);
    try std.testing.expectEqual(@as(?u32, 42), result);
}

test "readMessageLength returns null on EOF (empty reader)" {
    var reader = SliceReader{ .data = &.{} };
    const result = try readMessageLength(&reader);
    try std.testing.expectEqual(@as(?u32, null), result);
}

// ── Round-trip / byte-position verification ───────────────────────────────────

test "encodeKeyPress byte layout: each position verified" {
    var buf: [6]u8 = undefined;
    _ = try encodeKeyPress(&buf, 0x0001F600, MOD_CTRL | MOD_ALT); // 😀, ctrl+alt
    // [0] opcode
    try std.testing.expectEqual(OP_KEY_PRESS, buf[0]);
    // [1..4] codepoint big-endian
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[2]);
    try std.testing.expectEqual(@as(u8, 0xF6), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[4]);
    // [5] modifiers
    try std.testing.expectEqual(MOD_CTRL | MOD_ALT, buf[5]);
}

// ── commandSize ──────────────────────────────────────────────────────────────

test "commandSize: commit_frame is 9 bytes when complete" {
    const data = [_]u8{ OP_COMMIT_FRAME, 0, 0, 0, 7, 0, 0, 0, 5 };
    try std.testing.expectEqual(@as(usize, 9), commandSize(&data));
}

test "commandSize: generation-aware begin_frame is 13 bytes when complete" {
    const data = [_]u8{ OP_BEGIN_FRAME, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 3 };
    try std.testing.expectEqual(@as(usize, 13), commandSize(&data));
}

test "commandSize: fixed-size commands clamp to available payload" {
    const data = [_]u8{OP_CLOSE_BUFFER};
    try std.testing.expectEqual(@as(usize, 1), commandSize(&data));
}

test "commandSize: set_cursor_shape is 2 bytes" {
    const data = [_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_BLOCK };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_tab_bar custom packet" {
    const data = [_]u8{
        OP_GUI_TAB_BAR, 0,    1,
        0x01,           0,    0,
        0,              1,    0,
        0,              1,    'e',
        0,              7,    'm',
        'a',            'i',  'n',
        '.',            'e',  'x',
        0x11,           0x22, 0x33,
        0x44,
    };
    try std.testing.expectEqual(data.len, commandSize(&data));
}

test "commandSize: gui_which_key custom packet" {
    const data = [_]u8{
        OP_GUI_WHICH_KEY, 1,
        0,                3,
        'S',              'P',
        'C',              0,
        2,                0,
        1,                0,
        1,                'f',
        0,                4,
        'f',              'i',
        'l',              'e',
        0,
    };
    try std.testing.expectEqual(data.len, commandSize(&data));
}

test "commandSize: hidden gui_which_key is two bytes" {
    const data = [_]u8{ OP_GUI_WHICH_KEY, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_completion custom packet" {
    const data = [_]u8{
        OP_GUI_COMPLETION, 1,
        0,                 4,
        0,                 12,
        0,                 1,
        0,                 2,
        1,                 0,
        5,                 'w',
        'r',               'i',
        't',               'e',
        0,                 9,
        'S',               'a',
        'v',               'e',
        ' ',               'f',
        'i',               'l',
        'e',               5,
        0,                 5,
        'M',               'i',
        'n',               'g',
        'a',               0,
        6,                 'm',
        'o',               'd',
        'u',               'l',
        'e',               0,
        4,                 'd',
        'o',               'c',
        's',               OP_COMMIT_FRAME,
    };
    // The trailing OP_COMMIT_FRAME sentinel proves the sizer stops exactly
    // after the selected-item documentation tail (#2322) rather than falling
    // back to payload.len on truncation.
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: hidden gui_completion is two bytes" {
    const data = [_]u8{ OP_GUI_COMPLETION, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_theme custom packet" {
    const data = [_]u8{
        OP_GUI_THEME,    2,
        0x40,            0x11,
        0x22,            0x33,
        0x30,            0x44,
        0x55,            0x66,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_breadcrumb custom packet" {
    const data = [_]u8{
        OP_GUI_BREADCRUMB, 3,
        0,                 3,
        'l',               'i',
        'b',               0,
        5,                 'm',
        'i',               'n',
        'g',               'a',
        0,                 9,
        'e',               'd',
        'i',               't',
        'o',               'r',
        '.',               'e',
        'x',               OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: empty gui_breadcrumb is two bytes" {
    const data = [_]u8{ OP_GUI_BREADCRUMB, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_file_tree len32 packet" {
    const data = [_]u8{
        OP_GUI_FILE_TREE, 0, 0, 0,               3,
        2,                0, 0, OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_file_tree_selection len16 packet" {
    const data = [_]u8{
        OP_GUI_FILE_TREE_SELECTION, 0,               4,
        1,                          0,               1,
        'a',                        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_gutter sectioned packet" {
    const data = [_]u8{
        OP_GUI_GUTTER,   1,
        0x01,            0,
        11,              0,
        7,               0,
        1,               0,
        0,               0,
        2,               1,
        0,               4,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_indent_guides len16 packet" {
    const data = [_]u8{
        OP_GUI_INDENT_GUIDES, 0,    6,
        0,                    7,    2,
        0xFF,                 0xFF, 0,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_workspaces len16 packet" {
    const data = [_]u8{
        OP_GUI_WORKSPACES, 0, 6,
        2,                 0, 7,
        0,                 0, 0,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_picker sectioned packet" {
    const data = [_]u8{
        OP_GUI_PICKER,   5,
        0x01,            0,
        17,              1,
        0,               0,
        0,               1,
        0,               2,
        0,               0,
        5,               'F',
        'i',             'l',
        'e',             's',
        0,               1,
        0x02,            0,
        5,               0,
        3,               's',
        'r',             'c',
        0x03,            0,
        31,              0,
        1,               0x11,
        0x22,            0x33,
        0x02,            0,
        7,               'm',
        'a',             'i',
        'n',             '.',
        'e',             'x',
        0,               3,
        'l',             'i',
        'b',             0,
        8,               'm',
        'o',             'd',
        'i',             'f',
        'i',             'e',
        'd',             0,
        0x05,            0,
        3,               0,
        1,               '>',
        0x06,            0,
        1,               0,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: hidden gui_picker is two bytes" {
    const data = [_]u8{ OP_GUI_PICKER, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_picker_preview packet" {
    const data = [_]u8{
        OP_GUI_PICKER_PREVIEW, 1,
        0,                     1,
        1,                     0x11,
        0x22,                  0x33,
        1,                     0,
        7,                     'p',
        'r',                   'e',
        'v',                   'i',
        'e',                   'w',
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: hidden gui_picker_preview is two bytes" {
    const data = [_]u8{ OP_GUI_PICKER_PREVIEW, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_hover_popup packet" {
    const data = [_]u8{
        OP_GUI_HOVER_POPUP, 1,
        0,                  3,
        0,                  9,
        1,                  0,
        2,                  0,
        1,                  0,
        0,                  2,
        1,                  0,
        4,                  'B',
        'o',                'l',
        'd',                13,
        0x11,               0x22,
        0x33,               1,
        0,                  4,
        'C',                'o',
        'd',                'e',
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: hidden gui_hover_popup is two bytes" {
    const data = [_]u8{ OP_GUI_HOVER_POPUP, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_signature_help packet" {
    const data = [_]u8{
        OP_GUI_SIGNATURE_HELP, 1,
        0,                     2,
        0,                     3,
        0,                     1,
        1,                     0,
        8,                     'f',
        'o',                   'o',
        '(',                   'a',
        ',',                   'b',
        ')',                   0,
        4,                     'd',
        'o',                   'c',
        's',                   2,
        0,                     1,
        'a',                   0,
        5,                     'f',
        'i',                   'r',
        's',                   't',
        0,                     1,
        'b',                   0,
        6,                     's',
        'e',                   'c',
        'o',                   'n',
        'd',                   OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: hidden gui_signature_help is two bytes" {
    const data = [_]u8{ OP_GUI_SIGNATURE_HELP, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_float_popup packet" {
    const data = [_]u8{
        OP_GUI_FLOAT_POPUP, 1,
        0,                  24,
        0,                  5,
        0,                  5,
        'H',                'e',
        'l',                'l',
        'o',                0,
        2,                  0,
        5,                  'l',
        'i',                'n',
        'e',                '1',
        0,                  5,
        'l',                'i',
        'n',                'e',
        '2',                OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: hidden gui_float_popup is two bytes" {
    const data = [_]u8{ OP_GUI_FLOAT_POPUP, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_git_status packet" {
    const data = [_]u8{
        OP_GUI_GIT_STATUS, 0,
        1,                 0,
        2,                 0,
        1,                 0,
        4,                 'm',
        'a',               'i',
        'n',               0,
        1,                 0x11,
        0x22,              0x33,
        0x44,              1,
        6,                 0,
        8,                 'l',
        'i',               'b',
        '/',               'a',
        '.',               'e',
        'x',               1,
        0,                 1,
        0,                 6,
        'p',               'u',
        's',               'h',
        'e',               'd',
        0,                 3,
        'l',               'i',
        'b',               0,
        6,                 'c',
        'o',               'm',
        'm',               'i',
        't',               0,
        2,                 OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: minimal gui_git_status packet" {
    const data = [_]u8{
        OP_GUI_GIT_STATUS, 0,
        0,                 0,
        0,                 0,
        0,                 0,
        0,                 0,
        0,                 0,
        0,                 0,
        0,                 0,
        0,                 0,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_bottom_panel packet" {
    const data = [_]u8{
        OP_GUI_BOTTOM_PANEL, 1,
        1,                   30,
        2,                   2,
        1,                   4,
        'L',                 'o',
        'g',                 's',
        2,                   5,
        'T',                 'e',
        's',                 't',
        's',                 0,
        0,                   0,
        7,                   0,
        1,                   0,
        0,                   0,
        7,                   3,
        4,                   0,
        0,                   0,
        42,                  0,
        8,                   'l',
        'i',                 'b',
        '/',                 'a',
        '.',                 'e',
        'x',                 0,
        4,                   'b',
        'o',                 'o',
        'm',                 OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: hidden gui_bottom_panel is two bytes" {
    const data = [_]u8{ OP_GUI_BOTTOM_PANEL, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(@as(usize, 2), commandSize(&data));
}

test "commandSize: gui_window_content len32 packet" {
    const data = [_]u8{
        OP_GUI_WINDOW_CONTENT, 0,
        0,                     0,
        20,                    1,
        0x01,                  0,
        0,                     0,
        14,                    0,
        7,                     0x02,
        0,                     1,
        0,                     2,
        0,                     0,
        0,                     0,
        0,                     0,
        9,                     OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_window_rows_delta sectioned packet" {
    const data = [_]u8{
        OP_GUI_WINDOW_ROWS_DELTA, 1,
        0x01,                     0,
        0,                        0,
        14,                       0,
        7,                        0,
        0,                        0,
        9,                        0x01,
        0,                        3,
        0,                        4,
        2,                        0,
        1,                        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_window_overlay_delta with cursorline" {
    const data = [_]u8{
        OP_GUI_WINDOW_OVERLAY_DELTA,
        0,
        7,
        0,
        0,
        0,
        9,
        0x03,
        0,
        3,
        0,
        4,
        2,
        0,
        1,
        0x12,
        0x34,
        0x56,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_split_separators packet" {
    const data = [_]u8{
        OP_GUI_SPLIT_SEPARATORS, 0x11,
        0x22,                    0x33,
        1,                       0,
        4,                       0,
        1,                       0,
        3,                       1,
        0,                       2,
        0,                       0,
        0,                       8,
        0,                       7,
        'm',                     'a',
        'i',                     'n',
        '.',                     'e',
        'x',                     OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: empty gui_split_separators packet" {
    const data = [_]u8{ OP_GUI_SPLIT_SEPARATORS, 0, 0, 0, 0, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_search_state len16 packet" {
    const data = [_]u8{ OP_GUI_SEARCH_STATE, 0, 6, 1, 0, 5, 0, 3, 0x0F, OP_COMMIT_FRAME };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_change_summary custom packet" {
    const data = [_]u8{
        OP_GUI_CHANGE_SUMMARY,
        1,
        0,
        0,
        0,
        1,
        0,
        8,
        'l',
        'i',
        'b',
        '/',
        'a',
        '.',
        'e',
        'x',
        1,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
        2,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_notifications len16 packet" {
    const data = [_]u8{ OP_GUI_NOTIFICATIONS, 0, 3, 1, 0, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: gui_edit_timeline len16 packet" {
    const data = [_]u8{ OP_GUI_EDIT_TIMELINE, 0, 4, 1, 0, 0, 0, OP_COMMIT_FRAME };
    try std.testing.expectEqual(data.len - 1, commandSize(&data));
}

test "commandSize: extension footer summary packets" {
    const overlay = [_]u8{ OP_GUI_EXTENSION_OVERLAY, 0, 1, 2, OP_COMMIT_FRAME };
    const panel = [_]u8{ OP_GUI_EXTENSION_PANEL, 0, 1, 3, OP_COMMIT_FRAME };
    const observatory = [_]u8{ OP_GUI_OBSERVATORY, 0, 0, 0, 6, 0x01, 0, 3, 1, 0, 4, OP_COMMIT_FRAME };
    try std.testing.expectEqual(overlay.len - 1, commandSize(&overlay));
    try std.testing.expectEqual(panel.len - 1, commandSize(&panel));
    try std.testing.expectEqual(observatory.len - 1, commandSize(&observatory));
}

test "commandSize: agent context custom packet" {
    const context = [_]u8{
        OP_GUI_AGENT_CONTEXT,
        1,
        0,
        6,
        'R',
        'e',
        'v',
        'i',
        'e',
        'w',
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        42,
        1,
        1,
        OP_COMMIT_FRAME,
    };
    try std.testing.expectEqual(context.len - 1, commandSize(&context));
}

test "commandSize: small retained semantic state packets" {
    const cursorline = [_]u8{ OP_GUI_CURSORLINE, 0, 2, 0x11, 0x22, 0x33, OP_COMMIT_FRAME };
    const separator = [_]u8{ OP_GUI_GUTTER_SEP, 0, 7, 0x44, 0x55, 0x66, OP_COMMIT_FRAME };
    const spacing = [_]u8{ OP_GUI_LINE_SPACING, 0, 2, 0, 120, OP_COMMIT_FRAME };
    const animation = [_]u8{ OP_GUI_CURSOR_ANIMATION, 0, 1, 0, OP_COMMIT_FRAME };
    const config = [_]u8{ OP_GUI_CONFIG_STATE, 0, 3, 1, 2, 3, OP_COMMIT_FRAME };
    const hover = [_]u8{ OP_GUI_HOVER_ACTION, 0, 4, 1, 0, 1, 'x', OP_COMMIT_FRAME };

    try std.testing.expectEqual(cursorline.len - 1, commandSize(&cursorline));
    try std.testing.expectEqual(separator.len - 1, commandSize(&separator));
    try std.testing.expectEqual(spacing.len - 1, commandSize(&spacing));
    try std.testing.expectEqual(animation.len - 1, commandSize(&animation));
    try std.testing.expectEqual(config.len - 1, commandSize(&config));
    try std.testing.expectEqual(hover.len - 1, commandSize(&hover));
}

test "commandSize: agent chat packet" {
    const chat = [_]u8{
        OP_GUI_AGENT_CHAT, 1,
        0x01,              0,
        2,                 1,
        2,                 OP_COMMIT_FRAME,
    };

    try std.testing.expectEqual(chat.len - 1, commandSize(&chat));
}

test "commandSize: gui_minibuffer custom packet" {
    const data = [_]u8{
        OP_GUI_MINIBUFFER, 1,
        0,                 0,
        3,                 1,
        ':',               0,
        5,                 'w',
        'r',               'i',
        't',               'e',
        0,                 0,
        0,                 0,
        0,                 0,
        0,                 0,
    };
    try std.testing.expectEqual(data.len, commandSize(&data));
}

test "commandSize: truncated variable-size commands clamp to available payload" {
    const data = [_]u8{ OP_SET_FONT_FALLBACK, 0x01, 0xFF, 0xFF };
    try std.testing.expectEqual(@as(usize, data.len), commandSize(&data));
}

test "commandSize: gui_observatory uses forward-compatible envelope" {
    const data = [_]u8{ OP_GUI_OBSERVATORY, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03 };
    try std.testing.expectEqual(@as(usize, data.len), commandSize(&data));
}

test "commandSize: gui_extension_runtime uses forward-compatible envelope" {
    const data = [_]u8{ OP_GUI_EXTENSION_RUNTIME, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03 };
    try std.testing.expectEqual(@as(usize, data.len), commandSize(&data));
}

test "commandSize: gui_sidebars uses forward-compatible envelope" {
    const data = [_]u8{ OP_GUI_SIDEBARS, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03 };
    try std.testing.expectEqual(@as(usize, data.len), commandSize(&data));
}

test "commandSize: truncated gui_observatory clamps to available payload" {
    const data = [_]u8{ OP_GUI_OBSERVATORY, 0x00 };
    try std.testing.expectEqual(@as(usize, data.len), commandSize(&data));
}

test "commandSize: truncated gui_sidebars clamps to available payload" {
    const data = [_]u8{ OP_GUI_SIDEBARS, 0x00 };
    try std.testing.expectEqual(@as(usize, data.len), commandSize(&data));
}

test "commandSize: unknown opcode returns 1" {
    const data = [_]u8{0xFE};
    try std.testing.expectEqual(@as(usize, 1), commandSize(&data));
}

test "commandSize: empty payload returns 0" {
    try std.testing.expectEqual(@as(usize, 0), commandSize(&[_]u8{}));
}

test "batch decode: transport survivors parse with correct sizing" {
    // Concatenated batch of surviving transport opcodes:
    // set_cursor_shape(2) + set_window_bg(4) + commit_frame(9) = 15 bytes (#2219).
    const payload = [_]u8{
        OP_SET_CURSOR_SHAPE, CURSOR_BLOCK,
        OP_SET_WINDOW_BG,    0x28,
        0x2C,                0x34,
        OP_COMMIT_FRAME,     0x00,
        0x00,                0x00,
        0x07,                0x00,
        0x00,                0x00,
        0x05,
    };

    var offset: usize = 0;
    var cmds: [3]RenderCommand = undefined;
    var count: usize = 0;

    while (offset < payload.len) {
        const remaining = payload[offset..];
        cmds[count] = try decodeCommand(remaining);
        count += 1;
        offset += commandSize(remaining);
    }

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(cmds[0] == .set_cursor_shape);
    try std.testing.expect(cmds[1] == .set_default_bg);
    try std.testing.expectEqual(@as(u24, 0x282C34), cmds[1].set_default_bg);
    try std.testing.expect(cmds[2] == .commit_frame);
}

test "encodeResize byte layout: self-consistent encoding" {
    var buf: [5]u8 = undefined;
    _ = try encodeResize(&buf, 0x0102, 0x0304);
    try std.testing.expectEqual(OP_RESIZE, buf[0]);
    // width = 0x0102 → [0x01, 0x02]
    try std.testing.expectEqual(@as(u8, 0x01), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[2]);
    // height = 0x0304 → [0x03, 0x04]
    try std.testing.expectEqual(@as(u8, 0x03), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x04), buf[4]);
    // Decode back the width and height directly from the bytes
    const width_back = std.mem.readInt(u16, buf[1..3], .big);
    const height_back = std.mem.readInt(u16, buf[3..5], .big);
    try std.testing.expectEqual(@as(u16, 0x0102), width_back);
    try std.testing.expectEqual(@as(u16, 0x0304), height_back);
}

// ── Highlight protocol tests ──────────────────────────────────────────────────

test "decode set_language" {
    // opcode(1) + buffer_id:4 + name_len:2 + "elixir"(6) = 13 bytes
    var data: [13]u8 = undefined;
    data[0] = OP_SET_LANGUAGE;
    std.mem.writeInt(u32, data[1..5], 7, .big); // buffer_id = 7
    std.mem.writeInt(u16, data[5..7], 6, .big); // name_len = 6
    @memcpy(data[7..13], "elixir");
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_language => |sl| {
            try std.testing.expectEqual(@as(u32, 7), sl.buffer_id);
            try std.testing.expectEqualStrings("elixir", sl.name);
        },
        else => return error.Malformed,
    }
}

test "decode set_language truncated returns malformed" {
    // opcode(1) + buffer_id:4 + name_len:2 + only 2 of 6 name bytes
    const data = [_]u8{ OP_SET_LANGUAGE, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06, 'e', 'l' };
    const result = decodeCommand(&data);
    try std.testing.expectError(error.Malformed, result);
}

test "decode parse_buffer" {
    // opcode(1) + buffer_id:4 + version:4 + source_len:4 + "hello"(5) = 18 bytes
    var data: [18]u8 = undefined;
    data[0] = OP_PARSE_BUFFER;
    std.mem.writeInt(u32, data[1..5], 3, .big); // buffer_id = 3
    std.mem.writeInt(u32, data[5..9], 1, .big); // version = 1
    std.mem.writeInt(u32, data[9..13], 5, .big); // source_len = 5
    @memcpy(data[13..18], "hello");
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .parse_buffer => |pb| {
            try std.testing.expectEqual(@as(u32, 3), pb.buffer_id);
            try std.testing.expectEqual(@as(u32, 1), pb.version);
            try std.testing.expectEqualStrings("hello", pb.source);
        },
        else => return error.Malformed,
    }
}

test "decode set_highlight_query" {
    const query = "(atom) @string";
    // opcode(1) + buffer_id(4) + query_len(4) + query
    var data: [1 + 4 + 4 + query.len]u8 = undefined;
    data[0] = OP_SET_HIGHLIGHT_QUERY;
    std.mem.writeInt(u32, data[1..5], 0, .big); // buffer_id = 0
    std.mem.writeInt(u32, data[5..9], query.len, .big);
    @memcpy(data[9..], query);
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_highlight_query => |shq| {
            try std.testing.expectEqualStrings(query, shq.source);
        },
        else => return error.Malformed,
    }
}

test "decode load_grammar" {
    // opcode + name_len:2 + "lua"(3) + path_len:2 + "/tmp/lua.so"(11)
    const data = [_]u8{ OP_LOAD_GRAMMAR, 0x00, 0x03 } ++ "lua".* ++ [_]u8{ 0x00, 0x0B } ++ "/tmp/lua.so".*;
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .load_grammar => |lg| {
            try std.testing.expectEqualStrings("lua", lg.name);
            try std.testing.expectEqualStrings("/tmp/lua.so", lg.path);
        },
        else => return error.Malformed,
    }
}

test "decode request_match_item" {
    var data: [17]u8 = undefined;
    data[0] = OP_REQUEST_MATCH_ITEM;
    std.mem.writeInt(u32, data[1..5], 7, .big);
    std.mem.writeInt(u32, data[5..9], 42, .big);
    std.mem.writeInt(u32, data[9..13], 3, .big);
    std.mem.writeInt(u32, data[13..17], 11, .big);

    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .request_match_item => |req| {
            try std.testing.expectEqual(@as(u32, 7), req.buffer_id);
            try std.testing.expectEqual(@as(u32, 42), req.request_id);
            try std.testing.expectEqual(@as(u32, 3), req.row);
            try std.testing.expectEqual(@as(u32, 11), req.col);
        },
        else => return error.Malformed,
    }
}

test "encode match_item_result" {
    var found_buf: [14]u8 = undefined;
    const found_len = encodeMatchItemResult(&found_buf, 42, .{ .row = 9, .col = 4 });
    try std.testing.expectEqual(@as(usize, 14), found_len);
    try std.testing.expectEqual(@as(u8, OP_MATCH_ITEM_RESULT), found_buf[0]);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, found_buf[1..5], .big));
    try std.testing.expectEqual(@as(u8, 1), found_buf[5]);
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, found_buf[6..10], .big));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, found_buf[10..14], .big));

    var empty_buf: [14]u8 = undefined;
    const empty_len = encodeMatchItemResult(&empty_buf, 43, null);
    try std.testing.expectEqual(@as(usize, 6), empty_len);
    try std.testing.expectEqual(@as(u8, OP_MATCH_ITEM_RESULT), empty_buf[0]);
    try std.testing.expectEqual(@as(u32, 43), std.mem.readInt(u32, empty_buf[1..5], .big));
    try std.testing.expectEqual(@as(u8, 0), empty_buf[5]);
}

test "decode request_structural_nav" {
    var data: [18]u8 = undefined;
    data[0] = OP_REQUEST_STRUCTURAL_NAV;
    std.mem.writeInt(u32, data[1..5], 7, .big);
    std.mem.writeInt(u32, data[5..9], 42, .big);
    std.mem.writeInt(u32, data[9..13], 3, .big);
    std.mem.writeInt(u32, data[13..17], 11, .big);
    data[17] = 2;

    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .request_structural_nav => |req| {
            try std.testing.expectEqual(@as(u32, 7), req.buffer_id);
            try std.testing.expectEqual(@as(u32, 42), req.request_id);
            try std.testing.expectEqual(@as(u32, 3), req.row);
            try std.testing.expectEqual(@as(u32, 11), req.col);
            try std.testing.expectEqual(StructuralNavAction.next_sibling, req.action);
        },
        else => return error.Malformed,
    }
}

test "decode request_structural_nav rejects invalid actions" {
    var data: [18]u8 = undefined;
    data[0] = OP_REQUEST_STRUCTURAL_NAV;
    std.mem.writeInt(u32, data[1..5], 7, .big);
    std.mem.writeInt(u32, data[5..9], 42, .big);
    std.mem.writeInt(u32, data[9..13], 3, .big);
    std.mem.writeInt(u32, data[13..17], 11, .big);
    data[17] = 4;

    try std.testing.expectError(error.Malformed, decodeCommand(&data));
}

test "encode node_info" {
    var found_buf: [280]u8 = undefined;
    const found_len = encodeNodeInfo(&found_buf, 42, .{
        .start_row = 1,
        .start_col = 2,
        .end_row = 3,
        .end_col = 4,
        .type_name = "call_expression",
    });
    try std.testing.expectEqual(@as(usize, 39), found_len);
    try std.testing.expectEqual(@as(u8, OP_NODE_INFO), found_buf[0]);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, found_buf[1..5], .big));
    try std.testing.expectEqual(@as(u8, 1), found_buf[5]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, found_buf[6..10], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, found_buf[10..14], .big));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, found_buf[14..18], .big));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, found_buf[18..22], .big));
    try std.testing.expectEqual(@as(u16, 15), std.mem.readInt(u16, found_buf[22..24], .big));
    try std.testing.expectEqualStrings("call_expression", found_buf[24..39]);

    var empty_buf: [280]u8 = undefined;
    const empty_len = encodeNodeInfo(&empty_buf, 43, null);
    try std.testing.expectEqual(@as(usize, 6), empty_len);
    try std.testing.expectEqual(@as(u8, OP_NODE_INFO), empty_buf[0]);
    try std.testing.expectEqual(@as(u32, 43), std.mem.readInt(u32, empty_buf[1..5], .big));
    try std.testing.expectEqual(@as(u8, 0), empty_buf[5]);
}

test "commandSize: set_language" {
    // opcode(1) + buffer_id(4) + name_len(2) + "elixir"(6) = 13 bytes
    var data: [13]u8 = undefined;
    data[0] = OP_SET_LANGUAGE;
    std.mem.writeInt(u32, data[1..5], 0, .big);
    std.mem.writeInt(u16, data[5..7], 6, .big);
    @memcpy(data[7..13], "elixir");
    try std.testing.expectEqual(@as(usize, 13), commandSize(&data));
}

test "commandSize: parse_buffer" {
    // opcode(1) + buffer_id(4) + version(4) + source_len(4) + "abc"(3) = 16 bytes
    var data: [16]u8 = undefined;
    data[0] = OP_PARSE_BUFFER;
    std.mem.writeInt(u32, data[1..5], 0, .big); // buffer_id
    std.mem.writeInt(u32, data[5..9], 1, .big); // version
    std.mem.writeInt(u32, data[9..13], 3, .big); // source_len
    @memcpy(data[13..16], "abc");
    try std.testing.expectEqual(@as(usize, 16), commandSize(&data));
}

test "commandSize: set_highlight_query" {
    // opcode(1) + buffer_id(4) + query_len(4) + "query"(5) = 14 bytes
    var data: [1 + 4 + 4 + 5]u8 = undefined;
    data[0] = OP_SET_HIGHLIGHT_QUERY;
    std.mem.writeInt(u32, data[1..5], 0, .big); // buffer_id
    std.mem.writeInt(u32, data[5..9], 5, .big); // query_len
    @memcpy(data[9..14], "query");
    try std.testing.expectEqual(@as(usize, 14), commandSize(&data));
}

test "decode set_injection_query" {
    const query = "(content) @injection.content";
    // opcode(1) + buffer_id(4) + query_len(4) + query
    var data: [1 + 4 + 4 + query.len]u8 = undefined;
    data[0] = OP_SET_INJECTION_QUERY;
    std.mem.writeInt(u32, data[1..5], 2, .big); // buffer_id = 2
    std.mem.writeInt(u32, data[5..9], query.len, .big);
    @memcpy(data[9..], query);
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .set_injection_query => |siq| {
            try std.testing.expectEqual(@as(u32, 2), siq.buffer_id);
            try std.testing.expectEqualStrings(query, siq.source);
        },
        else => return error.Malformed,
    }
}

test "commandSize: set_injection_query" {
    // opcode(1) + buffer_id(4) + query_len(4) + "query"(5) = 14 bytes
    var data: [1 + 4 + 4 + 5]u8 = undefined;
    data[0] = OP_SET_INJECTION_QUERY;
    std.mem.writeInt(u32, data[1..5], 0, .big);
    std.mem.writeInt(u32, data[5..9], 5, .big);
    @memcpy(data[9..14], "query");
    try std.testing.expectEqual(@as(usize, 14), commandSize(&data));
}

test "decode close_buffer" {
    var data: [5]u8 = undefined;
    data[0] = OP_CLOSE_BUFFER;
    std.mem.writeInt(u32, data[1..5], 42, .big);
    const cmd = try decodeCommand(&data);
    switch (cmd) {
        .close_buffer => |buffer_id| {
            try std.testing.expectEqual(@as(u32, 42), buffer_id);
        },
        else => return error.Malformed,
    }
}

test "commandSize: close_buffer" {
    var data: [5]u8 = undefined;
    data[0] = OP_CLOSE_BUFFER;
    std.mem.writeInt(u32, data[1..5], 0, .big);
    try std.testing.expectEqual(@as(usize, 5), commandSize(&data));
}

test "commandSize: load_grammar" {
    const data = [_]u8{ OP_LOAD_GRAMMAR, 0x00, 0x03 } ++ "lua".* ++ [_]u8{ 0x00, 0x04 } ++ "path".*;
    try std.testing.expectEqual(@as(usize, 12), commandSize(&data));
}

test "encodeHighlightSpans round-trip" {
    const spans = [_]Span{
        .{ .start_byte = 0, .end_byte = 9, .capture_id = 0, .pattern_index = 5, .layer = 0 },
        .{ .start_byte = 10, .end_byte = 15, .capture_id = 1, .pattern_index = 3, .layer = 1 },
    };
    const buf = try encodeHighlightSpans(std.testing.allocator, 5, 42, &spans);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqual(OP_HIGHLIGHT_SPANS, buf[0]);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, buf[1..5], .big)); // buffer_id
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[5..9], .big)); // version
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[9..13], .big)); // count
    // First span (14 bytes each)
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[13..17], .big)); // start
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, buf[17..21], .big)); // end
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[21..23], .big)); // capture_id
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, buf[23..25], .big)); // pattern_index
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[25..27], .big)); // layer
    // Second span
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buf[27..31], .big)); // start
    try std.testing.expectEqual(@as(u32, 15), std.mem.readInt(u32, buf[31..35], .big)); // end
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[35..37], .big)); // capture_id
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, buf[37..39], .big)); // pattern_index
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[39..41], .big)); // layer
}

test "encodeHighlightNames round-trip" {
    const names = [_][]const u8{ "keyword", "string" };
    const buf = try encodeHighlightNames(std.testing.allocator, 3, &names);
    defer std.testing.allocator.free(buf);

    try std.testing.expectEqual(OP_HIGHLIGHT_NAMES, buf[0]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[1..5], .big)); // buffer_id
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, buf[5..7], .big)); // count
    // "keyword" (7)
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, buf[7..9], .big));
    try std.testing.expectEqualStrings("keyword", buf[9..16]);
    // "string" (6)
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, buf[16..18], .big));
    try std.testing.expectEqualStrings("string", buf[18..24]);
}

test "encodeGrammarLoaded" {
    var buf: [20]u8 = undefined;
    const len = try encodeGrammarLoaded(&buf, true, "elixir");
    try std.testing.expectEqual(@as(usize, 10), len);
    try std.testing.expectEqual(OP_GRAMMAR_LOADED, buf[0]);
    try std.testing.expectEqual(@as(u8, 1), buf[1]);
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqualStrings("elixir", buf[4..10]);
}

// ── Log message protocol tests ────────────────────────────────────────────────

test "encodeLogMessage byte layout" {
    var buf: [20]u8 = undefined;
    const len = try encodeLogMessage(&buf, LOG_LEVEL_WARN, "test msg");
    try std.testing.expectEqual(@as(usize, 12), len); // 4 header + 8 msg
    try std.testing.expectEqual(OP_LOG_MESSAGE, buf[0]);
    try std.testing.expectEqual(LOG_LEVEL_WARN, buf[1]);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, buf[2..4], .big));
    try std.testing.expectEqualStrings("test msg", buf[4..12]);
}

test "encodeLogMessage all levels" {
    var buf: [10]u8 = undefined;
    const levels = [_]u8{ LOG_LEVEL_ERR, LOG_LEVEL_WARN, LOG_LEVEL_INFO, LOG_LEVEL_DEBUG };
    for (levels) |lvl| {
        _ = try encodeLogMessage(&buf, lvl, "hi");
        try std.testing.expectEqual(lvl, buf[1]);
    }
}

test "encodeLogMessage empty message" {
    var buf: [4]u8 = undefined;
    const len = try encodeLogMessage(&buf, LOG_LEVEL_INFO, "");
    try std.testing.expectEqual(@as(usize, 4), len);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[2..4], .big));
}

test "encodeLogMessage buffer too small returns error" {
    var buf: [3]u8 = undefined; // needs at least 4
    const result = encodeLogMessage(&buf, LOG_LEVEL_ERR, "");
    try std.testing.expectError(error.Malformed, result);
}

// ── Request reparse protocol tests ────────────────────────────────────────────

test "encodeRequestReparse byte layout" {
    var buf: [5]u8 = undefined;
    const len = try encodeRequestReparse(&buf, 42);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(OP_REQUEST_REPARSE, buf[0]);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[1..5], .big));
}

test "encodeRequestReparse with zero buffer_id" {
    var buf: [5]u8 = undefined;
    const len = try encodeRequestReparse(&buf, 0);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[1..5], .big));
}

test "encodeRequestReparse with max buffer_id" {
    var buf: [5]u8 = undefined;
    const len = try encodeRequestReparse(&buf, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqual(std.math.maxInt(u32), std.mem.readInt(u32, buf[1..5], .big));
}

test "encodeRequestReparse buffer too small returns error" {
    var buf: [4]u8 = undefined;
    const result = encodeRequestReparse(&buf, 1);
    try std.testing.expectError(error.Malformed, result);
}

test "tab GUI action re-exports stay wired to generated opcodes" {
    try std.testing.expectEqual(opcodes.GUI_ACTION_TAB_REORDER, GUI_ACTION_TAB_REORDER);
    try std.testing.expectEqual(opcodes.GUI_ACTION_TAB_PIN, GUI_ACTION_TAB_PIN);
    try std.testing.expectEqual(opcodes.GUI_ACTION_TAB_UNPIN, GUI_ACTION_TAB_UNPIN);
    try std.testing.expectEqual(opcodes.GUI_ACTION_TAB_MOVE_LEFT, GUI_ACTION_TAB_MOVE_LEFT);
    try std.testing.expectEqual(opcodes.GUI_ACTION_TAB_MOVE_RIGHT, GUI_ACTION_TAB_MOVE_RIGHT);
}

test {
    _ = @import("generated/protocol_schema_test.zig");
}

// Conformance: schema-framed commands are sized by the generated commandSize authority. The corpus includes the indent_guides (0x91) regression that desynced the Go reader.
test "generated commandSize matches protocol.commandSize" {
    const generated_size = @import("generated/protocol_command_size.zig");

    const cases = [_][]const u8{
        &[_]u8{ OP_SET_CURSOR_SHAPE, CURSOR_BLOCK },
        &[_]u8{ OP_SET_WINDOW_BG, 0x28, 0x2C, 0x34 },
        &[_]u8{ OP_SET_TITLE, 0x00, 0x03, 'a', 'b', 'c' },
        &[_]u8{ opcodes.OP_GUI_INDENT_GUIDES, 0x00, 0x06, 1, 2, 3, 4, 5, 6 },
        &[_]u8{ opcodes.OP_GUI_FILE_TREE, 0, 0, 0, 2, 0xAA, 0xBB },
    };

    for (cases) |payload| {
        const result = generated_size.commandSize(payload);
        try std.testing.expectEqual(generated_size.Status.sized, result.status);
        try std.testing.expectEqual(commandSize(payload), result.size);
    }
}

test "generated-sized unrendered opcode does not consume following command" {
    const cases = [_][]const u8{
        &[_]u8{ opcodes.OP_GUI_INDENT_GUIDES, 0x00, 0x06, 1, 2, 3, 4, 5, 6, OP_COMMIT_FRAME, 0, 0, 0, 1, 0, 0, 0, 0 },
        &[_]u8{ 0xB7, 0x00, 0x02, 0xAA, 0xBB, OP_COMMIT_FRAME, 0, 0, 0, 1, 0, 0, 0, 0 },
    };

    for (cases) |packet| {
        var offset: usize = 0;

        const first = try decodeCommand(packet[offset..]);
        try std.testing.expect(first == .noop);
        offset += commandSize(packet[offset..]);

        const second = try decodeCommand(packet[offset..]);
        try std.testing.expect(second == .commit_frame);
    }
}

// ── Per-frontend framing contract (generalized from PR #2347) ─────────────────
//
// Why this exists: three times in this project's history a hand-written framing
// authority drifted from the generated schema and desynced a frontend's command
// stream. PR #2347 was the third (the macOS decoder mis-sized the sectioned
// gui_surface_layout, 0xA4, and looped the loader). The #2322 instance was the
// Zig sizer missing the gui_completion documentation tail. PR #2347 added one
// opcode's regression; this test generalizes it across EVERY opcode the parser
// stream can carry so a fourth instance is impossible on the Zig side.
//
// What it asserts: for every OP_* the live commandSize/decodeCommand path frames,
// a minimal payload followed by a commit_frame sentinel must be sized EXACTLY to
// the body boundary, and the trailing commit_frame must remain a decodable 9-byte
// command. The sentinel is the #2322 guarantee: a sizer that falls back to
// payload.len on truncation would swallow the commit_frame and fail.
//
// How opcodes are enumerated (self-updating on schema regen): comptime reflection
// over the generated opcodes module (`std.meta.declarations`) yields every OP_*
// constant. There is no hand-maintained opcode list to rot; a new opcode added to
// docs/protocol_schema.toml regenerates protocol_opcodes.zig and enters this loop
// the next time the test compiles.
//
// Which opcodes the parser stream routes: commandSize routes generated-sized,
// hand-custom (customCommandSize), AND parser commands (parserCommandSize); every
// other opcode (frontend->BEAM input, parser responses) makes decodeCommand return
// error.UnknownOpcode and is correctly excluded here.
//
// How minimal payloads are synthesized: a single zero-fill search, framing-kind
// agnostic. For each opcode it finds the smallest zero-filled body that both sizes
// to its own length and decodes without error; appending the commit_frame must not
// change that size. Zero bytes mean zero counts and zero-length strings, so the
// search converges on the true minimal bounded frame for fixed / len16 / len32 /
// sectioned / custom / parser framings alike. Opcodes whose decoder requires a
// nonzero length prefix (none today) would go in minimalBodyOverrides.
//
// FAILURE BY DEFAULT IS THE POINT: a new opcode that no zero-filled body within
// the probe bound can frame (a new custom needing nonzero structure, or a real
// mis-framing) fails this test loudly by name. Fix the framing or add an override;
// do not silence it.

const FramingContract = struct {
    const max_probe = 48;

    // commit_frame is a complete fixed:9 command; the sizer must leave it intact.
    const sentinel = [_]u8{ OP_COMMIT_FRAME, 0, 0, 0, 7, 0, 0, 0, 0 };

    /// Returns true when `op` is framed by the parser stream: decodeCommand routes
    /// it rather than returning error.UnknownOpcode. Probed with a generous zero
    /// body so length guards do not falsely report Malformed for a framed opcode.
    fn isFramed(op: u8) bool {
        var buf: [1 + max_probe]u8 = [_]u8{0} ** (1 + max_probe);
        buf[0] = op;
        if (decodeCommand(&buf)) |_| {
            return true;
        } else |err| return err != error.UnknownOpcode;
    }

    /// Finds the smallest zero-filled body (opcode + N zeros) that frames exactly:
    /// it sizes to its own length, decodes without error, and appending the
    /// sentinel does not extend that size (so the commit_frame survives). Writes
    /// the body into `out` and returns its length, or null when nothing within the
    /// probe bound frames (the loud-failure signal).
    fn minimalBody(op: u8, out: []u8) ?usize {
        var n: usize = 0;
        while (n <= max_probe) : (n += 1) {
            const len = 1 + n;
            @memset(out[0..len], 0);
            out[0] = op;
            const body = out[0..len];

            // Must size to exactly its own length.
            if (commandSize(body) != len) continue;
            // Must decode within those bounds without error.
            _ = decodeCommand(body) catch continue;

            // Appending the sentinel must not change the framed size: the body is
            // bounded and the commit_frame stays a separate command.
            var full: [1 + max_probe + sentinel.len]u8 = undefined;
            @memcpy(full[0..len], body);
            @memcpy(full[len .. len + sentinel.len], &sentinel);
            if (commandSize(full[0 .. len + sentinel.len]) != len) continue;

            return len;
        }
        return null;
    }
};

test "framing contract: every parser-stream opcode is exactly framed" {
    var framed: usize = 0;
    inline for (@typeInfo(opcodes).@"struct".decls) |decl| {
        comptime if (decl.name.len < 3 or !std.mem.eql(u8, decl.name[0..3], "OP_")) continue;
        const value = @field(opcodes, decl.name);
        comptime if (@TypeOf(value) != u8) continue;

        if (FramingContract.isFramed(value)) {
            framed += 1;

            var body_buf: [1 + FramingContract.max_probe]u8 = undefined;
            const body_len = FramingContract.minimalBody(value, &body_buf) orelse {
                std.debug.print(
                    "opcode {s} (0x{X:0>2}) is framed by the parser stream but no minimal " ++
                        "zero-filled body within {d} bytes frames exactly; its sizer/decoder " ++
                        "likely mis-frames or needs nonzero structure. Fix the framing or add " ++
                        "a FramingContract override.\n",
                    .{ decl.name, value, FramingContract.max_probe },
                );
                return error.UnframedOpcode;
            };

            // Build body ++ sentinel and assert exact framing to the boundary.
            var full: [1 + FramingContract.max_probe + FramingContract.sentinel.len]u8 = undefined;
            @memcpy(full[0..body_len], body_buf[0..body_len]);
            @memcpy(full[body_len .. body_len + FramingContract.sentinel.len], &FramingContract.sentinel);
            const packet = full[0 .. body_len + FramingContract.sentinel.len];

            // The first command is framed to exactly body_len.
            try std.testing.expectEqual(body_len, commandSize(packet));
            // The trailing bytes are the intact commit_frame sentinel (9 bytes),
            // proving no truncation fallback swallowed it (#2322).
            try std.testing.expectEqual(@as(usize, FramingContract.sentinel.len), commandSize(packet[body_len..]));
            try std.testing.expect((try decodeCommand(packet[body_len..])) == .commit_frame);
        }
    }

    // Sanity: enumeration must discover a non-trivial framed set, else reflection
    // or classification silently broke and the contract would assert nothing.
    try std.testing.expect(framed > 30);
}
