package ui

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/cellbuf"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func timelineReviewModel(files []protocol.TimelineFile) Model {
	model := New(80, 24, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiEditTimeline: {Timeline: protocol.EditTimeline{
			Visible: true, Generation: 37, ViewingIndex: 0xFFFF, Files: files,
		}},
	}
	model.surfacePlacements = []generated.SurfacePlacement{{
		SurfaceID: surfaceIDEditTimeline,
		Rect:      generated.Rect{Row: 15, Col: 4, Width: 60, Height: 6},
		Z:         170, HitKind: 8,
	}}
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	return model
}
func TestTimelineReviewPathKeepsItsFilenameWhenNarrow(t *testing.T) {
	path := strings.Repeat("/long project 界e\u0301", 8) + "/checkout.ex"
	model := timelineReviewModel([]protocol.TimelineFile{{Path: path}})
	timeline, _ := model.editTimeline()
	for _, width := range []uint16{32, 60, 140} {
		model.surfacePlacements[0].Rect.Width = width
		model.layout = model.computeLayout()
		rendered := ansi.Strip(strings.Join(model.renderEditTimeline(timeline), "\n"))
		if !strings.Contains(rendered, "checkout.ex") {
			t.Fatalf("width%d hides the filename needed to choose Review: %q", width, rendered)
		}
	}
}

func TestTimelineReviewButtonsActivateExactOfferedPaths(t *testing.T) {
	paths := []string{"/project/z dir/shared.ex", "/project/a+dir/shared.ex"}
	model := timelineReviewModel([]protocol.TimelineFile{{Path: paths[0]}, {Path: paths[1]}})
	model.viewport.SetContent(model.content())
	_ = model.View()

	var previousY int
	for index, path := range paths {
		button := waitForZone(t, model, zoneIDTimelineReview(37, path))
		if button.EndX-button.StartX+1 != 8 || button.StartX != 4 {
			t.Fatalf("Review must be an explicit eight-cell button inside the placement, got %+v", button)
		}
		if index > 0 && button.StartY != previousY+1 {
			t.Fatalf("duplicate basenames must retain distinct source-ordered targets: %+v", button)
		}
		previousY = button.StartY
		click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: button.StartX + 1, Y: button.StartY})
		packet, ok := model.semanticMousePacket(click)
		if !ok || !bytes.Equal(packet, protocol.EncodeGUISemanticItemActivate(5, 2, 37, []byte(path))) {
			t.Fatalf("Review click must carry original generation and exact full path %q, ok=%v packet=%v", path, ok, packet)
		}
		click.X = button.EndX + 2
		if packet, ok := model.semanticMousePacket(click); !ok || packet != nil {
			t.Fatal("file summary text must be contained without activating Review")
		}
	}
}

func TestTimelineReviewNeverRetargetsStaleOrMissingOffers(t *testing.T) {
	for _, change := range []string{"generation", "membership", "hidden", "zero generation"} {
		t.Run(change, func(t *testing.T) {
			model := timelineReviewModel([]protocol.TimelineFile{{Path: "/project/original.ex"}})
			_ = model.View()
			button := waitForZone(t, model, zoneIDTimelineReview(37, "/project/original.ex"))
			payload := model.chrome[generated.OPGuiEditTimeline]
			switch change {
			case "generation":
				payload.Timeline.Generation++
			case "membership":
				payload.Timeline.Files = []protocol.TimelineFile{{Path: "/project/other.ex"}}
			case "hidden":
				payload.Timeline.Visible = false
			case "zero generation":
				payload.Timeline.Generation = 0
			}
			model.chrome[generated.OPGuiEditTimeline] = payload
			click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: button.StartX + 1, Y: button.StartY})
			if packet, _ := model.semanticMousePacket(click); packet != nil {
				t.Fatalf("a stale Review target must not fall back to another file: %v", packet)
			}
		})
	}
}

