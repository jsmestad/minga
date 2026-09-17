package ui

import (
	"encoding/binary"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func residentTestSection(id byte, body []byte) []byte {
	section := []byte{id}
	section = binary.BigEndian.AppendUint32(section, uint32(len(body)))
	return append(section, body...)
}

func residentTestEncodeRow(row protocol.WindowRow) []byte {
	body := []byte{row.Kind}
	body = binary.BigEndian.AppendUint64(body, row.ID)
	body = binary.BigEndian.AppendUint32(body, row.BufferLine)
	body = binary.BigEndian.AppendUint32(body, row.ContentHash)
	body = binary.BigEndian.AppendUint32(body, uint32(len(row.Text)))
	body = append(body, row.Text...)
	return binary.BigEndian.AppendUint16(body, 0)
}

func residentTestRowsDelta(t *testing.T, windowID uint16, contentEpoch, baseCount, resultCount, start, deleteCount uint32, inserted []protocol.WindowRow) protocol.Command {
	t.Helper()
	header := make([]byte, 0, 14)
	header = binary.BigEndian.AppendUint16(header, windowID)
	header = binary.BigEndian.AppendUint32(header, contentEpoch)
	header = append(header, 1)
	header = binary.BigEndian.AppendUint16(header, 0)
	header = binary.BigEndian.AppendUint16(header, 0)
	header = append(header, 0)
	header = binary.BigEndian.AppendUint16(header, 0)

	splices := make([]byte, 0)
	splices = binary.BigEndian.AppendUint32(splices, baseCount)
	splices = binary.BigEndian.AppendUint32(splices, resultCount)
	splices = binary.BigEndian.AppendUint32(splices, 1)
	splices = binary.BigEndian.AppendUint32(splices, start)
	splices = binary.BigEndian.AppendUint32(splices, deleteCount)
	splices = binary.BigEndian.AppendUint32(splices, uint32(len(inserted)))
	for _, row := range inserted {
		splices = append(splices, 1)
		splices = append(splices, residentTestEncodeRow(row)...)
	}

	scroll := make([]byte, 0, 39)
	scroll = binary.BigEndian.AppendUint16(scroll, windowID)
	scroll = append(scroll, 0)
	scroll = binary.BigEndian.AppendUint32(scroll, 0)
	scroll = binary.BigEndian.AppendUint16(scroll, 0)
	scroll = binary.BigEndian.AppendUint16(scroll, 0)
	scroll = binary.BigEndian.AppendUint32(scroll, 0)
	scroll = binary.BigEndian.AppendUint32(scroll, 5)
	scroll = binary.BigEndian.AppendUint32(scroll, 0)
	scroll = binary.BigEndian.AppendUint32(scroll, resultCount)
	scroll = binary.BigEndian.AppendUint32(scroll, contentEpoch)
	scroll = binary.BigEndian.AppendUint32(scroll, 1)
	scroll = binary.BigEndian.AppendUint32(scroll, 0)

	packet := []byte{generated.OPGuiWindowRowsDelta, 3}
	packet = append(packet, residentTestSection(0x01, header)...)
	packet = append(packet, residentTestSection(0x0B, splices)...)
	packet = append(packet, residentTestSection(0x0A, scroll)...)
	command, err := protocol.DecodeCommand(packet)
	if err != nil {
		t.Fatalf("decode actual A2 rows delta: %v", err)
	}
	if command.Kind != protocol.CommandWindowDelta || !command.Window.RowSplicesSet {
		t.Fatalf("actual A2 did not decode as structural rows delta: %+v", command)
	}
	command.Window.GeometrySet = true
	command.Window.Geometry = protocol.PaneGeometry{ContentRect: protocol.Rect{Width: 18, Height: 5}, ViewportRows: 5, TotalLines: resultCount, TotalVisualRows: resultCount}
	return command
}

func residentWindowCommand(windowID uint16, contentEpoch uint32, lineCount int, kind protocol.CommandKind) protocol.Command {
	rows := make([]protocol.WindowRow, lineCount)
	for index := range rows {
		rows[index] = protocol.WindowRow{ID: uint64(index + 1), ContentHash: uint32(index + 1), BufferLine: uint32(index), Text: "line"}
	}
	return protocol.Command{Kind: kind, Window: protocol.WindowContent{ID: windowID, ContentEpoch: contentEpoch, Rows: rows, SequentialRows: true, GeometrySet: true, Geometry: protocol.PaneGeometry{TotalLines: uint32(lineCount), TotalVisualRows: uint32(lineCount)}}}
}

func residentGutterCommand(windowID uint16, contentEpoch, lineCount uint32, retain bool, overrides map[uint32]protocol.GutterEntry) protocol.Command {
	return protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiGutter,
		WindowGutter: protocol.Gutter{
			WindowID:        windowID,
			LineNumberWidth: 3,
			SignColWidth:    2,
			Resident: &protocol.ResidentGutterEntries{
				ContentEpoch:    contentEpoch,
				LineCount:       lineCount,
				RetainOverrides: retain,
				Overrides:       overrides,
			},
		},
	}}
}

