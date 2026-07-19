package ui

import (
	"bytes"
	"fmt"
	"image/color"
	"reflect"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/cellbuf"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func testThemeCommand() protocol.Command {
	colors := map[byte]uint32{
		themeEditorBG:         0x1E1F2A,
		themeEditorFG:         0xC7D0E8,
		themeTreeBG:           0x222433,
		themeTreeFG:           0xB8C0D8,
		themeTreeSelectBG:     0x343A52,
		themeTreeDirFG:        0x7DB7FF,
		themeTreeSelectionFG:  0xF7FAFF,
		themeTabBG:            0x242634,
		themeTabInactiveFG:    0x747B93,
		themePopupBG:          0x292D3E,
		themePopupFG:          0xD9E0F5,
		themePopupSelBG:       0x3A425C,
		themePopupSelFG:       0xF7FAFF,
		themePopupDescFG:      0x747B93,
		themePopupKeyFG:       0xF7FAFF,
		themeBreadcrumbBG:     0x232634,
		themeModelineBG:       0x222536,
		themeModelineFG:       0xAEB7D0,
		themeAccent:           0x7DB7FF,
		themeGutterFG:         0x697088,
		themeGutterCurrentFG:  0xC7D0E8,
		themeDiagnosticError:  0xFF8AA6,
		themeWarningFG:        0xF5C276,
		themeDiagnosticInfo:   0x7DCFFF,
		themeDiagnosticHint:   0xA6DA95,
		themeHighlightReadBG:  0x33384C,
		themeHighlightWriteBG: 0x4A3F2B,
		themeSelectionBG:      0x2F4463,
	}

	for _, slot := range requiredThemeSlots {
		if _, ok := colors[slot]; !ok {
			colors[slot] = uint32(slot)<<16 | uint32(slot)<<8 | uint32(slot)
		}
	}

	return protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTheme, Theme: protocol.Theme{Colors: colors}}}
}

// frame wraps semantic/chrome commands in a keyframe transaction (#2219):
// begin_frame(seq=1, base=0) ++ gui_theme ++ commands ++ commit_frame(seq=1).
// Under the staged model nothing applies until commit, so tests that exercise
// the live effect of a command must deliver it inside a transaction.
func frame(commands ...protocol.Command) []protocol.Command {
	out := make([]protocol.Command, 0, len(commands)+3)
	out = append(out, protocol.Command{Kind: protocol.CommandBeginFrame, FrameSeq: 1, BaseFrameSeq: 0})
	if found, _ := stagingThemeValidation(commands); !found {
		out = append(out, testThemeCommand())
	}
	out = append(out, commands...)
	out = append(out, protocol.Command{Kind: protocol.CommandCommitFrame, FrameSeq: 1})
	return out
}

func TestFloatingPickerRendersOverEditorAndSuppressesFooterOverlays(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiMinibuffer: {
			Mini: protocol.Minibuffer{Visible: true, Prompt: ":", Input: "write"},
		},
		generated.OPGuiCompletion: {
			Complete: protocol.Completion{Visible: true, Items: []protocol.CompletionItem{{Label: "Enum.map"}}},
		},
		generated.OPGuiWhichKey: {
			Which: protocol.WhichKey{Visible: true, Prefix: "SPC", Bindings: []protocol.WhichKeyBinding{{Key: "f", Description: "file"}}},
		},
		generated.OPGuiPicker: {
			Picker: protocol.Picker{Visible: true, Title: "Files", Query: "main", Items: []protocol.PickerItem{{Label: "main.ex"}}},
		},
	}

	footer := strings.Join(model.footerLines(), "\n")
	if strings.Contains(footer, "Files") || strings.Contains(footer, "main.ex") || strings.Contains(footer, "Enum.map") || strings.Contains(footer, "SPC") || strings.Contains(footer, ":write") {
		t.Fatalf("footer should stay a status bar while picker floats: %q", footer)
	}

	view := ansi.Strip(model.View().Content)
	if !strings.Contains(view, "Files") || !strings.Contains(view, "main.ex") {
		t.Fatalf("view should render floating picker: %q", view)
	}
}

func TestWorkspaceRowRendersAsQuietNavigation(t *testing.T) {
	model := New(100, 20, nil, nil)
	row := ansi.Strip(model.renderWorkspaces(protocol.WorkspaceBar{Spaces: []protocol.Workspace{
		{Label: "Files", Icon: "", TabCount: 1},
		{Label: "Agent", Icon: "󰚩", TabCount: 1, Active: true},
	}}, model.width))

	for _, want := range []string{"Spaces", " Files (1 tab)", "▎󰚩 Agent (1 tab)"} {
		if !strings.Contains(row, want) {
			t.Fatalf("workspace row missing %q in %q", want, row)
		}
	}
	if strings.Contains(row, "workspace") || strings.Contains(row, "Agent 1") || strings.Contains(row, "Files 1") {
		t.Fatalf("workspace row should avoid implementation labels and bare counts: %q", row)
	}
}

func TestViewCarriesFullWindowBackgroundColor(t *testing.T) {
	model := New(20, 6, nil, nil)
	view := model.View()
	if view.BackgroundColor == nil {
		t.Fatal("view should set a background color so Bubble Tea paints transparent cells")
	}
	wantR, wantG, wantB, wantA := model.editorBackground().RGBA()
	gotR, gotG, gotB, gotA := view.BackgroundColor.RGBA()
	if gotR != wantR || gotG != wantG || gotB != wantB || gotA != wantA {
		t.Fatalf("view background = rgba(%d,%d,%d,%d), want rgba(%d,%d,%d,%d)", gotR, gotG, gotB, gotA, wantR, wantG, wantB, wantA)
	}
	if lines := strings.Split(ansi.Strip(view.Content), "\n"); len(lines) < model.height {
		t.Fatalf("view should cover full terminal height, got %d lines for height %d: %+v", len(lines), model.height, lines)
	}
}

func TestWhichKeyRendersCompactFloatingPopup(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiWhichKey: {
			Which: protocol.WhichKey{Visible: true, Prefix: "SPC", Page: 0, PageCount: 2, Bindings: []protocol.WhichKeyBinding{{Key: "/", Description: "Search project"}, {Key: "1", Description: "Tab 1"}, {Key: "2", Description: "Tab 2"}}},
		},
	}

	footer := strings.Join(model.footerLines(), "\n")
	if strings.Contains(footer, "Search project") || strings.Contains(footer, "Tab 1") {
		t.Fatalf("footer should stay a status bar while which-key floats: %q", footer)
	}

	view := ansi.Strip(model.View().Content)
	if !strings.Contains(view, "Keys SPC") || !strings.Contains(view, "1/2") || !strings.Contains(view, "/    Search project") || !strings.Contains(view, "1   󰓩 Tab 1") {
		t.Fatalf("which-key popup should render structured key/description rows: %q", view)
	}
	if !strings.Contains(view, "3 bindings") || !strings.Contains(view, "Esc") {
		t.Fatalf("which-key popup should include a compact footer: %q", view)
	}
}

func TestWhichKeyStylesGroupsAndLimitsColumnCount(t *testing.T) {
	model := New(160, 24, nil, nil)
	bindings := []protocol.WhichKeyBinding{
		{Key: "f", Description: "+file"},
		{Key: "g", Description: "+git"},
		{Key: "b", Description: "+buffer"},
		{Key: "s", Description: "Search project"},
		{Key: "1", Description: "Tab 1"},
		{Key: "2", Description: "Tab 2"},
		{Key: "3", Description: "Tab 3"},
		{Key: "4", Description: "Tab 4"},
		{Key: "5", Description: "Tab 5"},
	}
	popup := ansi.Strip(model.renderFloatingWhichKey(protocol.WhichKey{Visible: true, Prefix: "SPC", Bindings: bindings}))
	if !strings.Contains(popup, "› +file ›") || !strings.Contains(popup, "› +git ›") {
		t.Fatalf("group entries should read as navigable groups: %q", popup)
	}
	firstBindingRow := ""
	for _, line := range strings.Split(popup, "\n") {
		if strings.Contains(line, "+file") {
			firstBindingRow = line
			break
		}
	}
	if count := strings.Count(firstBindingRow, "│"); count > 4 {
		t.Fatalf("which-key should use at most three columns, got row %q", firstBindingRow)
	}
}

func TestExtensionRuntimeEnvelopeIsStoredAndSurfacedInFooter(t *testing.T) {
	model := New(80, 24, nil, nil)
	updated, _ := model.Update(port.PacketMsg{Commands: frame(
		protocol.Command{Kind: protocol.CommandExtensionRuntime, ExtensionRuntime: protocol.ExtensionRuntimePayload{
			ExtensionID: "acme.lint",
			Channel:     "pane",
			Payload:     []byte{0x01, 0x02, 0x03},
		}},
	)})
	model = updated.(Model)

	stored, ok := model.extensionRuntimes["acme.lint"]
	if !ok {
		t.Fatalf("extension runtime envelope was dropped instead of stored: %#v", model.extensionRuntimes)
	}
	if stored.Channel != "pane" || !bytes.Equal(stored.Payload, []byte{0x01, 0x02, 0x03}) {
		t.Fatalf("stored extension runtime payload mismatch: %#v", stored)
	}

	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	if !strings.Contains(footer, "ext acme.lint") {
		t.Fatalf("footer should surface the active extension runtime: %q", footer)
	}
}

func TestExtensionRuntimeLatestEnvelopeWinsAndIdsAreSortedDeterministically(t *testing.T) {
	model := New(80, 24, nil, nil)
	updated, _ := model.Update(port.PacketMsg{Commands: frame(
		protocol.Command{Kind: protocol.CommandExtensionRuntime, ExtensionRuntime: protocol.ExtensionRuntimePayload{ExtensionID: "zeta", Channel: "a", Payload: []byte{0x01}}},
		protocol.Command{Kind: protocol.CommandExtensionRuntime, ExtensionRuntime: protocol.ExtensionRuntimePayload{ExtensionID: "alpha", Channel: "b", Payload: []byte{0x02}}},
		protocol.Command{Kind: protocol.CommandExtensionRuntime, ExtensionRuntime: protocol.ExtensionRuntimePayload{ExtensionID: "zeta", Channel: "c", Payload: []byte{0x09}}},
	)})
	model = updated.(Model)

	if got := model.extensionRuntimes["zeta"]; got.Channel != "c" || !bytes.Equal(got.Payload, []byte{0x09}) {
		t.Fatalf("latest envelope per extension id should win: %#v", got)
	}
	if got := model.extensionRuntimeStatus(); got != "ext alpha,zeta" {
		t.Fatalf("extension runtime status should list ids sorted: %q", got)
	}
}

func TestExtensionRuntimeIgnoresEmptyExtensionID(t *testing.T) {
	model := New(80, 24, nil, nil)
	updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
		{Kind: protocol.CommandExtensionRuntime, ExtensionRuntime: protocol.ExtensionRuntimePayload{ExtensionID: "", Channel: "pane", Payload: []byte{0x01}}},
	}})
	model = updated.(Model)
	if len(model.extensionRuntimes) != 0 {
		t.Fatalf("envelope with empty extension id should be ignored, got %#v", model.extensionRuntimes)
	}
}

func TestProtocolErrorRendersBlockingSurfaceAndTakesPrecedence(t *testing.T) {
	out := make(chan []byte, 4)
	model := New(80, 24, out, nil)
	// Seed normal content so the test proves the error surface takes precedence
	// over it rather than only rendering on a blank model.
	updated, _ := model.Update(port.PacketMsg{Commands: frame(
		protocol.Command{Kind: protocol.CommandSetTitle, Title: "editor"},
		protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
			ID:   1,
			Rows: []protocol.WindowRow{{Text: "normal editor content"}},
		}},
	)})
	model = updated.(Model)

	message := "protocol_version mismatch: frontend 1, beam 2"
	// protocol_error is out-of-band: it arrives with no open transaction and
	// latches directly.
	updated, _ = model.Update(port.PacketMsg{Commands: []protocol.Command{
		{Kind: protocol.CommandProtocolError, ProtocolError: message},
	}})
	model = updated.(Model)

	if model.protocolError != message {
		t.Fatalf("model did not latch protocol error: %q", model.protocolError)
	}

	rendered := ansi.Strip(model.View().Content)
	if !strings.Contains(rendered, "Protocol error") {
		t.Fatalf("blocking surface should show a title, got: %q", rendered)
	}
	if !strings.Contains(rendered, message) {
		t.Fatalf("blocking surface should show the reason, got: %q", rendered)
	}
	if strings.Contains(rendered, "normal editor content") {
		t.Fatalf("blocking surface should take precedence over normal content, got: %q", rendered)
	}

	packets := drainOutboundPackets(out)
	var logPacket []byte
	for _, packet := range packets {
		if _, _, ok := decodeLogMessage(packet); ok {
			logPacket = packet
		}
	}
	if logPacket == nil {
		t.Fatalf("protocol error should send a log_message packet, got %d packets", len(packets))
	}
	level, text, ok := decodeLogMessage(logPacket)
	if !ok {
		t.Fatalf("protocol error packet should be log_message, got %v", packets[0])
	}
	if level != protocol.LogLevelErr {
		t.Fatalf("protocol error log level = %d, want err", level)
	}
	if !strings.Contains(text, "Go TUI protocol error: "+message) {
		t.Fatalf("protocol error log should include reason, got %q", text)
	}
}

func TestFooterRendersStatusMessageWithModelineSegments(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {
			Status: protocol.StatusBar{
				Message: "Modified buffers exist. Really quit? (y/n)",
				Left:    []protocol.StatusSegment{{Text: " NORMAL "}},
				Right:   []protocol.StatusSegment{{Text: "46:1"}},
			},
		},
	}

	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	if !strings.Contains(footer, "Modified buffers exist. Really quit? (y/n)") {
		t.Fatalf("footer should render status message with modeline segments: %q", footer)
	}
}

func TestOperationOnlyStatusIsDiscoverableAfterCommittedFrame(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.now = func() time.Time { return feedbackTestStart }
	operation := testOperation(42, generated.OperationStatusPending, "Formatting")
	statusCommand := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiStatusBar,
		Status: protocol.StatusBar{Operation: &operation},
	}}

	updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 1, BaseFrameSeq: 0},
		testThemeCommand(),
		statusCommand,
	}})
	model = updated.(Model)
	if _, ok := model.statusBar(); ok || model.feedback.hasDisplay {
		t.Fatal("operation must not be observed before its frame commits")
	}

	updated, _ = model.Update(port.PacketMsg{Commands: []protocol.Command{{Kind: protocol.CommandCommitFrame, FrameSeq: 1}}})
	model = updated.(Model)
	status, ok := model.statusBar()
	if !ok || status.Operation == nil || status.Operation.OperationID != 42 {
		t.Fatalf("operation-only status was not discoverable: %+v, %v", status, ok)
	}
	if got := ansi.Strip(strings.Join(model.footerLines(), "\n")); !strings.Contains(got, "Formatting") {
		t.Fatalf("operation-only footer = %q", got)
	}
}

func TestOperationFeedbackUsesOneOutstandingChromeTickAndTickTimestamp(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.now = func() time.Time { return feedbackTestStart }
	operation := testOperation(1, generated.OperationStatusRunning, "Formatting")
	updated, firstTick := model.Update(port.PacketMsg{Commands: frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiStatusBar,
		Status: protocol.StatusBar{Operation: &operation},
	}})})
	model = updated.(Model)
	if firstTick == nil || !model.feedback.ticking {
		t.Fatal("running operation should schedule one chrome tick")
	}

	updated, duplicate := model.Update(struct{}{})
	model = updated.(Model)
	if duplicate != nil {
		t.Fatal("an outstanding chrome tick must not be duplicated")
	}

	clockCalled := false
	model.now = func() time.Time {
		clockCalled = true
		return feedbackTestStart.Add(time.Hour)
	}
	updated, rearmed := model.Update(feedbackTickMsg{at: feedbackTestStart.Add(spinnerDelay)})
	model = updated.(Model)
	if clockCalled {
		t.Fatal("feedback tick consulted the wall clock instead of its message timestamp")
	}
	if rearmed == nil || !model.feedback.ticking || model.feedback.spinnerOnAt.IsZero() {
		t.Fatalf("tick should use its timestamp and re-arm running animation: %+v", model.feedback)
	}
}

func TestOperationFeedbackFinalTickDrainsWithoutRearming(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.now = func() time.Time { return feedbackTestStart }
	operation := testOperation(1, generated.OperationStatusCanceled, "Canceled")
	updated, scheduled := model.Update(port.PacketMsg{Commands: frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiStatusBar,
		Status: protocol.StatusBar{Operation: &operation},
	}})})
	model = updated.(Model)
	if scheduled == nil || !model.feedback.ticking {
		t.Fatal("terminal dwell should schedule a chrome tick")
	}

	updated, rearmed := model.Update(feedbackTickMsg{at: feedbackTestStart.Add(terminalDwell)})
	model = updated.(Model)
	if rearmed != nil || model.feedback.ticking || model.feedback.hasDisplay {
		t.Fatalf("final dwell tick should drain cleanly: cmd=%v feedback=%+v", rearmed, model.feedback)
	}
}

func TestChromeTickCoexistsWithPickerLoadingWithoutDuplication(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.now = func() time.Time { return feedbackTestStart }
	model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Picker: protocol.Picker{LoadStatus: 1}}

	updated, scheduled := model.Update(struct{}{})
	model = updated.(Model)
	if scheduled == nil || !model.feedback.ticking {
		t.Fatal("picker loading should schedule the shared chrome tick")
	}
	updated, duplicate := model.Update(struct{}{})
	model = updated.(Model)
	if duplicate != nil {
		t.Fatal("picker and feedback must share one outstanding tick")
	}

	updated, rearmed := model.Update(feedbackTickMsg{at: feedbackTestStart.Add(feedbackTickInterval)})
	model = updated.(Model)
	if rearmed == nil || !model.feedback.ticking || model.feedback.frame != 1 {
		t.Fatalf("picker loading should re-arm shared tick: %+v", model.feedback)
	}

	model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Picker: protocol.Picker{LoadStatus: 2}}
	updated, final := model.Update(feedbackTickMsg{at: feedbackTestStart.Add(2 * feedbackTickInterval)})
	model = updated.(Model)
	if final != nil || model.feedback.ticking {
		t.Fatal("last picker tick should drain after loading finishes")
	}
}

func TestTypedFeedbackNarrowWidthKeepsDecorationAndPlainEllipsisStaysPlain(t *testing.T) {
	model := New(20, 8, nil, nil)
	operation := testOperation(1, generated.OperationStatusError, "A very long formatting failure")
	model.feedback.transition(&operation, feedbackTestStart)
	status := protocol.StatusBar{
		Left:  []protocol.StatusSegment{{Text: " N "}},
		Right: []protocol.StatusSegment{{Text: "1:1"}},
	}
	line := model.renderStatusSegments(status)
	plain := ansi.Strip(line)
	if lipgloss.Width(line) > model.width {
		t.Fatalf("narrow feedback width = %d, want <= %d: %q", lipgloss.Width(line), model.width, plain)
	}
	if !strings.Contains(plain, "✕") || strings.Contains(plain, "ordinary notice") {
		t.Fatalf("narrow status discarded typed decoration: %q", plain)
	}

	model.feedback = feedbackState{}
	status.Message = "ordinary notice…"
	plain = ansi.Strip(model.renderStatusSegments(status))
	if !strings.Contains(plain, "ordinary") {
		t.Fatalf("plain ellipsis notice was not rendered independently: %q", plain)
	}
	for _, spinner := range spinnerFrames {
		if strings.Contains(plain, spinner) {
			t.Fatalf("ordinary ellipsis notice inferred spinner %q: %q", spinner, plain)
		}
	}
}

