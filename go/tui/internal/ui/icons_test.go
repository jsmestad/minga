package ui

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestFileTreeIconUsesTransmittedColorOnlyWhenUnselected(t *testing.T) {
	row := protocol.FileTreeRow{Icon: "", IconColor: 0xDEA584, Name: "main.rs"}

	icon := fileTreeIcon(row, false)
	selected := fileTreeIcon(row, true)

	if icon.glyph != "" {
		t.Fatalf("glyph = %q, want the transmitted glyph", icon.glyph)
	}
	if icon.color != "#DEA584" {
		t.Fatalf("color = %q, want #DEA584 (the theme-resolved icon color)", icon.color)
	}
	if selected.color != "" {
		t.Fatalf("selected icon color = %q, want selection foreground instead of the transmitted icon color", selected.color)
	}
}

func TestFileTreeIconKeepsDeviconFallbackWhenSelected(t *testing.T) {
	// When the BEAM sends no glyph, the renderer derives one locally; the
	// transmitted color is not consulted on that path, even if the row is selected.
	unselected := fileTreeIcon(protocol.FileTreeRow{Name: "main.go", Path: "/p/main.go"}, false)
	selected := fileTreeIcon(protocol.FileTreeRow{Name: "main.go", Path: "/p/main.go", Selected: true}, true)

	if unselected.glyph == "" || selected.glyph == "" {
		t.Fatal("expected a derived devicon glyph for a known filetype")
	}
	if unselected.color == "" || selected.color == "" {
		t.Fatalf("devicon fallback should keep its color for selected and unselected rows: unselected=%q selected=%q", unselected.color, selected.color)
	}
	if unselected.glyph != selected.glyph || unselected.color != selected.color {
		t.Fatalf("devicon fallback should remain unchanged when selected: unselected=%+v selected=%+v", unselected, selected)
	}
}
