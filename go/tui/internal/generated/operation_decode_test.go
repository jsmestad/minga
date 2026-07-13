package generated

import (
	"encoding/binary"
	"testing"
)

func TestGuiStatusBarOperationGeneratedDecodeRoundTrip(t *testing.T) {
	message := []byte("Working...")
	payload := make([]byte, 0, 8+3+2+len(message)+12)
	id := make([]byte, 8)
	binary.BigEndian.PutUint64(id, 4_294_967_297)
	payload = append(payload, id...)
	payload = append(payload, byte(OperationKindLspRename), byte(OperationStatusRunning), 0x07)
	payload = append(payload, 0, byte(len(message)))
	payload = append(payload, message...)
	payload = append(payload, 0, 2, 0, 5)
	payload = append(payload, 0, 0, 0, 7, 0, 0, 0, 10)

	decoded, consumed, err := GoldenDecode("GuiStatusBarOperation", payload)
	if err != nil {
		t.Fatalf("decode operation: %v", err)
	}
	if consumed != len(payload) {
		t.Fatalf("consumed %d bytes, want %d", consumed, len(payload))
	}

	operation, ok := decoded.(GuiStatusBarOperation)
	if !ok {
		t.Fatalf("decoded type %T, want GuiStatusBarOperation", decoded)
	}
	if operation.OperationID != 4_294_967_297 || operation.Kind != OperationKindLspRename || operation.Status != OperationStatusRunning {
		t.Fatalf("identity fields = %#v", operation)
	}
	if operation.Flags != 0x07 || operation.Message != "Working..." {
		t.Fatalf("semantic fields = %#v", operation)
	}
	if operation.QueuePosition != 2 || operation.QueueTotal != 5 || operation.ProgressCurrent != 7 || operation.ProgressTotal != 10 {
		t.Fatalf("optional fields = %#v", operation)
	}
}
