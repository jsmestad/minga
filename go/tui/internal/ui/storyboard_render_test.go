package ui

// Storyboard renderer (#4036).
//
// The storyboard factory drives every built scenario through the real editor and records the packets the BEAM sends to the frontend (test/storyboard/render_test.exs).
// This test replays each TUI transcript through the production packet decoder and Model.Update, renders Model.View into a cell buffer, and writes the frame as a text grid with its style runs.
// It runs only when MINGA_STORYBOARD_TRANSCRIPTS names the exported transcripts; MINGA_STORYBOARD_RENDERS names the output directory.
// design/tools/storyboard/renders.py compares the frames with the baselines in test/storyboard/baselines and builds the storyboard page (docs/design/storyboard.md, "Renders and baselines").

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image/color"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/port"
)

// storyboardTranscript is one recorded scenario capture, as test/support/storyboard/render.ex writes it.
type storyboardTranscript struct {
	Version  int      `json:"version"`
	Scenario string   `json:"scenario"`
	Frontend string   `json:"frontend"`
	Theme    string   `json:"theme"`
	Size     string   `json:"size"`
	Cols     int      `json:"cols"`
	Rows     int      `json:"rows"`
	Packets  []string `json:"packets"`
}

func TestStoryboardRenders(t *testing.T) {
	transcripts := os.Getenv("MINGA_STORYBOARD_TRANSCRIPTS")
	if transcripts == "" {
		t.Skip("set MINGA_STORYBOARD_TRANSCRIPTS to the exported storyboard transcripts (docs/design/storyboard.md)")
	}
	out := os.Getenv("MINGA_STORYBOARD_RENDERS")
	if out == "" {
		t.Fatal("MINGA_STORYBOARD_RENDERS must name the output directory")
	}
	paths, err := filepath.Glob(filepath.Join(transcripts, "*", "tui-*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatalf("no TUI transcripts under %s", transcripts)
	}
	sort.Strings(paths)
	for _, path := range paths {
		rel, _ := filepath.Rel(transcripts, path)
		t.Run(strings.TrimSuffix(rel, ".json"), func(t *testing.T) {
			transcript := loadStoryboardTranscript(t, path)
			frame := renderStoryboardTranscript(t, transcript)
			name := strings.TrimSuffix(filepath.Base(path), ".json") + ".txt"
			dir := filepath.Join(out, filepath.Dir(rel))
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, name), []byte(frame), 0o644); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func loadStoryboardTranscript(t *testing.T, path string) storyboardTranscript {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var transcript storyboardTranscript
	if err := json.Unmarshal(raw, &transcript); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	if transcript.Version != 1 || transcript.Frontend != "tui" || transcript.Cols <= 0 || transcript.Rows <= 0 {
		t.Fatalf("%s: unsupported transcript header %+v", path, transcript)
	}
	return transcript
}

// renderStoryboardTranscript replays the packets in order, the way the port reader delivers them, and serializes the final frame.
func renderStoryboardTranscript(t *testing.T, transcript storyboardTranscript) string {
	t.Helper()
	model := New(uint16(transcript.Cols), uint16(transcript.Rows), nil)
	var warnings []string
	warn := func(_ byte, text string) { warnings = append(warnings, text) }
	for i, encoded := range transcript.Packets {
		packet, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			t.Fatalf("packet %d: %v", i, err)
		}
		next, _ := model.Update(port.PacketMsg{Commands: port.DecodePacket(packet, warn)})
		model = next.(Model)
	}
	if len(warnings) > 0 {
		t.Fatalf("%s: decoder warnings: %v", transcript.Scenario, warnings)
	}
	if model.protocolError != "" {
		t.Fatalf("%s: protocol error: %s", transcript.Scenario, model.protocolError)
	}
	if model.lastFrameOutcome != frameOutcomeApplied {
		t.Fatalf("%s: the last frame was not applied (outcome %v)", transcript.Scenario, model.lastFrameOutcome)
	}
	return serializeStoryboardFrame(transcript, model)
}

// serializeStoryboardFrame draws the view into a cell buffer and writes the text grid, then one line per style run.
//
// Colours are the effective colours a viewer sees: cells without a colour take the view's default foreground or background, and reverse video swaps them.
// Wide glyphs occupy their cells; the continuation cell adds no text, so a text row can be shorter in runes than the terminal is wide.
func serializeStoryboardFrame(transcript storyboardTranscript, model Model) string {
	view := model.View()
	buffer := uv.NewScreenBuffer(transcript.Cols, transcript.Rows)
	buffer.Method = ansi.GraphemeWidth
	uv.NewStyledString(view.Content).Draw(buffer, buffer.Bounds())

	defaultFg, defaultBg := hexColor(view.ForegroundColor, "#000000"), hexColor(view.BackgroundColor, "#000000")
	var text, styles strings.Builder
	fmt.Fprintf(&text, "# minga storyboard frame v1\n# scenario: %s\n# frontend: tui\n# theme: %s\n# size: %dx%d\n",
		transcript.Scenario, transcript.Theme, transcript.Cols, transcript.Rows)
	if view.Cursor != nil {
		fmt.Fprintf(&text, "# cursor: %d,%d\n", view.Cursor.Position.Y, view.Cursor.Position.X)
	} else {
		text.WriteString("# cursor: none\n")
	}
	text.WriteString("## text\n")
	styles.WriteString("## styles (row start-end fg bg attrs)\n")
	for y := 0; y < transcript.Rows; y++ {
		var row strings.Builder
		run := styleRun{start: -1}
		for x := 0; x < transcript.Cols; x++ {
			cell := buffer.CellAt(x, y)
			key := styleRun{fg: defaultFg, bg: defaultBg}
			if cell != nil {
				row.WriteString(cell.Content)
				key = effectiveStyle(cell.Style, defaultFg, defaultBg)
			} else {
				row.WriteByte(' ')
			}
			if run.start >= 0 && run.sameStyle(key) {
				run.end = x
				continue
			}
			if run.start >= 0 {
				run.write(&styles, y)
			}
			key.start, key.end = x, x
			run = key
		}
		if run.start >= 0 {
			run.write(&styles, y)
		}
		text.WriteString(strings.TrimRight(row.String(), " "))
		text.WriteByte('\n')
	}
	return text.String() + styles.String()
}

// styleRun is a span of cells in one row with the same effective style.
type styleRun struct {
	start, end int
	fg, bg     string
	attrs      string
}

func (r styleRun) sameStyle(o styleRun) bool {
	return r.fg == o.fg && r.bg == o.bg && r.attrs == o.attrs
}

func (r styleRun) write(out *strings.Builder, row int) {
	attrs := r.attrs
	if attrs == "" {
		attrs = "-"
	}
	fmt.Fprintf(out, "%d %d-%d %s %s %s\n", row, r.start, r.end, r.fg, r.bg, attrs)
}

// effectiveStyle resolves a cell style to the colours a viewer sees and a short attribute word.
func effectiveStyle(style uv.Style, defaultFg, defaultBg string) styleRun {
	fg, bg := hexColor(style.Fg, defaultFg), hexColor(style.Bg, defaultBg)
	var attrs []string
	for _, attr := range []struct {
		bit  uint8
		name string
	}{{uv.AttrBold, "bold"}, {uv.AttrFaint, "faint"}, {uv.AttrItalic, "italic"}, {uv.AttrReverse, "reverse"}, {uv.AttrStrikethrough, "strike"}} {
		if style.Attrs&attr.bit != 0 {
			attrs = append(attrs, attr.name)
		}
	}
	if style.Underline != uv.UnderlineStyleNone {
		attrs = append(attrs, "underline")
	}
	if style.Attrs&uv.AttrReverse != 0 {
		fg, bg = bg, fg
	}
	return styleRun{fg: fg, bg: bg, attrs: strings.Join(attrs, ",")}
}

func hexColor(c color.Color, fallback string) string {
	if c == nil {
		return fallback
	}
	r, g, b, _ := c.RGBA()
	return fmt.Sprintf("#%02x%02x%02x", r>>8, g>>8, b>>8)
}
