package protocol

import "github.com/jsmestad/minga/go/tui/internal/generated"

const (
	ModShift byte = 0x01
	ModCtrl  byte = 0x02
	ModAlt   byte = 0x04
	ModSuper byte = 0x08
)

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

func EncodeKeyPress(codepoint rune, modifiers byte) []byte {
	value := uint32(codepoint)
	return []byte{generated.OPKeyPress, byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value), modifiers}
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

func EncodePaste(text string) []byte {
	payload := []byte(text)
	if len(payload) > 65535 {
		payload = payload[:65535]
	}
	return append([]byte{generated.OPPasteEvent, byte(len(payload) >> 8), byte(len(payload))}, payload...)
}
