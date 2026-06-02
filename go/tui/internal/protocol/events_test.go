package protocol

import (
	"bytes"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestEncodeGUIFileTreeClick(t *testing.T) {
	got := EncodeGUIFileTreeClick(7)
	want := []byte{generated.OPGuiAction, generated.GUIActionFileTreeClick, 0, 7}
	if !bytes.Equal(got, want) {
		t.Fatalf("file tree click packet = %v, want %v", got, want)
	}
}

func TestEncodeGUIExecuteCommand(t *testing.T) {
	got := EncodeGUIExecuteCommand("write")
	want := []byte{generated.OPGuiAction, generated.GUIActionExecuteCommand, 0, 5, 'w', 'r', 'i', 't', 'e'}
	if !bytes.Equal(got, want) {
		t.Fatalf("execute command packet = %v, want %v", got, want)
	}
}