func TestResidentGutterSnapshotReplacesAndClearsSigns(t *testing.T) {
	model := New(30, 6, nil, nil)
	model = applyTo(t, model,
		beginFrame(1, 0),
		testThemeCommand(),
		residentWindowCommand(7, 10, 3, protocol.CommandWindowContent),
		residentGutterCommand(7, 10, 3, false, map[uint32]protocol.GutterEntry{1: {BufferLine: 1, SignType: 1}}),
		commitFrame(1),
	)

	model = applyTo(t, model,
		beginFrame(2, 1),
		residentGutterCommand(7, 10, 3, false, map[uint32]protocol.GutterEntry{2: {BufferLine: 2, SignType: 2}}),
		commitFrame(2),
	)
	gutter, ok := model.windowGutter(7)
	if !ok {
		t.Fatal("resident gutter disappeared after replacement snapshot")
	}
	oldEntry, _ := gutter.EntryAt(1)
	newEntry, _ := gutter.EntryAt(2)
	if oldEntry.SignType != 0 || newEntry.SignType != 2 || len(gutter.Resident.Overrides) != 1 {
		t.Fatalf("replacement snapshot did not replace signs: old=%+v new=%+v gutter=%+v", oldEntry, newEntry, gutter)
	}

	model = applyTo(t, model,
		beginFrame(3, 2),
		residentGutterCommand(7, 10, 3, false, map[uint32]protocol.GutterEntry{}),
		commitFrame(3),
	)
	gutter, _ = model.windowGutter(7)
	cleared, _ := gutter.EntryAt(2)
	if cleared.SignType != 0 || len(gutter.Resident.Overrides) != 0 {
		t.Fatalf("explicit empty snapshot did not clear signs: %+v", gutter)
	}
}

func TestResidentGutterRetainPreservesMatchingOverrides(t *testing.T) {
	model := New(30, 6, nil, nil)
	model = applyTo(t, model,
		beginFrame(1, 0),
		testThemeCommand(),
		residentWindowCommand(7, 10, 3, protocol.CommandWindowContent),
		residentGutterCommand(7, 10, 3, false, map[uint32]protocol.GutterEntry{1: {BufferLine: 1, SignType: 1}}),
		commitFrame(1),
	)

	retain := residentGutterCommand(7, 10, 3, true, nil)
	retain.Chrome.WindowGutter.CursorLine = 2
	model = applyTo(t, model, beginFrame(2, 1), retain, commitFrame(2))
	gutter, ok := model.windowGutter(7)
	entry, entryOK := gutter.EntryAt(1)
	if !ok || !entryOK || entry.SignType != 1 || gutter.CursorLine != 2 || gutter.Resident.RetainOverrides {
		t.Fatalf("matching retain did not preserve overrides and update config: %+v", gutter)
	}
}

