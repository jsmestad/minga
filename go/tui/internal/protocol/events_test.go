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

func TestEncodeGUIBreadcrumbClick(t *testing.T) {
	got := EncodeGUIBreadcrumbClick(3)
	want := []byte{generated.OPGuiAction, generated.GUIActionBreadcrumbClick, 3}
	if !bytes.Equal(got, want) {
		t.Fatalf("breadcrumb click packet = %v, want %v", got, want)
	}
}

func TestEncodeGUICompletionSelect(t *testing.T) {
	got := EncodeGUICompletionSelect(258)
	want := []byte{generated.OPGuiAction, generated.GUIActionCompletionSelect, 1, 2}
	if !bytes.Equal(got, want) {
		t.Fatalf("completion select packet = %v, want %v", got, want)
	}
}

func TestEncodeGUIHoverOpenAction(t *testing.T) {
	got := EncodeGUIHoverOpenAction()
	want := []byte{generated.OPGuiAction, generated.GUIActionHoverOpenAction}
	if !bytes.Equal(got, want) {
		t.Fatalf("hover open action packet = %v, want %v", got, want)
	}
}

func TestEncodeGUISidebarAction(t *testing.T) {
	got := EncodeGUISidebarAction("git", "git_status", "activate")
	want := []byte{
		generated.OPGuiAction, generated.GUIActionSidebarAction,
		0, 3, 'g', 'i', 't',
		0, 10, 'g', 'i', 't', '_', 's', 't', 'a', 't', 'u', 's',
		0, 8, 'a', 'c', 't', 'i', 'v', 'a', 't', 'e',
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("sidebar action packet = %v, want %v", got, want)
	}
}
