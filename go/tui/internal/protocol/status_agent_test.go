package protocol

import (
	"encoding/binary"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func statusPacket(contentKind byte, agent []byte) []byte {
	identity := []byte{contentKind, 0, 0}
	packet := []byte{generated.OPGuiStatusBar, 1}
	packet = append(packet, 0x01)
	packet = binary.BigEndian.AppendUint16(packet, uint16(len(identity)))
	packet = append(packet, identity...)
	if agent == nil {
		return packet
	}
	packet[1]++
	packet = append(packet, 0x09)
	packet = binary.BigEndian.AppendUint16(packet, uint16(len(agent)))
	return append(packet, agent...)
}

func TestStatusAgentSectionCarriesConversationTotal(t *testing.T) {
	agent := []byte{4}
	agent = append(agent, "gpt5"...)
	agent = binary.BigEndian.AppendUint32(agent, 205)
	agent = append(agent, 0, 0, 0, 0, 0, 0, 0)
	command, err := DecodeCommand(statusPacket(1, agent))
	if err != nil {
		t.Fatal(err)
	}
	if command.Chrome.Status.Agent == nil {
		t.Fatal("agent-content status bar should decode its message total")
	}
	if got := command.Chrome.Status.Agent.MessageCount; got != 205 {
		t.Fatalf("MessageCount = %d, want 205", got)
	}
}

func TestStatusAgentTotalIsAbsentForBufferContent(t *testing.T) {
	command, err := DecodeCommand(statusPacket(0, nil))
	if err != nil {
		t.Fatal(err)
	}
	if command.Chrome.Status.Agent != nil {
		t.Fatalf("buffer-content status bar should not carry an agent total: %+v", command.Chrome.Status.Agent)
	}
}