func TestModeSegmentRendersColoredPillBadge(t *testing.T) {
	model := New(80, 24, nil, nil)
	updated, _ := model.Update(port.PacketMsg{Commands: frame(
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
			Opcode: generated.OPGuiStatusBar,
			Status: protocol.StatusBar{
				Left:  []protocol.StatusSegment{{Name: "mode", Text: " NORMAL "}},
				Right: []protocol.StatusSegment{{Name: "position", Text: "1:1 Top"}},
			},
		}},
	)})
	model = updated.(Model)

	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	if !strings.Contains(footer, " NORMAL ") {
		t.Fatalf("footer should contain mode text: %q", footer)
	}
	if !strings.Contains(footer, "1:1 Top") {
		t.Fatalf("footer should contain position text: %q", footer)
	}

	// Verify the raw (non-stripped) output carries ANSI sequences from mode colors.
	// The bootstrap palette assigns distinct mode BG (0x61AFEF for NORMAL) so the
	// rendered text must differ from a plain ChromeSurface render.
	raw := strings.Join(model.footerLines(), "\n")
	if raw == footer {
		t.Fatalf("mode segment should carry ANSI color sequences, but raw == stripped")
	}
}

func TestModeColorsMatchViMode(t *testing.T) {
	model := New(80, 24, nil, nil)
	theme := model.palette()

	assertColor := func(label string, got, want color.Color) {
		t.Helper()
		gr, gg, gb, _ := got.RGBA()
		wr, wg, wb, _ := want.RGBA()
		if gr != wr || gg != wg || gb != wb {
			t.Errorf("%s: got rgba(%d,%d,%d), want rgba(%d,%d,%d)", label, gr>>8, gg>>8, gb>>8, wr>>8, wg>>8, wb>>8)
		}
	}

	bg, fg := model.modeColors(" NORMAL ")
	assertColor("NORMAL bg", bg, theme.ModeNormal())
	assertColor("NORMAL fg", fg, theme.ModeNormalText())

	bg, fg = model.modeColors(" INSERT ")
	assertColor("INSERT bg", bg, theme.ModeInsert())
	assertColor("INSERT fg", fg, theme.ModeInsertText())

	bg, fg = model.modeColors(" VISUAL ")
	assertColor("VISUAL bg", bg, theme.ModeVisual())
	assertColor("VISUAL fg", fg, theme.ModeVisualText())
}

func TestInfoSegmentUsesModelineInfoPalette(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {
			Status: protocol.StatusBar{
				Left:  []protocol.StatusSegment{{Name: "mode", Text: " NORMAL "}, {Name: "info", Text: " main.ex "}},
				Right: []protocol.StatusSegment{{Name: "position", Text: "1:1"}},
			},
		},
	}

	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	if !strings.Contains(footer, " main.ex ") {
		t.Fatalf("footer should contain info segment text: %q", footer)
	}
}

func TestFooterRendersModeIconBeforeModeText(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {
			Status: protocol.StatusBar{
				Left:  []protocol.StatusSegment{{Text: " NORMAL "}},
				Right: []protocol.StatusSegment{{Text: "1:1"}},
			},
		},
	}
	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	if !strings.Contains(footer, " NORMAL") {
		t.Fatalf("footer should prepend mode icon before mode text: %q", footer)
	}
}

func TestFooterRendersFileIconBeforeFilename(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {
			Status: protocol.StatusBar{
				Filename: "main.go",
				Left:     []protocol.StatusSegment{{Text: " NORMAL "}},
				Right:    []protocol.StatusSegment{{Text: "1:1"}},
			},
		},
	}
	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	icon := devIconForPath("main.go", false)
	if icon.glyph == "" {
		t.Fatal("expected devicon for main.go")
	}
	if !strings.Contains(footer, icon.glyph) {
		t.Fatalf("footer should render file type icon for filename: %q (want glyph %q)", footer, icon.glyph)
	}
}

func TestFooterFallbackRendersFileIcon(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {
			Status: protocol.StatusBar{
				Filename: "app.rs",
				Line:     10,
				Column:   5,
			},
		},
	}
	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	icon := devIconForPath("app.rs", false)
	if icon.glyph == "" {
		t.Fatal("expected devicon for app.rs")
	}
	if !strings.Contains(footer, icon.glyph) {
		t.Fatalf("fallback footer should render file type icon before filename: %q (want glyph %q)", footer, icon.glyph)
	}
	if !strings.Contains(footer, "app.rs") {
		t.Fatalf("fallback footer should still contain filename: %q", footer)
	}
}

func TestHeaderRendersBreadcrumbWithTabs(t *testing.T) {
	model := New(120, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiTabBar: {
			Tabs: protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Icon: "󰈙", Label: "main.ex", Active: true}}},
		},
		generated.OPGuiBreadcrumb: {
			Breadcrumb: protocol.Breadcrumb{Segments: []string{"lib", "minga", "main.ex"}},
		},
	}

	header := ansi.Strip(strings.Join(model.headerLines(), "\n"))
	if !strings.Contains(header, "▌ 󰈙 main.ex") || !strings.Contains(header, "lib ❯ minga ❯ main.ex") {
		t.Fatalf("wide header should render active tab accent and breadcrumbs together: %q", header)
	}
}

func TestHeaderTruncatesLongTabLabels(t *testing.T) {
	model := New(120, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiTabBar: {
			Tabs: protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Icon: "󰈙", Label: "signature_help_builder_test.exs", Active: true}}},
		},
	}

	header := ansi.Strip(strings.Join(model.headerLines(), "\n"))
	if !strings.Contains(header, "signature_help_builder_…") || strings.Contains(header, "signature_help_builder_test.exs") {
		t.Fatalf("header should truncate long tab labels, got %q", header)
	}
}

func TestHeaderHidesBreadcrumbsAtNarrowWidth(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiTabBar: {
			Tabs: protocol.TabBar{Tabs: []protocol.Tab{{Icon: "󰈙", Label: "main.ex", Active: true}}},
		},
		generated.OPGuiBreadcrumb: {
			Breadcrumb: protocol.Breadcrumb{Segments: []string{"lib", "minga", "main.ex"}},
		},
	}

	header := ansi.Strip(strings.Join(model.headerLines(), "\n"))
	if strings.Contains(header, "lib ❯ minga") {
		t.Fatalf("narrow header should not spend a row on breadcrumbs: %q", header)
	}
}

func TestPickerPreviewRendersWithPicker(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiPicker: {
			Picker: protocol.Picker{Visible: true, Title: "Files", Items: []protocol.PickerItem{{Label: "main.ex"}}},
		},
		generated.OPGuiPickerPreview: {
			Preview: protocol.PickerPreview{
				Visible: true,
				Lines: []protocol.PreviewLine{{
					Segments: []protocol.PreviewSegment{{Text: "def main", FG: 0xCCDDEE, Bold: true}},
				}},
			},
		},
	}

	view := ansi.Strip(model.View().Content)
	if !strings.Contains(view, "Preview") || !strings.Contains(view, "def main") {
		t.Fatalf("floating picker should render picker preview: %q", view)
	}
}

func TestFloatingPickerCoversEditorContentBelow(t *testing.T) {
	model := New(120, 30, nil, nil)
	picker := protocol.Picker{
		Visible: true,
		Title:   "Find File",
		Items: []protocol.PickerItem{
			{Label: "test-advisor.md", Description: ".pi/agents"},
			{Label: "git-worktrees.md", Description: ".pi/prompts"},
			{Label: "Makefile"},
		},
	}
	preview := protocol.PickerPreview{Visible: true, Lines: []protocol.PreviewLine{
		{Segments: []protocol.PreviewSegment{{Text: ".PHONY: help lint lint.format lint.credo", FG: 0xCCDDEE}}},
		{Segments: []protocol.PreviewSegment{{Text: "native.support native.tui native.go-tui", FG: 0xCCDDEE}}},
	}}
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiPicker:        {Picker: picker},
		generated.OPGuiPickerPreview: {Preview: preview},
	}

	popup := model.renderFloatingPicker(picker, preview)
	popupWidth := lipgloss.Width(popup)
	popupHeight := lipgloss.Height(popup)
	buffer := cellbuf.NewBuffer(popupWidth, popupHeight)
	cellbuf.SetContent(buffer, popup)
	for row := 0; row < popupHeight; row++ {
		for col := 0; col < popupWidth; col++ {
			cell := buffer.Cell(col, row)
			if cell.Width == 0 && cell.Rune == 0 {
				continue
			}
			if cell.Style.Bg == nil {
				t.Fatalf("floating picker cell %d,%d has no background style: rune=%q width=%d popup=%q", row, col, cell.Rune, cell.Width, popup)
			}
		}
	}
	x := max((model.width-popupWidth)/2, 0)
	y := max((model.height-popupHeight)/2, 0)
	background := strings.TrimSuffix(strings.Repeat(strings.Repeat("X", model.width)+"\n", model.height), "\n")
	view := ansi.Strip(model.composeFrame(background))
	viewLines := strings.Split(view, "\n")

	for row := y; row < min(y+popupHeight, len(viewLines)); row++ {
		cells := []rune(viewLines[row])
		if len(cells) < x+popupWidth {
			t.Fatalf("composed row %d too narrow: width=%d want at least %d in %q", row, len(cells), x+popupWidth, viewLines[row])
		}
		popupCells := string(cells[x : x+popupWidth])
		if strings.Contains(popupCells, "X") {
			t.Fatalf("floating picker leaked editor content on row %d: %q", row, popupCells)
		}
	}
}

func TestPickerSelectedRowHasVisibleMarker(t *testing.T) {
	model := New(80, 24, nil, nil)
	rows := model.renderPickerList("Agent Model", protocol.Picker{
		Visible:  true,
		Selected: 1,
		Items: []protocol.PickerItem{
			{Label: "GPT-5 Codex", Description: "openai_codex"},
			{Label: "Claude Sonnet", Description: "anthropic"},
		},
	}, 4, 80)
	stripped := ansi.Strip(strings.Join(rows, "\n"))
	if !strings.Contains(stripped, "▌") || !strings.Contains(stripped, "Claude Sonnet") {
		t.Fatalf("selected picker row should include a visible marker: %q", stripped)
	}
	if strings.Contains(stripped, "▌ GPT-5 Codex") {
		t.Fatalf("selection marker should only appear on selected row: %q", stripped)
	}
}

func TestPickerSelectedRowUsesSelectionColors(t *testing.T) {
	model := New(80, 24, nil, nil)
	rows := model.renderPickerList("Buffers", protocol.Picker{
		Visible:  true,
		Selected: 0,
		Items:    []protocol.PickerItem{{Label: "Untitled-1", Description: "dirty"}},
	}, 2, 40)
	joined := strings.Join(rows, "\n")
	if !strings.Contains(joined, "48;2;51;51;51") {
		t.Fatalf("selected picker row should use popup selection background: %q", joined)
	}
	if !strings.Contains(joined, "38;2;255;255;255") {
		t.Fatalf("selected picker row should use popup selection foreground: %q", joined)
	}
}

func TestPickerPreviewDefaultsToPopupTextAndSurface(t *testing.T) {
	model := New(80, 24, nil, nil)
	rendered := model.renderPickerPreview(protocol.PickerPreview{Visible: true, Lines: []protocol.PreviewLine{{Segments: []protocol.PreviewSegment{{Text: "plain preview"}}}}}, 3, 40)
	joined := strings.Join(rendered, "\n")
	if !strings.Contains(joined, "38;2;255;255;255") {
		t.Fatalf("plain preview text should use popup foreground instead of terminal default: %q", joined)
	}
	if !strings.Contains(joined, "48;2;0;0;0") {
		t.Fatalf("preview rows should use popup surface background: %q", joined)
	}
}

func TestPickerOverlayIsBounded(t *testing.T) {
	model := New(100, 24, nil, nil)
	items := make([]protocol.PickerItem, 20)
	lines := make([]protocol.PreviewLine, 20)
	for i := range items {
		items[i] = protocol.PickerItem{Label: "item"}
		lines[i] = protocol.PreviewLine{Segments: []protocol.PreviewSegment{{Text: "preview"}}}
	}
	rendered := model.renderPicker(
		protocol.Picker{Visible: true, Title: "Files", Items: items},
		protocol.PickerPreview{Visible: true, Lines: lines},
	)
	if len(rendered) > model.maxOverlayHeight() {
		t.Fatalf("picker overlay height = %d, want <= %d", len(rendered), model.maxOverlayHeight())
	}
}

func TestWidePickerPreviewRendersBesideList(t *testing.T) {
	model := New(120, 30, nil, nil)
	rendered := model.renderPicker(
		protocol.Picker{Visible: true, Title: "Files", Items: []protocol.PickerItem{{Label: "test-advisor.md", Description: ".pi/agents"}, {Label: "minga-parallel.md", Description: ".pi/prompts"}}},
		protocol.PickerPreview{Visible: true, Lines: []protocol.PreviewLine{{Segments: []protocol.PreviewSegment{{Text: "def main"}}}}},
	)
	joined := strings.Join(rendered, "\n")
	if !strings.Contains(joined, "test-advisor.md") || !strings.Contains(joined, ".pi/agents") || !strings.Contains(joined, "def main") {
		t.Fatalf("wide picker should render one-row file results and preview together: %q", joined)
	}
	for index, line := range rendered {
		if width := lipgloss.Width(line); width > model.width {
			t.Fatalf("wide picker row %d width = %d, want <= %d: %q", index, width, model.width, line)
		}
	}
	if len(rendered) > model.maxOverlayHeight() {
		t.Fatalf("wide picker overlay height = %d, want <= %d", len(rendered), model.maxOverlayHeight())
	}
}

func TestHiddenWindowCursorDoesNotOverrideVisibleWindowCursor(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 1, CursorRow: 4, CursorCol: 18, CursorShape: 1, CursorVisible: true, Rows: []protocol.WindowRow{{Text: "typed text"}}})
	model.putWindow(protocol.WindowContent{ID: 2, CursorRow: 1, CursorCol: 0, CursorShape: 0, CursorVisible: false, Rows: []protocol.WindowRow{{Text: "Untitled-1 *"}}})

	if model.cursorRow != 4 || model.cursorCol != 18 || model.cursorShape != 1 {
		t.Fatalf("hidden secondary window cursor should not override active cursor: row=%d col=%d shape=%d", model.cursorRow, model.cursorCol, model.cursorShape)
	}
}

func TestHiddenWindowDeltaDoesNotOverrideVisibleWindowCursor(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 1, ContentEpoch: 2, CursorRow: 4, CursorCol: 18, CursorShape: 1, CursorVisible: true, Rows: []protocol.WindowRow{{Text: "typed text"}}})
	model.putWindow(protocol.WindowContent{ID: 2, ContentEpoch: 2, CursorRow: 1, CursorCol: 0, CursorShape: 0, CursorVisible: false, Rows: []protocol.WindowRow{{Text: "Untitled-1 *"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 2, ContentEpoch: 2, CursorRow: 1, CursorCol: 0, CursorShape: 0, CursorVisible: false, Rows: []protocol.WindowRow{{Text: "Untitled-1 *"}}})

	if model.cursorRow != 4 || model.cursorCol != 18 || model.cursorShape != 1 {
		t.Fatalf("hidden secondary window delta should not override active cursor: row=%d col=%d shape=%d", model.cursorRow, model.cursorCol, model.cursorShape)
	}
}

func TestVisibleToHiddenWindowDeltaRestoresRemainingVisibleCursor(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 1, ContentEpoch: 2, CursorRow: 4, CursorCol: 18, CursorShape: 1, CursorVisible: true, Rows: []protocol.WindowRow{{Text: "typed text"}}})
	model.putWindow(protocol.WindowContent{ID: 2, ContentEpoch: 2, CursorRow: 1, CursorCol: 0, CursorShape: 0, CursorVisible: true, Rows: []protocol.WindowRow{{Text: "Untitled-1 *"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 2, ContentEpoch: 2, CursorRow: 1, CursorCol: 0, CursorShape: 0, CursorVisible: false, Rows: []protocol.WindowRow{{Text: "Untitled-1 *"}}})

	if model.cursorRow != 4 || model.cursorCol != 18 || model.cursorShape != 1 {
		t.Fatalf("visible-to-hidden delta should restore remaining visible cursor: row=%d col=%d shape=%d", model.cursorRow, model.cursorCol, model.cursorShape)
	}
}

func TestHiddenToVisibleWindowDeltaUpdatesCursor(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 1, ContentEpoch: 2, CursorRow: 4, CursorCol: 18, CursorShape: 1, CursorVisible: true, Rows: []protocol.WindowRow{{Text: "typed text"}}})
	model.putWindow(protocol.WindowContent{ID: 2, ContentEpoch: 2, CursorRow: 1, CursorCol: 0, CursorShape: 0, CursorVisible: false, Rows: []protocol.WindowRow{{Text: "Untitled-1 *"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 2, ContentEpoch: 2, CursorRow: 2, CursorCol: 5, CursorShape: 2, CursorVisible: true, Rows: []protocol.WindowRow{{Text: "Untitled-1 *"}}})

	if model.cursorRow != 2 || model.cursorCol != 5 || model.cursorShape != 2 {
		t.Fatalf("hidden-to-visible delta should update cursor: row=%d col=%d shape=%d", model.cursorRow, model.cursorCol, model.cursorShape)
	}
}

// A cursor scrolled off-viewport (#2684) is encoded by the BEAM with the
// cursorline section absent (Cursorline.Visible == false), so the paint path
// must not draw a cursorline highlight. When it returns to view the section
// reappears and the highlight comes back. Text is identical either way; only
// styling changes.
func TestOffViewportCursorHidesCursorlineHighlight(t *testing.T) {
	model := New(80, 24, nil, nil)
	rows := []protocol.WindowRow{{Text: "cursor line"}}

	onScreen := protocol.WindowContent{ID: 1, Rows: rows, Cursorline: protocol.Cursorline{Visible: true, Row: 0, BG: 0x223344}}
	offScreen := protocol.WindowContent{ID: 1, Rows: rows, Cursorline: protocol.Cursorline{Visible: false}}

	lit := model.renderSemanticContentRow(onScreen, 0, 0, 40)
	dark := model.renderSemanticContentRow(offScreen, 0, 0, 40)

	if lit == dark {
		t.Fatalf("cursorline highlight should change the rendered row when the cursor is on-screen")
	}
	if ansi.Strip(lit) != ansi.Strip(dark) {
		t.Fatalf("cursorline should change styling only, not text: %q vs %q", ansi.Strip(lit), ansi.Strip(dark))
	}
	if strings.Contains(dark, "223344") {
		t.Fatalf("off-viewport row must carry no cursorline background: %q", dark)
	}
}

func TestApplyWindowDeltaResolvesRefsAndReplacesRowSnapshot(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 2,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, Text: "old one"},
			{ID: 2, ContentHash: 22, Text: "old two"},
			{ID: 3, ContentHash: 33, Text: "removed"},
		},
	})

	model.applyWindowDelta(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 2,
		Rows: []protocol.WindowRow{
			{Ref: true, ID: 1, ContentHash: 11},
			{ID: 2, ContentHash: 44, Text: "new two"},
		},
	})

	rows := model.windows[7].Rows
	if len(rows) != 2 {
		t.Fatalf("row count = %d, want 2: %+v", len(rows), rows)
	}
	if rows[0].Text != "old one" || rows[1].Text != "new two" {
		t.Fatalf("delta rows resolved incorrectly: %+v", rows)
	}
}