func TestTimelineReviewBoundsAndScrollPreserveReadingAnchor(t *testing.T) {
	files := make([]protocol.TimelineFile, 100)
	for index := range files {
		// Descending names expose accidental client-side sorting.
		files[index] = protocol.TimelineFile{Path: fmt.Sprintf("/project/file-%03d.ex", 100-index)}
	}
	model := timelineReviewModel(files)
	payload := model.chrome[generated.OPGuiEditTimeline]
	lines := model.renderEditTimeline(payload.Timeline)
	if len(lines) != 6 {
		t.Fatalf("100 files must occupy only the committed six-row band, got %d rows", len(lines))
	}
	for _, line := range lines {
		if width := ansi.StringWidth(line); width != 60 {
			t.Fatalf("timeline row must fit the committed width, got %d cells", width)
		}
	}
	_ = model.View()
	first := waitForZone(t, model, zoneIDTimelineReview(37, files[0].Path))
	if model.zones.Get(zoneIDTimelineReview(37, files[4].Path)) != nil {
		t.Fatal("clipped files must not leave invisible mouse targets")
	}
	wheel := tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: first.StartX, Y: first.StartY})
	var handled bool
	model, handled = model.localMouse(wheel)
	if !handled {
		t.Fatal("wheel inside the visible timeline must scroll its resident file list")
	}
	_ = model.View()
	anchor := waitForZone(t, model, zoneIDTimelineReview(37, files[3].Path))
	if anchor.StartY != first.StartY || anchor.StartX != first.StartX {
		t.Fatal("scrolling files must not move the Review controls")
	}
	if model.zones.Get(zoneIDTimelineReview(37, files[0].Path)) != nil {
		t.Fatal("scrolled-out files must lose their mouse targets")
	}

	// A new source offer before the anchor and a status update elsewhere must not select, reveal, or scroll to that file. Preserve the reading path.
	payload.Timeline.Generation++
	payload.Timeline.Files = append([]protocol.TimelineFile{{Path: "/project/new.ex", ReviewStatus: 1}}, files...)
	model.chrome[generated.OPGuiEditTimeline] = payload
	_ = model.View()
	retained := waitForZone(t, model, zoneIDTimelineReview(38, files[3].Path))
	if retained.StartY != anchor.StartY || retained.StartX != anchor.StartX {
		t.Fatal("background writes must retain the current reading anchor and control positions")
	}
	if model.zones.Get(zoneIDTimelineReview(38, "/project/new.ex")) != nil {
		t.Fatal("background status must not reveal or choose the new file")
	}

	for range 40 {
		model, _ = model.localMouse(wheel)
	}
	_ = model.View()
	last := waitForZone(t, model, zoneIDTimelineReview(38, files[99].Path))
	if last.StartY != first.StartY+3 {
		t.Fatalf("scroll boundary must expose the final offered file without moving the band, got %+v", last)
	}
	click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: last.StartX + 1, Y: last.StartY})
	packet, ok := model.semanticMousePacket(click)
	if !ok || !bytes.Equal(packet, protocol.EncodeGUISemanticItemActivate(5, 2, 38, []byte(files[99].Path))) {
		t.Fatalf("last file Review must remain reachable with its offered identity, ok=%v packet=%v", ok, packet)
	}
	wheel.Button = tea.MouseWheelUp
	for range 40 {
		model, _ = model.localMouse(wheel)
	}
	_ = model.View()
	waitForZone(t, model, zoneIDTimelineReview(38, "/project/new.ex"))
	wheel.X = 0
	if _, handled := model.localMouse(wheel); handled {
		t.Fatal("wheel outside the timeline placement must not scroll its files")
	}
}

func TestTimelineReviewFitsSmallBandsAndOneFile(t *testing.T) {
	for _, width := range []uint16{12, 20, 60} {
		for _, height := range []uint16{1, 2, 3} {
			t.Run(fmt.Sprintf("%dx%d", width, height), func(t *testing.T) {
				model := timelineReviewModel([]protocol.TimelineFile{{Path: "/project/long/path/shared.ex"}})
				model.surfacePlacements[0].Rect.Width = width
				model.surfacePlacements[0].Rect.Height = height
				model.layout = model.computeLayout()
				model.viewport.SetHeight(model.layout.body.Height)
				model.viewport.SetContent(model.content())
				_ = model.View()
				button := model.zones.Get(zoneIDTimelineReview(37, "/project/long/path/shared.ex"))
				if height < 3 {
					if button != nil {
						t.Fatal("a band with no file rows must not expose Review targets")
					}
					_, handled := model.localMouse(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 4, Y: 16}))
					if !handled {
						t.Fatal("a tiny visible band must contain wheel input without indexing a nonexistent row")
					}
					return
				}
				if button == nil || button.StartX != 4 || button.EndX != 11 || button.StartY != 18 {
					t.Fatalf("one-file Review must remain visible in a narrow band, got %+v", button)
				}
				timeline, _ := model.editTimeline()
				text := ansi.Strip(strings.Join(model.renderEditTimeline(timeline), "\n"))
				if !strings.Contains(text, "[Review]") {
					t.Fatalf("terminal-compatible Review label missing: %q", text)
				}
			})
		}
	}
}

