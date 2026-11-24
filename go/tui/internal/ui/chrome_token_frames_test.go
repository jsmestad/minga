package ui

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// chromeFrameSizes are the terminal sizes the chrome token migration records frames at.
var chromeFrameSizes = []struct{ width, height uint16 }{{80, 24}, {120, 40}}

// chromeFrameGoldenSize is the size whose grids are committed under chromeFrameGoldenDir and compared cell for cell on every run.
var chromeFrameGoldenSize = struct{ width, height uint16 }{80, 24}

// chromeFrameGoldenDir holds one plain text grid per chrome surface at chromeFrameGoldenSize.
const chromeFrameGoldenDir = "testdata/chrome_token_frames"

// updateChromeFrames rewrites the committed golden grids: go test ./internal/ui/ -run TestChromeTokenFrames -update.
var updateChromeFrames = flag.Bool("update", false, "rewrite the committed chrome token frame grids in "+chromeFrameGoldenDir)

// chromeFrameScenario renders one chrome surface to text lines at the model's size.
type chromeFrameScenario struct {
	name   string
	render func(m Model) []string
}

// TestChromeTokenFrames renders every chrome surface that uses the token scale at 80x24 and 120x40. It checks that each surface renders, compares each 80x24 grid with its committed golden in testdata/chrome_token_frames (rewrite them with -update), and writes every plain text grid to $MINGA_TUI_FRAME_DIR when that variable is set, so a token change can be diffed cell by cell (docs/CHARM_TUI.md#chrome-tokens).
func TestChromeTokenFrames(t *testing.T) {
	dir := os.Getenv("MINGA_TUI_FRAME_DIR")
	for _, size := range chromeFrameSizes {
		for _, scenario := range chromeFrameScenarios() {
			name := fmt.Sprintf("%s_%dx%d", scenario.name, size.width, size.height)
			t.Run(name, func(t *testing.T) {
				model := New(size.width, size.height, nil)
				model.layout = model.computeLayout()
				lines := scenario.render(model)
				if len(lines) == 0 {
					t.Fatalf("%s rendered no rows", scenario.name)
				}
				grid := chromeFrameGrid(lines)
				if size == chromeFrameGoldenSize {
					checkChromeFrameGolden(t, name, grid)
				}
				if dir == "" {
					return
				}
				if err := os.WriteFile(filepath.Join(dir, name+".txt"), []byte(grid), 0o644); err != nil {
					t.Fatal(err)
				}
			})
		}
	}
}

// chromeFrameGrid flattens rendered rows to plain text, one terminal row per line, with trailing blanks trimmed.
func chromeFrameGrid(lines []string) string {
	var grid strings.Builder
	for _, line := range lines {
		for _, row := range strings.Split(line, "\n") {
			grid.WriteString(strings.TrimRight(ansi.Strip(row), " "))
			grid.WriteByte('\n')
		}
	}
	return grid.String()
}

