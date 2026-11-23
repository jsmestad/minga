package ui

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// groupedItems returns one item per group name, labelled "<group>-<n>", with activation ids from 1.
func groupedItems(groups ...string) []protocol.PickerItem {
	items := make([]protocol.PickerItem, 0, len(groups))
	counts := map[string]int{}
	for i, group := range groups {
		items = append(items, protocol.PickerItem{
			ActivationID: uint32(i + 1),
			Label:        fmt.Sprintf("%s-%d", strings.ToLower(group), counts[group]),
			Group:        group,
		})
		counts[group]++
	}
	return items
}

func TestPickerItemWindowMatchesTheUngroupedScrollWindow(t *testing.T) {
	for count := 1; count <= 14; count++ {
		items := make([]protocol.PickerItem, count)
		for budget := 1; budget <= 12; budget++ {
			for selected := 0; selected < count; selected++ {
				wantStart := 0
				if selected >= budget {
					wantStart = selected - budget + 1
				}
				wantEnd := min(wantStart+budget, count)
				start, end, _ := pickerItemWindow(items, selected, budget)
				if start != wantStart || end != wantEnd {
					t.Fatalf("count %d budget %d selected %d: window [%d,%d), want [%d,%d)", count, budget, selected, start, end, wantStart, wantEnd)
				}
			}
		}
	}
}

func TestPickerItemWindowCountsSectionHeaderRows(t *testing.T) {
	items := groupedItems("A", "A", "A", "B", "B", "B")
	for _, tc := range []struct {
		selected, start, end int
	}{
		// Header A, a-0, a-1, a-2, then header B would need two rows for b-0.
		{selected: 0, start: 0, end: 3},
		// Header A (kept at the top), a-2, header B, b-0, b-1.
		{selected: 4, start: 2, end: 5},
		// Header B, b-0, b-1, b-2.
		{selected: 5, start: 3, end: 6},
	} {
		start, end, headers := pickerItemWindow(items, tc.selected, 5)
		if start != tc.start || end != tc.end || !headers {
			t.Fatalf("selected %d: window [%d,%d) headers=%v, want [%d,%d) with headers", tc.selected, start, end, headers, tc.start, tc.end)
		}
		if rows := pickerItemRows(items, start, end-1, true); rows > 5 {
			t.Fatalf("selected %d: %d rows exceed the budget", tc.selected, rows)
		}
	}
}

func TestPickerItemWindowDropsHeadersWhenOnlyTheSelectedItemFits(t *testing.T) {
	items := groupedItems("A", "A", "B", "B")
	start, end, headers := pickerItemWindow(items, 3, 1)
	if start != 3 || end != 4 || headers {
		t.Fatalf("one-row list: window [%d,%d) headers=%v, want [3,4) without headers", start, end, headers)
	}
}

func TestGroupedPickerDrawsOneHeaderPerSectionAboveItsItems(t *testing.T) {
	for _, width := range []uint16{60, 80, 120} {
		// A 40-row terminal gives the overlay its 12-row maximum, room for every row and both headers.
		model := New(width, 40, nil)
		lines := strings.Split(ansi.Strip(model.renderFloatingPicker(modelPickerFixture(0), protocol.PickerPreview{})), "\n")
		var body []string
		for _, line := range lines {
			if text := strings.TrimSpace(strings.Trim(line, "│╭╮╰╯─")); text != "" {
				body = append(body, text)
			}
		}
		// Title, then the sections: each header once, directly above its first item.
		want := []string{"Claude (subscription)", "Claude Opus 4", "Claude Sonnet 4", "Claude Haiku 4", "Connection", "Retry current connection"}
		got := []string{}
		for _, text := range body[1:] {
			for _, label := range want {
				if text == label || strings.Contains(text, label+" ") || strings.HasSuffix(text, label) {
					got = append(got, label)
					break
				}
			}
		}
		if strings.Join(got, "|") != strings.Join(want, "|") {
			t.Fatalf("width %d: rows %q, want %q\n%s", width, got, want, strings.Join(lines, "\n"))
		}
		if strings.Count(strings.Join(lines, "\n"), "Claude (subscription)") != 1 {
			t.Fatalf("width %d: the route name should appear once, as the header:\n%s", width, strings.Join(lines, "\n"))
		}
	}
}

