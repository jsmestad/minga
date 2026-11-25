package ui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// boardModeline is the "editing while Minga works" modeline as the BEAM sends it: the design's order, with drop ranks filetype 2, position 3, git 4, Minga 5 (compact) and warnings 6.
func boardModeline() protocol.StatusBar {
	working := byte(1)
	return protocol.StatusBar{
		Left: []protocol.StatusSegment{
			{Name: "mode", Text: "NORMAL"},
			{Name: "needs_you", Text: "Needs you", State: 2, Label: "1 task needs you", Key: "SPC a a", Command: "agent_tasks"},
			{Name: "filename", Text: "chrome_state.ex ●", Command: "buffer_list"},
			{Name: "change", Text: "change 1/2"},
			{Name: "git", Text: "main +11", Drop: 4},
			{Name: "minga", Text: "Minga working 2/3", Drop: 5, HasCompact: true, Compact: "2/3", State: working},
			{Name: "errors", Text: "1"},
			{Name: "warnings", Text: "2", Drop: 6},
		},
		Right: []protocol.StatusSegment{
			{Name: "filetype", Text: "Elixir", Drop: 2},
			{Name: "position", Text: "240:31", Drop: 3},
		},
	}
}

func TestModelineDropsSegmentsInTheBEAMsOrderAsTheTerminalNarrows(t *testing.T) {
	cases := []struct {
		width   int
		present []string
		absent  []string
	}{
		{150, []string{"NORMAL", "◉ Needs you", "chrome_state.ex ●", "change 1/2", "main +11", "◐ Minga working 2/3", "E 1", "W 2", "Elixir", "240:31"}, nil},
		{90, []string{"main +11", "◐ Minga working 2/3", "W 2"}, []string{"Elixir", "240:31"}},
		{80, []string{"◐ Minga working 2/3", "W 2"}, []string{"main +11", "Elixir", "240:31"}},
		{70, []string{"◐ 2/3", "W 2"}, []string{"Minga working", "main +11"}},
		{60, []string{"NORMAL", "◉ Needs you", "chrome_state.ex ●", "change 1/2", "◐ 2/3", "E 1"}, []string{"W 2"}},
	}
	for _, tc := range cases {
		model := New(uint16(tc.width), 24, nil)
		footer := ansi.Strip(model.renderStatusSegments(boardModeline()))
		for _, want := range tc.present {
			if !strings.Contains(footer, want) {
				t.Errorf("width %d: missing %q in %q", tc.width, want, footer)
			}
		}
		for _, gone := range tc.absent {
			if strings.Contains(footer, gone) {
				t.Errorf("width %d: %q should have given way in %q", tc.width, gone, footer)
			}
		}
		if got := ansi.StringWidth(footer); got > tc.width {
			t.Errorf("width %d: modeline is %d cells wide: %q", tc.width, got, footer)
		}
	}
}

func TestModelineSegmentsSitOneGapApartInsideTheInsets(t *testing.T) {
	model := New(60, 24, nil)
	status := protocol.StatusBar{
		Left:  []protocol.StatusSegment{{Name: "mode", Text: "NORMAL"}, {Name: "filename", Text: "a.ex"}},
		Right: []protocol.StatusSegment{{Name: "filetype", Text: "Elixir", Drop: 2}, {Name: "position", Text: "1:1", Drop: 3}},
	}
	footer := ansi.Strip(model.renderStatusSegments(status))
	pill := gap(modelinePillPaddingH) + "NORMAL" + gap(modelinePillPaddingH)
	if !strings.HasPrefix(footer, gap(modelineInset)+pill+gap(modelineSegmentGap)+"a.ex") {
		t.Fatalf("left cluster should start at the inset, one gap after the pill: %q", footer)
	}
	if !strings.HasSuffix(footer, "Elixir"+gap(modelineSegmentGap)+"1:1"+gap(modelineInset)) {
		t.Fatalf("right cluster should end at the trailing inset: %q", footer)
	}
	if strings.Contains(footer, "│") {
		t.Fatalf("segments are separated by a gap, not a rule: %q", footer)
	}
}

