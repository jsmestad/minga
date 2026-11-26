package ui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// whichKeyFixture is SPC a as the BEAM sends it: named sections, a group with a count, a breadcrumb and hints.
func whichKeyFixture() protocol.WhichKey {
	entry := func(section, key, label string, kind byte, count string) generated.WhichKeyEntry {
		return generated.WhichKeyEntry{Kind: kind, Key: key, Codepoint: uint32([]rune(key)[0]), Label: label, Section: section, Count: count}
	}
	needsYou := func(e generated.WhichKeyEntry) generated.WhichKeyEntry {
		e.CountTone = protocol.WhichKeyCountNeedsYou
		return e
	}
	return protocol.WhichKey{
		Visible: true,
		Path:    "SPC a",
		Breadcrumb: []generated.WhichKeyCrumb{
			{Key: "SPC", Path: "SPC"},
			{Key: "a", Label: "Minga", Path: "SPC a"},
		},
		Count:     "· 1 needs you",
		CountTone: protocol.WhichKeyCountNeedsYou,
		Hints:     []generated.WhichKeyHint{{Key: "⌫", Label: "back"}, {Key: "esc", Label: "close"}},
		Entries: []generated.WhichKeyEntry{
			needsYou(entry("Tasks", "a", "Agent view", 0, "· 1 needs you")),
			entry("Tasks", "n", "New session", 0, ""),
			entry("Tasks", "s", "Stop", 0, ""),
			entry("Conversation", "v", "Conversation split", 0, ""),
			entry("Conversation", "?", "Ask about this", 0, ""),
			entry("Conversation", "e", "Rewrite selection", 0, ""),
			entry("Conversation", "q", "Queue ›", whichKeyKindGroup, ""),
			entry("Changes", "r", "Pending reviews", 0, "· 3"),
			entry("Changes", "u", "Undo all agent edits", 0, ""),
			entry("Changes", "p", "Publish edits…", 0, ""),
			entry("More", "x", "Context ›", whichKeyKindGroup, ""),
			entry("More", "S", "Session ›", whichKeyKindGroup, ""),
			entry("More", "W", "Why this line", 0, ""),
			entry("More", "A", "Code autobiography", 0, ""),
		},
	}
}

func whichKeyModel(width, height uint16) Model {
	model := New(width, height, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiWhichKey: {Opcode: generated.OPGuiWhichKey, Which: whichKeyFixture()}}
	return model
}

func TestWhichKeyPanelIsFullWidthAboveTheModelineWithoutAShadow(t *testing.T) {
	for _, size := range [][2]uint16{{80, 24}, {120, 40}, {150, 38}} {
		model := whichKeyModel(size[0], size[1])
		layer := model.floatingWhichKeyLayer()
		if layer == nil {
			t.Fatalf("%v: which-key layer did not render", size)
		}
		content := layer.GetContent()
		if layer.GetX() != 0 || lipgloss.Width(content) != int(size[0]) {
			t.Fatalf("%v: panel spans x=%d width %d, want the full width", size, layer.GetX(), lipgloss.Width(content))
		}
		if bottom := layer.GetY() + lipgloss.Height(content); bottom != int(size[1])-model.footerRows() {
			t.Fatalf("%v: panel ends on row %d, want directly above the modeline at %d", size, bottom, int(size[1])-model.footerRows())
		}
		for _, l := range model.floatingOverlayLayers() {
			if l.GetZ() == whichKeyLayerZ-1 {
				t.Fatalf("%v: which-key must not cast a shadow over the modeline", size)
			}
		}
	}
}

func TestWhichKeyBordersCarryTheBreadcrumbAndHints(t *testing.T) {
	model := whichKeyModel(120, 40)
	lines := strings.Split(ansi.Strip(model.renderFloatingWhichKey(whichKeyFixture())), "\n")
	if top := lines[0]; !strings.HasPrefix(top, "╭ SPC › a Minga · 1 needs you ─") || !strings.HasSuffix(top, "╮") {
		t.Fatalf("top border should carry the breadcrumb and the group count: %q", top)
	}
	// One leading edge: the breadcrumb starts in the column where section names start.
	if crumb, section := strings.Index(lines[0], "SPC"), strings.Index(lines[1], "Tasks"); len([]rune(lines[0][:crumb])) != len([]rune(lines[1][:section])) {
		t.Fatalf("breadcrumb and section names should share a leading edge: %q / %q", lines[0], lines[1])
	}
	if bottom := lines[len(lines)-1]; !strings.HasSuffix(bottom, " ⌫ back  esc close ─╯") {
		t.Fatalf("bottom border should carry the panel's keys: %q", bottom)
	}
}

