package protocol

import "github.com/jsmestad/minga/go/tui/internal/generated"

const (
	ModShift byte = 0x01
	ModCtrl  byte = 0x02
	ModAlt   byte = 0x04
	ModSuper byte = 0x08
)

// Log levels for EncodeLogMessage, matching the BEAM's decode_log_level.
const (
	LogLevelErr   byte = 0
	LogLevelWarn  byte = 1
	LogLevelInfo  byte = 2
	LogLevelDebug byte = 3
)

// EncodeLogMessage encodes a log_message event so the BEAM routes renderer
// diagnostics into Minga's *Messages* buffer, matching the Zig renderer.
// Wire format: <0x60, level:u8, msg_len:u16, msg>. The message is truncated to
// the u16 length ceiling.
func EncodeLogMessage(level byte, msg string) []byte {
	if len(msg) > 0xFFFF {
		msg = msg[:0xFFFF]
	}
	out := make([]byte, 0, 4+len(msg))
	out = append(out, generated.OPLogMessage, level, byte(len(msg)>>8), byte(len(msg)))
	return append(out, msg...)
}

func EncodeReady(width, height uint16) []byte {
	return []byte{
		generated.OPReady,
		byte(width >> 8), byte(width),
		byte(height >> 8), byte(height),
		1,
		7,
		0, // frontend_type: tui
		2, // color_depth: rgb
		1, // unicode_width: unicode_15
		0, // image_support: none
		0, // float_support: emulated
		0, // text_rendering: monospace
		1, // semantic_ui: true
	}
}

func EncodeResize(width, height uint16) []byte {
	return []byte{generated.OPResize, byte(width >> 8), byte(width), byte(height >> 8), byte(height)}
}

// EncodeKeyPress encodes a key press carrying a u32 input correlation sequence
// (ticket #2215) appended after the modifiers byte. The BEAM echoes the sequence
// on batch_end so the frontend can resolve an end-to-end keystroke-to-write
// latency sample. A sequence of 0 means "no correlation".
func EncodeKeyPress(codepoint rune, modifiers byte, seq uint32) []byte {
	value := uint32(codepoint)
	return []byte{
		generated.OPKeyPress,
		byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value),
		modifiers,
		byte(seq >> 24), byte(seq >> 16), byte(seq >> 8), byte(seq),
	}
}

func EncodeMouseEvent(row, col int16, button, mods, eventType, clickCount byte) []byte {
	return []byte{
		generated.OPMouseEvent,
		byte(uint16(row) >> 8), byte(row),
		byte(uint16(col) >> 8), byte(col),
		button,
		mods,
		eventType,
		clickCount,
	}
}

func EncodeGUIFileTreeClick(index uint16) []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionFileTreeClick, byte(index >> 8), byte(index)}
}

func EncodeGUISelectTab(id uint32) []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionSelectTab, byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)}
}

func EncodeGUIExecuteCommand(command string) []byte {
	payload := []byte(command)
	if len(payload) > 65535 {
		payload = payload[:65535]
	}
	out := []byte{generated.OPGuiAction, generated.GUIActionExecuteCommand, byte(len(payload) >> 8), byte(len(payload))}
	return append(out, payload...)
}

func EncodePaste(text string) []byte {
	payload := []byte(text)
	if len(payload) > 65535 {
		payload = payload[:65535]
	}
	return append([]byte{generated.OPPasteEvent, byte(len(payload) >> 8), byte(len(payload))}, payload...)
}
