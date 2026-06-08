package ui

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestFileTreeIconUsesTransmittedColor(t *testing.T) {
	row := protocol.FileTreeRow{Icon: "", IconColor: 0xDEA584, Name: "main.rs"}

	icon := fileTreeIcon(row)

	if icon.glyph != "" {
		t.Fatalf("glyph = %q, want the transmitted glyph", icon.glyph)
	}
	if icon.color != "#DEA584" {
		t.Fatalf("color = %q, want #DEA584 (the theme-resolved icon color)", icon.color)
	}
}

func TestFileTreeIconFallsBackToDevIconsWhenNoGlyph(t *testing.T) {
	// When the BEAM sends no glyph, the renderer derives one locally; the
	// transmitted color is not consulted on that path.
	icon := fileTreeIcon(protocol.FileTreeRow{Name: "main.go", Path: "/p/main.go"})

	if icon.glyph == "" {
		t.Fatal("expected a derived devicon glyph for a known filetype")
	}
}
