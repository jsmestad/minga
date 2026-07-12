/// Port protocol constants that are not opcode values.
///
/// Opcode and GUI action constants are generated in `macos/.generated/protocol/ProtocolOpcodes.generated.swift` from `docs/protocol_schema.toml`.

// MARK: - Sectioned format section IDs
// Used by opcodes with self-describing sections (gui_status_bar, etc.).
// Format: section_id(1) + section_len(2, big-endian) + payload(section_len)

let SECTION_IDENTITY: UInt8 = 0x01
let SECTION_CURSOR: UInt8 = 0x02
let SECTION_DIAGNOSTICS: UInt8 = 0x03
let SECTION_LANGUAGE: UInt8 = 0x04
let SECTION_GIT: UInt8 = 0x05
let SECTION_FILE: UInt8 = 0x06
let SECTION_MESSAGE: UInt8 = 0x07
let SECTION_RECORDING: UInt8 = 0x08
let SECTION_AGENT: UInt8 = 0x09
let SECTION_INDENT: UInt8 = 0x0A
let SECTION_MODELINE_SEGMENTS: UInt8 = 0x0B
let SECTION_SELECTION: UInt8 = 0x0C
let SECTION_WORKSPACE: UInt8 = 0x0D
let SECTION_PENDING_KEYS: UInt8 = 0x0E

// GUI theme color slot IDs (GUI_COLOR_*) moved to GUIColorSlots.swift in the
// MingaProtocol framework so the preview framework can share them.

// MARK: - Cursor shapes

let CURSOR_BLOCK: UInt8 = 0x00
let CURSOR_BEAM: UInt8 = 0x01
let CURSOR_UNDERLINE: UInt8 = 0x02

// MARK: - Capability constants

let CAPS_VERSION: UInt8 = 2

let FRONTEND_TUI: UInt8 = 0
let FRONTEND_NATIVE_GUI: UInt8 = 1

let COLOR_RGB: UInt8 = 2
let UNICODE_15: UInt8 = 1
let IMAGE_NATIVE: UInt8 = 3
let FLOAT_NATIVE: UInt8 = 1
let TEXT_PROPORTIONAL: UInt8 = 1
let SEMANTIC_UI_ENABLED: UInt8 = 1

// Capability-format-2 resource-policy tail. Values are hard admission bounds;
// zero leaves a dimension unadvertised until that limit is enforced. The packet
// byte ceiling is enforced by ProtocolReader before payload allocation.
let RESOURCE_POLICY_VERSION: UInt8 = 1
let RESOURCE_MAX_FRAME_BYTES: UInt32 = 64 * 1024 * 1024
let RESOURCE_MAX_FRAME_COMMANDS: UInt32 = 0
let RESOURCE_MAX_WINDOW_ROWS: UInt32 = 0

// MARK: - Text attribute bits

let ATTR_BOLD: UInt8 = 0x01
let ATTR_UNDERLINE: UInt8 = 0x02
let ATTR_ITALIC: UInt8 = 0x04
let ATTR_REVERSE: UInt8 = 0x08
let ATTR_STRIKETHROUGH: UInt16 = 0x10

// Underline style (3 bits at position 5-7 in extended 16-bit attrs)
let UL_STYLE_SHIFT: UInt16 = 5
let UL_STYLE_MASK: UInt16 = 0x07  // 3 bits
let UL_STYLE_LINE: UInt16 = 0
let UL_STYLE_CURL: UInt16 = 1
let UL_STYLE_DASHED: UInt16 = 2
let UL_STYLE_DOTTED: UInt16 = 3
let UL_STYLE_DOUBLE: UInt16 = 4

// Bold/italic style mask for font variant selection (bits 0 and 2 of attrs)
let FONT_STYLE_MASK: UInt8 = 0x05

// MARK: - Mouse button constants

let MOUSE_BUTTON_LEFT: UInt8 = 0x00
let MOUSE_BUTTON_MIDDLE: UInt8 = 0x01
let MOUSE_BUTTON_RIGHT: UInt8 = 0x02
let MOUSE_BUTTON_NONE: UInt8 = 0x03
let MOUSE_SCROLL_UP: UInt8 = 0x40
let MOUSE_SCROLL_DOWN: UInt8 = 0x41
let MOUSE_SCROLL_RIGHT: UInt8 = 0x42
let MOUSE_SCROLL_LEFT: UInt8 = 0x43

// MARK: - Settings value types

let SETTING_VALUE_BOOL: UInt8 = 0x01
let SETTING_VALUE_INT: UInt8 = 0x02
let SETTING_VALUE_STRING: UInt8 = 0x03
let SETTING_VALUE_ATOM: UInt8 = 0x04
let SETTING_VALUE_FLOAT: UInt8 = 0x05

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
