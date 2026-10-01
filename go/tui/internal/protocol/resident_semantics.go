package protocol

import (
	"encoding/binary"
	"fmt"
	"unicode/utf8"
)

type ResidentCursor struct {
	Eligible bool
	Row      uint32
	Col      uint16
}
type ResidentCursorline struct {
	Present bool
	Row     uint32
	BG      uint32
}
type ResidentSelection struct {
	Present  bool
	Type     byte
	StartRow uint32
	StartCol uint16
	EndRow   uint32
	EndCol   uint16
}
type ResidentRowSplice struct {
	Start       uint32
	DeleteCount uint32
	InsertCount uint32
}
type ResidentGuideRun struct {
	Start uint32
	End   uint32
	Level uint16
}
type ResidentGuideReplacement struct {
	Start uint32
	End   uint32
	Runs  []ResidentGuideRun
}
type ResidentDiagnostic struct {
	StartRow uint32
	StartCol uint16
	EndRow   uint32
	EndCol   uint16
	Severity byte
}
type ResidentDiagnosticReplacement struct {
	Start       uint32
	End         uint32
	Diagnostics []ResidentDiagnostic
}
type ResidentAnnotation struct {
	Row  uint32
	Kind byte
	FG   uint32
	BG   uint32
	Text string
}
type ResidentAnnotationReplacement struct {
	Start       uint32
	End         uint32
	Annotations []ResidentAnnotation
}

type ResidentSemanticsHeader struct {
	Version           byte
	Mode              byte
	WindowID          uint16
	ContentEpoch      uint32
	BaseRevision      uint32
	Revision          uint32
	TargetRowRevision uint32
	RowCount          uint32
	FirstRowID        uint64
	LastRowID         uint64
}

type ResidentGuideUpdate struct {
	TabWidth          byte
	ActiveGuideCol    uint16
	GuideCols         []uint16
	RowSplices        []ResidentRowSplice
	GuideReplacements []ResidentGuideReplacement
}

type ResidentDiagnosticUpdate struct {
	Diagnostics      []ResidentDiagnostic
	DiagnosticRanges []ResidentDiagnosticReplacement
	DiagnosticMode   byte
}

type ResidentAnnotationUpdate struct {
	Annotations      []ResidentAnnotation
	AnnotationRanges []ResidentAnnotationReplacement
	AnnotationMode   byte
}

type ResidentSemantics struct {
	ResidentSemanticsHeader
	Flags      byte
	Cursor     ResidentCursor
	Cursorline ResidentCursorline
	Selection  ResidentSelection
	ResidentGuideUpdate
	ResidentDiagnosticUpdate
	ResidentAnnotationUpdate
}

type residentSemanticCursor struct {
	data []byte
	pos  int
}

func (c *residentSemanticCursor) remaining() int { return len(c.data) - c.pos }
func (c *residentSemanticCursor) u8() (byte, error) {
	if c.remaining() < 1 {
		return 0, fmt.Errorf("short resident semantics")
	}
	v := c.data[c.pos]
	c.pos++
	return v, nil
}
func (c *residentSemanticCursor) u16() (uint16, error) {
	if c.remaining() < 2 {
		return 0, fmt.Errorf("short resident semantics")
	}
	v := binary.BigEndian.Uint16(c.data[c.pos : c.pos+2])
	c.pos += 2
	return v, nil
}
func (c *residentSemanticCursor) u24() (uint32, error) {
	if c.remaining() < 3 {
		return 0, fmt.Errorf("short resident semantics")
	}
	v := uint32(c.data[c.pos])<<16 | uint32(c.data[c.pos+1])<<8 | uint32(c.data[c.pos+2])
	c.pos += 3
	return v, nil
}
func (c *residentSemanticCursor) u32() (uint32, error) {
	if c.remaining() < 4 {
		return 0, fmt.Errorf("short resident semantics")
	}
	v := binary.BigEndian.Uint32(c.data[c.pos : c.pos+4])
	c.pos += 4
	return v, nil
}
func (c *residentSemanticCursor) u64() (uint64, error) {
	if c.remaining() < 8 {
		return 0, fmt.Errorf("short resident semantics")
	}
	v := binary.BigEndian.Uint64(c.data[c.pos : c.pos+8])
	c.pos += 8
	return v, nil
}
func (c *residentSemanticCursor) string16() (string, error) {
	n, err := c.u16()
	if err != nil || c.remaining() < int(n) {
		return "", fmt.Errorf("short resident annotation text")
	}
	bytes := c.data[c.pos : c.pos+int(n)]
	if !utf8.Valid(bytes) {
		return "", fmt.Errorf("invalid resident annotation text")
	}
	v := string(bytes)
	c.pos += int(n)
	return v, nil
}

