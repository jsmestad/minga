package protocol

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestDecodeExtensionRuntime(t *testing.T) {
	payload := []byte{generated.OPGuiExtensionRuntime, 0, 0, 0, 18, 0, 5}
	payload = append(payload, []byte("hello")...)
	payload = append(payload, 0, 4)
	payload = append(payload, []byte("pane")...)
	payload = append(payload, []byte{0x87, 1, 2, 3, 4}...)

	cmd, err := DecodeCommand(payload)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if cmd.Kind != CommandExtensionRuntime || cmd.Size != len(payload) {
		t.Fatalf("command kind/size = %v/%d", cmd.Kind, cmd.Size)
	}
	if cmd.ExtensionRuntime.ExtensionID != "hello" || cmd.ExtensionRuntime.Channel != "pane" || string(cmd.ExtensionRuntime.Payload) != string([]byte{0x87, 1, 2, 3, 4}) {
		t.Fatalf("decoded runtime = %#v", cmd.ExtensionRuntime)
	}
}