func TestInvalidFullReplaceWithDecreasingBufferLinesPreservesCommittedState(t *testing.T) {
	model := New(80, 24, nil, nil)
	_ = model.applyCommands(frame(protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
		ID: 7,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, BufferLine: 10, Text: "committed one"},
			{ID: 2, ContentHash: 22, BufferLine: 11, Text: "committed two"},
		},
	}}))

	_ = model.applyCommands([]protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 2, BaseFrameSeq: 1},
		{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
			ID: 7,
			Rows: []protocol.WindowRow{
				{ID: 3, ContentHash: 33, BufferLine: 12, Text: "invalid one"},
				{ID: 4, ContentHash: 44, BufferLine: 9, Text: "invalid two"},
			},
		}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 2},
	})

	rows := model.residentRows[7].materialize()
	if !reflect.DeepEqual(rows, model.windows[7].Rows) || rows[0].Text != "committed one" || rows[1].Text != "committed two" {
		t.Fatalf("invalid full replace changed committed rows: resident=%+v window=%+v", rows, model.windows[7].Rows)
	}
}

func TestApplyWindowDeltaInvalidatesMissingRetainedRowRef(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 2, Rows: []protocol.WindowRow{{ID: 1, ContentHash: 11, Text: "old one"}}})
	model.putWindow(protocol.WindowContent{ID: 8, ContentEpoch: 3, Rows: []protocol.WindowRow{{Text: "other"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 2, Rows: []protocol.WindowRow{{Ref: true, ID: 99, ContentHash: 99}}})

	if _, ok := model.windows[7]; ok {
		t.Fatalf("window with missing retained row ref should be invalidated: %+v", model.windows[7])
	}
	if len(model.windowOrder) != 1 || model.windowOrder[0] != 8 {
		t.Fatalf("window order should drop invalidated window: %+v", model.windowOrder)
	}
}

func TestApplyWindowDeltaInvalidatesHashMismatchedRetainedRowRef(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 2, Rows: []protocol.WindowRow{{ID: 1, ContentHash: 11, Text: "old one"}}})
	model.putWindow(protocol.WindowContent{ID: 8, ContentEpoch: 3, Rows: []protocol.WindowRow{{Text: "other"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 2, Rows: []protocol.WindowRow{{Ref: true, ID: 1, ContentHash: 99}}})

	if _, ok := model.windows[7]; ok {
		t.Fatalf("window with hash-mismatched retained row ref should be invalidated: %+v", model.windows[7])
	}
	if len(model.windowOrder) != 1 || model.windowOrder[0] != 8 {
		t.Fatalf("window order should drop invalidated window: %+v", model.windowOrder)
	}
}

func TestApplyWindowDeltaPreservesOverlayScrollPresentation(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		ScrollSet:    true,
		Scroll: protocol.ScrollPresentation{
			WindowID:         7,
			AnchorTop:        10,
			AnchorLeft:       2,
			VisibleStartLine: 10,
			VisibleEndLine:   20,
			ContentEpoch:     9,
			LayoutGeneration: 11,
		},
	})

	model.applyWindowDelta(protocol.WindowContent{
		ID:            7,
		ContentEpoch:  9,
		CursorVisible: true,
		CursorRow:     3,
		CursorCol:     4,
		CursorShape:   2,
		Cursorline:    protocol.Cursorline{Visible: true, Row: 3, BG: 0x112233},
	})

	window := model.windows[7]
	if !window.ScrollSet {
		t.Fatal("overlay delta should preserve existing scroll presentation metadata")
	}
	if window.Scroll != (protocol.ScrollPresentation{WindowID: 7, AnchorTop: 10, AnchorLeft: 2, VisibleStartLine: 10, VisibleEndLine: 20, ContentEpoch: 9, LayoutGeneration: 11}) {
		t.Fatalf("overlay delta should not alter scroll presentation: %+v", window.Scroll)
	}
}

func TestApplyWindowDeltaClearsStaleScrollPresentationFromSectionedDelta(t *testing.T) {
	model := New(80, 24, nil, nil)
	baseline := protocol.ScrollPresentation{WindowID: 7, AnchorTop: 10, AnchorLeft: 2, VisibleStartLine: 10, VisibleEndLine: 20, ContentEpoch: 9, LayoutGeneration: 11}
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollSet: true, Scroll: baseline})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 9, Rows: []protocol.WindowRow{}})

	window := model.windows[7]
	if len(window.Rows) != 0 {
		t.Fatalf("empty sectioned delta should clear existing rows, got %+v", window.Rows)
	}
	if window.ScrollSet || window.Scroll != (protocol.ScrollPresentation{}) {
		t.Fatalf("sectioned delta without scroll metadata should clear stale presentation metadata: %+v", window.Scroll)
	}

	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollSet: true, Scroll: baseline})
	model.applyWindowDelta(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows:         []protocol.WindowRow{},
		ScrollSet:    true,
		Scroll:       protocol.ScrollPresentation{WindowID: 99, ContentEpoch: 9},
	})

	window = model.windows[7]
	if window.ScrollSet || window.Scroll != (protocol.ScrollPresentation{}) {
		t.Fatalf("sectioned delta with mismatched scroll metadata should clear stale presentation metadata: %+v", window.Scroll)
	}
}

func TestApplyWindowDeltaAppliesMatchingScrollPresentation(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		ScrollSet:    true,
		Scroll: protocol.ScrollPresentation{
			WindowID:         7,
			AnchorTop:        10,
			AnchorLeft:       2,
			VisibleStartLine: 10,
			VisibleEndLine:   20,
			ContentEpoch:     9,
			LayoutGeneration: 11,
		},
		Rows: []protocol.WindowRow{{Text: "old"}},
	})

	next := protocol.ScrollPresentation{WindowID: 7, AnchorTop: 12, AnchorLeft: 3, VisibleStartLine: 12, VisibleEndLine: 22, ContentEpoch: 9, LayoutGeneration: 12}
	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 9, Rows: []protocol.WindowRow{{Text: "new"}}, ScrollSet: true, Scroll: next})

	window := model.windows[7]
	if !window.ScrollSet || window.Scroll != next {
		t.Fatalf("sectioned delta should replace scroll presentation metadata: %+v", window.Scroll)
	}
	if len(window.Rows) != 1 || window.Rows[0].Text != "new" {
		t.Fatalf("sectioned delta should still update rows: %+v", window.Rows)
	}
}

func TestCursorShapeSequenceTracksProtocolShape(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.cursorShape = 1
	if got := model.cursorStyleSequence(); got != "\x1b[6 q" {
		t.Fatalf("beam cursor sequence = %q", got)
	}
	model.cursorShape = 2
	if got := model.cursorStyleSequence(); got != "\x1b[4 q" {
		t.Fatalf("underline cursor sequence = %q", got)
	}
}

func TestThemeCommandUpdatesModelPalette(t *testing.T) {
	model := New(20, 4, nil, nil)
	_ = model.applyCommands(frame(testThemeCommand()))

	if got := model.activePalette.colors[themeEditorBG]; got != 0x1E1F2A {
		t.Fatalf("editor background slot = 0x%06X, want 0x1E1F2A", got)
	}
	if got := model.activePalette.colors[themeSelectionBG]; got != 0x2F4463 {
		t.Fatalf("selection slot = 0x%06X, want 0x2F4463", got)
	}
}

func TestBootstrapPaletteIsThemeAgnostic(t *testing.T) {
	palette := bootstrapPalette()
	want := map[byte]uint32{
		themeEditorBG:        0x000000,
		themeEditorFG:        0xFFFFFF,
		themeTreeBG:          0x000000,
		themeTreeSelectBG:    0x333333,
		themeTreeSelectionFG: 0xFFFFFF,
		themeTabBG:           0x111317,
		themePopupBG:         0x000000,
		themePopupSelFG:      0xFFFFFF,
		themeModelineBG:      0x000000,
		themeAccent:          0xFFFFFF,
		themeDiagnosticError: 0xFF0000,
		themeSelectionBG:     0x333333,
	}

	for slot, expected := range want {
		if got := palette.colors[slot]; got != expected {
			t.Fatalf("slot 0x%02X = 0x%06X, want 0x%06X", slot, got, expected)
		}
	}
}

func TestKeyframeWithoutThemeShowsProtocolError(t *testing.T) {
	model := New(20, 4, nil, nil)
	_ = model.applyCommands([]protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 1, BaseFrameSeq: 0},
		{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "unthemed"}}}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 1},
	})

	if model.protocolError != "missing gui_theme in keyframe" {
		t.Fatalf("missing gui_theme should latch protocol error, got %q", model.protocolError)
	}
	if strings.Contains(ansi.Strip(model.View().Content), "unthemed") {
		t.Fatalf("unthemed keyframe should not render content")
	}
}

func TestKeyframeWithEmptyThemeShowsProtocolError(t *testing.T) {
	model := New(20, 4, nil, nil)
	_ = model.applyCommands([]protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 1, BaseFrameSeq: 0},
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTheme, Theme: protocol.Theme{Colors: map[byte]uint32{}}}},
		{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "empty"}}}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 1},
	})

	if !strings.Contains(model.protocolError, "missing gui_theme slots in keyframe") {
		t.Fatalf("empty gui_theme should report missing slots, got %q", model.protocolError)
	}
	if !strings.Contains(model.protocolError, "0x01") || !strings.Contains(model.protocolError, "0xA0") {
		t.Fatalf("empty gui_theme should list missing slot ids, got %q", model.protocolError)
	}
	if strings.Contains(ansi.Strip(model.View().Content), "empty") {
		t.Fatalf("empty keyframe should not render content")
	}
}

func TestKeyframeWithIncompleteThemeShowsProtocolError(t *testing.T) {
	model := New(20, 4, nil, nil)
	_ = model.applyCommands([]protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 1, BaseFrameSeq: 0},
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTheme, Theme: protocol.Theme{Colors: map[byte]uint32{themeEditorBG: 0x1E1F2A, themeEditorFG: 0xC7D0E8}}}},
		{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "partial"}}}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 1},
	})

	if !strings.Contains(model.protocolError, "missing gui_theme slots in keyframe") {
		t.Fatalf("partial gui_theme should report missing slots, got %q", model.protocolError)
	}
	if !strings.Contains(model.protocolError, "0x03") || !strings.Contains(model.protocolError, "0xA0") {
		t.Fatalf("partial gui_theme should list missing slot ids, got %q", model.protocolError)
	}
	if strings.Contains(ansi.Strip(model.View().Content), "partial") {
		t.Fatalf("partial keyframe should not render content")
	}
}

func TestDeltaFrameWithEmptyThemeShowsProtocolError(t *testing.T) {
	model := New(20, 4, nil, nil)
	_ = model.applyCommands(frame(
		protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "baseline"}}}},
	))
	baselineEditorBG := model.activePalette.colors[themeEditorBG]

	_ = model.applyCommands([]protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 2, BaseFrameSeq: 1},
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTheme, Theme: protocol.Theme{Colors: map[byte]uint32{}}}},
		{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "delta-empty"}}}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 2},
	})

	if !strings.Contains(model.protocolError, "missing gui_theme slots") {
		t.Fatalf("empty delta gui_theme should report missing slots, got %q", model.protocolError)
	}
	if !strings.Contains(model.protocolError, "0x01") || !strings.Contains(model.protocolError, "0xA0") {
		t.Fatalf("empty delta gui_theme should list missing slot ids, got %q", model.protocolError)
	}
	if got := model.activePalette.colors[themeEditorBG]; got != baselineEditorBG {
		t.Fatalf("delta theme failure should not change palette: 0x%06X != 0x%06X", got, baselineEditorBG)
	}
	if strings.Contains(ansi.Strip(model.View().Content), "delta-empty") {
		t.Fatalf("empty delta frame should not render content")
	}
}

func TestDeltaFrameWithPartialThemeShowsProtocolError(t *testing.T) {
	model := New(20, 4, nil, nil)
	_ = model.applyCommands(frame(
		protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "baseline"}}}},
	))
	baselineEditorBG := model.activePalette.colors[themeEditorBG]

	_ = model.applyCommands([]protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 3, BaseFrameSeq: 1},
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTheme, Theme: protocol.Theme{Colors: map[byte]uint32{themeEditorBG: 0x1E1F2A, themeEditorFG: 0xC7D0E8}}}},
		{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "delta-partial"}}}},
		{Kind: protocol.CommandCommitFrame, FrameSeq: 3},
	})

	if !strings.Contains(model.protocolError, "missing gui_theme slots") {
		t.Fatalf("partial delta gui_theme should report missing slots, got %q", model.protocolError)
	}
	if !strings.Contains(model.protocolError, "0x03") || !strings.Contains(model.protocolError, "0xA0") {
		t.Fatalf("partial delta gui_theme should list missing slot ids, got %q", model.protocolError)
	}
	if got := model.activePalette.colors[themeEditorBG]; got != baselineEditorBG {
		t.Fatalf("delta theme failure should not change palette: 0x%06X != 0x%06X", got, baselineEditorBG)
	}
	if strings.Contains(ansi.Strip(model.View().Content), "delta-partial") {
		t.Fatalf("partial delta frame should not render content")
	}
}

func TestPaletteUsesSemanticTreeAndPopupSlots(t *testing.T) {
	palette := paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{
		themeTreeDirFG:       0x010203,
		themeTreeSelectionFG: 0x020304,
		themePopupDescFG:     0x030405,
		themePopupKeyFG:      0x040506,
	}})

	if palette.TreeDirectoryText() != lipgloss.Color("#010203") {
		t.Fatalf("tree directory text should use tree_dir_fg")
	}
	if palette.TreeSelectionText() != lipgloss.Color("#020304") {
		t.Fatalf("tree selection text should use tree_selection_fg")
	}
	if palette.PopupMutedText() != lipgloss.Color("#030405") {
		t.Fatalf("popup muted text should use popup_desc_fg")
	}
	if palette.KeycapText() != lipgloss.Color("#040506") {
		t.Fatalf("keycap text should use popup_key_fg")
	}
}

func TestSemanticWindowUsesThemeForSelectionOverlay(t *testing.T) {
	model := New(20, 4, nil, nil)
	model.activePalette = paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{themeSelectionBG: 0x112233}})
	style := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Selection: protocol.Selection{Type: 1, StartRow: 0, StartCol: 1, EndRow: 0, EndCol: 3}}, 0, 1)

	if style.GetBackground() != model.palette().Selection() {
		t.Fatalf("selection overlay should use theme selection color")
	}
}

func TestSemanticWindowUsesKindSpecificDocumentHighlightTheme(t *testing.T) {
	model := New(20, 4, nil, nil)
	model.activePalette = paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{themeHighlightReadBG: 0x223344, themeHighlightWriteBG: 0x334455, themeSelectionBG: 0x445566}})
	readStyle := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Highlights: []protocol.DocumentHighlight{{Kind: 2, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1}}}, 0, 0)
	writeStyle := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Highlights: []protocol.DocumentHighlight{{Kind: 3, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1}}}, 0, 0)
	textStyle := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Highlights: []protocol.DocumentHighlight{{Kind: 1, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1}}}, 0, 0)

	if readStyle.GetBackground() != lipgloss.Color("#223344") || writeStyle.GetBackground() != lipgloss.Color("#334455") || textStyle.GetBackground() != lipgloss.Color("#445566") {
		t.Fatalf("document highlight colors should be kind-specific: read=%v write=%v text=%v", readStyle.GetBackground(), writeStyle.GetBackground(), textStyle.GetBackground())
	}
}

func TestSemanticWindowRendersGutterCursorlineTildesAndModeline(t *testing.T) {
	model := New(30, 6, nil, nil)
	model.gutters = map[uint16]protocol.Gutter{
		7: {
			WindowID:        7,
			ContentHeight:   3,
			CursorLine:      0,
			LineNumberStyle: 0,
			LineNumberWidth: 3,
			SignColWidth:    2,
			Entries: []protocol.GutterEntry{
				{BufferLine: 0},
				{BufferLine: 1},
				{BufferLine: 2, DisplayType: 5},
			},
		},
	}
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {
			Status: protocol.StatusBar{
				Left:  []protocol.StatusSegment{{Text: " NORMAL "}},
				Right: []protocol.StatusSegment{{Text: "1:1 Top"}},
			},
		},
	}
	model.putWindow(protocol.WindowContent{
		ID:         7,
		Cursorline: protocol.Cursorline{Visible: true, Row: 0, BG: 0x333333},
		Rows:       []protocol.WindowRow{{BufferLine: 0, Text: "hello"}},
	})
	model.viewport.SetContent(model.content())

	view := ansi.Strip(model.View().Content)

	if !strings.Contains(view, "1 hello") || !strings.Contains(view, "~") {
		t.Fatalf("semantic view should include gutter line number, content, and tilde filler: %q", view)
	}
	if !strings.Contains(view, " NORMAL ") || !strings.Contains(view, "1:1 Top") {
		t.Fatalf("semantic view should render modeline segments: %q", view)
	}
}

func TestAgentChatPanelRendersStructuredTranscript(t *testing.T) {
	model := New(120, 34, nil, nil)
	chat := protocol.AgentChat{
		Visible:       true,
		Status:        2,
		ModelName:     "anthropic:claude-sonnet-4",
		ThinkingLevel: "medium",
		Prompt:        "fix the renderer",
	}
	model.transcript.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Messages: []protocol.AgentChatMessage{
		{Kind: 0x01, Text: "please fix the agent view"},
		{Kind: 0x02, Text: "I will make the agent surface semantic."},
		{Kind: 0x04, Name: "read_file", Summary: "go/tui/internal/ui/render_surfaces.go", Status: 1, DurationMS: 25, Collapsed: true},
		{Kind: 0x09, Name: "edit_file", Summary: "Update agent renderer", PreviewLines: []string{"+ semantic panel"}},
		{Kind: 0x06, Usage: protocol.AgentUsage{Input: 1200, Output: 300, CostMicros: 12500}},
	}})

	view := ansi.Strip(strings.Join(model.renderAgentChatPanelWithLimit(chat, 120, 28), "\n"))
	for _, want := range []string{"󰚩 Agent", "anthropic / claude-sonnet-4", "◌ medium", "Read", "read_file", "path:", "Approval edit_file", "Usage", "NORMAL", "fix the renderer", "◇ Session", "Provider", "Model", "Context", "Hints", "╰"} {
		if !strings.Contains(view, want) {
			t.Fatalf("agent chat panel missing %q in %q", want, view)
		}
	}
}