func TestWhichKeySectionsFormColumnsFilledTopToBottom(t *testing.T) {
	model := whichKeyModel(150, 38)
	lines := strings.Split(ansi.Strip(model.renderFloatingWhichKey(whichKeyFixture())), "\n")
	heading := lines[1]
	for _, name := range []string{"Tasks", "Conversation", "Changes", "More"} {
		if !strings.Contains(heading, name) {
			t.Fatalf("heading row should name every section: %q", heading)
		}
	}
	// Column-major: the first entry row reads across the sections' first entries.
	first := lines[2]
	for _, want := range []string{"a Agent view · 1 needs you", "v Conversation split", "r Pending reviews · 3", "x Context ›"} {
		if !strings.Contains(first, want) {
			t.Fatalf("first row should start each section: want %q in %q", want, first)
		}
	}
	if !strings.Contains(lines[3], "n New session") {
		t.Fatalf("Tasks should continue down its column: %q", lines[3])
	}
	// The column gap is the panel token, with no rule between columns.
	if strings.Count(first, "│") != 2 {
		t.Fatalf("columns are separated by space, not a rule: %q", first)
	}
	gapText := "1 needs you" + strings.Repeat(" ", whichKeyColumnGap.cols()) + "v"
	if !strings.Contains(first, gapText) {
		t.Fatalf("columns should sit %d columns apart after the widest entry: %q", whichKeyColumnGap.cols(), first)
	}
}

func TestWhichKeyNarrowTerminalTruncatesLabelsWithEllipsisAndKeepsRowsInside(t *testing.T) {
	model := whichKeyModel(60, 24)
	popup := ansi.Strip(model.renderFloatingWhichKey(whichKeyFixture()))
	for _, line := range strings.Split(popup, "\n") {
		if got := lipgloss.Width(line); got != 60 {
			t.Fatalf("every row should be exactly the terminal width, got %d: %q", got, line)
		}
	}
	if !strings.Contains(popup, "…") {
		t.Fatalf("a label that does not fit should end in an ellipsis:\n%s", popup)
	}
}

func TestWhichKeyGroupsUseTheGroupColourRoleAndKeysOneColour(t *testing.T) {
	model := whichKeyModel(120, 24)
	model.activePalette = paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{byte(generated.ColorRoleGroup): 0xCA9EE6}})
	columns := whichKeyColumnsFor(whichKeySections(whichKeyFixture().Entries), 4)
	group := generated.WhichKeyEntry{Kind: whichKeyKindGroup, Key: "S", Label: "Session ›"}
	leaf := generated.WhichKeyEntry{Key: "s", Label: "+ looks like a group but is a command"}
	// #CA9EE6 is 202;158;230.
	if cell := model.renderWhichKeyEntry(group, columns[0]); !strings.Contains(cell, "38;2;202;158;230mSession ›") {
		t.Fatalf("group label should draw in the group colour role: %q", cell)
	}
	if cell := model.renderWhichKeyEntry(leaf, columns[0]); strings.Contains(cell, "202;158;230") {
		t.Fatalf("a command row must not use the group colour: %q", cell)
	}
	accent := model.palette().Accent()
	groupKey := lipgloss.NewStyle().Foreground(accent).Render("S")
	leafKey := lipgloss.NewStyle().Foreground(accent).Render("s")
	if !strings.Contains(model.renderWhichKeyEntry(group, columns[0]), strings.TrimSuffix(groupKey, "\x1b[m")) ||
		!strings.Contains(model.renderWhichKeyEntry(leaf, columns[0]), strings.TrimSuffix(leafKey, "\x1b[m")) {
		t.Fatalf("group and command keys should both use the accent colour")
	}
}

