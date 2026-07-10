package protocol

import (
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
