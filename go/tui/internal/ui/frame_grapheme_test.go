package ui

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

func TestFrameCompositionPreservesCompleteGraphemes(t *testing.T) {
	for _, test := range []struct {
		name    string
		content string
		want    string
		cluster string
	}{
		{name: "ASCII base", content: "ae\u0301z", want: "ae\u0301z", cluster: "e\u0301"},
		{name: "non-composable marks", content: "ax\u0301\u0327z", want: "ax\u0301\u0327z", cluster: "x\u0301\u0327"},
		{name: "non-ASCII base", content: "a界\u0301z", want: "a界\u0301z", cluster: "界\u0301"},
		{name: "style between base and mark", content: "ae\x1b[31m\u0301\x1b[0mz", want: "ae\u0301z", cluster: "e\u0301"},
	} {
		t.Run(test.name, func(t *testing.T) {
			model := New(30, 4, nil, nil)
			rendered := model.composeFrame(test.content)
			if stripped := ansi.Strip(rendered); !strings.Contains(stripped, test.want) {
				t.Fatalf("shared frame compositor changed source text: got %q, want %q", stripped, test.want)
			}
			canvas := lipgloss.NewCanvas(model.width, model.height)
			canvas.Compose(lipgloss.NewLayer(rendered))
			cell := canvas.CellAt(1, 0)
			if cell == nil || cell.Content != test.cluster || cell.Width != ansi.StringWidth(test.cluster) {
				t.Fatalf("compositor detached combining content: got %+v, want complete cluster %q", cell, test.cluster)
			}
			next := canvas.CellAt(1+ansi.StringWidth(test.cluster), 0)
			if next == nil || next.Content != "z" {
				t.Fatalf("combining content drifted into following cell: %+v", next)
			}
		})
	}
}