func TestAgentChatAssistantMarkdownCodeCardPreservesBlankLinesAndTruncates(t *testing.T) {
	model := New(40, 16, nil, nil)
	msg := markdownCodeCardMessage()

	view := ansi.Strip(strings.Join(model.renderAgentAssistantMessage(msg, 40), "\n"))
	if !strings.Contains(view, "Elixir") {
		t.Fatalf("markdown code card should render label: %q", view)
	}
	if !strings.Contains(view, "›") {
		t.Fatalf("markdown code card should mark truncated code lines: %q", view)
	}
	if !strings.Contains(view, "│ │ ") {
		t.Fatalf("markdown code card should preserve blank code rows: %q", view)
	}
}

func TestAgentChatRenderMessageRoutesAssistantMarkdownCodeCards(t *testing.T) {
	model := New(40, 16, nil, nil)
	msg := markdownCodeCardMessage()

	view := ansi.Strip(strings.Join(model.renderAgentMessage(msg, 40), "\n"))
	if !strings.Contains(view, "Elixir") || !strings.Contains(view, "╭─") {
		t.Fatalf("renderAgentMessage should route assistant_markdown to code-card renderer: %q", view)
	}
}

func markdownCodeCardMessage() protocol.AgentChatMessage {
	return protocol.AgentChatMessage{
		Kind: agentKindAssistantMarkdown,
		MarkdownBlocks: []protocol.AgentMarkdownBlock{
			{
				ID:       1,
				Kind:     0x07,
				Flags:    0x01,
				Language: "elixir",
				Label:    "Elixir",
				Lines: []protocol.AgentStyledLine{
					{{Text: "", FG: 0x98BE65, BG: 0x21242B, Flags: 0x10}},
					{{Text: "  " + strings.Repeat("x", 80), FG: 0x98BE65, BG: 0x21242B, Flags: 0x10}},
				},
			},
		},
	}
}

func TestAgentChatAssistantStyledLinesPreserveCodeIndentationAndOverflow(t *testing.T) {
	model := New(80, 24, nil, nil)
	styledLines := []protocol.AgentStyledLine{
		{{Text: "Here is code", FG: 0xBBC2CF}},
		{{Text: "  def hello do", FG: 0x98BE65, BG: 0x21242B, Flags: 0x10}},
		{{Text: "    :world", FG: 0x98BE65, BG: 0x21242B, Flags: 0x10}},
	}
	for i := 0; i < 12; i++ {
		styledLines = append(styledLines, protocol.AgentStyledLine{{Text: fmt.Sprintf("line %02d", i), FG: 0xBBC2CF}})
	}
	msg := protocol.AgentChatMessage{Kind: agentKindStyled, StyledLines: styledLines}

	view := ansi.Strip(strings.Join(model.renderAgentAssistantMessage(msg, 80), "\n"))
	if !strings.Contains(view, "│   def hello do") || !strings.Contains(view, "│     :world") {
		t.Fatalf("styled assistant should preserve code indentation: %q", view)
	}
	if !strings.Contains(view, "… +3 lines · ⏎ expand") {
		t.Fatalf("styled assistant should show overflow affordance: %q", view)
	}
}

func TestAgentChatAssistantStyledCodeLineShowsLongLineIndicator(t *testing.T) {
	model := New(36, 16, nil, nil)
	msg := protocol.AgentChatMessage{
		Kind: agentKindStyled,
		StyledLines: []protocol.AgentStyledLine{
			{{Text: "  " + strings.Repeat("x", 80), FG: 0x98BE65, BG: 0x21242B, Flags: 0x10}},
		},
	}

	view := ansi.Strip(strings.Join(model.renderAgentAssistantMessage(msg, 36), "\n"))
	if !strings.Contains(view, "›") {
		t.Fatalf("long styled code line should show truncation indicator: %q", view)
	}
}

func TestAgentChatAssistantStyledCodeLineShowsIndicatorAcrossSplitRuns(t *testing.T) {
	model := New(36, 16, nil, nil)
	msg := protocol.AgentChatMessage{
		Kind: agentKindStyled,
		StyledLines: []protocol.AgentStyledLine{
			{{Text: "  " + strings.Repeat("x", 30), FG: 0x98BE65, BG: 0x21242B, Flags: 0x10}, {Text: "yy", FG: 0x98BE65, BG: 0x21242B, Flags: 0x10}},
		},
	}

	view := ansi.Strip(strings.Join(model.renderAgentAssistantMessage(msg, 36), "\n"))
	if !strings.Contains(view, "›") {
		t.Fatalf("split-run styled code line should show truncation indicator: %q", view)
	}
}

func TestAgentChatAssistantMixedProseAndInlineCodeOmitsCodeIndicator(t *testing.T) {
	model := New(36, 16, nil, nil)
	msg := protocol.AgentChatMessage{
		Kind: agentKindStyled,
		StyledLines: []protocol.AgentStyledLine{
			{{Text: "This line mentions ", FG: 0xBBC2CF}, {Text: "code()", FG: 0x98BE65, BG: 0x21242B, Flags: 0x10}, {Text: " and then keeps going with prose that should truncate", FG: 0xBBC2CF}},
		},
	}

	view := ansi.Strip(strings.Join(model.renderAgentAssistantMessage(msg, 36), "\n"))
	if strings.Contains(view, "›") {
		t.Fatalf("mixed prose and inline code should not show code truncation indicator: %q", view)
	}
}

func TestAgentChatThinkingRendersMultipleLinesWhenExpanded(t *testing.T) {
	model := New(80, 24, nil, nil)
	msg := protocol.AgentChatMessage{
		Kind:      agentKindThinking,
		Text:      "first line\nsecond line\nthird line\nfourth line\nfifth line\nsixth line",
		Collapsed: false,
	}

	view := ansi.Strip(strings.Join(model.renderAgentThinkingMessage(msg, 80), "\n"))
	for _, want := range []string{"Thinking expanded", "first line", "second line", "third line", "fourth line", "fifth line"} {
		if !strings.Contains(view, want) {
			t.Fatalf("expanded thinking missing %q in %q", want, view)
		}
	}
	if strings.Contains(view, "sixth line") {
		t.Fatalf("expanded thinking should cap body at five lines: %q", view)
	}
}

func TestAgentChatThinkingCollapsedRemainsSingleLine(t *testing.T) {
	model := New(80, 24, nil, nil)
	msg := protocol.AgentChatMessage{
		Kind:      agentKindThinking,
		Text:      "first line\nsecond line",
		Collapsed: true,
	}

	view := ansi.Strip(strings.Join(model.renderAgentThinkingMessage(msg, 80), "\n"))
	if !strings.Contains(view, "Thinking collapsed") || !strings.Contains(view, "first line") {
		t.Fatalf("collapsed thinking should show header and first body line: %q", view)
	}
	if strings.Contains(view, "second line") {
		t.Fatalf("collapsed thinking should only show one body line: %q", view)
	}
}

func TestAgentChatToolExpandedRendersMultipleResultLines(t *testing.T) {
	model := New(96, 24, nil, nil)
	msg := protocol.AgentChatMessage{
		Kind:      agentKindTool,
		Name:      "grep",
		Summary:   "TODO in lib",
		Status:    1,
		Collapsed: false,
		Result:    "first match\nsecond match\nthird match",
	}

	view := ansi.Strip(strings.Join(model.renderAgentToolMessage(msg, 96), "\n"))
	for _, want := range []string{"Tool", "TODO in lib", "first match", "second match", "third match"} {
		if !strings.Contains(view, want) {
			t.Fatalf("expanded tool result missing %q in %q", want, view)
		}
	}
}

func TestAgentChatToolCollapsedShowsExpansionHint(t *testing.T) {
	model := New(96, 24, nil, nil)
	msg := protocol.AgentChatMessage{
		Kind:      agentKindTool,
		Name:      "read_file",
		Summary:   "lib/app.ex",
		Status:    1,
		Collapsed: true,
		Result:    "line one\nline two",
	}

	view := ansi.Strip(strings.Join(model.renderAgentToolMessage(msg, 96), "\n"))
	if !strings.Contains(view, "result collapsed") || !strings.Contains(view, "Ctrl+Alt+X") {
		t.Fatalf("collapsed tool should show expansion hint: %q", view)
	}
	if strings.Contains(view, "line two") {
		t.Fatalf("collapsed tool should not dump result lines: %q", view)
	}
}

func TestAgentChatToolRendersInlineDiffPreview(t *testing.T) {
	model := New(96, 24, nil, nil)
	msg := protocol.AgentChatMessage{
		Kind:         agentKindTool,
		Name:         "edit_file",
		Summary:      "lib/app.ex",
		Status:       1,
		Collapsed:    true,
		PreviewKind:  1,
		PreviewLines: []string{"file: lib/app.ex", "-old", "+new"},
	}

	view := ansi.Strip(strings.Join(model.renderAgentToolMessage(msg, 96), "\n"))
	for _, want := range []string{"diff:", "file: lib/app.ex", "-old", "+new"} {
		if !strings.Contains(view, want) {
			t.Fatalf("tool preview missing %q in %q", want, view)
		}
	}
}

func TestAgentChatShortcutTogglesLatestThinkingBlock(t *testing.T) {
	out := make(chan []byte, 1)
	model := New(80, 24, out, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiAgentChat: {AgentChat: protocol.AgentChat{
		Visible: true,
	}}}
	model.transcript.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Messages: []protocol.AgentChatMessage{
		{ID: 11, Kind: agentKindUser, Text: "fix this"},
		{ID: 22, Kind: agentKindThinking, Text: "first", Collapsed: true},
		{ID: 33, Kind: agentKindAssistant, Text: "ok"},
		{ID: 44, Kind: agentKindThinking, Text: "second", Collapsed: false},
	}})

	_, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: 'z', Mod: tea.ModCtrl | tea.ModAlt}))
	if got, want := <-out, protocol.EncodeGUIAgentToolToggle(44); !bytes.Equal(got, want) {
		t.Fatalf("ctrl+alt+z packet = %v, want %v", got, want)
	}
}

func TestAgentChatShortcutTogglesLatestToolBlock(t *testing.T) {
	out := make(chan []byte, 1)
	model := New(80, 24, out, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiAgentChat: {AgentChat: protocol.AgentChat{
		Visible: true,
	}}}
	model.transcript.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Messages: []protocol.AgentChatMessage{
		{ID: 11, Kind: agentKindUser, Text: "fix this"},
		{ID: 22, Kind: agentKindTool, Name: "read_file", Collapsed: true},
		{ID: 33, Kind: agentKindAssistant, Text: "ok"},
		{ID: 44, Kind: agentKindStyledTool, Name: "grep", Collapsed: false},
	}})

	_, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: 'x', Mod: tea.ModCtrl | tea.ModAlt}))
	if got, want := <-out, protocol.EncodeGUIAgentToolToggle(44); !bytes.Equal(got, want) {
		t.Fatalf("ctrl+alt+x packet = %v, want %v", got, want)
	}
}

func TestAgentChatShortcutTogglesLatestToolBlockIgnoresZeroID(t *testing.T) {
	var panel agentPanel
	chat := protocol.AgentChat{Visible: true}
	messages := []protocol.AgentChatMessage{
		{ID: 7, Kind: agentKindUser, Text: "fix this"},
		{ID: 0, Kind: agentKindTool, Name: "read_file", Collapsed: true},
	}

	packet, handled := panel.handleKey(chat, messages, tea.KeyPressMsg(tea.Key{Code: 'x', Mod: tea.ModCtrl | tea.ModAlt}))
	if handled || packet != nil {
		t.Fatalf("ctrl+alt+x should not send a toggle for zero ID tool block, handled=%v packet=%v", handled, packet)
	}
}

func TestAgentAnimationCueChangesAcrossFrames(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.agent.animationFrame = 0
	first := ansi.Strip(model.renderAgentStatusBadge(1))
	model.agent.animationFrame = 1
	second := ansi.Strip(model.renderAgentStatusBadge(1))
	if first == second {
		t.Fatalf("thinking status badge should animate across frames: %q", first)
	}
	chat := protocol.AgentChat{Visible: true, Status: 1}
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiAgentChat: {AgentChat: chat}}
	if !model.agent.animating(chat, nil) {
		t.Fatalf("visible thinking agent should animate")
	}
}

func TestAgentChatVisibleRendersAsMainBody(t *testing.T) {
	model := New(120, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiAgentChat: {AgentChat: protocol.AgentChat{
		Visible:       true,
		Status:        0,
		ModelName:     "anthropic:claude-sonnet-4",
		ThinkingLevel: "medium",
		Prompt:        "",
	}}}
	model.transcript.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Messages: []protocol.AgentChatMessage{
		{Kind: 0x05, Text: "Session started · 14:57:49 UTC"},
	}})
	model.putWindow(protocol.WindowContent{ID: 7, Rows: []protocol.WindowRow{{Text: ""}}})
	model.viewport.SetContent(model.content())

	bodyLines := strings.Split(ansi.Strip(model.content()), "\n")
	body := strings.Join(bodyLines, "\n")
	if !strings.Contains(body, "󰚩 Agent") || !strings.Contains(body, "Session") || !strings.Contains(body, "Ask Minga") || !strings.Contains(body, "Minga is ready") || !strings.Contains(body, "/explain") || !strings.Contains(body, "Explain this file") {
		t.Fatalf("agent chat should render in main body: %q", body)
	}
	if strings.Contains(body, "~") {
		t.Fatalf("agent chat body should not show editor tilde filler: %q", body)
	}
	if strings.Contains(body, "Messages1") || strings.Contains(body, "Provideranthropic") {
		t.Fatalf("agent details labels and values should not be smashed together: %q", body)
	}
	bottomComposer := strings.Join(bodyLines[max(len(bodyLines)-3, 0):], "\n")
	if !strings.Contains(bottomComposer, "NORMAL") || !strings.Contains(bottomComposer, "Ask Minga") {
		t.Fatalf("agent composer should be pinned to bottom body rows: %+v", bodyLines)
	}
	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	if strings.Contains(footer, "◇ Agent") || strings.Contains(footer, "Ask Minga") {
		t.Fatalf("agent chat should not be duplicated in footer overlay: %q", footer)
	}
}

func TestOverlayLinesRenderRemainingSemanticSurfaces(t *testing.T) {
	// Every overlay surface is registry-placed now (#2281): a surface renders only
	// when the BEAM emits its placement, so each case provides one.
	model := New(60, 12, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiAgentContext: {AgentContext: protocol.AgentContext{Visible: true, Task: "Review diff", Status: 3, CanApprove: true, Progress: protocol.AgentProgress{ActiveAction: "Running shell", ToolCount: 2, FileCount: 1, ReviewHint: "Review: approve or reject changes"}, Todos: []protocol.AgentTodo{{Status: 1, Description: "Inspect files"}}}}}
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDAgentContext, Z: 260, HitKind: 8},
	}
	if got := strings.Join(model.overlayLines(), "\n"); !strings.Contains(got, "needs you") || !strings.Contains(got, "Review diff") {
		t.Fatalf("agent context overlay missing content: %q", got)
	}

	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiToolManager: {ToolManager: protocol.ToolManager{Visible: true, Tools: []protocol.ToolSummary{{Name: "elixir-ls", Label: "Elixir LS", Status: 1}}}}}
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDToolManager, Z: 240, HitKind: 8},
	}
	if got := strings.Join(model.overlayLines(), "\n"); !strings.Contains(got, "Elixir LS") || !strings.Contains(got, "installed") {
		t.Fatalf("tool manager overlay missing content: %q", got)
	}
}

func TestSplitSeparatorsRenderOnContent(t *testing.T) {
	model := New(24, 6, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiSplitSeparators: {Splits: protocol.SplitSeparators{Verticals: []protocol.VerticalSeparator{{Col: 2, StartRow: 1, EndRow: 1}}}}}
	lines := model.withSplitSeparators([]string{"\x1b[1mabcd\x1b[0m", "efgh"})
	if !strings.Contains(lines[0], "│") {
		t.Fatalf("vertical replacement should render on visible content: %q", lines[0])
	}
	if !strings.Contains(lines[0], "\x1b[1md") {
		t.Fatalf("vertical replacement should resume existing ANSI styling after separator: %q", lines[0])
	}
}

func TestSplitSeparatorsRenderOnBlankRow(t *testing.T) {
	model := New(24, 6, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiSplitSeparators: {Splits: protocol.SplitSeparators{Horizontals: []protocol.HorizontalSeparator{{Row: 1, Col: 0, Width: 16, Filename: "main.ex"}}}}}
	lines := model.withSplitSeparators([]string{"", ""})
	if !strings.Contains(ansi.Strip(lines[0]), "main.ex") || !strings.Contains(ansi.Strip(lines[0]), "─") {
		t.Fatalf("horizontal separator should render on blank row: %q", lines[0])
	}
}

func TestSplitSeparatorsNormalizeAgainstHeaderAndFileTree(t *testing.T) {
	model := New(80, 6, nil, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Width: 24, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}}}},
		generated.OPGuiSplitSeparators: {Splits: protocol.SplitSeparators{
			Verticals:   []protocol.VerticalSeparator{{Col: 25, StartRow: 1, EndRow: 2}},
			Horizontals: []protocol.HorizontalSeparator{{Row: 2, Col: 25, Width: 2}},
		}},
	}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "body-0"}, {Text: "body-1"}, {Text: "body-2"}}})
	model.layout = model.computeLayout()
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	if len(lines) < 3 {
		t.Fatalf("unexpected view lines: %+v", lines)
	}
	if got := visibleIndex(lines[1], "│"); got != 23 {
		t.Fatalf("tree border separator should land at visible column 23 (last tree column), got %d in %q", got, lines[1])
	}
	if got := visibleIndex(lines[2], "─"); got != 24 {
		t.Fatalf("horizontal separator should land at column 24 (tree width, separator embedded) after normalization, got %d in %q", got, lines[2])
	}
}

func TestFileTreeSelectedRowPaintsBackgroundAcrossSegments(t *testing.T) {
	model := New(40, 8, nil, nil)
	rendered := model.renderFileTreeRow(protocol.FileTreeRow{Name: "installer", Icon: "󰉋", Directory: true, Selected: true}, 24, fileTreeRowGuides{})
	if count := strings.Count(rendered, "48;2;51;51;51"); count < 4 {
		t.Fatalf("selected file-tree row should carry selection background across marker, icon, label, and fill, count=%d row=%q", count, rendered)
	}
	if got := displayWidth(ansi.Strip(rendered)); got != 24 {
		t.Fatalf("selected file-tree row should fill requested width, got %d row=%q", got, rendered)
	}
}

