package ui

import (
	"fmt"
	"strings"
	"testing"

	xansi "github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestAuthoredTextMarginPreservesBoundaryGlyphsAndPointerTargets(t *testing.T) {
	for _, paneWidth := range []int{1, 12, 60, 140} {
		for _, totalRows := range []int{1, 12} {
			t.Run(fmt.Sprintf("width%d/rows%d", paneWidth, totalRows), func(t *testing.T) {
				textWidth := max(paneWidth-1, 1)
				prefix := ""
				if textWidth >= 6 {
					prefix = "界e\u0301😀"
				}
				text := prefix + strings.Repeat("x", textWidth-xansi.StringWidth(prefix)-1) + "t"
				rows := make([]protocol.WindowRow, totalRows)
				for index := range rows {
					rows[index] = protocol.WindowRow{ID: uint64(index + 100), ContentHash: uint32(index + 1), BufferLine: uint32(index), Text: text}
				}
				window := protocol.WindowContent{
					ID: 7, ContentEpoch: 1, Rows: rows, GeometrySet: true,
					Geometry: protocol.PaneGeometry{
						ContentRect:  protocol.Rect{Width: uint16(paneWidth), Height: 3},
						TextRect:     protocol.Rect{Width: uint16(textWidth), Height: 3},
						ClipRect:     protocol.Rect{Width: uint16(textWidth), Height: 3},
						ViewportRows: 3, ViewportCols: uint16(textWidth), TotalLines: uint32(totalRows),
					},
				}
				model := New(uint16(max(paneWidth, 12)), 8, nil, nil)
				model = applyTo(t, model,
					beginFrame(1, 0), testThemeCommand(),
					protocol.Command{Kind: protocol.CommandWindowContent, Window: window},
					protocol.Command{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 700}},
					commitFrame(1),
				)
				assertCells := func(model Model, capacity int) {
					t.Helper()
					lines := strings.Split(xansi.Strip(model.View().Content), "\n")
					line := lines[model.layout.body.Y]
					if got, want := xansi.Cut(line, 0, capacity), xansi.Cut(text, 0, capacity); got != want {
						t.Fatalf("text aperture lost boundary characters: got %q, want %q", got, want)
					}
					margin := xansi.Cut(line, capacity, paneWidth)
					if totalRows > 3 && paneWidth > 1 {
						want := strings.Repeat(" ", paneWidth-capacity-1) + "▐"
						if margin != want {
							t.Fatalf("indicator must stay outside text: got %q, want %q", margin, want)
						}
					} else if strings.TrimSpace(margin) != "" {
						t.Fatalf("inactive margin contains text: %q", margin)
					}
				}
				assertCells(model, textWidth)
				assertTextTarget(t, model, model.layout.body.X+textWidth-1, model.layout.body.Y, 7, 700, 0, 100, uint32(textWidth-1))
				if paneWidth > textWidth {
					if _, ok := model.editorTextTargetAt(model.layout.body.X+textWidth, model.layout.body.Y, 0); ok {
						t.Fatal("presentation margin became an initial text target")
					}
				}
				if got := model.maxPresentationLeft(model.windows[7]); got != 0 {
					t.Fatalf("already fitting rows gained horizontal overflow: %d", got)
				}

				delta := window
				delta.Rows = make([]protocol.WindowRow, len(rows))
				for index, row := range rows {
					delta.Rows[index] = protocol.WindowRow{Ref: true, ID: row.ID, ContentHash: row.ContentHash}
				}
				model = applyTo(t, model, deltaWindowFrame(2, 1, delta)...)
				assertCells(model, textWidth)

				if textWidth > 1 {
					delta.Geometry.TextRect.Width--
					delta.Geometry.ClipRect.Width--
					delta.Geometry.ViewportCols--
					model = applyTo(t, model, deltaWindowFrame(3, 2, delta)...)
					assertCells(model, textWidth-1)
					if _, ok := model.editorTextTargetAt(model.layout.body.X+textWidth-1, model.layout.body.Y, 0); ok {
						t.Fatal("old cached text capacity survived a geometry change")
					}
				}
			})
		}
	}
}