func decodeResidentSemantics(payload []byte) (Command, error) {
	if len(payload) < 5 {
		return Command{}, fmt.Errorf("short resident semantics envelope")
	}
	n := uint64(binary.BigEndian.Uint32(payload[1:5]))
	if n > uint64(len(payload)-5) {
		return Command{}, fmt.Errorf("short resident semantics payload")
	}
	end := 5 + int(n)
	c := residentSemanticCursor{data: payload[5:end]}
	var err error
	s := ResidentSemantics{}
	if s.Version, err = c.u8(); err != nil {
		return Command{}, err
	}
	if s.Mode, err = c.u8(); err != nil {
		return Command{}, err
	}
	if s.WindowID, err = c.u16(); err != nil {
		return Command{}, err
	}
	if s.ContentEpoch, err = c.u32(); err != nil {
		return Command{}, err
	}
	if s.BaseRevision, err = c.u32(); err != nil {
		return Command{}, err
	}
	if s.Revision, err = c.u32(); err != nil {
		return Command{}, err
	}
	if s.TargetRowRevision, err = c.u32(); err != nil {
		return Command{}, err
	}
	if s.RowCount, err = c.u32(); err != nil {
		return Command{}, err
	}
	if s.FirstRowID, err = c.u64(); err != nil {
		return Command{}, err
	}
	if s.LastRowID, err = c.u64(); err != nil {
		return Command{}, err
	}
	if s.Flags, err = c.u8(); err != nil {
		return Command{}, err
	}
	if s.Flags&0x80 != 0 || s.Flags&0x48 == 0x48 || s.Flags&0x30 == 0x30 {
		return Command{}, fmt.Errorf("invalid resident semantics flags")
	}
	s.Cursor.Eligible = s.Flags&1 != 0
	if s.Cursor.Row, err = c.u32(); err != nil {
		return Command{}, err
	}
	if s.Cursor.Col, err = c.u16(); err != nil {
		return Command{}, err
	}
	if s.Flags&2 != 0 {
		s.Cursorline.Present = true
		if s.Cursorline.Row, err = c.u32(); err != nil {
			return Command{}, err
		}
		if s.Cursorline.BG, err = c.u24(); err != nil {
			return Command{}, err
		}
	}
	if s.Flags&4 != 0 {
		s.Selection.Present = true
		if s.Selection.Type, err = c.u8(); err != nil {
			return Command{}, err
		}
		if s.Selection.StartRow, err = c.u32(); err != nil {
			return Command{}, err
		}
		if s.Selection.StartCol, err = c.u16(); err != nil {
			return Command{}, err
		}
		if s.Selection.EndRow, err = c.u32(); err != nil {
			return Command{}, err
		}
		if s.Selection.EndCol, err = c.u16(); err != nil {
			return Command{}, err
		}
	}
	if s.TabWidth, err = c.u8(); err != nil {
		return Command{}, err
	}
	if s.ActiveGuideCol, err = c.u16(); err != nil {
		return Command{}, err
	}
	guideCols, err := c.u16()
	if err != nil || int(guideCols) > c.remaining()/2 {
		return Command{}, fmt.Errorf("invalid resident guide columns")
	}
	s.GuideCols = make([]uint16, int(guideCols))
	for i := range s.GuideCols {
		if s.GuideCols[i], err = c.u16(); err != nil {
			return Command{}, err
		}
	}
	spliceCount, err := c.u16()
	if err != nil || int(spliceCount) > c.remaining()/12 {
		return Command{}, fmt.Errorf("invalid resident row splices")
	}
	s.RowSplices = make([]ResidentRowSplice, int(spliceCount))
	for i := range s.RowSplices {
		if s.RowSplices[i].Start, err = c.u32(); err != nil {
			return Command{}, err
		}
		if s.RowSplices[i].DeleteCount, err = c.u32(); err != nil {
			return Command{}, err
		}
		if s.RowSplices[i].InsertCount, err = c.u32(); err != nil {
			return Command{}, err
		}
	}
	guideReplaces, err := c.u16()
	if err != nil {
		return Command{}, err
	}
	s.GuideReplacements = make([]ResidentGuideReplacement, int(guideReplaces))
	for i := range s.GuideReplacements {
		r := &s.GuideReplacements[i]
		if r.Start, err = c.u32(); err != nil {
			return Command{}, err
		}
		if r.End, err = c.u32(); err != nil {
			return Command{}, err
		}
		runCount, e := c.u32()
		if e != nil || uint64(runCount) > uint64(c.remaining()/10) {
			return Command{}, fmt.Errorf("invalid resident guide runs")
		}
		r.Runs = make([]ResidentGuideRun, int(runCount))
		for j := range r.Runs {
			if r.Runs[j].Start, err = c.u32(); err != nil {
				return Command{}, err
			}
			if r.Runs[j].End, err = c.u32(); err != nil {
				return Command{}, err
			}
			if r.Runs[j].Level, err = c.u16(); err != nil {
				return Command{}, err
			}
		}
	}
	if s.Flags&8 != 0 {
		s.DiagnosticMode = 1
		count, e := c.u32()
		if e != nil || uint64(count) > uint64(c.remaining()/13) {
			return Command{}, fmt.Errorf("invalid resident diagnostics")
		}
		if s.Diagnostics, err = decodeResidentDiagnostics(&c, int(count)); err != nil {
			return Command{}, err
		}
	} else if s.Flags&0x40 != 0 {
		s.DiagnosticMode = 2
		count, e := c.u16()
		if e != nil {
			return Command{}, e
		}
		s.DiagnosticRanges = make([]ResidentDiagnosticReplacement, int(count))
		for i := range s.DiagnosticRanges {
			r := &s.DiagnosticRanges[i]
			if r.Start, err = c.u32(); err != nil {
				return Command{}, err
			}
			if r.End, err = c.u32(); err != nil {
				return Command{}, err
			}
			n, e := c.u32()
			if e != nil || uint64(n) > uint64(c.remaining()/13) {
				return Command{}, fmt.Errorf("invalid resident diagnostic range")
			}
			if r.Diagnostics, err = decodeResidentDiagnostics(&c, int(n)); err != nil {
				return Command{}, err
			}
		}
	}
	if s.Flags&0x10 != 0 {
		s.AnnotationMode = 1
		count, e := c.u32()
		if e != nil || uint64(count) > uint64(c.remaining()/15) {
			return Command{}, fmt.Errorf("invalid resident annotations")
		}
		if s.Annotations, err = decodeResidentAnnotations(&c, int(count)); err != nil {
			return Command{}, err
		}
	} else if s.Flags&0x20 != 0 {
		s.AnnotationMode = 2
		count, e := c.u16()
		if e != nil {
			return Command{}, e
		}
		s.AnnotationRanges = make([]ResidentAnnotationReplacement, int(count))
		for i := range s.AnnotationRanges {
			r := &s.AnnotationRanges[i]
			if r.Start, err = c.u32(); err != nil {
				return Command{}, err
			}
			if r.End, err = c.u32(); err != nil {
				return Command{}, err
			}
			n, e := c.u32()
			if e != nil || uint64(n) > uint64(c.remaining()/15) {
				return Command{}, fmt.Errorf("invalid resident annotation range")
			}
			if r.Annotations, err = decodeResidentAnnotations(&c, int(n)); err != nil {
				return Command{}, err
			}
		}
	}
	if c.remaining() != 0 {
		return Command{}, fmt.Errorf("trailing resident semantics bytes")
	}
	return Command{Kind: CommandResidentSemantics, Size: end, ResidentSemantics: s}, nil
}