func TestResidentGutterStructuralCountChangeRequiresReplacement(t *testing.T) {
	model := New(30, 6, nil, nil)
	model = applyTo(t, model,
		beginFrame(1, 0),
		testThemeCommand(),
		residentWindowCommand(7, 10, 2, protocol.CommandWindowContent),
		residentGutterCommand(7, 10, 2, false, map[uint32]protocol.GutterEntry{1: {BufferLine: 1, SignType: 1}}),
		commitFrame(1),
	)

	model = applyTo(t, model,
		beginFrame(2, 1),
		residentWindowCommand(7, 10, 3, protocol.CommandWindowDelta),
		residentGutterCommand(7, 10, 3, false, map[uint32]protocol.GutterEntry{2: {BufferLine: 2, SignType: 3}}),
		commitFrame(2),
	)
	gutter, ok := model.windowGutter(7)
	entry, entryOK := gutter.EntryAt(2)
	if !ok || !entryOK || gutter.EntryCount() != 3 || entry.SignType != 3 {
		t.Fatalf("structural replacement did not publish new extent: %+v", gutter)
	}
}

func TestResidentGutterEpochMismatchRejectsWithoutPublication(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(30, 6, out, nil)
	model = applyTo(t, model,
		beginFrame(1, 0),
		testThemeCommand(),
		residentWindowCommand(7, 10, 3, protocol.CommandWindowContent),
		residentGutterCommand(7, 10, 3, false, map[uint32]protocol.GutterEntry{1: {BufferLine: 1, SignType: 1}}),
		commitFrame(1),
	)
	drainOutboundPackets(out)

	model = applyTo(t, model,
		beginFrame(2, 1),
		residentGutterCommand(7, 11, 3, false, map[uint32]protocol.GutterEntry{2: {BufferLine: 2, SignType: 3}}),
		commitFrame(2),
	)
	packets := drainOutboundPackets(out)
	if len(packets) != 2 || packets[0][0] != generated.OPFrameRejected || packets[0][13] != protocol.RejectWindowEpoch {
		t.Fatalf("expected epoch rejection and diagnostic, got %v", packets)
	}
	gutter, _ := model.windowGutter(7)
	retained, _ := gutter.EntryAt(1)
	rejected, _ := gutter.EntryAt(2)
	if retained.SignType != 1 || rejected.SignType != 0 || model.lastCommittedSeq != 1 {
		t.Fatalf("epoch mismatch partially published: gutter=%+v seq=%d", gutter, model.lastCommittedSeq)
	}
}

func TestResidentGutterTracksLocalPresentationScroll(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.gutters[7] = protocol.Gutter{
		WindowID:        7,
		ContentHeight:   2,
		LineNumberStyle: 3,
		SignColWidth:    2,
		Resident: &protocol.ResidentGutterEntries{
			ContentEpoch: 9,
			LineCount:    4,
			Overrides: map[uint32]protocol.GutterEntry{
				1: {BufferLine: 1, SignType: 8, SignText: "A"},
				2: {BufferLine: 2, SignType: 8, SignText: "B"},
				3: {BufferLine: 3, SignType: 8, SignText: "C"},
			},
		},
	}
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 1, BufferLine: 0, Text: "zero"},
			{ID: 2, ContentHash: 2, BufferLine: 1, Text: "one"},
			{ID: 3, ContentHash: 3, BufferLine: 2, Text: "two"},
			{ID: 4, ContentHash: 4, BufferLine: 3, Text: "three"},
		},
		GeometrySet: true,
		Geometry:    protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 10, Height: 2}, ViewportRows: 2, TotalLines: 4},
		ScrollSet:   true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, VisibleStartLine: 0, VisibleEndLine: 2, OverscanStartLine: 0, OverscanEndLine: 4,
		},
	})

	initial := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(initial, "zero") || !strings.Contains(initial, "A  one") {
		t.Fatalf("initial resident gutter rows are misaligned: %q", initial)
	}

	model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
	scrolled := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(scrolled, "A  one") || !strings.Contains(scrolled, "B  two") || strings.Contains(scrolled, "zero") {
		t.Fatalf("locally scrolled resident gutter rows are misaligned: %q", scrolled)
	}
}