// Decode the actual timeline and placement packets before sending them through Update's committed-frame path.
// The placement is independent of file count.
func timelineChromeCommands(t *testing.T, files []protocol.TimelineFile, rect generated.Rect) []protocol.Command {
	t.Helper()
	body := []byte{1, 0xFF, 0xFF, 0, byte(len(files))}
	for _, file := range files {
		body = binary.BigEndian.AppendUint16(body, uint16(len(file.Path)))
		body = append(body, file.Path...)
		body = append(body, file.EntryCount)
		body = binary.BigEndian.AppendUint32(body, file.LinesAdded)
		body = binary.BigEndian.AppendUint32(body, file.LinesRemoved)
		body = append(body, file.ReviewStatus)
	}
	body = binary.BigEndian.AppendUint32(body, 37)
	timeline := binary.BigEndian.AppendUint16([]byte{generated.OPGuiEditTimeline}, uint16(len(body)))
	timeline = append(timeline, body...)
	placement := binary.BigEndian.AppendUint16(nil, 1)
	for _, value := range []uint16{surfaceIDEditTimeline, rect.Row, rect.Col, rect.Width, rect.Height, 170} {
		placement = binary.BigEndian.AppendUint16(placement, value)
	}
	placement = append(placement, 8)
	layout := binary.BigEndian.AppendUint16([]byte{generated.OPGuiSurfaceLayout, 1, 1}, uint16(len(placement)))
	layout = append(layout, placement...)
	commands := make([]protocol.Command, 0, 2)
	for _, packet := range [][]byte{timeline, layout} {
		command, err := protocol.DecodeCommand(packet)
		if err != nil {
			t.Fatal(err)
		}
		commands = append(commands, command)
	}
	return commands
}

func timelineMinibufferCommand(t *testing.T, visible bool) protocol.Command {
	t.Helper()
	packet := []byte{generated.OPGuiMinibuffer, 0}
	if visible {
		packet = []byte{generated.OPGuiMinibuffer, 1, 0, 0, 5, 1, ':'}
		packet = binary.BigEndian.AppendUint16(packet, 5)
		packet = append(packet, "write"...)
		packet = append(packet, 0, 0, 0, 0, 0, 0, 0, 0)
		packet = binary.BigEndian.AppendUint32(packet, 17)
	}
	command, err := protocol.DecodeCommand(packet)
	if err != nil {
		t.Fatal(err)
	}
	return command
}

