package protocol

import (
	"encoding/binary"
	"reflect"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestAgentQueueWireDecodeIsBounded(t *testing.T) {
	body := []byte{
		1, 1, 0x11, 0x22, 0x33, 0x44,
		0, 1, 'r', 0, 1, 'Q', 0, 1, 'S', 0, 1, 'N',
		0x80, 0, 0, 0, 0, 0, 0, 1,
		1, 2, 1, 'p', 0, 1, 'P',
		1, 0x80, 0, 0, 0, 0, 0, 0, 1, 0x40, 0, 0, 0, 0, 0, 0, 2, 1, 1, '1', 0, 1, 'A', 1, 2,
		1, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0, 1, '1', 0, 1, 'B', 0, 0,
		0, 0, 0, 0, 0, 0, 0,
	}
	packet := func(body []byte) []byte {
		return append(binary.BigEndian.AppendUint32([]byte{0xAE}, uint32(len(body))), body...)
	}
	first := packet(body)
	following := []byte{0xAE, 0, 0, 0, 1, 0}
	cmd, err := DecodeCommand(append(append([]byte{}, first...), following...))
	if err != nil || cmd.Kind != CommandChrome || cmd.Size != len(first) {
		t.Fatalf("queue didn't frame in batch: size=%d kind=%v error=%v", cmd.Size, cmd.Kind, err)
	}
	want := generated.GuiAgentQueueFields{
		Visible: 1, Focused: 1, WorkspaceID: 0x11223344, RecordID: "r", Title: "Q", Summary: "S", RemovedNote: "N", SelectedID: 0x8000000000000001,
		Hints:   []generated.AgentQueueHint{{Action: generated.AgentQueueActionPasteAfter, Key: "p", Label: "P"}},
		Pending: []generated.AgentQueueRow{{ID: 0x8000000000000001, Revision: 0x4000000000000002, Kind: 1, Label: "1", Preview: "A", AttachmentCount: 0x102}},
		Removed: []generated.AgentQueueRow{{ID: 3, Revision: 4, Label: "1", Preview: "B"}},
		Empty:   generated.EmptyList{Actions: []generated.EmptyListAction{}},
	}
	if !reflect.DeepEqual(cmd.Chrome.AgentQueue, want) {
		t.Fatalf("queue decoded as %+v, want %+v", cmd.Chrome.AgentQueue, want)
	}
	cmd, err = DecodeCommand(following)
	if err != nil || cmd.Size != len(following) || !reflect.DeepEqual(cmd.Chrome.AgentQueue, generated.GuiAgentQueueFields{}) {
		t.Fatalf("hide didn't decode to empty fields: %+v, %v", cmd.Chrome.AgentQueue, err)
	}
	for n := range body {
		if _, err := DecodeCommand(append(packet(body[:n]), following...)); err == nil {
			t.Fatalf("truncated queue with %d payload bytes consumed the following command", n)
		}
	}
	for name, malformed := range map[string][]byte{
		"hidden trailing data": {0, 0},
		"shown trailing data":  append(append([]byte{}, body...), 0),
		"invalid visibility":   {2},
		"invalid focus flag":   append([]byte{1, 2}, body[2:]...),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := DecodeCommand(packet(malformed)); err == nil {
				t.Fatal("malformed queue was accepted")
			}
		})
	}
}

func TestAgentQueueWireRejectsIncompleteOrUnexpectedOffers(t *testing.T) {
	row := AgentQueueRowRef{1, 2}
	zero := AgentQueueRowRef{}
	for _, tc := range []struct {
		action       generated.AgentQueueAction
		row, removed AgentQueueRowRef
	}{
		{generated.AgentQueueActionSelect, zero, zero},
		{generated.AgentQueueActionRemove, AgentQueueRowRef{ID: 1}, zero},
		{generated.AgentQueueActionEdit, row, row},
		{generated.AgentQueueActionPasteAfter, row, zero},
		{generated.AgentQueueActionPasteBefore, zero, row},
		{generated.AgentQueueActionClose, row, zero},
		{generated.AgentQueueActionComposer, zero, row},
		{generated.AgentQueueActionUnknown, zero, zero},
	} {
		if got := EncodeGUIAgentQueueAction(tc.action, 11, "rec", tc.row, tc.removed); got != nil {
			t.Errorf("unexpected action %d packet: %x", tc.action, got)
		}
	}
}