func TestResidentGutterOverridesParticipateInLineCacheIdentity(t *testing.T) {
	model := New(20, 6, nil, nil)
	window := protocol.WindowContent{ID: 7, ContentEpoch: 9}
	first := protocol.Gutter{WindowID: 7, Resident: &protocol.ResidentGutterEntries{
		ContentEpoch: 9,
		LineCount:    4,
		Overrides:    map[uint32]protocol.GutterEntry{1: {BufferLine: 1, SignType: 1}},
	}}
	second := protocol.Gutter{WindowID: 7, Resident: &protocol.ResidentGutterEntries{
		ContentEpoch: 9,
		LineCount:    4,
		Overrides:    map[uint32]protocol.GutterEntry{1: {BufferLine: 1, SignType: 2}},
	}}

	if model.windowContextFingerprint(window, 20, first, true) == model.windowContextFingerprint(window, 20, second, true) {
		t.Fatal("resident gutter override change did not invalidate line cache identity")
	}
}

func TestSequentialResidentA2StructuralEditsKeepShiftedRowsAndGutterAligned(t *testing.T) {
	const (
		windowID = 7
		epoch    = 19
	)
	baseRows := make([]protocol.WindowRow, 300)
	for index := range baseRows {
		baseRows[index] = protocol.WindowRow{
			ID:          uint64(index + 1),
			BufferLine:  uint32(index),
			ContentHash: uint32(index + 1),
			Text:        fmt.Sprintf("line %03d", index),
		}
	}

	windowCommand := func(rows []protocol.WindowRow) protocol.Command {
		return protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
			ID:             windowID,
			ContentEpoch:   epoch,
			SequentialRows: true,
			Rows:           rows,
			GeometrySet:    true,
			Geometry:       protocol.PaneGeometry{ContentRect: protocol.Rect{Width: 18, Height: 5}, ViewportRows: 5, TotalLines: uint32(len(rows)), TotalVisualRows: uint32(len(rows))},
			ScrollSet:      true,
			Scroll: protocol.ScrollPresentation{
				WindowID: windowID, ContentEpoch: epoch, VisibleEndLine: 5, OverscanEndLine: uint32(len(rows)), LayoutGeneration: 1,
			},
		}}
	}
	gutterCommand := func(count uint32) protocol.Command {
		command := residentGutterCommand(windowID, epoch, count, false, map[uint32]protocol.GutterEntry{})
		command.Chrome.WindowGutter.ContentHeight = 5
		command.Chrome.WindowGutter.LineNumberStyle = 1
		return command
	}
	hydrate := func(rows []protocol.WindowRow) Model {
		model := New(20, 8, nil, nil)
		return applyTo(t, model, beginFrame(1, 0), testThemeCommand(), windowCommand(rows), gutterCommand(uint32(len(rows))), commitFrame(1))
	}
	scrollTo50 := func(model Model) Model {
		for range 50 {
			model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
		}
		return model
	}
	render := func(model Model) string {
		return strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[windowID])), "\n")
	}

	model := scrollTo50(hydrate(baseRows))
	_ = render(model)
	inserted := []protocol.WindowRow{
		{ID: 1_001, BufferLine: 50, ContentHash: 1_001, Text: "inserted A"},
		{ID: 1_002, BufferLine: 51, ContentHash: 1_002, Text: "inserted B"},
		{ID: 1_003, BufferLine: 52, ContentHash: 1_003, Text: "inserted C"},
	}
	insertA2 := residentTestRowsDelta(t, windowID, epoch, 300, 303, 50, 0, inserted)
	model = applyTo(t, model, beginFrame(2, 1), insertA2, gutterCommand(303), commitFrame(2))
	if model.lastFrameOutcome != frameOutcomeApplied || !model.residentRows[windowID].sequential {
		t.Fatalf("sequential A2 insert outcome = %v", model.lastFrameOutcome)
	}

	expectedAfterInsert := make([]protocol.WindowRow, 0, 303)
	expectedAfterInsert = append(expectedAfterInsert, baseRows[:50]...)
	expectedAfterInsert = append(expectedAfterInsert, inserted...)
	expectedAfterInsert = append(expectedAfterInsert, baseRows[50:]...)
	for index := range expectedAfterInsert {
		expectedAfterInsert[index].BufferLine = uint32(index)
	}
	freshAfterInsert := scrollTo50(hydrate(expectedAfterInsert))
	if incremental, fresh := render(model), render(freshAfterInsert); incremental != fresh {
		t.Fatalf("shifted suffix render differs from fresh hydration:\nincremental:\n%s\nfresh:\n%s", incremental, fresh)
	}
	shifted, shiftedOK := model.windowRow(model.windows[windowID], 53)
	gutter, gutterOK := model.windowGutter(windowID)
	gutterEntry, gutterEntryOK := gutter.EntryAt(53)
	if !shiftedOK || shifted.BufferLine != 53 || shifted.Text != "line 050" || !gutterOK || !gutterEntryOK || gutterEntry.BufferLine != 53 {
		t.Fatalf("shifted suffix and gutter disagree: row=%+v rowOK=%v gutter=%+v gutterOK=%v", shifted, shiftedOK, gutterEntry, gutterOK && gutterEntryOK)
	}

	deleteA2 := residentTestRowsDelta(t, windowID, epoch, 303, 300, 50, 3, nil)
	model = applyTo(t, model, beginFrame(3, 2), deleteA2, gutterCommand(300), commitFrame(3))
	if model.lastFrameOutcome != frameOutcomeApplied {
		t.Fatalf("sequential A2 deletion outcome = %v", model.lastFrameOutcome)
	}
	freshAfterDelete := scrollTo50(hydrate(baseRows))
	if incremental, fresh := render(model), render(freshAfterDelete); incremental != fresh {
		t.Fatalf("post-deletion render differs from fresh hydration:\nincremental:\n%s\nfresh:\n%s", incremental, fresh)
	}
	restored, restoredOK := model.windowRow(model.windows[windowID], 50)
	if !restoredOK || restored.BufferLine != 50 || restored.Text != "line 050" {
		t.Fatalf("deletion did not restore projected suffix: %+v, %v", restored, restoredOK)
	}
}

