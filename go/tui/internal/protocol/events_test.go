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

func TestEncodeGUITabReorder(t *testing.T) {
	got := EncodeGUITabReorder(0x01020304, 5)
	want := []byte{generated.OPGuiAction, generated.GUIActionTabReorder, 0x01, 0x02, 0x03, 0x04, 0, 5}
	if !bytes.Equal(got, want) {
		t.Fatalf("tab_reorder packet = %v, want %v", got, want)
	}
}

func TestEncodeGUIFileTreeDrop(t *testing.T) {
	got := EncodeGUIFileTreeDrop(2, 0xAABBCCDD, true, 0, "id", "p", []string{"src/a.ex"})
	want := []byte{
		generated.OPGuiAction, generated.GUIActionFileTreeDrop,
		0, 2, // target_index
		0xAA, 0xBB, 0xCC, 0xDD, // target_path_hash
		1,              // target_kind (dir)
		0,              // modifiers
		0, 2, 'i', 'd', // target_id (string16)
		0, 1, 'p', // target_path (string16)
		0, 1, // source_count
		0, 8, 's', 'r', 'c', '/', 'a', '.', 'e', 'x', // source path (string16)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("file_tree_drop packet = %v, want %v", got, want)
	}
}

func TestEncodeGUIFileTreeDropFileTarget(t *testing.T) {
	got := EncodeGUIFileTreeDrop(0, 0, false, 0, "", "", nil)
	// target_kind byte must be 0 for a file target, source_count 0.
	if got[8] != 0 {
		t.Fatalf("target_kind = %d, want 0 for a file target", got[8])
	}
}

func TestEncodeGUIExecuteCommand(t *testing.T) {
	got := EncodeGUIExecuteCommand("write")
	want := []byte{generated.OPGuiAction, generated.GUIActionExecuteCommand, 0, 5, 'w', 'r', 'i', 't', 'e'}
	if !bytes.Equal(got, want) {
		t.Fatalf("execute command packet = %v, want %v", got, want)
	}
}

func TestEncodeGUIAgentToolToggle(t *testing.T) {
	got := EncodeGUIAgentToolToggle(0x01020304)
	want := []byte{generated.OPGuiAction, generated.GUIActionAgentToolToggle, 0x01, 0x02, 0x03, 0x04}
	if !bytes.Equal(got, want) {
		t.Fatalf("agent tool toggle packet = %v, want %v", got, want)
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

func TestEncodeGUINotificationDismiss(t *testing.T) {
	got := EncodeGUINotificationDismiss("build:test")
	want := []byte{
		generated.OPGuiAction, generated.GUIActionNotificationDismiss,
		0, 10, 'b', 'u', 'i', 'l', 'd', ':', 't', 'e', 's', 't',
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("notification dismiss packet = %v, want %v", got, want)
	}
}

func TestEncodeGUINotificationAction(t *testing.T) {
	got := EncodeGUINotificationAction("build:test", "show_logs")
	want := []byte{
		generated.OPGuiAction, generated.GUIActionNotificationAction,
		0, 10, 'b', 'u', 'i', 'l', 'd', ':', 't', 'e', 's', 't',
		0, 9, 's', 'h', 'o', 'w', '_', 'l', 'o', 'g', 's',
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("notification action packet = %v, want %v", got, want)
	}
}

func TestEncodeGUIObservatoryInspect(t *testing.T) {
	got := EncodeGUIObservatoryInspect("<0.123.0>")
	want := []byte{
		generated.OPGuiAction, generated.GUIActionObservatoryInspect,
		0, 9, '<', '0', '.', '1', '2', '3', '.', '0', '>',
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("observatory inspect packet = %v, want %v", got, want)
	}
}

func TestEncodeGUITimelineNavigate(t *testing.T) {
	// index is a big-endian u16, matching macOS sendTimelineNavigate (writeU16).
	got := EncodeGUITimelineNavigate(258)
	want := []byte{
		generated.OPGuiAction, generated.GUIActionTimelineNavigate,
		0x01, 0x02,
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("timeline navigate packet = %v, want %v", got, want)
	}
}

func TestEncodeGUIFloatPopupDismiss(t *testing.T) {
	got := EncodeGUIFloatPopupDismiss()
	want := []byte{generated.OPGuiAction, generated.GUIActionFloatPopupDismiss}
	if !bytes.Equal(got, want) {
		t.Fatalf("float popup dismiss packet = %v, want %v", got, want)
	}
}

func TestEncodeScrollBatchDown(t *testing.T) {
	got := EncodeScrollBatch(42, 3, 0)
	want := []byte{generated.OPScrollBatch, 0, 42, 0, 3, 0}
	if !bytes.Equal(got, want) {
		t.Fatalf("scroll batch down = %v, want %v", got, want)
	}
}

func TestEncodeScrollBatchUp(t *testing.T) {
	got := EncodeScrollBatch(1, -5, 1)
	want := []byte{generated.OPScrollBatch, 0, 1, 0xFF, 0xFB, 1}
	if !bytes.Equal(got, want) {
		t.Fatalf("scroll batch up = %v, want %v", got, want)
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
