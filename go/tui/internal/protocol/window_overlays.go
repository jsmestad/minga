package protocol

import (
	"github.com/jsmestad/minga/go/tui/internal/generated"
)

type Selection struct {
	Type     byte
	StartRow uint16
	StartCol uint16
	EndRow   uint16
	EndCol   uint16
}

type SearchMatch struct {
	Row      uint16
	StartCol uint16
	EndCol   uint16
	Current  bool
}

type DiagnosticRange struct {
	StartRow uint16
	StartCol uint16
	EndRow   uint16
	EndCol   uint16
	Severity byte
}

type DocumentHighlight struct {
	StartRow uint16
	StartCol uint16
	EndRow   uint16
	EndCol   uint16
	Kind     byte
}

type LineAnnotation struct {
	Row  uint16
	Kind byte
	FG   uint32
	BG   uint32
	Text string
}

// Rect is a type alias for the generated rect structure.
type Rect = generated.Rect

// ScrollPresentation carries BEAM-authored metadata for client-local presentation scrolling.
// VisibleEndLine and OverscanEndLine are exclusive bounds: start <= line < end.
type ScrollPresentation struct {
	WindowID              uint16
	ResetRequired         bool
	AnchorTop             uint32
	AnchorLeft            uint16
	AnchorVisualRowOffset uint16
	VisibleStartLine      uint32
	VisibleEndLine        uint32
	OverscanStartLine     uint32
	OverscanEndLine       uint32
	ContentEpoch          uint32
	LayoutGeneration      uint32
	// ScrollSeq is the monotonic scroll-authority sequence (#2661). The TUI
	// does not use local-presentation scroll offsets, so it only carries this
	// field through for parity with the wire format; it does not change any
	// TUI-visible rendering or input behavior.
	ScrollSeq uint32
}

type PaneGeometry struct {
	WindowID        uint16
	TotalRect       Rect
	ContentRect     Rect
	TextRect        Rect
	GutterRect      Rect
	ClipRect        Rect
	ViewportTop     uint32
	ViewportLeft    uint16
	ViewportRows    uint16
	ViewportCols    uint16
	TotalLines      uint32
	VisualRowOffset uint16
	TotalVisualRows uint32
	LineNumberWidth uint16
	SignColWidth    uint16
	HitRegions      []HitRegion
}

// HitRegion is a type alias for the generated hit region structure.
type HitRegion = generated.HitRegion

func decodeSelection(section []byte, window *WindowContent) {
	window.SelectionSet = true
	if len(section) < 1 || section[0] == 0 {
		window.Selection = Selection{}
		return
	}
	if len(section) < 9 {
		return
	}
	window.Selection = Selection{Type: section[0], StartRow: u16(section, 1), StartCol: u16(section, 3), EndRow: u16(section, 5), EndCol: u16(section, 7)}
}

func decodeSearchMatches(section []byte, window *WindowContent) {
	window.SearchSet = true
	genMatches, _, err := generated.DecodeGuiWindowContentSearchMatches(section, 0, len(section))
	if err != nil {
		window.SearchMatches = nil
		return
	}
	matches := make([]SearchMatch, 0, len(genMatches))
	for _, gm := range genMatches {
		matches = append(matches, SearchMatch{Row: gm.Row, StartCol: gm.StartCol, EndCol: gm.EndCol, Current: gm.IsCurrent != 0})
	}
	window.SearchMatches = matches
}

func decodeDiagnosticRanges(section []byte, window *WindowContent) {
	window.DiagnosticsSet = true
	genRanges, _, err := generated.DecodeGuiWindowContentDiagnosticRanges(section, 0, len(section))
	if err != nil {
		window.Diagnostics = nil
		return
	}
	ranges := make([]DiagnosticRange, 0, len(genRanges))
	for _, gr := range genRanges {
		ranges = append(ranges, DiagnosticRange{StartRow: gr.StartRow, StartCol: gr.StartCol, EndRow: gr.EndRow, EndCol: gr.EndCol, Severity: gr.Severity})
	}
	window.Diagnostics = ranges
}

func decodeDocumentHighlights(section []byte, window *WindowContent) {
	window.HighlightsSet = true
	genHighlights, _, err := generated.DecodeGuiWindowContentDocumentHighlights(section, 0, len(section))
	if err != nil {
		window.Highlights = nil
		return
	}
	highlights := make([]DocumentHighlight, 0, len(genHighlights))
	for _, gh := range genHighlights {
		highlights = append(highlights, DocumentHighlight{StartRow: gh.StartRow, StartCol: gh.StartCol, EndRow: gh.EndRow, EndCol: gh.EndCol, Kind: gh.Kind})
	}
	window.Highlights = highlights
}

func decodeLineAnnotations(section []byte, window *WindowContent) {
	window.AnnotationsSet = true
	genAnnotations, _, err := generated.DecodeGuiWindowContentAnnotations(section, 0, len(section))
	if err != nil {
		window.Annotations = nil
		return
	}
	annotations := make([]LineAnnotation, 0, len(genAnnotations))
	for _, ga := range genAnnotations {
		annotations = append(annotations, LineAnnotation{Row: ga.Row, Kind: ga.Kind, FG: ga.FG, BG: ga.BG, Text: ga.Text})
	}
	window.Annotations = annotations
}

func decodeScrollPresentation(section []byte, window *WindowContent) {
	gen, _, err := generated.DecodeGuiWindowContentScrollPresentation(section, 0, len(section))
	if err != nil {
		return
	}
	window.Scroll = ScrollPresentation{
		WindowID:              gen.WindowID,
		ResetRequired:         gen.Flags&0x01 != 0,
		AnchorTop:             gen.AnchorTop,
		AnchorLeft:            gen.AnchorLeft,
		AnchorVisualRowOffset: gen.AnchorVisualRowOffset,
		VisibleStartLine:      gen.VisibleStartLine,
		VisibleEndLine:        gen.VisibleEndLine,
		OverscanStartLine:     gen.OverscanStartLine,
		OverscanEndLine:       gen.OverscanEndLine,
		ContentEpoch:          gen.ContentEpoch,
		LayoutGeneration:      gen.LayoutGeneration,
		ScrollSeq:             gen.ScrollSeq,
	}
	window.ScrollSet = true
}

func decodePaneGeometry(section []byte, window *WindowContent) {
	gen, _, err := generated.DecodeGuiWindowContentGeometry(section, 0, len(section))
	if err != nil {
		return
	}
	window.Geometry = PaneGeometry{
		WindowID:        gen.WindowID,
		TotalRect:       gen.TotalRect,
		ContentRect:     gen.ContentRect,
		TextRect:        gen.TextRect,
		GutterRect:      gen.GutterRect,
		ClipRect:        gen.ClipRect,
		ViewportTop:     gen.ViewportTop,
		ViewportLeft:    gen.ViewportLeft,
		ViewportRows:    gen.ViewportRows,
		ViewportCols:    gen.ViewportCols,
		TotalLines:      gen.ViewportTotalLines,
		VisualRowOffset: gen.ViewportVisualRowOffset,
		TotalVisualRows: gen.ViewportTotalVisualRows,
		LineNumberWidth: gen.LineNumberWidth,
		SignColWidth:    gen.SignColWidth,
		HitRegions:      gen.HitRegions,
	}
	window.GeometrySet = true
}