func TestTimelineCommittedChromeKeepsComposedPromptAndReviewStationary(t *testing.T) {
	for _, size := range [][2]uint16{{140, 40}, {60, 24}} {
		for _, state := range []struct {
			mode string
			mini bool
		}{{"chat", false}, {"chat", true}, {"review", false}, {"review", true}} {
			mode := state.mode
			t.Run(fmt.Sprintf("%dx%d/%s/minibuffer=%t", size[0], size[1], mode, state.mini), func(t *testing.T) {
				width, height := size[0], size[1]
				out := make(chan []byte, 128)
				model := New(width, height, out)
				chat := protocol.AgentChat{Visible: true, Prompt: "METADATA_NOT_DRAFT", PromptVisibleRows: 1, InputFocused: true}
				model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows("draft stays"), 0, 2, 0, 0, protocol.Selection{}), 800)
				review := protocol.StatusReview{Path: "/project/review.ex", Freshness: protocol.ReviewStale, Generation: 43, ItemID: "opaque:+/% review"}
				footerRows := uint16(1)
				if state.mini {
					footerRows++
				}
				rect := generated.Rect{Row: uint16(model.layout.grid.Height) - footerRows - 3, Width: width, Height: 3}
				mini := timelineMinibufferCommand(t, state.mini)
				files := make([]protocol.TimelineFile, 100)
				for index := range files {
					// Source order intentionally differs from lexical path order.
					files[index] = protocol.TimelineFile{Path: fmt.Sprintf("/project/Ω dir/%03d/shared.ex", 100-index), EntryCount: 1}
				}
				commit := func(offered []protocol.TimelineFile) {
					t.Helper()
					seq := model.lastCommittedSeq + 1
					commands := []protocol.Command{beginFrame(seq, model.lastCommittedSeq)}
					commands = append(commands, timelineChromeCommands(t, offered, rect)...)
					commands = append(commands, mini, protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
						Opcode:       generated.OPGuiAgentContext,
						AgentContext: protocol.AgentContext{Visible: true, Status: 4, Task: "Activity belongs to native chrome", Progress: protocol.AgentProgress{FileCount: uint16(len(offered))}},
					}})
					if mode == "review" {
						chat.Visible = false
						commands = append(commands, reviewStatusCommand(t, &review),
							protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiAgentChat, AgentChat: chat}},
							protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
								ID: 7, Rows: []protocol.WindowRow{{ID: 700, Text: "Review body retained"}},
								GeometrySet: true, Geometry: protocol.PaneGeometry{
									ContentRect: protocol.Rect{Width: width, Height: rect.Row},
									TextRect:    protocol.Rect{Width: width, Height: rect.Row},
								},
							}},
							protocol.Command{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: 7, PresentationID: 700}},
						)
					} else {
						commands = append(commands, reviewStatusCommand(t, nil))
					}
					commands = append(commands,
						protocol.Command{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: protocol.AgentPromptWindowID, PresentationID: 800}},
						protocol.Command{Kind: protocol.CommandCommitFrame, FrameSeq: seq},
					)
					updated, _ := model.Update(port.PacketMsg{Commands: commands})
					model = updated.(Model)
					if model.lastCommittedSeq != seq {
						t.Fatalf("composed chrome frame %d rejected", seq)
					}
					if strings.Contains(model.View().Content, "Agent context") {
						t.Fatal("unplaced compact context covers Agent workspace controls")
					}
				}
				click := func(x, y int, want []byte) {
					t.Helper()
					drainOutboundPackets(out)
					updated, _ := updateFromPublishedView(model, model.View(), tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: x, Y: y}))
					model = updated.(Model)
					packets := drainOutboundPackets(out)
					if want == nil {
						if len(packets) != 0 {
							t.Fatalf("blank chrome emitted input: %x", packets)
						}
					} else if len(packets) != 1 || !bytes.Equal(packets[0], want) {
						t.Fatalf("visible composed control emitted %x, want %x", packets, want)
					}
				}
				var baseline uiLayout
				var promptBaseline agentComposerPlacement
				var fitBaseline protocol.AgentPromptFit
				var controlsBaseline [3]zoneInfo
				assertFrame := func(first bool, count int) {
					t.Helper()
					view := model.View()
					lines := strings.Split(ansi.Strip(view.Content), "\n")
					if len(lines) != int(height) {
						t.Fatalf("composed frame has %d rows, want %d", len(lines), height)
					}
					for y, line := range lines {
						if ansi.StringWidth(line) > int(width) {
							t.Fatalf("composed row %d escapes terminal width: %q", y, line)
						}
					}
					grid := cellbuf.NewBuffer(int(width), int(height))
					cellbuf.SetContent(grid, view.Content)
					assertText := func(x, y int, text string) {
						t.Helper()
						for offset, r := range text {
							cell := grid.Cell(x+offset, y)
							if cell == nil || cell.Rune != r {
								t.Fatalf("composed cell (%d,%d) does not show %q: %q", x+offset, y, text, lines[y])
							}
						}
					}
					if first {
						baseline = model.layout
					} else if model.layout != baseline {
						t.Fatalf("file count moved chrome: %+v -> %+v", baseline, model.layout)
					}
					band := model.layout.timeline
					if band != (uiRect{X: 0, Y: int(height - footerRows - 3), Width: int(width), Height: 3}) ||
						model.layout.body.Y+model.layout.body.Height != band.Y ||
						band.Y+band.Height != model.layout.footer.Y ||
						model.layout.footer.Y+model.layout.footer.Height != int(height) || model.layout.footer.Height != int(footerRows) {
						t.Fatalf("body/timeline/footer overlap or escape terminal: %+v", model.layout)
					}
					if state.mini && !strings.Contains(lines[int(height)-1], ":write") {
						t.Fatalf("committed minibuffer disappeared from the second footer row: %q", lines[int(height)-1])
					}
					if _, active := model.overlayWinner(); active {
						t.Fatal("persistent timeline still competes for the popup slot")
					}
					assertText(1, band.Y+1, fmt.Sprintf("Review files (%d)", count))
					if count == 0 {
						assertText(0, band.Y+2, "No changed files")
						if strings.Contains(strings.Join(lines[band.Y:band.Y+band.Height], "\n"), "[Review]") {
							t.Fatal("empty mounted chrome offered a fake Review action")
						}
						for id := range model.zones.zones {
							if strings.HasPrefix(id, zonePrefixTimelineReview) {
								t.Fatalf("empty mounted chrome retained file offer %q", id)
							}
						}
					} else {
						assertText(0, band.Y+2, "[Review]")
					}
					if mode == "chat" {
						p, ok := model.agentPromptPlacement()
						if !ok {
							t.Fatal("committed composer disappeared")
						}
						if first {
							promptBaseline, fitBaseline = p, model.agent.lastPromptFit
						} else if p != promptBaseline || model.agent.lastPromptFit != fitBaseline {
							t.Fatal("file count or local scroll moved the composer or its reported fit")
						}
						x, y := model.layout.body.X+p.col, model.layout.body.Y+p.row
						assertText(x, y, "draft stays")
						assertText(x-p.prefix, model.layout.body.Y+p.controlsRow, "Send")
						assertText(x-p.prefix-1, band.Y-1, "╰")
						if view.Cursor == nil || view.Cursor.X != x+2 || view.Cursor.Y != y {
							t.Fatalf("prompt caret lost the shared physical transform: %+v", view.Cursor)
						}
						target, ok := model.editorTextTargetAt(x+2, y, 0)
						if !ok || target.windowID != protocol.AgentPromptWindowID || target.presentationID != 800 || target.utf16Offset != 2 {
							t.Fatalf("drawn prompt text no longer matches its pointer target: %+v", target)
						}
						click(x-p.prefix, model.layout.body.Y+p.controlsRow, protocol.EncodeGUIAgentComposerSubmit(800, 0))
					} else {
						if !strings.Contains(strings.Join(lines[:band.Y], "\n"), "Review body retained") {
							t.Fatal("timeline clipped the Review body")
						}
						ids := [3]string{zoneIDReviewControl(review, 1), zoneIDReviewControl(review, 2), zoneIDReviewHelp}
						labels := [3]string{"[Back to chat]", "[Review latest]", "[Help]"}
						for index, id := range ids {
							zone := waitForZone(t, model, id)
							if first {
								controlsBaseline[index] = *zone
							} else if *zone != controlsBaseline[index] {
								t.Fatalf("file count moved Review control %s", id)
							}
							if zone.StartY != model.layout.footer.Y || zone.EndX >= int(width) {
								t.Fatalf("Review control escaped footer: %+v", zone)
							}
							assertText(zone.StartX, zone.StartY, labels[index])
							want := protocol.EncodeGUIExecuteCommand("agent_toggle_help")
							if index < 2 {
								want = protocol.EncodeGUISemanticItemActivate(6, byte(index+1), review.Generation, []byte(review.ItemID))
							}
							click(zone.StartX, zone.StartY, want)
						}
					}
					// Separator and summary padding are chrome, never hidden text targets.
					click(int(width)-1, band.Y, nil)
					if _, ok := model.editorTextTargetAt(int(width)-1, band.Y+2, 0); ok {
						t.Fatal("blank timeline cells resolved to hidden editor text")
					}
				}
				for step, count := range []int{0, 1, 100, 0} {
					commit(files[:count])
					assertFrame(step == 0, count)
					if count == 0 {
						y := model.layout.timeline.Y + 2
						click(0, y, nil)
						drainOutboundPackets(out)
						updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 0, Y: y}))
						model = updated.(Model)
						if packets := drainOutboundPackets(out); len(packets) != 0 {
							t.Fatalf("empty chrome wheel leaked into the prompt/editor: %x", packets)
						}
						continue
					}
					zone := waitForZone(t, model, zoneIDTimelineReview(37, files[0].Path))
					firstX, firstY := zone.StartX, zone.StartY
					click(firstX, firstY, protocol.EncodeGUISemanticItemActivate(5, 2, 37, []byte(files[0].Path)))
					if count == 100 {
						drainOutboundPackets(out)
						for range 33 {
							updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: firstX, Y: firstY}))
							model = updated.(Model)
						}
						if packets := drainOutboundPackets(out); len(packets) != 0 {
							t.Fatalf("local file wheel leaked source input: %x", packets)
						}
						assertFrame(false, count)
						last := waitForZone(t, model, zoneIDTimelineReview(37, files[99].Path))
						if last.StartX != firstX || last.StartY != firstY || model.zones.Get(zoneIDTimelineReview(37, files[0].Path)) != nil {
							t.Fatal("scrolling to file 100 moved the band or retained an invisible first-file target")
						}
						click(last.StartX, last.StartY, protocol.EncodeGUISemanticItemActivate(5, 2, 37, []byte(files[99].Path)))
					}
				}
			})
		}
	}
}

