package protocol

import (
	"bytes"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestDecodeWindowContentRejectsRowCountBeyondSectionBytes(t *testing.T) {
	packet := windowContentPacket(section32(0x02, []byte{0xFF, 0xFF, 0xFF, 0xFF}))

	if _, err := DecodeCommand(packet); err == nil {
		t.Fatal("DecodeCommand accepted a row count that cannot fit in the rows section")
	}
}

func TestDecodeWindowDeltaRejectsRowCountBeyondSectionBytes(t *testing.T) {
	header := []byte{0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0}
	packet := append([]byte{generated.OPGuiWindowRowsDelta, 2}, section32(0x01, header)...)
	packet = append(packet, section32(0x02, []byte{0xFF, 0xFF, 0xFF, 0xFF})...)

	if _, err := DecodeCommand(packet); err == nil {
		t.Fatal("DecodeCommand accepted a row delta count that cannot fit in the rows section")
	}
}

func TestDecodeWindowDeltaRejectsMalformedSections(t *testing.T) {
	header := []byte{0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0}

	for _, opcode := range []byte{generated.OPGuiWindowRowsDelta, generated.OPGuiWindowViewportDelta} {
		t.Run("declared section length", func(t *testing.T) {
			packet := append([]byte{opcode, 1, 0x01, 0, 0, 0, 15}, header...)
			if _, err := DecodeCommand(packet); err == nil {
				t.Fatal("DecodeCommand accepted a truncated declared section")
			}
		})

		t.Run("trailing row bytes", func(t *testing.T) {
			rows := []byte{0, 0, 0, 0, 0xFF}
			packet := append([]byte{opcode, 2}, section32(0x01, header)...)
			packet = append(packet, section32(0x02, rows)...)
			if _, err := DecodeCommand(packet); err == nil {
				t.Fatal("DecodeCommand accepted trailing row bytes")
			}
		})
	}
}

func TestDecodeClipboardWriteSupportsMoreThanUint16Bytes(t *testing.T) {
	text := bytes.Repeat([]byte{'x'}, 65_536)
	packet := []byte{generated.OPClipboardWrite}
	packet = append(packet, u32Bytes(uint32(5+len(text)))...)
	packet = append(packet, 0)
	packet = append(packet, u32Bytes(uint32(len(text)))...)
	packet = append(packet, text...)

	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if len(command.ClipboardText) != len(text) {
		t.Fatalf("clipboard text length = %d, want %d", len(command.ClipboardText), len(text))
	}
}

func TestDecodeWindowDeltaSupportsMoreThanUint16Rows(t *testing.T) {
	const rowCount = 65_536
	header := []byte{0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0}
	rows := u32Bytes(rowCount)

	for rowID := uint64(0); rowID < rowCount; rowID++ {
		rows = append(rows, 0)
		rows = append(rows, byte(rowID>>56), byte(rowID>>48), byte(rowID>>40), byte(rowID>>32), byte(rowID>>24), byte(rowID>>16), byte(rowID>>8), byte(rowID))
		rows = append(rows, 0, 0, 0, 0)
	}

	packet := append([]byte{generated.OPGuiWindowRowsDelta, 2}, section32(0x01, header)...)
	packet = append(packet, section32(0x02, rows)...)
	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if len(command.Window.Rows) != rowCount {
		t.Fatalf("decoded rows = %d, want %d", len(command.Window.Rows), rowCount)
	}
}
