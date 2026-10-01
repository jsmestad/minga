package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestDecodeResidentSemanticsAccepts65536GuideRuns(t *testing.T) {
	var body bytes.Buffer
	body.WriteByte(1)
	body.WriteByte(0)
	writeResidentU16(&body, 7)
	writeResidentU32(&body, 9)
	writeResidentU32(&body, 0)
	writeResidentU32(&body, 1)
	writeResidentU32(&body, 1)
	writeResidentU32(&body, 65_536)
	writeResidentU64(&body, 1)
	writeResidentU64(&body, 65_536)
	body.WriteByte(0x18)
	writeResidentU32(&body, 0)
	writeResidentU16(&body, 0)
	body.WriteByte(2)
	writeResidentU16(&body, 0)
	writeResidentU16(&body, 0)
	writeResidentU16(&body, 0)
	writeResidentU16(&body, 1)
	writeResidentU32(&body, 0)
	writeResidentU32(&body, 65_536)
	writeResidentU32(&body, 65_536)
	for row := uint32(0); row < 65_536; row++ {
		writeResidentU32(&body, row)
		writeResidentU32(&body, row+1)
		writeResidentU16(&body, uint16(row%8))
	}
	writeResidentU32(&body, 0)
	writeResidentU32(&body, 0)

	payload := make([]byte, 5, 5+body.Len())
	payload[0] = generated.OPGuiResidentSemantics
	binary.BigEndian.PutUint32(payload[1:], uint32(body.Len()))
	payload = append(payload, body.Bytes()...)
	command, err := decodeResidentSemantics(payload)
	if err != nil {
		t.Fatalf("decode maximum guide run count: %v", err)
	}
	if got := len(command.ResidentSemantics.GuideReplacements[0].Runs); got != 65_536 {
		t.Fatalf("decoded %d guide runs, want 65536", got)
	}
}

func writeResidentU16(buffer *bytes.Buffer, value uint16) {
	var encoded [2]byte
	binary.BigEndian.PutUint16(encoded[:], value)
	buffer.Write(encoded[:])
}

func writeResidentU32(buffer *bytes.Buffer, value uint32) {
	var encoded [4]byte
	binary.BigEndian.PutUint32(encoded[:], value)
	buffer.Write(encoded[:])
}

func writeResidentU64(buffer *bytes.Buffer, value uint64) {
	var encoded [8]byte
	binary.BigEndian.PutUint64(encoded[:], value)
	buffer.Write(encoded[:])
}