func TestFullSnapshotPromotesSequentialRowsWithinContentEpoch(t *testing.T) {
	model := New(20, 8, nil, nil)
	windowed := residentWindowCommand(7, 10, 3, protocol.CommandWindowContent)
	windowed.Window.SequentialRows = false
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), windowed, commitFrame(1))
	sequential := residentWindowCommand(7, 10, 3, protocol.CommandWindowContent)
	model = applyTo(t, model, beginFrame(2, 1), sequential, commitFrame(2))
	if model.lastFrameOutcome != frameOutcomeApplied || !model.residentRows[7].sequential || model.lastCommittedSeq != 2 {
		t.Fatal("same-epoch full snapshot did not promote the row store")
	}
}

func TestResidentGutterRejectsWindowedRows(t *testing.T) {
	model := New(20, 8, nil, nil)
	window := residentWindowCommand(7, 10, 3, protocol.CommandWindowContent)
	window.Window.SequentialRows = false
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), window,
		residentGutterCommand(7, 10, 3, false, nil), commitFrame(1))
	if model.lastFrameOutcome != frameOutcomeRejected || model.lastCommittedSeq != 0 {
		t.Fatal("resident gutter paired with windowed rows was published")
	}
}

func TestSequentialRowsRejectIncompleteDocumentWithoutGutter(t *testing.T) {
	model := New(20, 8, nil, nil)
	window := residentWindowCommand(7, 10, 3, protocol.CommandWindowContent)
	window.Window.Geometry.TotalLines = 300
	window.Window.Geometry.TotalVisualRows = 300
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), window, commitFrame(1))
	if model.lastFrameOutcome != frameOutcomeRejected || model.lastCommittedSeq != 0 {
		t.Fatal("incomplete sequential document without a gutter was published")
	}
}
