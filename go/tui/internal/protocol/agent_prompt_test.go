package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestAgentPromptFitWire(t *testing.T) {
	fit := AgentPromptFit{WindowID: AgentPromptWindowID, Generation: 0x0102030405060708, Columns: 0x0123, MaxRows: 8}
	want := []byte{generated.OPGuiAction, 0x66, 0xff, 0xfe, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0x23, 0, 8}
	if got := EncodeGUIAgentPromptFit(fit); !bytes.Equal(got, want) {
		t.Fatalf("fit = %x, want %x", got, want)
	}
}

func TestAgentPromptScrollSignedRowsWire(t *testing.T) {
	for _, delta := range []int32{-2147483648, -8192, -1, 0, 1, 8192, 2147483647} {
		packet := EncodeGUIAgentPromptScroll(AgentPromptScroll{WindowID: AgentPromptWindowID, Generation: 0x0102030405060708, DeltaRows: delta})
		if len(packet) != 16 || packet[0] != generated.OPGuiAction || packet[1] != 0x67 || binary.BigEndian.Uint16(packet[2:4]) != AgentPromptWindowID || binary.BigEndian.Uint64(packet[4:12]) != 0x0102030405060708 || int32(binary.BigEndian.Uint32(packet[12:16])) != delta {
			t.Fatalf("scroll %d = %x", delta, packet)
		}
	}
}
