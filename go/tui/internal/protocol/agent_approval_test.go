package protocol

import (
	"bytes"
	"strings"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestEncodeGUIAgentToolApprovalExactTargetAndDecision(t *testing.T) {
	target := AgentApprovalTarget{SessionID: "s_1", RequestID: "r_2", ToolCallID: "tc_3"}
	for _, decision := range []generated.AgentApprovalDecision{
		generated.AgentApprovalDecisionApprove,
		generated.AgentApprovalDecisionApproveSession,
		generated.AgentApprovalDecisionApproveTurn,
		generated.AgentApprovalDecisionReject,
	} {
		want := []byte{generated.OPGuiAction, 0x68, 0, 3, 's', '_', '1', 0, 3, 'r', '_', '2', 0, 4, 't', 'c', '_', '3', byte(decision)}
		if got := EncodeGUIAgentToolApproval(target, decision); !bytes.Equal(got, want) {
			t.Fatalf("decision %d packet = %x, want %x", decision, got, want)
		}
	}
	for _, decision := range []generated.AgentApprovalDecision{generated.AgentApprovalDecisionUnknown, 5, 255} {
		if got := EncodeGUIAgentToolApproval(target, decision); got != nil {
			t.Fatalf("unknown decision %d emitted %x", decision, got)
		}
	}
}

func TestEncodeGUIAgentToolApprovalNeverTruncatesOrOmitsIdentity(t *testing.T) {
	valid := AgentApprovalTarget{SessionID: "s", RequestID: "r", ToolCallID: "t"}
	for field := range 3 {
		for _, value := range []string{"", strings.Repeat("x", 65536)} {
			target := valid
			switch field {
			case 0:
				target.SessionID = value
			case 1:
				target.RequestID = value
			case 2:
				target.ToolCallID = value
			}
			if got := EncodeGUIAgentToolApproval(target, generated.AgentApprovalDecisionApprove); got != nil {
				t.Fatalf("invalid identity field %d length %d emitted a packet", field, len(value))
			}
		}
	}
}

func TestDecodeApprovalRequiresVersion32IdentityBeforePreview(t *testing.T) {
	prefix := []byte{0x09, 0}
	for _, value := range []string{"shell", "run command", "tool:old"} {
		prefix = append(prefix, string16(value)...)
	}
	body := append([]byte(nil), prefix...)
	body = append(body, string16("session:old")...)
	body = append(body, string16("request:old")...)
	body = append(body, 2, 0, 1)
	body = append(body, string16("echo safe")...)
	message, ok := decodeAgentMessageBody(99, body)
	if !ok || message.ID != 99 || message.ApprovalTarget != (AgentApprovalTarget{SessionID: "session:old", RequestID: "request:old", ToolCallID: "tool:old"}) || message.PreviewKind != 2 || len(message.PreviewLines) != 1 || message.PreviewLines[0] != "echo safe" || message.Result != "" {
		t.Fatalf("approval identity/preview = %+v, ok=%t", message, ok)
	}
	for end := range len(body) {
		if _, ok := decodeAgentMessageBody(99, body[:end]); ok {
			t.Fatalf("approval accepted truncated body at %d/%d", end, len(body))
		}
	}
	legacy := append(prefix, 2, 0, 0)
	if _, ok := decodeAgentMessageBody(99, legacy); ok {
		t.Fatal("accepted version31 ID-less approval body")
	}
}