func TestFileTreeDirtyRowUsesGitModifiedColor(t *testing.T) {
	model := New(40, 8, nil, nil)
	rendered := model.renderFileTreeRow(protocol.FileTreeRow{Name: "main.go", Dirty: true}, 30, fileTreeRowGuides{})
	// TreeGitModified bootstrap color is 0xE5C07B = rgb(229,192,123).
	// The dirty indicator and filename should use this instead of the
	// Warning color (0xFFAA00 = rgb(255,170,0)).
	if !strings.Contains(rendered, "38;2;229;192;123") {
		t.Fatalf("dirty file-tree row should use TreeGitModified color (229,192,123), got %q", rendered)
	}
	if strings.Contains(rendered, "38;2;255;170;0") {
		t.Fatalf("dirty file-tree row should not use Warning color (255,170,0), got %q", rendered)
	}
}

func TestFileTreeDirtySelectedRowKeepsSelectionColors(t *testing.T) {
	model := New(40, 8, nil, nil)
	rendered := model.renderFileTreeRow(protocol.FileTreeRow{Name: "main.go", Dirty: true, Selected: true}, 30, fileTreeRowGuides{})
	// TreeSelectionText bootstrap color is 0xFFFFFF = rgb(255,255,255).
	// Dirty+selected rows should use selection text, not git-modified for the name.
	if !strings.Contains(rendered, "38;2;255;255;255") {
		t.Fatalf("dirty+selected file-tree row should use selection text color, got %q", rendered)
	}
}

func TestFileTreeMatchHighlightAccentsMatchedCharacters(t *testing.T) {
	model := New(40, 8, nil, nil)
	_ = model.applyCommands(frame(testThemeCommand()))
	rendered := model.renderFileTreeRow(protocol.FileTreeRow{
		Name:           "main.go",
		Icon:           "",
		MatchPositions: []uint16{0, 1},
	}, 30, fileTreeRowGuides{})
	stripped := ansi.Strip(rendered)
	if !strings.Contains(stripped, "main.go") {
		t.Fatalf("rendered row should contain filename, got %q", stripped)
	}
	// The test theme accent 0x7DB7FF = (125, 183, 255) produces "125;183;255" in ANSI.
	// Characters at positions 0 ("m") and 1 ("a") should carry this accent foreground.
	if !strings.Contains(rendered, "125;183;255") {
		t.Fatalf("matched characters should carry accent foreground color, got %q", rendered)
	}
}

func TestFileTreeMatchHighlightSkippedWhenNoPositions(t *testing.T) {
	model := New(40, 8, nil, nil)
	_ = model.applyCommands(frame(testThemeCommand()))
	withMatch := model.renderFileTreeRow(protocol.FileTreeRow{
		Name:           "main.go",
		Icon:           "",
		MatchPositions: []uint16{0},
	}, 30, fileTreeRowGuides{})
	withoutMatch := model.renderFileTreeRow(protocol.FileTreeRow{
		Name: "main.go",
		Icon: "",
	}, 30, fileTreeRowGuides{})
	// Without match positions, no accent highlighting should appear in the name portion.
	// The accent color should only appear in the version with match positions.
	if strings.Contains(withoutMatch, "125;183;255") {
		t.Fatalf("row without match positions should not contain accent color, got %q", withoutMatch)
	}
	if !strings.Contains(withMatch, "125;183;255") {
		t.Fatalf("row with match positions should contain accent color, got %q", withMatch)
	}
}

func TestFileTreeMatchHighlightPreservesRowWidth(t *testing.T) {
	model := New(40, 8, nil, nil)
	_ = model.applyCommands(frame(testThemeCommand()))
	rendered := model.renderFileTreeRow(protocol.FileTreeRow{
		Name:           "config.toml",
		Icon:           "",
		MatchPositions: []uint16{0, 3, 7},
	}, 28, fileTreeRowGuides{})
	if got := displayWidth(ansi.Strip(rendered)); got != 28 {
		t.Fatalf("highlighted file-tree row should fill requested width, got %d row=%q", got, rendered)
	}
}

func TestFileTreeWidthRespectsProtocolGeometryAndSafetyClamp(t *testing.T) {
	if got := fileTreeWidth(80, protocol.FileTree{Width: 18}); got != 18 {
		t.Fatalf("file tree width = %d, want narrow protocol width 18", got)
	}
	if got := fileTreeWidth(80, protocol.FileTree{Width: 36}); got != 36 {
		t.Fatalf("file tree width = %d, want protocol width 36", got)
	}
	if got := fileTreeWidth(80, protocol.FileTree{Width: 120}); got != 79 {
		t.Fatalf("file tree width = %d, want terminal clamp 79", got)
	}
}

func TestFileTreeReservesVisibleEmptyState(t *testing.T) {
	model := New(80, 6, nil, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Status: 2, Width: 18, Root: "/repo"}}}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	if len(lines) < 2 {
		t.Fatalf("visible empty file tree should render reserved sidebar: %+v", lines)
	}
	if !strings.Contains(lines[1], "No files") {
		t.Fatalf("empty file tree should render status row: %q", lines[1])
	}
	if got := visibleIndex(lines[1], "pane"); got != 18 {
		t.Fatalf("empty file tree should reserve protocol width, got pane at %d in %q", got, lines[1])
	}
}

func TestSemanticWindowsRespectProtocolFileTreeWidth(t *testing.T) {
	model := New(80, 6, nil, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Width: 36, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}}}}}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	if len(lines) < 2 {
		t.Fatalf("semantic window should render with file tree width alignment: %+v", lines)
	}
	if got := visibleIndex(lines[1], "pane"); got != 36 {
		t.Fatalf("file tree width should follow protocol geometry without a gap, got %d in %q", got, lines[1])
	}
}

func TestSemanticWindowsNormalizeAbsoluteTUILayoutGeometry(t *testing.T) {
	model := New(90, 8, nil, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Width: 36, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}}}}}
	model.layout = model.computeLayout()
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 1, Col: 37, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	if len(lines) < 2 {
		t.Fatalf("semantic window should render with normalized geometry: %+v", lines)
	}
	if got := visibleIndex(lines[1], "pane"); got != 36 {
		t.Fatalf("absolute TUI geometry should not double-count file-tree width, got pane at %d in %q", got, lines[1])
	}
	if len(lines) > 2 && strings.Contains(lines[2], "pane") {
		t.Fatalf("absolute TUI geometry should not double-count header rows: %+v", lines[:3])
	}
}

func TestApplyWindowDeltaAppliesScrollLeftSetAndCropsRendering(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeft: 0, Rows: []protocol.WindowRow{{Text: "abcdef"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeftSet: true, ScrollLeft: 2})

	window := model.windows[7]
	if window.ScrollLeft != 2 {
		t.Fatalf("scroll left should update from matching-epoch delta, got %d", window.ScrollLeft)
	}
	rendered := ansi.Strip(model.renderSemanticContentRow(window, 0, 0, 4))
	if !strings.HasPrefix(rendered, "cdef") {
		t.Fatalf("cropped rendering should start at the updated scroll offset, got %q", rendered)
	}
}

func stripRenderedLines(lines []string) []string {
	stripped := make([]string, len(lines))
	for i, line := range lines {
		stripped[i] = ansi.Strip(line)
	}
	return stripped
}

func TestPresentationScrollUsesOverscanRowsImmediately(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 1, Text: "above"},
			{ID: 2, ContentHash: 2, Text: "top"},
			{ID: 3, ContentHash: 3, Text: "bottom"},
			{ID: 4, ContentHash: 4, Text: "below"},
		},
		GeometrySet: true,
		Geometry:    protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 10, Height: 2}},
		ScrollSet:   true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: 10, VisibleStartLine: 10, VisibleEndLine: 12, OverscanStartLine: 9, OverscanEndLine: 13,
		},
	})

	initial := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(initial, "top") || !strings.Contains(initial, "bottom") || strings.Contains(initial, "below") {
		t.Fatalf("initial render should use committed visible rows, got %q", initial)
	}

	model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
	scrolled := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(scrolled, "bottom") || !strings.Contains(scrolled, "below") || strings.Contains(scrolled, "top") {
		t.Fatalf("local presentation scroll should shift into overscan rows immediately, got %q", scrolled)
	}
}

// TestPresentationScrollResidentReachesDocumentBottom covers #2671 AC1: over a
// resident window (the payload spans the whole document, so overscan is anchored
// at line 0 and reaches TotalLines), a fast fling scrolls continuously to the
// last full page instead of starving at an overscan edge. The row offset clamps
// at documentRows - visibleRows so the document bottom is reachable.
func TestPresentationScrollResidentReachesDocumentBottom(t *testing.T) {
	const docRows = 100
	const visibleRows = 10

	rows := make([]protocol.WindowRow, docRows)
	for i := range rows {
		rows[i] = protocol.WindowRow{ID: uint64(i + 1), ContentHash: uint32(i + 1), BufferLine: uint32(i), Text: fmt.Sprintf("line %d", i)}
	}

	model := New(20, 14, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows:         rows,
		GeometrySet:  true,
		Geometry: protocol.PaneGeometry{
			ContentRect:  protocol.Rect{Row: 0, Col: 0, Width: 10, Height: visibleRows},
			ViewportRows: visibleRows,
			TotalLines:   docRows,
		},
		ScrollSet: true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: 0,
			VisibleStartLine: 0, VisibleEndLine: visibleRows,
			OverscanStartLine: 0, OverscanEndLine: docRows,
		},
	})

	if !windowCoversDocument(model.windows[7]) {
		t.Fatal("a full-document resident payload should be detected as covering the document")
	}

	// A fling far larger than the payload window: it must accumulate to the
	// document bottom, not clamp at a small overscan runway.
	for i := 0; i < 500; i++ {
		model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
	}

	scroll := model.localPresentation.scrolls[7]
	// Scroll-past-end: the last line can reach the top of the viewport, so
	// the max offset is docRows - 1 (not docRows - visibleRows).
	if want := docRows - 1; scroll.rowOffset != want {
		t.Fatalf("resident fling should reach the scroll-past-end offset %d, got %d", want, scroll.rowOffset)
	}
}

// TestPresentationScrollWindowedClampsAtOverscanEdge covers #2671 AC4: a windowed
// window (residence-off / over-threshold: the payload is a small overscan slice,
// not the whole document) keeps today's overscan-payload clamp, so the offset
// caps at the payload edge byte-identically to before this change.
func TestPresentationScrollWindowedClampsAtOverscanEdge(t *testing.T) {
	const visibleRows = 2

	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 1, Text: "a"},
			{ID: 2, ContentHash: 2, Text: "b"},
			{ID: 3, ContentHash: 3, Text: "c"},
			{ID: 4, ContentHash: 4, Text: "d"},
		},
		GeometrySet: true,
		Geometry: protocol.PaneGeometry{
			ContentRect:  protocol.Rect{Row: 0, Col: 0, Width: 10, Height: visibleRows},
			ViewportRows: visibleRows,
			// The document is far larger than the resident payload, and overscan
			// does not span it, so this is a windowed window.
			TotalLines: 1000,
		},
		ScrollSet: true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: 10,
			VisibleStartLine: 10, VisibleEndLine: 12,
			OverscanStartLine: 9, OverscanEndLine: 13,
		},
	})

	if windowCoversDocument(model.windows[7]) {
		t.Fatal("a windowed overscan payload must not be detected as covering the document")
	}

	for i := 0; i < 500; i++ {
		model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
	}

	// Overscan payload bound: len(rows)=4, visible=2, before=(10-9)=1 -> after=1.
	scroll := model.localPresentation.scrolls[7]
	if scroll.rowOffset != 1 {
		t.Fatalf("windowed scroll should clamp at the overscan edge (offset 1), got %d", scroll.rowOffset)
	}
}

// TestPresentationScrollResidentReachesDocumentTop is the upward mirror of the
// document-bottom test: from a mid-document anchor, an upward fling over a
// resident window clamps at the document top (offset -before), and a downward
// fling from the same anchor still reaches the last full page.
func TestPresentationScrollResidentReachesDocumentTop(t *testing.T) {
	const docRows = 100
	const visibleRows = 10
	const anchorTop = 50

	rows := make([]protocol.WindowRow, docRows)
	for i := range rows {
		rows[i] = protocol.WindowRow{ID: uint64(i + 1), ContentHash: uint32(i + 1), BufferLine: uint32(i), Text: fmt.Sprintf("line %d", i)}
	}

	model := New(20, 14, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows:         rows,
		GeometrySet:  true,
		Geometry: protocol.PaneGeometry{
			ContentRect:  protocol.Rect{Row: 0, Col: 0, Width: 10, Height: visibleRows},
			ViewportRows: visibleRows,
			TotalLines:   docRows,
		},
		ScrollSet: true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: anchorTop,
			VisibleStartLine: anchorTop, VisibleEndLine: anchorTop + visibleRows,
			OverscanStartLine: 0, OverscanEndLine: docRows,
		},
	})

	for i := 0; i < 500; i++ {
		model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp, X: 1, Y: model.layout.header.Height}), -1)
	}
	scroll := model.localPresentation.scrolls[7]
	if want := -anchorTop; scroll.rowOffset != want {
		t.Fatalf("resident upward fling should clamp at the document top offset %d, got %d", want, scroll.rowOffset)
	}

	for i := 0; i < 500; i++ {
		model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
	}
	scroll = model.localPresentation.scrolls[7]
	// Scroll-past-end: max forward offset is docRows - 1 - anchorTop.
	if want := docRows - 1 - anchorTop; scroll.rowOffset != want {
		t.Fatalf("resident downward fling should reach the scroll-past-end offset %d, got %d", want, scroll.rowOffset)
	}
}

// TestWindowCoversDocumentBoundaries pins the coverage predicate at its seams:
// coverage requires the overscan range to span [0, TotalLines) AND the payload
// to actually deliver that many rows, so a one-line-short overscan range or a
// truncated payload that still advertises full coverage degrades to the
// windowed overscan clamp instead of promising document rows it does not hold.
func TestWindowCoversDocumentBoundaries(t *testing.T) {
	const docRows = 20

	makeWindow := func(overscanEnd uint32, payloadRows int) protocol.WindowContent {
		rows := make([]protocol.WindowRow, payloadRows)
		for i := range rows {
			rows[i] = protocol.WindowRow{ID: uint64(i + 1), ContentHash: uint32(i + 1), BufferLine: uint32(i), Text: fmt.Sprintf("line %d", i)}
		}
		return protocol.WindowContent{
			ID:           7,
			ContentEpoch: 9,
			Rows:         rows,
			GeometrySet:  true,
			Geometry:     protocol.PaneGeometry{ViewportRows: 5, TotalLines: docRows},
			ScrollSet:    true,
			Scroll: protocol.ScrollPresentation{
				WindowID: 7, ContentEpoch: 9,
				VisibleStartLine: 0, VisibleEndLine: 5,
				OverscanStartLine: 0, OverscanEndLine: overscanEnd,
			},
		}
	}

	cases := []struct {
		name        string
		overscanEnd uint32
		payloadRows int
		want        bool
	}{
		{"exact coverage", docRows, docRows, true},
		{"overscan one line short", docRows - 1, docRows, false},
		{"truncated payload with covering metadata", docRows, docRows - 1, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := windowCoversDocument(makeWindow(tc.overscanEnd, tc.payloadRows)); got != tc.want {
				t.Fatalf("windowCoversDocument = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestPresentationScrollUsesMatchingOverscanGutterRows(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.gutters = map[uint16]protocol.Gutter{
		7: {
			WindowID:        7,
			ContentHeight:   2,
			CursorLine:      10,
			LineNumberStyle: 3,
			LineNumberWidth: 0,
			SignColWidth:    2,
			Entries: []protocol.GutterEntry{
				{BufferLine: 9, SignType: 8, SignText: "A"},
				{BufferLine: 10, SignType: 8, SignText: "B"},
				{BufferLine: 11, SignType: 8, SignText: "C"},
				{BufferLine: 12, SignType: 8, SignText: "D"},
			},
		},
	}
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 1, BufferLine: 9, Text: "above"},
			{ID: 2, ContentHash: 2, BufferLine: 10, Text: "top"},
			{ID: 3, ContentHash: 3, BufferLine: 11, Text: "bottom"},
			{ID: 4, ContentHash: 4, BufferLine: 12, Text: "below"},
		},
		GeometrySet: true,
		Geometry:    protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 10, Height: 2}},
		ScrollSet:   true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: 10, VisibleStartLine: 10, VisibleEndLine: 12, OverscanStartLine: 9, OverscanEndLine: 13,
		},
	})

	initial := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(initial, "B  top") || strings.Contains(initial, "A  top") {
		t.Fatalf("visible content should use the matching presentation gutter row, got %q", initial)
	}

	model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
	scrolled := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(scrolled, "C  bottom") || !strings.Contains(scrolled, "D  below") {
		t.Fatalf("locally shifted content should keep matching gutter rows, got %q", scrolled)
	}
}

func TestPresentationScrollUsesPayloadLocalRowsForWrappedContent(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 1, Text: "above"},
			{ID: 2, ContentHash: 2, Text: "top"},
			{ID: 3, ContentHash: 3, Text: "middle"},
			{ID: 4, ContentHash: 4, Text: "bottom"},
			{ID: 5, ContentHash: 5, Text: "below"},
		},
		GeometrySet: true,
		Geometry: protocol.PaneGeometry{
			ContentRect:     protocol.Rect{Row: 0, Col: 0, Width: 10, Height: 2},
			ViewportRows:    2,
			VisualRowOffset: 1,
			TotalVisualRows: 5,
		},
		ScrollSet: true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: 10, VisibleStartLine: 10, VisibleEndLine: 12, OverscanStartLine: 10, OverscanEndLine: 12,
		},
	})

	initial := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(initial, "above") || !strings.Contains(initial, "top") || strings.Contains(initial, "middle") {
		t.Fatalf("wrapped payload should not skip its first row just because document visual offset is non-zero, got %q", initial)
	}

	model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
	model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)
	model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 1, Y: model.layout.header.Height}), 1)

	scroll := model.localPresentation.scrolls[7]
	if scroll.rowOffset != 3 {
		t.Fatalf("wrapped presentation scroll should allow payload-local appended rows before clamping, got %d", scroll.rowOffset)
	}

	rendered := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(rendered, "bottom") || !strings.Contains(rendered, "below") || strings.Contains(rendered, "top") {
		t.Fatalf("wrapped presentation scroll should render the actual payload rows, got %q", rendered)
	}
}

func TestPresentationScrollShiftWheelMovesHorizontally(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows:         []protocol.WindowRow{{ID: 1, ContentHash: 1, Text: "abcdef"}},
		GeometrySet:  true,
		Geometry:     protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 4, Height: 1}},
		ScrollSet:    true,
		Scroll:       protocol.ScrollPresentation{WindowID: 7, ContentEpoch: 9, AnchorTop: 10, AnchorLeft: 0, LayoutGeneration: 5},
	})

	model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, Mod: tea.ModShift, X: 1, Y: model.layout.header.Height}), 1)
	scroll := model.localPresentation.scrolls[7]
	if scroll.rowOffset != 0 || scroll.colOffset != 1 {
		t.Fatalf("shift wheel-down should move presentation horizontally, got row=%d col=%d", scroll.rowOffset, scroll.colOffset)
	}

	model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp, Mod: tea.ModShift, X: 1, Y: model.layout.header.Height}), -1)
	if _, ok := model.localPresentation.scrolls[7]; ok {
		t.Fatalf("shift wheel-up should cancel the horizontal offset and clear presentation scroll")
	}
}