// checkChromeFrameGolden fails when grid differs from the committed golden for name, naming the first row that differs.
func checkChromeFrameGolden(t *testing.T, name, grid string) {
	t.Helper()
	path := filepath.Join(chromeFrameGoldenDir, name+".txt")
	if *updateChromeFrames {
		if err := os.MkdirAll(chromeFrameGoldenDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(grid), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v; record intentional frames with: go test ./internal/ui/ -run TestChromeTokenFrames -update", err)
	}
	if grid == string(want) {
		return
	}
	got, wanted := strings.Split(grid, "\n"), strings.Split(string(want), "\n")
	for row := range max(len(got), len(wanted)) {
		var g, w string
		if row < len(got) {
			g = got[row]
		}
		if row < len(wanted) {
			w = wanted[row]
		}
		if g != w {
			t.Fatalf("%s differs from %s at row %d:\n got: %q\nwant: %q\nRecord an intentional change with -update and in go/tui/chrome_token_migration.json.", name, path, row+1, g, w)
		}
	}
}

func chromeFrameScenarios() []chromeFrameScenario {
	one := func(value string) []string { return []string{value} }
	review := protocol.StatusReview{Path: "lib/minga_editor/render_model/ui/review.ex", Freshness: protocol.ReviewStale}
	conflict := review
	conflict.ConflictIndex = 2
	chat := protocol.AgentChat{Visible: true, Status: 1, ModelName: "anthropic:claude-sonnet-4", ThinkingLevel: "medium", Prompt: "ordinary draft", PromptVisibleRows: 1, InputFocused: true}
	failed := protocol.AgentChat{
		Visible: true, Status: agentStatusNeedsYou, Lifecycle: protocol.AgentChatFailed, LifecycleReason: "provider unavailable",
		LifecycleRemedy: protocol.AgentStartRemedy{Kind: protocol.AgentStartRemedyRetry, Label: "Retry", KeyHint: "r"},
		LifecycleNotice: protocol.AgentLifecycleNotice{Headline: "Agent session stopped", Note: "Your draft is saved. SPC a n starts a new session."},
		ModelName:       "Not started", Prompt: "kept draft", PromptVisibleRows: 1,
	}
	tool := protocol.AgentChatMessage{ID: 7, Kind: agentKindTool, Name: "read_file", Summary: "lib/minga.ex", Result: "defmodule Minga do\nend", Status: 1, PreviewLines: []string{"defmodule Minga do"}, RetainedOutputOffer: [16]byte{1}}
	collapsed := tool
	collapsed.Collapsed = true
	failedTool := tool
	failedTool.IsError = true
	failedTool.Status = 2
	approval := protocol.AgentChatMessage{ID: 8, Kind: agentKindApprovalTool, Name: "write_file", Summary: "lib/minga.ex", PreviewLines: []string{"+ defmodule Minga do", "+ end"}, ApprovalTarget: approvalControlTarget("A")}
	return []chromeFrameScenario{
		{"tabs", func(m Model) []string {
			return one(m.renderTabs(protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Label: "main.go", Active: true, Dirty: true}, {ID: 2, Label: "render_chrome.go"}, {ID: 3, Label: "Untitled-1", Ephemeral: true}}}, m.width))
		}},
		{"breadcrumb", func(m Model) []string {
			m.chrome[generated.OPGuiGitStatus] = protocol.ChromePayload{Opcode: generated.OPGuiGitStatus, Git: protocol.GitStatus{Branch: "main", Ahead: 1, Entries: []protocol.GitStatusEntry{{Path: "a.go"}}}}
			return one(m.renderBreadcrumb(protocol.Breadcrumb{Segments: []string{"go", "tui", "render_chrome.go"}}, m.width))
		}},
		{"git_status_panel", func(m Model) []string {
			git := protocol.GitStatus{Branch: "main", Entries: []protocol.GitStatusEntry{{Section: 0, Path: "lib/a.ex"}, {Section: 1, Path: "lib/b.ex"}, {Section: 2, Path: "new.txt"}}}
			style := m.panelStyle()
			return m.renderGitStatusPanel(git, style, style, 40, 10, &gitStatusHits{})
		}},
		{"footer_fallback", func(m Model) []string {
			m.chrome[generated.OPGuiStatusBar] = protocol.ChromePayload{Opcode: generated.OPGuiStatusBar, Status: protocol.StatusBar{Filename: "main.go", Line: 12, Column: 4, Message: "saved"}}
			m.chrome[generated.OPGuiSearchState] = protocol.ChromePayload{Opcode: generated.OPGuiSearchState, Search: protocol.SearchState{Active: true, Count: 4, CurrentIndex: 2}}
			m.resyncPending = true
			return m.footerLines()
		}},
		{"footer_segments", func(m Model) []string {
			return one(m.renderStatusSegments(protocol.StatusBar{Filename: "main.go", PendingKeys: "SPC f", Left: []protocol.StatusSegment{{Text: " NORMAL "}}, Right: []protocol.StatusSegment{{Text: "12:4"}}}))
		}},
		{"minibuffer", func(m Model) []string {
			return one(m.renderMinibuffer(protocol.Minibuffer{Visible: true, Prompt: ":", Input: "write", Context: "E32: No file name"}))
		}},
		{"completion", func(m Model) []string {
			completion := protocol.Completion{Visible: true, Items: []protocol.CompletionItem{{Label: "fmt.Println", Detail: "func(a ...any)"}, {Label: "fmt.Printf", Detail: "func(format string, a ...any)"}}, Documentation: "Println formats using the default formats for its operands and writes to standard output."}
			return m.renderCompletion(completion, 60, 10)
		}},
		{"which_key", func(m Model) []string {
			which := protocol.WhichKey{Visible: true, Prefix: "SPC", Page: 0, PageCount: 2, Bindings: []protocol.WhichKeyBinding{{Kind: whichKeyKindGroup, Key: "f", Description: "Files ›"}, {Kind: whichKeyKindGroup, Key: "b", Description: "Buffers ›"}, {Kind: whichKeyKindGroup, Key: "w", Description: "Windows ›"}, {Kind: whichKeyKindGroup, Key: "a", Description: "Minga ›"}, {Kind: whichKeyKindGroup, Key: "g", Description: "Git ›"}, {Key: "q", Description: "Quit editor"}}}
			return append(m.renderWhichKey(which), m.renderFloatingWhichKey(which))
		}},
		{"picker", func(m Model) []string {
			picker := modelPickerFixture(0)
			picker.Query = "claude"
			picker.Marked = 1
			picker.LoadStatus = 1
			return append(m.renderPicker(picker, protocol.PickerPreview{}), m.renderFloatingPicker(picker, protocol.PickerPreview{}))
		}},
		{"prompt_choices", func(m Model) []string {
			return one(m.renderPromptChoices(promptChoiceFixture(1)))
		}},
		{"signature", func(m Model) []string {
			return m.renderSignature(protocol.SignatureHelp{Visible: true, Signatures: []protocol.Signature{{Label: "Println(a ...any)", Doc: "Println formats.", Parameters: []protocol.SignatureParameter{{Label: "a", Doc: "values"}}}}})
		}},
		{"bottom_panel", func(m Model) []string {
			m.bottomPanelScrollback = 2
			return m.renderBottomPanel(protocol.BottomPanel{Visible: true, HeightPercent: 30, Messages: []protocol.PanelMessage{{ID: 1, Level: 1, Text: "LSP: elixir-ls connected"}, {ID: 2, Level: 3, Text: "format failed"}}})
		}},
		{"observatory", func(m Model) []string {
			return m.renderObservatory(protocol.Observatory{Visible: true, Count: 2, Nodes: []protocol.ObservatoryNode{{PID: "<0.1.0>", Name: "Minga.Supervisor"}, {PID: "<0.2.0>", Name: "Minga.Buffer", Depth: 2}}})
		}},
		{"edit_timeline", func(m Model) []string {
			m.layout.timeline = uiRect{Width: m.width, Height: 6}
			files := m.renderEditTimeline(protocol.EditTimeline{Visible: true, Files: []protocol.TimelineFile{{Path: "lib/a.ex", EntryCount: 2, LinesAdded: 3}}})
			entries := m.renderEditTimeline(protocol.EditTimeline{Visible: true, Entries: []protocol.TimelineEntry{{Index: 1, EntryID: "e1", ToolName: "write_file", TimestampDelta: 4}}})
			return append(files, entries...)
		}},
		{"notifications", func(m Model) []string {
			return m.renderNotifications(protocol.Notifications{Visible: true, Items: []protocol.Notification{{ID: "n1", Title: "Update ready", Body: "Restart to apply", Source: "minga", Dismissable: true, Actions: []protocol.NotificationAction{{ID: "a1", Label: "Restart"}, {ID: "a2", Label: "Later"}}}}})
		}},
		{"file_tree", func(m Model) []string {
			tree := protocol.FileTree{Visible: true, Root: "minga", Rows: []protocol.FileTreeRow{{ID: "1", Name: "lib", Directory: true, Expanded: true}, {ID: "2", Name: "minga.ex", Depth: 1}}}
			m.chrome[generated.OPGuiFileTree] = protocol.ChromePayload{Opcode: generated.OPGuiFileTree, Tree: tree}
			withTree, _ := m.withFileTree([]string{"main", "body"})
			return append(m.renderFileTree(tree, 30, 6, false), withTree...)
		}},
		{"review_status", func(m Model) []string {
			return []string{m.renderReviewStatus(review), m.renderReviewStatus(conflict)}
		}},
		{"empty_state", func(m Model) []string {
			return modelWithEmptyState(uint16(m.width), uint16(m.height), returningUserEmptyState()).renderEmptyState(returningUserEmptyState())
		}},
		{"agent_help", func(m Model) []string {
			return m.agentHelpContent(protocol.AgentHelp{Visible: true, Groups: []protocol.AgentHelpGroup{{Title: "Prompt", Bindings: []protocol.AgentHelpBinding{{Key: "Enter", Description: "send"}}}, {Title: "Transcript", Bindings: []protocol.AgentHelpBinding{{Key: "j/k", Description: "scroll"}}}}}, 40)
		}},
		{"agent_header", func(m Model) []string {
			return []string{m.renderAgentHeader(chat, m.width), m.renderAgentTranscriptSeparator(m.width), m.renderAgentNotice("Queued", "next prompt waits", m.width), m.renderAgentDetailHint("Enter", "send", 40)}
		}},
		{"agent_landing", func(m Model) []string {
			return append(m.renderAgentLandingState(m.width), m.renderAgentEmptyState(m.width)...)
		}},
		{"agent_lifecycle", func(m Model) []string {
			return m.renderAgentLifecycleNotice(failed, m.width, 10)
		}},
		{"agent_messages", func(m Model) []string {
			var lines []string
			for _, msg := range []protocol.AgentChatMessage{
				{Kind: agentKindUser, Text: "Explain the chrome token scale"},
				{Kind: agentKindAssistant, Text: "The scale converts points to cells."},
				{Kind: agentKindSystem, Text: "Session resumed"},
				{Kind: agentKindThinking, Text: "Considering the anatomy table"},
				tool, collapsed, failedTool, approval,
				{Kind: agentKindUsage, Usage: protocol.AgentUsage{Input: 1200, Output: 300, CostMicros: 4200}},
			} {
				lines = append(lines, m.renderAgentMessage(msg, m.width)...)
			}
			lines = append(lines, m.renderAgentMarkdownBlock(protocol.AgentMarkdownBlock{Kind: 0x05}, m.width)...)
			code := protocol.AgentMarkdownBlock{Kind: 0x04, Flags: 0x01, Label: "Elixir", Lines: []protocol.AgentStyledLine{{{Text: "IO.puts(:ok)"}}}}
			return append(lines, m.renderAgentCodeCardRows(code, m.width, 0, 4)...)
		}},
		{"agent_composer", func(m Model) []string {
			return m.renderAgentComposerWithLimit(chat, m.width, 6)
		}},
	}
}
