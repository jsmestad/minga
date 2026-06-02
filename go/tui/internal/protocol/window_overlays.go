package protocol

import "unicode/utf8"

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

type Rect struct {
	Row    uint16
	Col    uint16
	Width  uint16
	Height uint16
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

type HitRegion struct {
	Kind     byte
	Rect     Rect
	WindowID uint16
}

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
	if len(section) < 2 {
		window.SearchMatches = nil
		return
	}
	count := int(u16(section, 0))
	offset := 2
	matches := make([]SearchMatch, 0, count)
	for i := 0; i < count && len(section) >= offset+7; i++ {
		matches = append(matches, SearchMatch{Row: u16(section, offset), StartCol: u16(section, offset+2), EndCol: u16(section, offset+4), Current: section[offset+6] != 0})
		offset += 7
	}
	window.SearchMatches = matches
}

func decodeDiagnosticRanges(section []byte, window *WindowContent) {
	window.DiagnosticsSet = true
	if len(section) < 2 {
		window.Diagnostics = nil
		return
	}
	count := int(u16(section, 0))
	offset := 2
	ranges := make([]DiagnosticRange, 0, count)
	for i := 0; i < count && len(section) >= offset+9; i++ {
		ranges = append(ranges, DiagnosticRange{StartRow: u16(section, offset), StartCol: u16(section, offset+2), EndRow: u16(section, offset+4), EndCol: u16(section, offset+6), Severity: section[offset+8]})
		offset += 9
	}
	window.Diagnostics = ranges
}

func decodeDocumentHighlights(section []byte, window *WindowContent) {
	window.HighlightsSet = true
	if len(section) < 2 {
		window.Highlights = nil
		return
	}
	count := int(u16(section, 0))
	offset := 2
	highlights := make([]DocumentHighlight, 0, count)
	for i := 0; i < count && len(section) >= offset+9; i++ {
		highlights = append(highlights, DocumentHighlight{StartRow: u16(section, offset), StartCol: u16(section, offset+2), EndRow: u16(section, offset+4), EndCol: u16(section, offset+6), Kind: section[offset+8]})
		offset += 9
	}
	window.Highlights = highlights
}

func decodeLineAnnotations(section []byte, window *WindowContent) {
	window.AnnotationsSet = true
	if len(section) < 2 {
		window.Annotations = nil
		return
	}
	count := int(u16(section, 0))
	offset := 2
	annotations := make([]LineAnnotation, 0, count)
	for i := 0; i < count && len(section) >= offset+11; i++ {
		annotation := LineAnnotation{Row: u16(section, offset), Kind: section[offset+2], FG: u24(section, offset+3), BG: u24(section, offset+6)}
		textLen := int(u16(section, offset+9))
		offset += 11
		if len(section) < offset+textLen || !utf8.Valid(section[offset:offset+textLen]) {
			break
		}
		annotation.Text = string(section[offset : offset+textLen])
		offset += textLen
		annotations = append(annotations, annotation)
	}
	window.Annotations = annotations
}

func decodePaneGeometry(section []byte, window *WindowContent) {
	window.GeometrySet = true
	const fixed = 67
	if len(section) < fixed {
		return
	}
	offset := 0
	geometry := PaneGeometry{WindowID: u16(section, offset)}
	offset += 2
	geometry.TotalRect = decodeRect(section, offset)
	offset += 8
	geometry.ContentRect = decodeRect(section, offset)
	offset += 8
	geometry.TextRect = decodeRect(section, offset)
	offset += 8
	geometry.GutterRect = decodeRect(section, offset)
	offset += 8
	geometry.ClipRect = decodeRect(section, offset)
	offset += 8
	geometry.ViewportTop = u32(section, offset)
	offset += 4
	geometry.ViewportLeft = u16(section, offset)
	offset += 2
	geometry.ViewportRows = u16(section, offset)
	offset += 2
	geometry.ViewportCols = u16(section, offset)
	offset += 2
	geometry.TotalLines = u32(section, offset)
	offset += 4
	geometry.VisualRowOffset = u16(section, offset)
	offset += 2
	geometry.TotalVisualRows = u32(section, offset)
	offset += 4
	geometry.LineNumberWidth = u16(section, offset)
	offset += 2
	geometry.SignColWidth = u16(section, offset)
	offset += 2
	count := int(section[offset])
	offset++
	regions := make([]HitRegion, 0, count)
	for i := 0; i < count && len(section) >= offset+11; i++ {
		regions = append(regions, HitRegion{Kind: section[offset], Rect: decodeRect(section, offset+1), WindowID: u16(section, offset+9)})
		offset += 11
	}
	geometry.HitRegions = regions
	window.Geometry = geometry
}

func decodeRect(section []byte, offset int) Rect {
	return Rect{Row: u16(section, offset), Col: u16(section, offset+2), Width: u16(section, offset+4), Height: u16(section, offset+6)}
}
