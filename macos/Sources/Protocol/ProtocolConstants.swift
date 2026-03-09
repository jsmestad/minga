/// Port protocol opcode constants and capability values.
///
/// These must match the values in `lib/minga/port/protocol.ex` and
/// `zig/src/protocol.zig`. See `docs/PROTOCOL.md` for the full spec.

// MARK: - Event opcodes (frontend → BEAM)

let OP_KEY_PRESS: UInt8 = 0x01
let OP_RESIZE: UInt8 = 0x02
let OP_READY: UInt8 = 0x03
let OP_MOUSE_EVENT: UInt8 = 0x04

// MARK: - Render command opcodes (BEAM → frontend)

let OP_DRAW_TEXT: UInt8 = 0x10
let OP_SET_CURSOR: UInt8 = 0x11
let OP_CLEAR: UInt8 = 0x12
let OP_BATCH_END: UInt8 = 0x13
let OP_DEFINE_REGION: UInt8 = 0x14
let OP_SET_CURSOR_SHAPE: UInt8 = 0x15
let OP_SET_TITLE: UInt8 = 0x16
let OP_SET_WINDOW_BG: UInt8 = 0x17
let OP_CLEAR_REGION: UInt8 = 0x18
let OP_DESTROY_REGION: UInt8 = 0x19
let OP_SET_ACTIVE_REGION: UInt8 = 0x1A

// MARK: - Highlight opcodes (ignored by GUI, handled by minga-parser)

let OP_SET_LANGUAGE: UInt8 = 0x20
let OP_PARSE_BUFFER: UInt8 = 0x21
let OP_SET_HIGHLIGHT_QUERY: UInt8 = 0x22
let OP_LOAD_GRAMMAR: UInt8 = 0x23
let OP_SET_INJECTION_QUERY: UInt8 = 0x24
let OP_QUERY_LANGUAGE_AT: UInt8 = 0x25
let OP_EDIT_BUFFER: UInt8 = 0x26
let OP_MEASURE_TEXT: UInt8 = 0x27

// MARK: - Cursor shapes

let CURSOR_BLOCK: UInt8 = 0x00
let CURSOR_BEAM: UInt8 = 0x01
let CURSOR_UNDERLINE: UInt8 = 0x02

// MARK: - Capability constants

let CAPS_VERSION: UInt8 = 1

let FRONTEND_TUI: UInt8 = 0
let FRONTEND_NATIVE_GUI: UInt8 = 1

let COLOR_RGB: UInt8 = 2
let UNICODE_15: UInt8 = 1
let IMAGE_NATIVE: UInt8 = 3
let FLOAT_NATIVE: UInt8 = 1
let TEXT_PROPORTIONAL: UInt8 = 1

// MARK: - Text attribute bits

let ATTR_BOLD: UInt8 = 0x01
let ATTR_ITALIC: UInt8 = 0x02
let ATTR_UNDERLINE: UInt8 = 0x04
let ATTR_REVERSE: UInt8 = 0x08

// MARK: - Mouse button constants

let MOUSE_BUTTON_LEFT: UInt8 = 0x00
let MOUSE_BUTTON_MIDDLE: UInt8 = 0x01
let MOUSE_BUTTON_RIGHT: UInt8 = 0x02
let MOUSE_BUTTON_NONE: UInt8 = 0x03
let MOUSE_SCROLL_UP: UInt8 = 0x40
let MOUSE_SCROLL_DOWN: UInt8 = 0x41
let MOUSE_SCROLL_RIGHT: UInt8 = 0x42
let MOUSE_SCROLL_LEFT: UInt8 = 0x43

// MARK: - Log message opcode (frontend → BEAM)

let OP_LOG_MESSAGE: UInt8 = 0x60

// MARK: - Log levels (must match Zig protocol.zig and Elixir protocol.ex)

let LOG_LEVEL_ERR: UInt8 = 0
let LOG_LEVEL_WARN: UInt8 = 1
let LOG_LEVEL_INFO: UInt8 = 2
let LOG_LEVEL_DEBUG: UInt8 = 3

// MARK: - Mouse event types

let MOUSE_PRESS: UInt8 = 0x00
let MOUSE_RELEASE: UInt8 = 0x01
let MOUSE_MOTION: UInt8 = 0x02
let MOUSE_DRAG: UInt8 = 0x03