func TestPresentationScrollHorizontalOffsetInvalidatesCachedRows(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows:         []protocol.WindowRow{{ID: 1, ContentHash: 1, Text: "abcdef"}},
		GeometrySet:  true,
		Geometry:     protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 10, Height: 1}},
		ScrollSet:    true,
		Scroll:       protocol.ScrollPresentation{WindowID: 7, ContentEpoch: 9, AnchorTop: 10, AnchorLeft: 2, LayoutGeneration: 5},
	})

	initial := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(initial, "abcdef") {
		t.Fatalf("initial render should show the unshifted cached row, got %q", initial)
	}

	model.localPresentation.scrolls[7] = presentationScroll{anchorTop: 10, anchorLeft: 2, contentEpoch: 9, layoutGeneration: 5, colOffset: 2}
	scrolled := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(scrolled, "cdef") || strings.Contains(scrolled, "abcdef") {
		t.Fatalf("horizontal presentation scroll should invalidate cached rows and shift content, got %q", scrolled)
	}
}

func TestPresentationScrollHorizontalWheelRightClampsAtContentEdge(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows:         []protocol.WindowRow{{ID: 1, ContentHash: 1, Text: "abcdef"}},
		GeometrySet:  true,
		Geometry:     protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 4, Height: 1}},
		ScrollSet:    true,
		Scroll:       protocol.ScrollPresentation{WindowID: 7, ContentEpoch: 9, AnchorTop: 10, AnchorLeft: 0, LayoutGeneration: 5},
	})

	for range 10 {
		model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelRight, X: 1, Y: model.layout.header.Height}), 1)
	}

	scroll := model.localPresentation.scrolls[7]
	if scroll.colOffset != 2 {
		t.Fatalf("horizontal presentation scroll should clamp at right edge, got col offset %d", scroll.colOffset)
	}
	rendered := strings.Join(stripRenderedLines(model.renderWindowRows(model.windows[7])), "|")
	if !strings.Contains(rendered, "cdef") || strings.TrimSpace(rendered) == "" {
		t.Fatalf("repeated wheel-right should not blank content past the edge, got %q", rendered)
	}
}

func TestPresentationScrollHorizontalWheelRightUsesTextRectWidth(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		Rows:         []protocol.WindowRow{{ID: 1, ContentHash: 1, Text: "abcdef"}},
		GeometrySet:  true,
		Geometry:     protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 7, Height: 1}, TextRect: protocol.Rect{Row: 0, Col: 3, Width: 4, Height: 1}},
		ScrollSet:    true,
		Scroll:       protocol.ScrollPresentation{WindowID: 7, ContentEpoch: 9, AnchorTop: 10, AnchorLeft: 0, LayoutGeneration: 5},
	})

	for range 10 {
		model = model.applyPresentationScrollDelta(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelRight, X: 3, Y: model.layout.header.Height}), 1)
	}

	if got := model.localPresentation.scrolls[7].colOffset; got != 2 {
		t.Fatalf("horizontal presentation scroll should clamp against text rect width, got col offset %d", got)
	}
}

func TestLegacyCursorlineAppliesToCellFallback(t *testing.T) {
	model := New(10, 4, nil, nil)
	model.cursorlineChrome = protocol.CursorlineChrome{Visible: true, Row: 0, BG: 0x112233}
	lines := model.withLegacyCursorline([]string{"hello     "})
	if len(lines) != 1 || ansi.Strip(lines[0]) == "" {
		t.Fatalf("legacy cursorline should preserve row content: %+v", lines)
	}
}

func TestApplyCommandsStoresIndentGuidesByWindow(t *testing.T) {
	model := New(30, 6, nil, nil)
	_ = model.applyCommands(frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiIndentGuides, IndentGuides: protocol.IndentGuides{WindowID: 7, TabWidth: 2, GuideCols: []uint16{2}, IndentLevels: []byte{2}}}}))

	guides, ok := model.indentGuides[7]
	if !ok || len(guides.GuideCols) != 1 || guides.GuideCols[0] != 2 {
		t.Fatalf("indent guides should be retained per window: %+v", model.indentGuides)
	}
}

func TestFileTreeSelectionUpdatesExistingTree(t *testing.T) {
	model := New(30, 6, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Rows: []protocol.FileTreeRow{{ID: "a", Name: "a"}, {ID: "b", Name: "b"}}}}}
	model.applyFileTreeSelection(protocol.FileTreeSelection{Focused: true, SelectedID: "b"})

	tree := model.chrome[generated.OPGuiFileTree].Tree
	if tree.Selected != "b" || !tree.Focused || tree.Rows[0].Selected || !tree.Rows[1].Selected || !tree.Rows[1].Focused {
		t.Fatalf("file tree selection not applied: %+v", tree)
	}
}

func TestFileTreeLocalNavigationPreviewMovesSelectionWhenEligible(t *testing.T) {
	t.Run("j advances locally while still forwarding to BEAM", func(t *testing.T) {
		out := make(chan []byte, 1)
		model := New(30, 6, out, nil)
		model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Focused: true, Flags: fileTreeVisibleFlag | fileTreeFocusedFlag | fileTreeLocalNavigationFlag, Status: fileTreeReadyStatus, Selected: "a", Rows: []protocol.FileTreeRow{{ID: "a", Name: "a", Selected: true, Focused: true}, {ID: "b", Name: "b"}}}}}

		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: fileTreeLocalNavigationDownKey, Text: string(fileTreeLocalNavigationDownKey)}))
		model = updated.(Model)

		if model.localPresentation.previewFileTreeIndex == nil || *model.localPresentation.previewFileTreeIndex != 1 {
			t.Fatalf("eligible j press should set preview file-tree index to 1, got %v", model.localPresentation.previewFileTreeIndex)
		}
		packets := drainOutboundPackets(out)
		if len(packets) != 1 || packets[0][0] != generated.OPKeyPress || codepoint(packets[0]) != fileTreeLocalNavigationDownKey || packets[0][5] != 0 {
			t.Fatalf("eligible j press should still forward the key packet: %#v", packets)
		}
	})

	t.Run("up arrow retreats locally while still forwarding to BEAM", func(t *testing.T) {
		out := make(chan []byte, 1)
		model := New(30, 6, out, nil)
		model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Focused: true, Flags: fileTreeVisibleFlag | fileTreeFocusedFlag | fileTreeLocalNavigationFlag, Status: fileTreeReadyStatus, Selected: "b", Rows: []protocol.FileTreeRow{{ID: "a", Name: "a"}, {ID: "b", Name: "b", Selected: true, Focused: true}}}}}

		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyUp}))
		model = updated.(Model)

		if model.localPresentation.previewFileTreeIndex == nil || *model.localPresentation.previewFileTreeIndex != 0 {
			t.Fatalf("eligible up-arrow press should set preview file-tree index to 0, got %v", model.localPresentation.previewFileTreeIndex)
		}
		packets := drainOutboundPackets(out)
		if len(packets) != 1 || packets[0][0] != generated.OPKeyPress || codepoint(packets[0]) != arrowUp || packets[0][5] != 0 {
			t.Fatalf("eligible up-arrow press should still forward the key packet: %#v", packets)
		}
	})
}

func TestFileTreeLocalNavigationPreviewRequiresEligibilityFlag(t *testing.T) {
	out := make(chan []byte, 1)
	model := New(30, 6, out, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Focused: true, Flags: fileTreeVisibleFlag | fileTreeFocusedFlag, Status: fileTreeReadyStatus, Selected: "a", Rows: []protocol.FileTreeRow{{ID: "a", Name: "a", Selected: true, Focused: true}, {ID: "b", Name: "b"}}}}}

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: fileTreeLocalNavigationDownKey, Text: string(fileTreeLocalNavigationDownKey)}))
	model = updated.(Model)

	if model.localPresentation.previewFileTreeIndex != nil {
		t.Fatalf("file tree should not set preview index when the local-navigation flag is clear, got %v", *model.localPresentation.previewFileTreeIndex)
	}
	packets := drainOutboundPackets(out)
	if len(packets) != 1 || packets[0][0] != generated.OPKeyPress || codepoint(packets[0]) != fileTreeLocalNavigationDownKey || packets[0][5] != 0 {
		t.Fatalf("non-eligible j press should still forward the key packet: %#v", packets)
	}
}

func TestModalOverlaySuppressesFileTreeNavigation(t *testing.T) {
	eligibleTree := protocol.FileTree{Visible: true, Focused: true, Flags: fileTreeVisibleFlag | fileTreeFocusedFlag | fileTreeLocalNavigationFlag, Status: fileTreeReadyStatus, Selected: "a", Rows: []protocol.FileTreeRow{{ID: "a", Name: "a", Selected: true, Focused: true}, {ID: "b", Name: "b"}}}
	jKey := tea.KeyPressMsg(tea.Key{Code: fileTreeLocalNavigationDownKey, Text: string(fileTreeLocalNavigationDownKey)})

	for _, tc := range []struct {
		name    string
		overlay map[byte]protocol.ChromePayload
	}{
		{"picker", map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: eligibleTree}, generated.OPGuiPicker: {Picker: protocol.Picker{Visible: true, Title: "Files", Items: []protocol.PickerItem{{Label: "main.ex"}}}}}},
		{"which-key", map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: eligibleTree}, generated.OPGuiWhichKey: {Which: protocol.WhichKey{Visible: true, Prefix: "SPC", Bindings: []protocol.WhichKeyBinding{{Key: "f", Description: "file"}}}}}},
		{"agent-chat", map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: eligibleTree}, generated.OPGuiAgentChat: {AgentChat: protocol.AgentChat{Visible: true, Status: 2, ModelName: "test"}}}},
	} {
		t.Run(tc.name+" suppresses local navigation", func(t *testing.T) {
			out := make(chan []byte, 1)
			model := New(30, 6, out, nil)
			model.chrome = tc.overlay

			updated, _ := model.Update(jKey)
			model = updated.(Model)

			tree := model.chrome[generated.OPGuiFileTree].Tree
			if tree.Selected != "a" || !tree.Rows[0].Selected {
				t.Fatalf("file tree should not preview locally when %s overlay is active: %+v", tc.name, tree)
			}
			packets := drainOutboundPackets(out)
			if len(packets) != 1 || packets[0][0] != generated.OPKeyPress {
				t.Fatalf("key should still be forwarded to BEAM when %s overlay is active: %#v", tc.name, packets)
			}
		})
	}
}

func TestApplyCommandsStoresSemanticGuttersByWindow(t *testing.T) {
	model := New(30, 6, nil, nil)
	_ = model.applyCommands(frame(
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiGutter, WindowGutter: protocol.Gutter{WindowID: 1, LineNumberWidth: 3, Entries: []protocol.GutterEntry{{BufferLine: 0}}}}},
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiGutter, WindowGutter: protocol.Gutter{WindowID: 2, LineNumberWidth: 3, Entries: []protocol.GutterEntry{{BufferLine: 9}}}}},
	))

	first, firstOK := model.windowGutter(1)
	second, secondOK := model.windowGutter(2)
	if !firstOK || !secondOK || first.Entries[0].BufferLine != 0 || second.Entries[0].BufferLine != 9 {
		t.Fatalf("gutters should be retained per window: first=%+v second=%+v", first, second)
	}
}

func TestSemanticWindowsUsePerWindowHeights(t *testing.T) {
	model := New(40, 8, nil, nil)
	model.gutters = map[uint16]protocol.Gutter{
		1: {WindowID: 1, ContentHeight: 1, LineNumberWidth: 3, Entries: []protocol.GutterEntry{{BufferLine: 0}}},
		2: {WindowID: 2, ContentHeight: 1, LineNumberWidth: 3, Entries: []protocol.GutterEntry{{BufferLine: 10}}},
	}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "first"}}})
	model.putWindow(protocol.WindowContent{ID: 2, Rows: []protocol.WindowRow{{Text: "second"}}})

	lines := model.semanticLines()
	joined := ansi.Strip(strings.Join(lines, "\n"))
	if len(lines) != 2 || !strings.Contains(joined, "first") || !strings.Contains(joined, "second") {
		t.Fatalf("semantic windows should not pad the first window over later windows: lines=%d %q", len(lines), joined)
	}
}

func TestSemanticWindowsUsePaneGeometryRects(t *testing.T) {
	model := New(24, 6, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "left"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 10, Height: 1}}})
	model.putWindow(protocol.WindowContent{ID: 2, Rows: []protocol.WindowRow{{Text: "right"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 12, Width: 10, Height: 1}}})

	lines := ansi.Strip(strings.Join(model.semanticLines(), "\n"))
	first := strings.Split(lines, "\n")[0]
	if !strings.Contains(first, "left") || !strings.Contains(first, "right") {
		t.Fatalf("semantic windows should compose into a body canvas: %q", first)
	}
	if got := strings.Index(first, "right"); got != 12 {
		t.Fatalf("right window should start at column 12, got %d in %q", got, first)
	}
}

func TestSemanticWindowsRespectHeaderRowOffset(t *testing.T) {
	model := New(24, 6, nil, nil)
	model.title = "Header"
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	if len(lines) < 2 || !strings.Contains(lines[1], "pane") {
		t.Fatalf("semantic window should render on first body row after header: %+v", lines)
	}
}

func TestSemanticWindowsDoNotClipFirstRowWithWorkspaceAndTabHeaders(t *testing.T) {
	model := New(80, 8, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiWorkspaces: {Spaces: protocol.WorkspaceBar{Spaces: []protocol.Workspace{{ID: 1, Label: "Files", Icon: "folder", Active: true, TabCount: 1}, {ID: 2, Label: "Tests", Icon: "beaker"}}}},
		generated.OPGuiTabBar:     {Tabs: protocol.TabBar{ActiveIndex: 0, Tabs: []protocol.Tab{{ID: 1, Label: "Untitled-1", Active: true, Dirty: true}}}},
	}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "Hey this is a thing"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 24, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	if len(lines) < 3 || !strings.Contains(lines[2], "Hey this is a thing") {
		t.Fatalf("semantic editor row 0 should render below workspace and tab headers: %+v", lines)
	}
}

func TestSemanticWindowsRespectFileTreeOffset(t *testing.T) {
	model := New(80, 6, nil, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Width: 24, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}}}}}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	if len(lines) < 2 {
		t.Fatalf("semantic window should render with file tree offset: %+v", lines)
	}
	if got := visibleIndex(lines[1], "pane"); got != 24 {
		t.Fatalf("file tree offset should leave pane at column 24, got %d in %q", got, lines[1])
	}
}

func TestSemanticWindowsRespectSidebarOffset(t *testing.T) {
	model := New(80, 6, nil, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiSidebars: {Sidebars: protocol.Sidebars{Visible: true, Items: []protocol.Sidebar{{ID: "files", DisplayName: "Files", SemanticKind: "file_tree", PreferredWidth: 18, Visible: true}}}}}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	if len(lines) < 2 {
		t.Fatalf("semantic window should render with sidebar offset: %+v", lines)
	}
	if !strings.Contains(lines[1], "│") {
		t.Fatalf("sidebar should have │ separator column: %q", lines[1])
	}
	// strings.Index returns byte offset: 18 ASCII sidebar chars + 3-byte │ = byte 21
	if got := strings.Index(lines[1], "pane"); got != 21 {
		t.Fatalf("sidebar + separator offset should place pane at byte 21 (18 sidebar + 3-byte separator), got %d in %q", got, lines[1])
	}
}

func TestSemanticRowsRespectScrollLeftAndIndentGuides(t *testing.T) {
	model := New(12, 6, nil, nil)
	model.indentGuides[7] = protocol.IndentGuides{WindowID: 7, TabWidth: 2, GuideCols: []uint16{2}}
	window := protocol.WindowContent{ID: 7, ScrollLeft: 2, Rows: []protocol.WindowRow{{Text: "    x"}}}

	rendered := ansi.Strip(model.renderSemanticContentRow(window, 0, 0, 8))
	if !strings.HasPrefix(rendered, "│ ") || !strings.Contains(rendered, "x") {
		t.Fatalf("scroll-left rendering should keep display-column guides aligned with AstroVim-style guide glyphs: %q", rendered)
	}
}

func TestOverlayDeltaPreservesExistingScrollLeft(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeft: 4, Rows: []protocol.WindowRow{{Text: "hello"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 9, CursorRow: 1, CursorCol: 2, CursorShape: 1, Cursorline: protocol.Cursorline{Visible: true, Row: 0, BG: 0x123456}})

	window := model.windows[7]
	if window.ScrollLeft != 4 {
		t.Fatalf("overlay delta should preserve scroll left, got %d", window.ScrollLeft)
	}
}

func TestDeltaForMissingWindowIsIgnored(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.applyWindowDelta(protocol.WindowContent{ID: 99, ContentEpoch: 1, CursorRow: 1, CursorCol: 2, CursorShape: 1})

	if len(model.windows) != 0 {
		t.Fatalf("missing window delta should be ignored, got %+v", model.windows)
	}
}

func TestStaleContentEpochDeltaIsIgnored(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeft: 4, CursorRow: 3, CursorCol: 4, CursorShape: 1, Rows: []protocol.WindowRow{{Text: "hello"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 8, CursorRow: 1, CursorCol: 2, CursorShape: 2, ScrollLeft: 0, Rows: []protocol.WindowRow{{Text: "changed"}}})

	window := model.windows[7]
	if window.ContentEpoch != 9 || window.CursorRow != 3 || window.CursorCol != 4 || window.CursorShape != 1 || window.ScrollLeft != 4 || window.Rows[0].Text != "hello" {
		t.Fatalf("stale delta should be ignored, got %+v", window)
	}
}

func TestSemanticDeltaClearsStaleOverlaysAndCursorline(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:             7,
		ContentEpoch:   4,
		Cursorline:     protocol.Cursorline{Visible: true, Row: 0, BG: 0x123456},
		Selection:      protocol.Selection{Type: 1, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1},
		SearchSet:      true,
		SearchMatches:  []protocol.SearchMatch{{Row: 0, StartCol: 0, EndCol: 1, Current: true}},
		DiagnosticsSet: true,
		Diagnostics:    []protocol.DiagnosticRange{{StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1, Severity: 0}},
		HighlightsSet:  true,
		Highlights:     []protocol.DocumentHighlight{{StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1, Kind: 2}},
		AnnotationsSet: true,
		Annotations:    []protocol.LineAnnotation{{Row: 0, Kind: 1, Text: "note"}},
		Rows:           []protocol.WindowRow{{Text: "hello"}},
	})

	before := model.applyWindowOverlays(lipgloss.NewStyle(), model.windows[7], 0, 0)
	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 4, Cursorline: protocol.Cursorline{}, SelectionSet: true, Selection: protocol.Selection{}, SearchSet: true, SearchMatches: []protocol.SearchMatch{}, DiagnosticsSet: true, Diagnostics: []protocol.DiagnosticRange{}, HighlightsSet: true, Highlights: []protocol.DocumentHighlight{}, AnnotationsSet: true, Annotations: []protocol.LineAnnotation{}})
	window := model.windows[7]
	if window.Cursorline.Visible || window.Selection.Type != 0 || len(window.SearchMatches) != 0 || len(window.Diagnostics) != 0 || len(window.Highlights) != 0 || len(window.Annotations) != 0 {
		t.Fatalf("stale overlay state should be cleared by empty deltas: %+v", window)
	}
	if got := strings.TrimSpace(model.renderRowAnnotations(window, 0)); got != "" {
		t.Fatalf("annotations should no longer render after clear: %q", got)
	}
	after := model.applyWindowOverlays(lipgloss.NewStyle(), window, 0, 0)
	if before.GetBackground() == after.GetBackground() {
		t.Fatalf("selection/highlight overlays should stop affecting rendering after clear: before=%v after=%v", before.GetBackground(), after.GetBackground())
	}
}