func TestUngroupedPickerDrawsNoHeaderRows(t *testing.T) {
	model := New(80, 24, nil)
	files := protocol.Picker{Visible: true, Title: "Files", Items: []protocol.PickerItem{
		{Label: "main.ex", Description: "lib/minga"},
		{Label: "editor.ex", Description: "lib/minga_editor"},
		{Label: "picker.ex", Description: "lib/minga_editor/ui"},
	}}
	rows := model.renderPickerList(files.Title, files, 5, 60)
	for i, label := range []string{"main.ex", "editor.ex", "picker.ex"} {
		if row := ansi.Strip(rows[i+2]); !strings.Contains(row, label) {
			t.Fatalf("row %d should be item %q with no header before it: %q", i+2, label, row)
		}
	}
}

func TestGroupedPickerKeepsTheSelectedItemAndItsHeaderInView(t *testing.T) {
	groups := make([]string, 0, 30)
	for i := 0; i < 15; i++ {
		groups = append(groups, "Alpha")
	}
	for i := 0; i < 15; i++ {
		groups = append(groups, "Beta")
	}
	items := groupedItems(groups...)
	model := New(80, 16, nil)
	for _, selected := range []int{0, 14, 15, 29} {
		picker := protocol.Picker{Visible: true, Title: "Grouped", Selected: uint16(selected), SelectedID: items[selected].ActivationID, Items: items}
		height := 8
		rows := model.renderPickerList(picker.Title, picker, height, 60)
		if len(rows) != height {
			t.Fatalf("selected %d: %d rows, want exactly %d", selected, len(rows), height)
		}
		text := make([]string, len(rows))
		for i, row := range rows {
			text[i] = strings.TrimSpace(ansi.Strip(row))
		}
		label := items[selected].Label
		selectedRow := -1
		for i, row := range text {
			if strings.HasPrefix(row, "▌") && strings.HasSuffix(row, label) {
				selectedRow = i
			}
		}
		if selectedRow < 0 {
			t.Fatalf("selected %d (%s) is not drawn:\n%s", selected, label, strings.Join(text, "\n"))
		}
		// The first drawn item names its section, so the selected item's group is always on screen above it.
		header := -1
		for i := 2; i < selectedRow; i++ {
			if text[i] == items[selected].Group {
				header = i
			}
		}
		if header < 0 {
			t.Fatalf("selected %d: no %q header above the selection:\n%s", selected, items[selected].Group, strings.Join(text, "\n"))
		}
	}
}

func TestGroupedPickerClicksActivateItemsAndHeadersActivateNothing(t *testing.T) {
	out := make(chan []byte, 2)
	model := New(80, 40, out)
	picker := modelPickerFixture(0)
	picker.Generation = 51
	model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Picker: picker}
	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	cell := func(label string) tea.MouseClickMsg {
		t.Helper()
		for y, line := range lines {
			if i := strings.Index(line, label); i >= 0 {
				return tea.MouseClickMsg(tea.Mouse{X: ansi.StringWidth(line[:i]), Y: y, Button: tea.MouseLeft})
			}
		}
		t.Fatalf("picker did not draw %q", label)
		return tea.MouseClickMsg{}
	}
	click := func(msg tea.MouseClickMsg, want []byte) {
		t.Helper()
		updated, _ := model.Update(msg)
		model = updated.(Model)
		select {
		case got := <-out:
			if !bytes.Equal(got, want) {
				t.Fatalf("click (%d,%d): packet %x, want %x", msg.X, msg.Y, got, want)
			}
		default:
			if want != nil {
				t.Fatalf("click (%d,%d): no packet, want %x", msg.X, msg.Y, want)
			}
		}
	}
	click(cell("Claude (subscription)"), nil)
	click(cell("Connection"), nil)
	click(cell("Claude Opus 4"), pickerActivationPacket(51, 1))
	click(cell("Claude Haiku 4"), pickerActivationPacket(51, 3))
	click(cell("Retry current connection"), pickerActivationPacket(51, 4))
}

func TestPickerLocalNavigationMovesFromOneSectionToTheNextItem(t *testing.T) {
	out := make(chan []byte, 1)
	model := New(60, 16, out)
	items := groupedItems("A", "A", "B")
	model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Opcode: generated.OPGuiPicker, Picker: protocol.Picker{Visible: true, Generation: 7, Selected: 1, SelectedID: 2, Items: items}}
	model.applyMutation(focusOwnerCommand(1, 8))

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'j', Text: "j"}))
	model = updated.(Model)

	if got := model.effectivePickerIndex(model.chrome[generated.OPGuiPicker].Picker); got != 2 {
		t.Fatalf("j from the last item of section A should preview the first item of B (index 2), got %d", got)
	}
}
