package protocol

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestDecodeWindowRowSplicesAndRejectAmbiguousLegacyRows(t *testing.T) {
	header := []byte{0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0}
	splices := append(u32be(3), u32be(3)...)
	splices = append(splices, u32be(1)...)
	splices = append(splices, u32be(1)...)
	splices = append(splices, u32be(1)...)
	splices = append(splices, u32be(1)...)
	splices = append(splices, 0)
	splices = append(splices, u64be(2)...)
	splices = append(splices, u32be(22)...)

	packet := append([]byte{generated.OPGuiWindowRowsDelta, 2}, section32(0x01, header)...)
	packet = append(packet, section32(0x0B, splices)...)
	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if !command.Window.RowSplicesSet || command.Window.BaseRowCount != 3 ||
		command.Window.ResultRowCount != 3 || len(command.Window.RowSplices) != 1 {
		t.Fatalf("decoded row splices mismatch: %#v", command.Window)
	}

	ambiguous := append([]byte{generated.OPGuiWindowRowsDelta, 3}, section32(0x01, header)...)
	ambiguous = append(ambiguous, section32(0x02, u32be(0))...)
	ambiguous = append(ambiguous, section32(0x0B, splices)...)
	if _, err := DecodeCommand(ambiguous); err == nil {
		t.Fatal("DecodeCommand accepted both legacy rows and v11 row splices")
	}
}

func TestDecodeWindowRowSplicesRejectsMalformedRangesAndArithmetic(t *testing.T) {
	header := []byte{0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0}
	cases := map[string][]byte{
		"range":      append(append(append(append(append(append(u32be(1), u32be(1)...), u32be(1)...), u32be(1)...), u32be(2)...), u32be(0)...), []byte{}...),
		"arithmetic": append(append(append(append(append(append(u32be(1), u32be(9)...), u32be(1)...), u32be(0)...), u32be(1)...), u32be(0)...), []byte{}...),
	}
	for name, splices := range cases {
		t.Run(name, func(t *testing.T) {
			packet := append([]byte{generated.OPGuiWindowRowsDelta, 2}, section32(0x01, header)...)
			packet = append(packet, section32(0x0B, splices)...)
			if _, err := DecodeCommand(packet); err == nil {
				t.Fatal("DecodeCommand accepted malformed row splices")
			}
		})
	}
}

func u64be(value uint64) []byte {
	return []byte{byte(value >> 56), byte(value >> 48), byte(value >> 40), byte(value >> 32),
		byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value)}
}