func TestSemanticMouseRoutesModelineAndFileTreeZones(t *testing.T) {
	model := New(60, 12, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {Status: protocol.StatusBar{Left: []protocol.StatusSegment{{Text: " save ", Command: "save"}}, Right: []protocol.StatusSegment{{Text: " quit", Command: "quit"}}}},
		generated.OPGuiTabBar:    {Tabs: protocol.TabBar{Tabs: []protocol.Tab{{ID: 41, Icon: "󰈙", Label: "one.ex"}, {ID: 42, Icon: "󰈙", Label: "two.ex", Active: true}}}},
		generated.OPGuiFileTree:  {Tree: protocol.FileTree{Visible: true, Width: 24, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}, {ID: "row-1", Name: "row-1"}}}},
	}
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	_ = model.View()

	saveZone := waitForZone(t, model, zoneIDModelineCommand("save"))
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: saveZone.StartX + 1, Y: saveZone.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUIExecuteCommand("save")) {
		t.Fatalf("modeline click should route execute command, ok=%v packet=%v", ok, cmd)
	}
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseRight, X: saveZone.StartX + 1, Y: saveZone.StartY})); ok {
		t.Fatalf("non-left clicks should fall back")
	}

	tabZone := waitForZone(t, model, zoneIDTab(42))
	cmd, ok = model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: tabZone.StartX + 1, Y: tabZone.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUISelectTab(42)) {
		t.Fatalf("tab click should route select-tab packet, ok=%v packet=%v", ok, cmd)
	}

	rowZone := waitForZone(t, model, zoneIDFileTreeRow(0))
	cmd, ok = model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: rowZone.StartX + 1, Y: rowZone.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUIFileTreeClick(0)) {
		t.Fatalf("file-tree click should route file-tree packet, ok=%v packet=%v", ok, cmd)
	}
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: rowZone.EndX + 10, Y: rowZone.EndY + 10})); ok {
		t.Fatalf("out-of-bounds clicks should fall back")
	}
}

func TestSemanticMouseBodyClickFallsThrough(t *testing.T) {
	model := New(60, 12, nil, nil)
	model.layout = model.computeLayout()

	bodyX := model.layout.body.X + 1
	bodyY := model.layout.body.Y + 1
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: bodyX, Y: bodyY})); ok {
		t.Fatal("body-region click should not be handled by semantic routing")
	}
}

func TestSemanticMouseRoutesBreadcrumbSegmentZones(t *testing.T) {
	model := New(120, 12, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiBreadcrumb: {Breadcrumb: protocol.Breadcrumb{Segments: []string{"lib", "minga", "main.ex"}}},
	}
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	_ = model.View()

	zone := waitForZone(t, model, zoneIDBreadcrumbSegment(1))
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUIBreadcrumbClick(1)) {
		t.Fatalf("breadcrumb click should route breadcrumb_click for segment 1, ok=%v packet=%v", ok, cmd)
	}
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseRight, X: zone.StartX + 1, Y: zone.StartY})); ok {
		t.Fatalf("non-left breadcrumb clicks should fall back")
	}
}

func TestSemanticMouseRoutesCompletionItemZones(t *testing.T) {
	model := New(60, 16, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiCompletion: {Complete: protocol.Completion{Visible: true, Selected: 0, Items: []protocol.CompletionItem{
			{Label: "alpha", Detail: "fn"},
			{Label: "beta", Detail: "fn"},
		}}},
	}
	// The completion overlay is registry-placed now (#2281): it renders at its
	// BEAM placement rect, and its zones are scanned from there. Place it at the
	// bottom band where it historically rendered.
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDCompletionMenu, Rect: generated.Rect{Row: 12, Col: 0, Width: 60, Height: 4}, Z: 301, HitKind: 8},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	zone := waitForZone(t, model, zoneIDCompletionItem(1))
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUICompletionSelect(1)) {
		t.Fatalf("completion row click should route completion_select index 1, ok=%v packet=%v", ok, cmd)
	}
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.EndX + 50, Y: zone.EndY + 50})); ok {
		t.Fatalf("out-of-bounds completion clicks should fall back")
	}
}

func TestSemanticMouseRoutesNotificationDismissAndActionZones(t *testing.T) {
	model := New(60, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiNotifications: {Notifications: protocol.Notifications{
			Visible: true,
			Items: []protocol.Notification{{
				ID:          "build:test",
				Title:       "Build failed",
				Source:      "build",
				Body:        "exit 1",
				Dismissable: true,
				Actions: []protocol.NotificationAction{
					{ID: "show_logs", Label: "Show logs"},
					{ID: "retry", Label: "Retry"},
				},
			}},
		}},
	}
	// Notifications is registry-placed (#2281): it renders at its BEAM placement
	// rect and its zones are scanned from there. Height 6 accounts for the
	// content rows (1 title + 2*items + items_with_actions = 1 + 2 + 1 = 4)
	// plus 2 for the rounded border frame (#2538). If the renderer ever emits
	// more rows than that formula counts, takeLines clips the extra rows and
	// their zones never register, so keep the two in lockstep.
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDNotifications, Rect: generated.Rect{Row: 20, Col: 0, Width: 60, Height: 6}, Z: 160, HitKind: 8},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	// Dismiss "x" zone routes notification_dismiss for the clicked id. Its
	// absolute coords come from the bottom-aligned placement, proving the overlay
	// zones merge at the placement offset (ScanInto).
	dismiss := waitForZone(t, model, zoneIDNotificationDismiss("build:test"))
	if dismiss.StartY < 20 || dismiss.StartY >= 26 {
		t.Fatalf("dismiss zone Y %d outside the notifications band rows 20..25", dismiss.StartY)
	}
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: dismiss.StartX, Y: dismiss.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUINotificationDismiss("build:test")) {
		t.Fatalf("dismiss click should route notification_dismiss, ok=%v packet=%v", ok, cmd)
	}

	// Action zone routes notification_action(id, action_id) for the clicked action.
	action := waitForZone(t, model, zoneIDNotificationAction("build:test", "retry"))
	cmd, ok = model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: action.StartX + 1, Y: action.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUINotificationAction("build:test", "retry")) {
		t.Fatalf("action click should route notification_action retry, ok=%v packet=%v", ok, cmd)
	}

	// A click that misses every notification zone falls through (ok=false) so the
	// BEAM OverlaySink containment swallows it: this is AC 2, the containment
	// fallback, and must not synthesize a buffer click.
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: dismiss.EndX + 40, Y: dismiss.EndY + 30})); ok {
		t.Fatalf("out-of-bounds notification clicks should fall back to BEAM containment")
	}
}

func TestNotificationDismissZoneAbsentWhenNotDismissable(t *testing.T) {
	model := New(60, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiNotifications: {Notifications: protocol.Notifications{
			Visible: true,
			Items: []protocol.Notification{{
				ID:          "progress:1",
				Title:       "Building",
				Source:      "build",
				Dismissable: false,
			}},
		}},
	}
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDNotifications, Rect: generated.Rect{Row: 21, Col: 0, Width: 60, Height: 5}, Z: 160, HitKind: 8},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	// A non-dismissable notification renders no dismiss affordance, so there is no
	// dismiss zone and nothing routes notification_dismiss (mirrors macOS, which
	// only draws the "x" when notification.dismissable).
	if zone := model.zones.Get(zoneIDNotificationDismiss("progress:1")); zone != nil {
		t.Fatalf("non-dismissable notification must not register a dismiss zone, got %+v", zone)
	}
}

func TestSemanticMouseRoutesObservatoryNodeZones(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiObservatory: {Observatory: protocol.Observatory{
			Visible: true,
			Count:   2,
			Nodes: []protocol.ObservatoryNode{
				{PID: "<0.123.0>", Name: "Editor", Depth: 0, MessageQueueLen: 0},
				{PID: "<0.456.0>", Name: "Buffer", Depth: 1, MessageQueueLen: 3},
			},
		}},
	}
	// Observatory is registry-placed (#2281): it renders at its BEAM placement rect
	// and its zones are scanned from there. Height 4 is the BEAM-derived value for
	// this state, NOT an arbitrary fit: FooterOverlays.content_height_observatory =
	// 1 (separator) + 1 (header) + node_count = 1 + 1 + 2 = 4. If the renderer
	// ever emits more rows than that formula counts, takeLines clips the extra rows
	// and their zones never register, so keep the two in lockstep (the #2333 height
	// lesson).
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDObservatory, Rect: generated.Rect{Row: 20, Col: 0, Width: 80, Height: 4}, Z: 180, HitKind: 8},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	// Each node row carries a zone keyed by its PID; a click routes
	// observatory_inspect(pid). The absolute coords come from the bottom-aligned
	// placement, proving the overlay zones merge at the placement offset (ScanInto).
	node := waitForZone(t, model, zoneIDObservatoryNode("<0.456.0>"))
	if node.StartY < 20 || node.StartY >= 24 {
		t.Fatalf("observatory node zone Y %d outside the band rows 20..23", node.StartY)
	}
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: node.StartX + 1, Y: node.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUIObservatoryInspect("<0.456.0>")) {
		t.Fatalf("observatory row click should route observatory_inspect, ok=%v packet=%v", ok, cmd)
	}

	// A click that misses every observatory zone falls through (ok=false) so the
	// BEAM OverlaySink containment swallows it: this is AC 2, the containment
	// fallback, and must not synthesize a buffer click.
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: node.EndX + 40, Y: node.EndY + 30})); ok {
		t.Fatalf("out-of-bounds observatory clicks should fall back to BEAM containment")
	}
}

func TestSemanticMouseRoutesEditTimelineEntryZones(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiEditTimeline: {Timeline: protocol.EditTimeline{
			Visible:      true,
			ViewingIndex: 0,
			Entries: []protocol.TimelineEntry{
				{Index: 0, ToolName: "write_file", TimestampDelta: 12},
				{Index: 1, ToolName: "apply_patch", TimestampDelta: 4},
			},
		}},
	}
	// Edit timeline is registry-placed (#2281). Height 4 is the BEAM-derived value:
	// FooterOverlays.content_height_edit_timeline = 1 (separator) + 1 (header) +
	// entry_count = 1 + 1 + 2 = 4. Same takeLines/clip lockstep as observatory
	// and notifications.
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDEditTimeline, Rect: generated.Rect{Row: 20, Col: 0, Width: 80, Height: 4}, Z: 170, HitKind: 8},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	// Each entry row carries a zone keyed by its index; a click routes
	// timeline_navigate(index).
	entry := waitForZone(t, model, zoneIDTimelineEntry(1))
	if entry.StartY < 20 || entry.StartY >= 24 {
		t.Fatalf("timeline entry zone Y %d outside the band rows 20..23", entry.StartY)
	}
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: entry.StartX + 1, Y: entry.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUITimelineNavigate(1)) {
		t.Fatalf("timeline row click should route timeline_navigate(1), ok=%v packet=%v", ok, cmd)
	}

	// A click that misses every timeline zone falls through (ok=false) so the BEAM
	// OverlaySink containment swallows it (AC 2 containment fallback).
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: entry.EndX + 40, Y: entry.EndY + 30})); ok {
		t.Fatalf("out-of-bounds timeline clicks should fall back to BEAM containment")
	}
}

func TestOverlayLinesRenderEditTimelineFiles(t *testing.T) {
	model := New(60, 12, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiEditTimeline: {Timeline: protocol.EditTimeline{
		Visible:      true,
		ViewingIndex: 0xFFFF,
		Files:        []protocol.TimelineFile{{Path: "lib/a.ex", EntryCount: 2, LinesAdded: 10, LinesRemoved: 3, ReviewStatus: 1}},
	}}}
	model.surfacePlacements = []generated.SurfacePlacement{{SurfaceID: surfaceIDEditTimeline, Z: 170, HitKind: 8}}

	if got := strings.Join(model.overlayLines(), "\n"); !strings.Contains(got, "lib/a.ex") || !strings.Contains(got, "+10/-3") {
		t.Fatalf("edit timeline file summary overlay missing content: %q", got)
	}
}

func TestSemanticMouseRoutesFloatPopupDismissOutsideBox(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiFloatPopup: {Float: protocol.FloatPopup{
			Visible: true,
			Title:   "Process <0.123.0>",
			Lines:   []string{"Class: buffer", "Lines: 42"},
		}},
	}
	// The float popup is a wrap-dependent surface: FooterOverlays sizes its band
	// to the clamp ceiling (:max), and Go bottom-aligns the rendered content
	// inside it (overlayLayer). With a 24-row terminal the ceiling is 24/3 = 8,
	// but here we pin a 6-row band so there is a phantom region above the content.
	// renderFloat draws 1 (title) + min(2 lines, ceiling-1) = 3 rows, bottom-
	// aligned: content occupies rows 21..23, the phantom band is rows 18..20.
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDFloatPopup, Rect: generated.Rect{Row: 18, Col: 0, Width: 80, Height: 6}, Z: 270, HitKind: 8},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	// A click in the phantom band ABOVE the rendered popup content (outside the
	// box but inside the band) dismisses, the same intent the keyboard quit key
	// reaches. Rows 18..20 are phantom; row 19 is comfortably inside.
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: 10, Y: 19}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUIFloatPopupDismiss()) {
		t.Fatalf("click outside the float box but in band should route float_popup_dismiss, ok=%v packet=%v", ok, cmd)
	}

	// A click INSIDE the rendered popup box (rows 21..23) has no clickable
	// affordance in the model (no links, no dismiss button), so it returns
	// ok=false and falls through to the raw mouse path where the BEAM OverlaySink
	// keeps it contained: it must NOT dismiss (matches the display-only macOS
	// FloatPopupOverlay).
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: 10, Y: 22})); ok {
		t.Fatalf("a click inside the float popup box must not dismiss it")
	}

	// A click OUTSIDE the band rect entirely (above row 18) is buffer content,
	// not ours: it returns ok=false so the raw mouse path forwards it to the
	// buffer underneath (AC 2 containment fallback boundary).
	if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: 10, Y: 17})); ok {
		t.Fatalf("a click outside the float popup band must not be claimed by the float handler")
	}
}

func TestFloatPopupDismissAbsentWhenContentFillsBand(t *testing.T) {
	model := New(80, 24, nil, nil)
	// Enough lines to fill the whole band: there is no phantom region, so no
	// outside-the-box-but-in-band click exists and nothing dismisses through this
	// path (the user dismisses via keyboard or a click outside the band).
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiFloatPopup: {Float: protocol.FloatPopup{
			Visible: true,
			Title:   "Help",
			Lines:   []string{"a", "b", "c", "d", "e", "f", "g", "h"},
		}},
	}
	// Band height 3, content 1 (title) + min(8, ceiling-1) clamped to 3 = 3 rows:
	// content fills the band (rows 21..23), no phantom rows.
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDFloatPopup, Rect: generated.Rect{Row: 21, Col: 0, Width: 80, Height: 3}, Z: 270, HitKind: 8},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	for _, y := range []int{21, 22, 23} {
		if _, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: 10, Y: y})); ok {
			t.Fatalf("with content filling the band, click at row %d must not dismiss the float popup", y)
		}
	}
}

func TestCompletionRendersDocumentationPreviewWhenPresent(t *testing.T) {
	model := New(60, 24, nil, nil)
	completion := protocol.Completion{
		Visible:       true,
		Selected:      0,
		Items:         []protocol.CompletionItem{{Label: "map", Detail: "Enum.map/2"}},
		Documentation: "Applies fun to each element of the enumerable.",
	}

	view := ansi.Strip(strings.Join(model.renderCompletion(completion), "\n"))
	if !strings.Contains(view, "Documentation") {
		t.Fatalf("expected a Documentation pane title, got: %q", view)
	}
	if !strings.Contains(view, "Applies fun to each element") {
		t.Fatalf("expected the doc preview body to render, got: %q", view)
	}
}

func TestCompletionWithoutDocumentationRendersNoPreviewPane(t *testing.T) {
	model := New(60, 24, nil, nil)
	withDoc := model.renderCompletion(protocol.Completion{
		Visible:       true,
		Items:         []protocol.CompletionItem{{Label: "map", Detail: "Enum.map/2"}},
		Documentation: "Applies fun.",
	})
	withoutDoc := model.renderCompletion(protocol.Completion{
		Visible: true,
		Items:   []protocol.CompletionItem{{Label: "map", Detail: "Enum.map/2"}},
	})

	noDocView := ansi.Strip(strings.Join(withoutDoc, "\n"))
	if strings.Contains(noDocView, "Documentation") {
		t.Fatalf("items without docs must not render a Documentation pane: %q", noDocView)
	}
	// AC 3: the item list must be unchanged (no layout shift) when docs are absent.
	// The doc variant adds extra pane lines, so the no-doc render is shorter, and
	// its item rows match the leading item rows of the doc variant.
	if len(withoutDoc) >= len(withDoc) {
		t.Fatalf("doc preview should add lines: withDoc=%d withoutDoc=%d", len(withDoc), len(withoutDoc))
	}
	// The border adds a top row (index 0) and a bottom row, so the first item
	// row is at index 2 (border top + title + first item).
	itemRow := ansi.Strip(withoutDoc[2])
	if !strings.Contains(itemRow, "map") {
		t.Fatalf("expected first item row to render the label, got: %q", itemRow)
	}
}

func TestSemanticMouseRoutesSidebarItemZones(t *testing.T) {
	model := New(80, 6, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiSidebars: {Sidebars: protocol.Sidebars{Visible: true, ActiveID: "files", Items: []protocol.Sidebar{
			{ID: "files", DisplayName: "Files", SemanticKind: "file_tree", PreferredWidth: 18, Visible: true},
			{ID: "git", DisplayName: "Git", SemanticKind: "git_status", PreferredWidth: 18, Visible: true},
		}}},
	}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 8, Height: 1}}})
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	_ = model.View()

	// Active sidebar click sends "toggle".
	activeZone := waitForZone(t, model, zoneIDSidebarItem("files"))
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: activeZone.StartX + 1, Y: activeZone.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUISidebarAction("files", "file_tree", "toggle")) {
		t.Fatalf("active sidebar click should route sidebar_action toggle, ok=%v packet=%v", ok, cmd)
	}

	// Inactive sidebar click sends "activate".
	inactiveZone := waitForZone(t, model, zoneIDSidebarItem("git"))
	cmd, ok = model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: inactiveZone.StartX + 1, Y: inactiveZone.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUISidebarAction("git", "git_status", "activate")) {
		t.Fatalf("inactive sidebar click should route sidebar_action activate, ok=%v packet=%v", ok, cmd)
	}
}