func TestModelineStateGlyphComesFromTheStateToken(t *testing.T) {
	model := New(80, 24, nil)
	for _, state := range generated.SpineStates {
		token := state.Token()
		wire := byte(0)
		for candidate := byte(1); candidate < 16; candidate++ {
			if got, ok := generated.SpineStateFromWire(candidate); ok && got == state {
				wire = candidate
			}
		}
		rendered := ansi.Strip(model.renderModelineSegment(protocol.StatusSegment{Name: "minga", Text: "Minga", State: wire}, false))
		if rendered != token.Glyph+gap(modelineGlyphToWords)+"Minga" {
			t.Errorf("%s: rendered %q", token.ID, rendered)
		}
	}
}

func TestModelineHoverEchoesMeaningAndKey(t *testing.T) {
	model := New(150, 24, nil)
	model.chrome[generated.OPGuiStatusBar] = protocol.ChromePayload{Status: boardModeline()}
	model.layout = model.computeLayout()
	_ = model.View()

	zone := waitForZone(t, model, zoneIDModelineSegment(1))
	hover := tea.MouseMotionMsg(tea.Mouse{X: zone.StartX + 1, Y: zone.StartY})
	updated, _ := model.Update(hover)
	model = updated.(Model)
	if footer := ansi.Strip(model.footerLines()[0]); !strings.Contains(footer, "1 task needs you · SPC a a") {
		t.Fatalf("the echo line should show the hover text: %q", footer)
	}

	click, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY}))
	if !ok || string(click) != string(protocol.EncodeGUIExecuteCommand("agent_tasks")) {
		t.Fatalf("clicking needs-you should run its key's command, ok=%v packet=%v", ok, click)
	}

	// The hover text is read from the current segments: once needs-you is gone, so is its echo.
	resolved := boardModeline()
	resolved.Left = append(resolved.Left[:1:1], resolved.Left[2:]...)
	model.chrome[generated.OPGuiStatusBar] = protocol.ChromePayload{Status: resolved}
	if footer := ansi.Strip(model.footerLines()[0]); strings.Contains(footer, "needs you · SPC a a") {
		t.Fatalf("a stale hover outlived its segment: %q", footer)
	}

	updated, _ = model.Update(tea.MouseMotionMsg(tea.Mouse{X: 0, Y: 0}))
	if got := updated.(Model).modelineHoverSegment; got != 0 {
		t.Fatalf("hover away from the modeline should clear the hover, got segment %d", got)
	}
}

// Hover text fills only the room the segments leave; it never drops a segment.
func TestModelineHoverNeverMovesSegments(t *testing.T) {
	model := New(70, 24, nil)
	status := boardModeline()
	model.chrome[generated.OPGuiStatusBar] = protocol.ChromePayload{Status: status}
	before := ansi.Strip(model.renderStatusSegments(status))
	model.modelineHoverSegment = 2
	after := ansi.Strip(model.renderStatusSegments(status))
	for _, kept := range []string{"NORMAL", "◉ Needs you", "change 1/2", "◐ 2/3", "W 2"} {
		if strings.Contains(before, kept) != strings.Contains(after, kept) {
			t.Fatalf("hovering changed whether %q shows:\nbefore %q\nafter  %q", kept, before, after)
		}
	}
}

// A long notice reserves at most a third of the row, as on macOS, so optional segments are not all dropped for it.
func TestModelineNoticeReservesAtMostAThird(t *testing.T) {
	model := New(150, 24, nil)
	status := boardModeline()
	status.Message = strings.Repeat("a long notice ", 20)
	footer := ansi.Strip(model.renderStatusSegments(status))
	for _, kept := range []string{"main +11", "◐ Minga working 2/3", "W 2"} {
		if !strings.Contains(footer, kept) {
			t.Fatalf("a long notice displaced %q: %q", kept, footer)
		}
	}
	if !strings.Contains(footer, "a long notice") {
		t.Fatalf("the notice should still show, cut to its room: %q", footer)
	}
}

// Which-key and the picker paint above any BEAM-placed footer band, whose layer z is its placement z (at most 301) plus 2 (#4157).
func TestModalLayersPaintAboveFooterBands(t *testing.T) {
	const highestBandLayerZ = 301 + 2
	// Each layer's shadow sits at its z minus 1, so that must still clear the layer below.
	if pickerLayerZ-1 <= highestBandLayerZ || pickerActionMenuLayerZ-1 <= pickerLayerZ || whichKeyLayerZ-1 <= pickerActionMenuLayerZ {
		t.Fatalf("the picker (%d), its action menu (%d) and which-key (%d) must paint above footer bands (%d) and in that order", pickerLayerZ, pickerActionMenuLayerZ, whichKeyLayerZ, highestBandLayerZ)
	}
}
