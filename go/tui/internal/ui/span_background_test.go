package ui

import (
	"strings"
	"testing"

	xansi "github.com/charmbracelet/x/ansi"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestSpanBackgroundTintsCellsPastRowText(t *testing.T) {
	model := New(12, 3, nil)
	const tint = 0x2C3A2C
	code := protocol.Span{StartCol: 0, EndCol: 4, FG: 0x98BE65, BG: tint}
	fill := protocol.Span{StartCol: 4, EndCol: 10, BG: tint}

	tinted := model.renderRow(protocol.WindowContent{}, protocol.WindowRow{Text: "+ ab", Spans: []protocol.Span{code, fill}}, 0, 10, false, 0)
	untinted := model.renderRow(protocol.WindowContent{}, protocol.WindowRow{Text: "+ ab", Spans: []protocol.Span{code}}, 0, 10, false, 0)

	if xansi.Strip(tinted) != xansi.Strip(untinted) || xansi.StringWidth(tinted) != 10 {
		t.Fatalf("tint must not change row text or width: %q vs %q", xansi.Strip(tinted), xansi.Strip(untinted))
	}
	if tinted == untinted {
		t.Fatal("a background span past the row text must paint its cells")
	}
	if strings.Count(xansi.Strip(tinted), " ") != 7 {
		t.Fatalf("row should keep one text space and six tinted blanks: %q", xansi.Strip(tinted))
	}
}

func TestForegroundOnlySpanPastRowTextLeavesCellsUnpainted(t *testing.T) {
	model := New(12, 3, nil)
	row := protocol.WindowRow{Text: "ab", Spans: []protocol.Span{{StartCol: 0, EndCol: 10, FG: 0x98BE65}}}
	plain := protocol.WindowRow{Text: "ab", Spans: []protocol.Span{{StartCol: 0, EndCol: 2, FG: 0x98BE65}}}

	if model.renderRow(protocol.WindowContent{}, row, 0, 10, false, 0) != model.renderRow(protocol.WindowContent{}, plain, 0, 10, false, 0) {
		t.Fatal("only a span background extends past the row text")
	}
}