func TestWhichKeyCountsDrawInTheRoleTheirToneNames(t *testing.T) {
	// #EF9F76 is 239;159;118, #E78284 is 231;130;132, #949CBB is 148;156;187.
	model := whichKeyModel(120, 24)
	model.activePalette = paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{
		byte(generated.ColorRoleNeedsYou):  0xEF9F76,
		byte(generated.ColorRoleFailure):   0xE78284,
		byte(generated.ColorRoleTextMuted): 0x949CBB,
	}})
	columns := whichKeyColumnsFor(whichKeySections(whichKeyFixture().Entries), 4)
	cases := []struct {
		tone uint8
		rgb  string
	}{
		{protocol.WhichKeyCountNeedsYou, "239;159;118"},
		{protocol.WhichKeyCountError, "231;130;132"},
		{protocol.WhichKeyCountMuted, "148;156;187"},
	}
	for _, c := range cases {
		entry := generated.WhichKeyEntry{Key: "a", Label: "Tasks", Count: "· 1", CountTone: c.tone}
		if cell := model.renderWhichKeyEntry(entry, columns[0]); !strings.Contains(cell, "38;2;"+c.rgb+"m· 1") {
			t.Fatalf("tone %d should draw the count in %s: %q", c.tone, c.rgb, cell)
		}
	}
	if border := model.whichKeyTopBorder(whichKeyFixture(), 120); !strings.Contains(border, "38;2;239;159;118m· 1 needs you") {
		t.Fatalf("the breadcrumb count should draw in its tone's role: %q", border)
	}
}

func TestWhichKeyBreadcrumbTitleIsBold(t *testing.T) {
	model := whichKeyModel(120, 24)
	border := model.whichKeyTopBorder(whichKeyFixture(), 120)
	title := lipgloss.NewStyle().Bold(true).Foreground(model.palette().PopupText()).Background(model.palette().PopupSurface()).Render("Minga")
	if !strings.Contains(border, strings.TrimSuffix(title, "\x1b[m")) {
		t.Fatalf("the open group's name should be bold: %q", border)
	}
	root := protocol.WhichKey{Breadcrumb: []generated.WhichKeyCrumb{{Key: "SPC", Label: "Leader", Path: "SPC"}}}
	leader := lipgloss.NewStyle().Bold(true).Foreground(model.palette().PopupText()).Background(model.palette().PopupSurface()).Render("Leader")
	if border := model.whichKeyTopBorder(root, 120); !strings.Contains(border, strings.TrimSuffix(leader, "\x1b[m")) {
		t.Fatalf("the root title should be bold: %q", border)
	}
}

func TestWhichKeyClicksPressRowsAndClimbTheBreadcrumb(t *testing.T) {
	model := whichKeyModel(120, 40)
	layer := model.floatingWhichKeyLayer()
	if layer == nil {
		t.Fatal("which-key layer did not render")
	}
	grid := strings.Split(ansi.Strip(layer.GetContent()), "\n")
	find := func(text string) (int, int) {
		for y, line := range grid {
			if x := strings.Index(line, text); x >= 0 {
				return lipgloss.Width(line[:x]), layer.GetY() + y
			}
		}
		t.Fatalf("%q not drawn", text)
		return 0, 0
	}
	click := func(x, y int) ([]byte, bool) {
		return model.whichKeyMousePacket(tea.MouseClickMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseLeft}))
	}

	// A row presses its own key on the panel's path; the click lands anywhere on the row.
	x, y := find("Queue ›")
	packet, ok := click(x+2, y)
	if want := protocol.EncodeGUIWhichKeyPress("SPC a", 'q', 0); !ok || string(packet) != string(want) {
		t.Fatalf("Queue row click = %v %q, want %q", ok, packet, want)
	}
	x, y = find("q Queue")
	if packet, _ := click(x, y); string(packet) != string(protocol.EncodeGUIWhichKeyPress("SPC a", 'q', 0)) {
		t.Fatalf("the key cell of a row presses that row too: %q", packet)
	}

	// The SPC crumb goes back up; the crumb for the open group does nothing but is swallowed.
	x, y = find("SPC ›")
	if packet, ok := click(x, y); !ok || string(packet) != string(protocol.EncodeGUIWhichKeyBack("SPC")) {
		t.Fatalf("SPC crumb click = %v %q", ok, packet)
	}
	x, y = find("a Minga")
	if packet, ok := click(x+3, y); !ok || packet != nil {
		t.Fatalf("the open group's crumb is swallowed without a packet, got %v %q", ok, packet)
	}

	// Outside the panel the click is not which-key's.
	if _, ok := click(5, layer.GetY()-1); ok {
		t.Fatal("a click above the panel must fall through")
	}
}