func decodeResidentDiagnostics(c *residentSemanticCursor, count int) ([]ResidentDiagnostic, error) {
	diagnostics := make([]ResidentDiagnostic, count)
	for i := range diagnostics {
		var err error
		d := &diagnostics[i]
		if d.StartRow, err = c.u32(); err != nil {
			return nil, err
		}
		if d.StartCol, err = c.u16(); err != nil {
			return nil, err
		}
		if d.EndRow, err = c.u32(); err != nil {
			return nil, err
		}
		if d.EndCol, err = c.u16(); err != nil {
			return nil, err
		}
		if d.Severity, err = c.u8(); err != nil {
			return nil, err
		}
	}
	return diagnostics, nil
}

func decodeResidentAnnotations(c *residentSemanticCursor, count int) ([]ResidentAnnotation, error) {
	a := make([]ResidentAnnotation, count)
	for i := range a {
		var err error
		if a[i].Row, err = c.u32(); err != nil {
			return nil, err
		}
		if a[i].Kind, err = c.u8(); err != nil {
			return nil, err
		}
		if a[i].FG, err = c.u24(); err != nil {
			return nil, err
		}
		if a[i].BG, err = c.u24(); err != nil {
			return nil, err
		}
		if a[i].Text, err = c.string16(); err != nil {
			return nil, err
		}
	}
	return a, nil
}