func TestSemanticMouseRoutesHoverActionZone(t *testing.T) {
	model := New(60, 16, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiHoverPopup:  {Hover: protocol.HoverPopup{Visible: true, Lines: []protocol.RichLine{{Segments: []protocol.RichSegment{{Text: "doc"}}}}}},
		generated.OPGuiHoverAction: {HoverAction: protocol.HoverAction{Visible: true, Name: "Open documentation"}},
	}
	// The hover popup is registry-placed now (#2281): it renders at its BEAM
	// placement rect and its hover-action zone is scanned from there.
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDHoverPopup, Rect: generated.Rect{Row: 12, Col: 0, Width: 60, Height: 4}, Z: 290, HitKind: 8},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	zone := waitForZone(t, model, zoneIDHoverAction)
	cmd, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY}))
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUIHoverOpenAction()) {
		t.Fatalf("hover action click should route hover_open_action, ok=%v packet=%v", ok, cmd)
	}
}

func TestBottomPanelShowsLatestMessagesByDefault(t *testing.T) {
	model, panel := bottomPanelTestModel(10, nil)
	visible := model.visibleBottomPanelMessages(panel)
	if len(visible) != model.bottomPanelVisibleRows(panel) {
		t.Fatalf("visible message count mismatch: got %d want %d", len(visible), model.bottomPanelVisibleRows(panel))
	}
	if visible[0].Text != "msg-7" || visible[len(visible)-1].Text != "msg-9" {
		t.Fatalf("bottom panel should start at latest messages, got %+v", visible)
	}
}

func TestBottomPanelHeightUsesSemanticPercent(t *testing.T) {
	model := New(80, 20, nil, nil)
	panel := protocol.BottomPanel{Visible: true, HeightPercent: 50}

	if got := model.bottomPanelHeight(panel); got != 10 {
		t.Fatalf("bottom panel height = %d, want semantic 50%% of terminal height", got)
	}
}

func TestBottomPanelWheelScrollIsHandledLocally(t *testing.T) {
	out := make(chan []byte, 1)
	model, _ := bottomPanelTestModel(10, out)
	next, _ := model.Update(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseWheelUp, X: 10, Y: 9}))
	updated := next.(Model)
	if updated.bottomPanelScrollback != bottomPanelWheelLines {
		t.Fatalf("wheel over bottom panel should update local scrollback, got %d", updated.bottomPanelScrollback)
	}
	select {
	case packet := <-out:
		t.Fatalf("wheel over bottom panel should not send editor mouse packet: %v", packet)
	default:
	}
	body := ansi.Strip(strings.Join(updated.overlayLines(), "\n"))
	if !strings.Contains(body, "msg-4") || strings.Contains(body, "msg-9") {
		t.Fatalf("bottom panel should scroll older messages, got %q", body)
	}
}

func TestBottomPanelWheelOutsidePanelFallsThrough(t *testing.T) {
	out := make(chan []byte, 1)
	model, _ := bottomPanelTestModel(10, out)
	next, _ := model.Update(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseWheelUp, X: 10, Y: 2}))
	updated := next.(Model)
	if updated.bottomPanelScrollback != 0 {
		t.Fatalf("wheel outside bottom panel should not update local scrollback, got %d", updated.bottomPanelScrollback)
	}
	select {
	case <-out:
	default:
		t.Fatalf("wheel outside bottom panel should fall through to editor mouse packet")
	}
}

func TestBottomPanelChromeUpdateClampsAndResetsScrollback(t *testing.T) {
	t.Run("shrinking list clamps stale scrollback", func(t *testing.T) {
		model, panel := bottomPanelTestModel(10, nil)
		model.bottomPanelScrollback = 6

		shrunk := panel
		shrunk.StreamInstance++
		shrunk.Messages = shrunk.Messages[:4]
		updated, _ := model.Update(port.PacketMsg{Commands: frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiBottomPanel, Bottom: shrunk}})})
		got := updated.(Model)

		if got.bottomPanelScrollback != 1 {
			t.Fatalf("shrinking bottom panel should clamp stale scrollback to 1, got %d", got.bottomPanelScrollback)
		}
	})

	t.Run("hidden panel resets stale scrollback", func(t *testing.T) {
		model, panel := bottomPanelTestModel(10, nil)
		model.bottomPanelScrollback = 5

		hidden := panel
		hidden.Visible = false
		updated, _ := model.Update(port.PacketMsg{Commands: frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiBottomPanel, Bottom: hidden}})})
		got := updated.(Model)

		if got.bottomPanelScrollback != 0 {
			t.Fatalf("hidden bottom panel should reset stale scrollback to 0, got %d", got.bottomPanelScrollback)
		}
	})
}

func TestBottomPanelMessageDeltasAppendWithinStream(t *testing.T) {
	model, panel := bottomPanelTestModel(2, nil)

	delta := panel
	delta.Messages = []protocol.PanelMessage{{ID: 2, Level: 1, Text: "msg-1"}, {ID: 3, Level: 1, Text: "msg-2"}}
	updated, _ := model.Update(port.PacketMsg{Commands: frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiBottomPanel, Bottom: delta}})})
	got := updated.(Model).chrome[generated.OPGuiBottomPanel].Bottom.Messages

	if len(got) != 3 || got[0].ID != 1 || got[1].ID != 2 || got[2].ID != 3 {
		t.Fatalf("bottom panel should append same-stream deltas without duplicates, got %+v", got)
	}
}

func TestBottomPanelMessageStreamChangeReplacesMessages(t *testing.T) {
	model, panel := bottomPanelTestModel(2, nil)

	next := panel
	next.StreamInstance++
	next.Messages = []protocol.PanelMessage{{ID: 1, Level: 1, Text: "fresh"}}
	updated, _ := model.Update(port.PacketMsg{Commands: frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiBottomPanel, Bottom: next}})})
	got := updated.(Model).chrome[generated.OPGuiBottomPanel].Bottom.Messages

	if len(got) != 1 || got[0].Text != "fresh" {
		t.Fatalf("bottom panel should replace messages on stream change, got %+v", got)
	}
}

func TestBottomPanelHideReopenKeepsSameStreamMessages(t *testing.T) {
	model, panel := bottomPanelTestModel(2, nil)

	hidden := panel
	hidden.Visible = false
	hidden.Messages = nil
	updated, _ := model.Update(port.PacketMsg{Commands: frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiBottomPanel, Bottom: hidden}})})
	hiddenModel := updated.(Model)

	reopened := panel
	reopened.Messages = nil
	updated, _ = hiddenModel.Update(port.PacketMsg{Commands: frame(protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiBottomPanel, Bottom: reopened}})})
	got := updated.(Model).chrome[generated.OPGuiBottomPanel].Bottom.Messages

	if len(got) != 2 || got[0].ID != 1 || got[1].ID != 2 {
		t.Fatalf("bottom panel should keep cached same-stream messages across hide/reopen, got %+v", got)
	}
}

func bottomPanelTestModel(messageCount int, out chan<- []byte) (Model, protocol.BottomPanel) {
	model := New(80, 12, out, nil)
	messages := make([]protocol.PanelMessage, 0, messageCount)
	for i := 0; i < messageCount; i++ {
		messages = append(messages, protocol.PanelMessage{ID: uint32(i + 1), Level: 1, Text: fmt.Sprintf("msg-%d", i)})
	}
	panel := protocol.BottomPanel{Visible: true, ActiveTab: 0, Tabs: []protocol.PanelTab{{Type: 0x01, Name: "Messages"}}, StreamInstance: 42, Messages: messages}
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiBottomPanel: {Opcode: generated.OPGuiBottomPanel, Bottom: panel}}
	// The bottom panel is registry-placed now (#2281): it renders and hit-tests by
	// its BEAM placement rect (bottom band, full width). Place it where
	// bottomPanelHeight computes its band so local scroll routing matches.
	height := model.bottomPanelHeight(panel)
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDBottomPanel, Rect: generated.Rect{Row: uint16(model.height - height), Col: 0, Width: uint16(model.width), Height: uint16(height)}, Z: 200, HitKind: 7},
	}
	return model, panel
}

func visibleIndex(value string, needle string) int {
	index := strings.Index(value, needle)
	if index < 0 {
		return -1
	}
	return displayWidth(value[:index])
}

func waitForZone(t *testing.T, model Model, id string) *zoneInfo {
	t.Helper()
	info := model.zones.Get(id)
	if info == nil {
		t.Fatalf("zone %q was not registered", id)
	}
	return info
}

func completionChrome(items int, selected uint16) protocol.ChromePayload {
	cItems := make([]protocol.CompletionItem, items)
	for i := range cItems {
		cItems[i] = protocol.CompletionItem{Kind: 1, Label: fmt.Sprintf("item%d", i)}
	}
	return protocol.ChromePayload{Opcode: generated.OPGuiCompletion, Complete: protocol.Completion{Visible: true, Selected: selected, Items: cItems}}
}

func TestCompletionLocalNavigationCtrlNAdvancesPreview(t *testing.T) {
	out := make(chan []byte, 1)
	model := New(30, 10, out, nil)
	model.chrome[generated.OPGuiCompletion] = completionChrome(5, 0)

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'n', Mod: tea.ModCtrl}))
	model = updated.(Model)

	if model.localPresentation.previewCompletionIndex == nil || *model.localPresentation.previewCompletionIndex != 1 {
		t.Fatalf("C-n should set preview completion index to 1, got %v", model.localPresentation.previewCompletionIndex)
	}
	packets := drainOutboundPackets(out)
	if len(packets) != 1 {
		t.Fatalf("C-n should still forward the key packet, got %d packets", len(packets))
	}
}

func TestCompletionLocalNavigationCtrlPRetreatsPreview(t *testing.T) {
	out := make(chan []byte, 1)
	model := New(30, 10, out, nil)
	model.chrome[generated.OPGuiCompletion] = completionChrome(5, 3)

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'p', Mod: tea.ModCtrl}))
	model = updated.(Model)

	if model.localPresentation.previewCompletionIndex == nil || *model.localPresentation.previewCompletionIndex != 2 {
		t.Fatalf("C-p should set preview completion index to 2, got %v", model.localPresentation.previewCompletionIndex)
	}
}

func TestCompletionLocalNavigationClampsAtBoundaries(t *testing.T) {
	t.Run("clamps at bottom", func(t *testing.T) {
		model := New(30, 10, nil, nil)
		model.chrome[generated.OPGuiCompletion] = completionChrome(3, 2)

		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'n', Mod: tea.ModCtrl}))
		model = updated.(Model)

		if model.localPresentation.previewCompletionIndex != nil {
			t.Fatalf("C-n at last item should not set preview (no movement), got %v", *model.localPresentation.previewCompletionIndex)
		}
	})

	t.Run("clamps at top", func(t *testing.T) {
		model := New(30, 10, nil, nil)
		model.chrome[generated.OPGuiCompletion] = completionChrome(3, 0)

		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'p', Mod: tea.ModCtrl}))
		model = updated.(Model)

		if model.localPresentation.previewCompletionIndex != nil {
			t.Fatalf("C-p at first item should not set preview (no movement), got %v", *model.localPresentation.previewCompletionIndex)
		}
	})
}

func TestCompletionLocalNavigationDoesNotMutateCommittedSelected(t *testing.T) {
	model := New(30, 10, nil, nil)
	model.chrome[generated.OPGuiCompletion] = completionChrome(5, 1)

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'n', Mod: tea.ModCtrl}))
	model = updated.(Model)

	if model.chrome[generated.OPGuiCompletion].Complete.Selected != 1 {
		t.Fatalf("C-n should not mutate the BEAM-committed Selected, got %d", model.chrome[generated.OPGuiCompletion].Complete.Selected)
	}
}

func TestCompletionLocalNavigationIgnoredWhenPopupHidden(t *testing.T) {
	model := New(30, 10, nil, nil)
	model.chrome[generated.OPGuiCompletion] = protocol.ChromePayload{Opcode: generated.OPGuiCompletion, Complete: protocol.Completion{Visible: false, Items: []protocol.CompletionItem{{Kind: 1, Label: "x"}}}}

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'n', Mod: tea.ModCtrl}))
	model = updated.(Model)

	if model.localPresentation.previewCompletionIndex != nil {
		t.Fatalf("C-n should be ignored when popup is hidden")
	}
}

func TestCompletionEffectiveIndexUsesPreviewWhenSet(t *testing.T) {
	model := New(30, 10, nil, nil)
	completion := protocol.Completion{Visible: true, Selected: 1, Items: []protocol.CompletionItem{{Kind: 1, Label: "a"}, {Kind: 1, Label: "b"}, {Kind: 1, Label: "c"}}}

	if got := model.effectiveCompletionIndex(completion); got != 1 {
		t.Fatalf("effective index with no preview should be committed, got %d", got)
	}

	idx := 2
	model.localPresentation.previewCompletionIndex = &idx
	if got := model.effectiveCompletionIndex(completion); got != 2 {
		t.Fatalf("effective index with preview should be preview index, got %d", got)
	}
}

func TestCompletionReconcileClearsPreviewOnBEAMUpdate(t *testing.T) {
	model := New(30, 10, nil, nil)
	idx := 2
	model.localPresentation.previewCompletionIndex = &idx

	_ = model.applyCommands(frame(
		protocol.Command{Kind: protocol.CommandChrome, Chrome: completionChrome(3, 1)},
	))

	if model.localPresentation.previewCompletionIndex != nil {
		t.Fatalf("BEAM completion update should clear the preview index")
	}
}

func TestCompletionTwoIndexRenderingSplit(t *testing.T) {
	model := New(80, 20, nil, nil)
	model.activePalette = paletteFromTheme(testThemeCommand().Chrome.Theme)
	model.themeApplied = true
	items := []protocol.CompletionItem{{Kind: 1, Label: "foo"}, {Kind: 1, Label: "bar"}, {Kind: 1, Label: "baz"}}
	model.chrome[generated.OPGuiCompletion] = protocol.ChromePayload{Opcode: generated.OPGuiCompletion, Complete: protocol.Completion{Visible: true, Selected: 0, Items: items, Documentation: "foo docs"}}
	idx := 2
	model.localPresentation.previewCompletionIndex = &idx

	lines := model.renderCompletion(model.chrome[generated.OPGuiCompletion].Complete)

	joined := ansi.Strip(strings.Join(lines, "\n"))
	if !strings.Contains(joined, "foo docs") {
		t.Fatalf("doc pane should show committed item's docs, not the preview item's: %q", joined)
	}
}

func pickerChrome(items int, selected uint16) protocol.ChromePayload {
	pItems := make([]protocol.PickerItem, items)
	for i := range pItems {
		pItems[i] = protocol.PickerItem{Label: fmt.Sprintf("item%d", i)}
	}
	return protocol.ChromePayload{Opcode: generated.OPGuiPicker, Picker: protocol.Picker{Visible: true, Selected: selected, Items: pItems}}
}

func TestPickerLocalNavigationJAdvancesPreview(t *testing.T) {
	out := make(chan []byte, 1)
	model := New(30, 10, out, nil)
	model.chrome[generated.OPGuiPicker] = pickerChrome(5, 0)

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'j', Text: "j"}))
	model = updated.(Model)

	if model.localPresentation.previewPickerIndex == nil || *model.localPresentation.previewPickerIndex != 1 {
		t.Fatalf("j should set preview picker index to 1, got %v", model.localPresentation.previewPickerIndex)
	}
	packets := drainOutboundPackets(out)
	if len(packets) != 1 {
		t.Fatalf("j should still forward the key packet, got %d packets", len(packets))
	}
}

func TestPickerLocalNavigationKRetreatsPreview(t *testing.T) {
	out := make(chan []byte, 1)
	model := New(30, 10, out, nil)
	model.chrome[generated.OPGuiPicker] = pickerChrome(5, 3)

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'k', Text: "k"}))
	model = updated.(Model)

	if model.localPresentation.previewPickerIndex == nil || *model.localPresentation.previewPickerIndex != 2 {
		t.Fatalf("k should set preview picker index to 2, got %v", model.localPresentation.previewPickerIndex)
	}
}

func TestPickerLocalNavigationClampsAtBoundaries(t *testing.T) {
	t.Run("clamps at bottom", func(t *testing.T) {
		model := New(30, 10, nil, nil)
		model.chrome[generated.OPGuiPicker] = pickerChrome(3, 2)

		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'j', Text: "j"}))
		model = updated.(Model)

		if model.localPresentation.previewPickerIndex != nil {
			t.Fatalf("j at last item should not set preview, got %v", *model.localPresentation.previewPickerIndex)
		}
	})

	t.Run("clamps at top", func(t *testing.T) {
		model := New(30, 10, nil, nil)
		model.chrome[generated.OPGuiPicker] = pickerChrome(3, 0)

		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'k', Text: "k"}))
		model = updated.(Model)

		if model.localPresentation.previewPickerIndex != nil {
			t.Fatalf("k at first item should not set preview, got %v", *model.localPresentation.previewPickerIndex)
		}
	})
}

func TestPickerLocalNavigationDoesNotMutateCommittedSelected(t *testing.T) {
	model := New(30, 10, nil, nil)
	model.chrome[generated.OPGuiPicker] = pickerChrome(5, 1)

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'j', Text: "j"}))
	model = updated.(Model)

	if model.chrome[generated.OPGuiPicker].Picker.Selected != 1 {
		t.Fatalf("j should not mutate the BEAM-committed Selected, got %d", model.chrome[generated.OPGuiPicker].Picker.Selected)
	}
}

func TestPickerLocalNavigationIgnoredWhenHidden(t *testing.T) {
	model := New(30, 10, nil, nil)
	model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Opcode: generated.OPGuiPicker, Picker: protocol.Picker{Visible: false, Items: []protocol.PickerItem{{Label: "x"}}}}

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'j', Text: "j"}))
	model = updated.(Model)

	if model.localPresentation.previewPickerIndex != nil {
		t.Fatalf("j should be ignored when picker is hidden")
	}
}

func TestPickerEffectiveIndexUsesPreviewWhenSet(t *testing.T) {
	model := New(30, 10, nil, nil)
	picker := protocol.Picker{Visible: true, Selected: 1, Items: []protocol.PickerItem{{Label: "a"}, {Label: "b"}, {Label: "c"}}}

	if got := model.effectivePickerIndex(picker); got != 1 {
		t.Fatalf("effective index with no preview should be committed, got %d", got)
	}

	idx := 2
	model.localPresentation.previewPickerIndex = &idx
	if got := model.effectivePickerIndex(picker); got != 2 {
		t.Fatalf("effective index with preview should be preview index, got %d", got)
	}
}

func TestPickerReconcileClearsPreviewOnBEAMUpdate(t *testing.T) {
	model := New(30, 10, nil, nil)
	idx := 2
	model.localPresentation.previewPickerIndex = &idx

	_ = model.applyCommands(frame(
		protocol.Command{Kind: protocol.CommandChrome, Chrome: pickerChrome(3, 1)},
	))

	if model.localPresentation.previewPickerIndex != nil {
		t.Fatalf("BEAM picker update should clear the preview index")
	}
}