func TestTimelineChromePadsEmptyAllocationAndRequiresPlacement(t *testing.T) {
	model := timelineReviewModel(nil)
	_ = model.View()
	layer := model.timelineLayer()
	if layer == nil || layer.GetX() != 4 || layer.GetY() != 16 || layer.Height() != 6 || layer.Width() != 60 {
		t.Fatalf("empty chrome did not occupy its complete authored allocation: %+v", layer)
	}
	if _, active := model.overlayWinner(); active {
		t.Fatal("empty chrome entered floating overlay competition")
	}
	model.surfacePlacements = nil
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	view := model.View().Content
	if model.timelineLayer() != nil || strings.Contains(ansi.Strip(view), "No changed files") {
		t.Fatal("unplaced timeline guessed a rectangle")
	}
}

func TestTimelineChromeRespectsHigherOverlayPointerContainment(t *testing.T) {
	files := []protocol.TimelineFile{{Path: "/project/first.ex"}, {Path: "/project/second.ex"}}
	model := timelineReviewModel(files)
	_ = model.View()
	button := waitForZone(t, model, zoneIDTimelineReview(37, files[0].Path))
	model.chrome[generated.OPGuiFloatPopup] = protocol.ChromePayload{Float: protocol.FloatPopup{
		Visible: true, Title: "Higher popup", Lines: []string{"covers file controls"},
	}}
	model.surfacePlacements = append(model.surfacePlacements, generated.SurfacePlacement{
		SurfaceID: surfaceIDFloatPopup,
		Rect:      generated.Rect{Row: uint16(button.StartY - model.layout.grid.Y), Col: 4, Width: 60, Height: 2},
		Z:         270, HitKind: 8,
	})
	_ = model.View()
	winner, ok := model.overlayWinner()
	if !ok || winner.surfaceID != surfaceIDFloatPopup || model.timelineLayer() == nil {
		t.Fatal("timeline mounting suppressed the independent floating popup")
	}
	wheel := tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: button.StartX, Y: button.StartY})
	updated, handled := model.localMouse(wheel)
	if handled || updated.timelineFirstPath != "" {
		t.Fatal("timeline wheel scrolled through higher-layer containment")
	}
	click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: button.StartX, Y: button.StartY})
	if packet, _ := model.semanticMousePacket(click); packet != nil {
		t.Fatalf("covered timeline offer activated through a higher layer: %x", packet)
	}
	if packet, ok := model.editTimelineMousePacket(click); ok || packet != nil {
		t.Fatal("direct timeline routing ignored higher-layer containment")
	}
}
