package protocol

import (
	"bytes"
	"testing"
)

func TestReadPacketRejectsPayloadOverMaximumBeforeAllocation(t *testing.T) {
	reader := bytes.NewReader([]byte{0xFF, 0xFF, 0xFF, 0xFF})

	if _, err := ReadPacket(reader); err == nil {
		t.Fatal("ReadPacket accepted an oversized payload length")
	}
}
