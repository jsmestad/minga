package main

import (
	"bytes"
	"os"
	"testing"
)

func TestTerminalWidthsMatchRenderer(t *testing.T) {
	shipped, err := os.ReadFile("../../" + tablePath)
	if err != nil {
		t.Fatal(err)
	}
	var want bytes.Buffer
	if err := writeWidths(&want); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(shipped, want.Bytes()) {
		t.Fatalf("BEAM and Go will disagree on wrapping; regenerate with: %s", regenerate)
	}
}
