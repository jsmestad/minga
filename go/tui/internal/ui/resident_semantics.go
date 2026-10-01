package ui

import (
	"fmt"
	"sort"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const maxResidentSemanticRows = 65_536

type residentSemanticStore struct {
	contentEpoch   uint32
	revision       uint32
	rowRevision    uint32
	rowCount       uint32
	firstRowID     uint64
	lastRowID      uint64
	cursor         protocol.ResidentCursor
	cursorline     protocol.ResidentCursorline
	selection      protocol.ResidentSelection
	tabWidth       byte
	activeGuideCol uint16
	guideCols      []uint16
	guides         *residentGuideNode
	diagnostics    *residentDiagnosticNode
	annotations    *residentAnnotationNode
}

type residentGuideNode struct {
	start    uint32
	end      uint32
	level    uint16
	priority uint64
	left     *residentGuideNode
	right    *residentGuideNode
	lazy     int64
	covered  uint64
	first    uint32
	last     uint32
}

type residentAnnotationNode struct {
	row      uint32
	values   []protocol.ResidentAnnotation
	priority uint64
	left     *residentAnnotationNode
	right    *residentAnnotationNode
	lazy     int64
}

type residentDiagnosticNode struct {
	start    uint32
	values   []protocol.ResidentDiagnostic
	priority uint64
	left     *residentDiagnosticNode
	right    *residentDiagnosticNode
	lazy     int64
	maxEnd   uint32
}

func applyResidentSemantics(base *residentSemanticStore, wire protocol.ResidentSemantics, window protocol.WindowContent, rows residentRows) (*residentSemanticStore, error) {
	if wire.Version != 1 || (wire.Mode != 0 && wire.Mode != 1) {
		return nil, fmt.Errorf("unsupported resident semantics version or mode")
	}
	if !rows.sequential {
		return nil, fmt.Errorf("resident semantics require sequential rows")
	}
	if wire.RowCount > maxResidentSemanticRows || int(wire.RowCount) != rows.count() {
		return nil, fmt.Errorf("resident semantic row count mismatch")
	}
	if window.ContentEpoch != wire.ContentEpoch {
		return nil, fmt.Errorf("resident semantic epoch mismatch")
	}
	if err := validateResidentBoundaryIDs(wire, rows); err != nil {
		return nil, err
	}
	if wire.Revision == 0 {
		return nil, fmt.Errorf("zero resident semantic revision")
	}
	var next residentSemanticStore
	if wire.Mode == 0 {
		if wire.BaseRevision != 0 || wire.TargetRowRevision == 0 || len(wire.RowSplices) != 0 {
			return nil, fmt.Errorf("invalid resident semantic keyframe")
		}
		next = residentSemanticStore{contentEpoch: wire.ContentEpoch, rowCount: wire.RowCount}
	} else {
		if base == nil || base.contentEpoch != wire.ContentEpoch || base.revision != wire.BaseRevision || wire.Revision <= wire.BaseRevision {
			return nil, fmt.Errorf("resident semantic base mismatch")
		}
		expectedRowRevision := base.rowRevision
		if len(wire.RowSplices) > 0 {
			if expectedRowRevision == ^uint32(0) {
				return nil, fmt.Errorf("resident row revision overflow")
			}
			expectedRowRevision++
		}
		if wire.TargetRowRevision != expectedRowRevision {
			return nil, fmt.Errorf("resident semantic row revision mismatch")
		}
		next = *base
	}
	if err := validateResidentSemanticScalars(wire); err != nil {
		return nil, err
	}
	guides := next.guides
	diagnostics := next.diagnostics
	annotations := next.annotations
	var err error
	if guides, diagnostics, annotations, err = applyResidentRankSplices(guides, diagnostics, annotations, next.rowCount, wire.RowSplices, wire.RowCount); err != nil {
		return nil, err
	}
	if guides, err = applyGuideReplacements(guides, wire.GuideReplacements, wire.RowCount, wire.Mode == 0); err != nil {
		return nil, err
	}
	if wire.Mode == 0 && wire.DiagnosticMode != 1 {
		return nil, fmt.Errorf("resident keyframe must replace diagnostics")
	}
	if wire.Mode == 0 && wire.AnnotationMode != 1 {
		return nil, fmt.Errorf("resident keyframe must replace annotations")
	}
	switch wire.DiagnosticMode {
	case 0:
	case 1:
		if err = validateDiagnostics(wire.Diagnostics, wire.RowCount); err != nil {
			return nil, err
		}
		diagnostics = buildDiagnosticTree(wire.Diagnostics)
	case 2:
		if diagnostics, err = applyDiagnosticReplacements(diagnostics, wire.DiagnosticRanges, wire.RowCount); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("invalid resident diagnostic mode")
	}
	switch wire.AnnotationMode {
	case 0:
	case 1:
		if err = validateAnnotations(wire.Annotations, 0, wire.RowCount); err != nil {
			return nil, err
		}
		annotations = buildAnnotationTree(wire.Annotations)
	case 2:
		if annotations, err = applyAnnotationReplacements(annotations, wire.AnnotationRanges, wire.RowCount); err != nil {
			return nil, err
		}
	default:
		return nil, fmt.Errorf("invalid resident annotation mode")
	}
	cols := append([]uint16(nil), wire.GuideCols...)
	next.contentEpoch = wire.ContentEpoch
	next.revision = wire.Revision
	next.rowRevision = wire.TargetRowRevision
	next.rowCount = wire.RowCount
	next.firstRowID = wire.FirstRowID
	next.lastRowID = wire.LastRowID
	next.cursor = wire.Cursor
	next.cursorline = wire.Cursorline
	next.selection = wire.Selection
	next.tabWidth = wire.TabWidth
	next.activeGuideCol = wire.ActiveGuideCol
	next.guideCols = cols
	next.guides = guides
	next.diagnostics = diagnostics
	next.annotations = annotations
	return &next, nil
}

func validateResidentBoundaryIDs(wire protocol.ResidentSemantics, rows residentRows) error {
	if wire.RowCount == 0 {
		if wire.FirstRowID != 0 || wire.LastRowID != 0 {
			return fmt.Errorf("nonzero empty resident boundary ids")
		}
		return nil
	}
	first, ok := rows.get(0)
	if !ok || first.ID == 0 || first.ID != wire.FirstRowID {
		return fmt.Errorf("resident first row id mismatch")
	}
	last, ok := rows.get(rows.count() - 1)
	if !ok || last.ID == 0 || last.ID != wire.LastRowID {
		return fmt.Errorf("resident last row id mismatch")
	}
	return nil
}

func validateResidentSemanticScalars(wire protocol.ResidentSemantics) error {
	if wire.TabWidth == 0 {
		return fmt.Errorf("zero resident tab width")
	}
	for i, col := range wire.GuideCols {
		if i > 0 && col <= wire.GuideCols[i-1] {
			return fmt.Errorf("unordered resident guide columns")
		}
	}
	if wire.RowCount == 0 {
		if wire.Cursor.Eligible || wire.Cursorline.Present || wire.Selection.Present {
			return fmt.Errorf("resident sparse rank in empty document")
		}
		return nil
	}
	if wire.Cursor.Row >= wire.RowCount {
		return fmt.Errorf("resident cursor rank out of bounds")
	}
	if wire.Cursorline.Present && wire.Cursorline.Row >= wire.RowCount {
		return fmt.Errorf("resident cursorline rank out of bounds")
	}
	if wire.Selection.Present {
		if wire.Selection.Type != 1 && wire.Selection.Type != 2 {
			return fmt.Errorf("invalid resident selection type")
		}
		if wire.Selection.StartRow >= wire.RowCount || wire.Selection.EndRow >= wire.RowCount || wire.Selection.StartRow > wire.Selection.EndRow {
			return fmt.Errorf("resident selection out of bounds")
		}
	}
	return nil
}

func applyResidentRankSplices(guides *residentGuideNode, diagnostics *residentDiagnosticNode, annotations *residentAnnotationNode, baseCount uint32, splices []protocol.ResidentRowSplice, resultCount uint32) (*residentGuideNode, *residentDiagnosticNode, *residentAnnotationNode, error) {
	count := uint64(baseCount)
	var previousStart uint32
	var previousEnd uint64
	hasPrevious := false
	offset := int64(0)
	for _, s := range splices {
		end := uint64(s.Start) + uint64(s.DeleteCount)
		if end > uint64(baseCount) || uint64(s.Start) < previousEnd || (hasPrevious && s.Start <= previousStart) || (s.DeleteCount == 0 && s.InsertCount == 0) {
			return nil, nil, nil, fmt.Errorf("invalid resident row splice")
		}
		previousStart = s.Start
		previousEnd = end
		hasPrevious = true
		count = count - uint64(s.DeleteCount) + uint64(s.InsertCount)
		if count > maxResidentSemanticRows {
			return nil, nil, nil, fmt.Errorf("resident row count overflow")
		}
		actual64 := int64(s.Start) + offset
		if actual64 < 0 || actual64 > int64(^uint32(0)) {
			return nil, nil, nil, fmt.Errorf("resident splice coordinate overflow")
		}
		actual := uint32(actual64)
		removeEnd64 := uint64(actual) + uint64(s.DeleteCount)
		if removeEnd64 > uint64(^uint32(0)) {
			return nil, nil, nil, fmt.Errorf("resident splice coordinate overflow")
		}
		guides = guideDeleteAndShift(guides, actual, uint32(removeEnd64), int64(s.InsertCount)-int64(s.DeleteCount))
		diagnostics = diagnosticSplice(diagnostics, actual, s.DeleteCount, s.InsertCount)
		annotations = annotationDeleteAndShift(annotations, actual, uint32(removeEnd64), int64(s.InsertCount)-int64(s.DeleteCount))
		offset += int64(s.InsertCount) - int64(s.DeleteCount)
	}
	if count != uint64(resultCount) {
		return nil, nil, nil, fmt.Errorf("resident splice result count mismatch")
	}
	return guides, diagnostics, annotations, nil
}

func applyGuideReplacements(root *residentGuideNode, replacements []protocol.ResidentGuideReplacement, rowCount uint32, keyframe bool) (*residentGuideNode, error) {
	if keyframe && (len(replacements) != 1 || replacements[0].Start != 0 || replacements[0].End != rowCount) {
		return nil, fmt.Errorf("incomplete resident keyframe guide coverage")
	}
	var previousEnd uint32
	for i, replacement := range replacements {
		if replacement.Start > replacement.End || replacement.End > rowCount || (i > 0 && replacement.Start < previousEnd) {
			return nil, fmt.Errorf("invalid resident guide replacement")
		}
		previousEnd = replacement.End
		cursor := replacement.Start
		for _, run := range replacement.Runs {
			if run.Start != cursor || run.End <= run.Start || run.End > replacement.End {
				return nil, fmt.Errorf("incomplete resident guide run coverage")
			}
			cursor = run.End
		}
		if cursor != replacement.End {
			return nil, fmt.Errorf("incomplete resident guide run coverage")
		}
		left, tail := guideSplit(root, replacement.Start)
		_, right := guideSplit(tail, replacement.End)
		middle := buildGuideTree(replacement.Runs)
		root = guideMerge(guideMerge(left, middle), right)
	}
	if rowCount == 0 {
		if root != nil {
			return nil, fmt.Errorf("resident guide coverage on empty document")
		}
		return root, nil
	}
	if root == nil || root.first != 0 || root.last != rowCount || root.covered != uint64(rowCount) {
		return nil, fmt.Errorf("resident guide coverage mismatch")
	}
	return root, nil
}

func validateDiagnostics(values []protocol.ResidentDiagnostic, rowCount uint32) error {
	for _, d := range values {
		if d.Severity > 3 || d.StartRow >= rowCount || d.EndRow >= rowCount || d.StartRow > d.EndRow || (d.StartRow == d.EndRow && d.StartCol > d.EndCol) {
			return fmt.Errorf("resident diagnostic out of bounds")
		}
	}
	return nil
}
func applyDiagnosticReplacements(root *residentDiagnosticNode, replacements []protocol.ResidentDiagnosticReplacement, rowCount uint32) (*residentDiagnosticNode, error) {
	var previousEnd uint32
	for i, replacement := range replacements {
		if replacement.Start > replacement.End || replacement.End > rowCount || (i > 0 && replacement.Start < previousEnd) {
			return nil, fmt.Errorf("invalid resident diagnostic replacement")
		}
		if err := validateDiagnostics(replacement.Diagnostics, rowCount); err != nil {
			return nil, err
		}
		for _, diagnostic := range replacement.Diagnostics {
			if diagnostic.StartRow < replacement.Start || diagnostic.StartRow >= replacement.End {
				return nil, fmt.Errorf("resident diagnostic start outside replacement")
			}
		}
		previousEnd = replacement.End
		left, tail := diagnosticSplit(root, replacement.Start)
		_, right := diagnosticSplit(tail, replacement.End)
		root = diagnosticMerge(diagnosticMerge(left, buildDiagnosticTree(replacement.Diagnostics)), right)
	}
	return root, nil
}
func validateAnnotations(values []protocol.ResidentAnnotation, start, end uint32) error {
	for _, a := range values {
		if a.Row < start || a.Row >= end || a.Kind > 2 {
			return fmt.Errorf("resident annotation out of bounds")
		}
	}
	return nil
}
func applyAnnotationReplacements(root *residentAnnotationNode, replacements []protocol.ResidentAnnotationReplacement, rowCount uint32) (*residentAnnotationNode, error) {
	var previousEnd uint32
	for i, r := range replacements {
		if r.Start > r.End || r.End > rowCount || (i > 0 && r.Start < previousEnd) {
			return nil, fmt.Errorf("invalid resident annotation replacement")
		}
		if err := validateAnnotations(r.Annotations, r.Start, r.End); err != nil {
			return nil, err
		}
		previousEnd = r.End
		left, tail := annotationSplit(root, r.Start)
		_, right := annotationSplit(tail, r.End)
		root = annotationMerge(annotationMerge(left, buildAnnotationTree(r.Annotations)), right)
	}
	return root, nil
}

func residentPriority(value uint64) uint64 {
	value += 0x9e3779b97f4a7c15
	value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9
	value = (value ^ (value >> 27)) * 0x94d049bb133111eb
	return value ^ (value >> 31)
}
func makeGuideNode(run protocol.ResidentGuideRun, left, right *residentGuideNode) *residentGuideNode {
	return makeGuideNodeWithPriority(run, left, right, residentPriority(uint64(run.Start)<<16|uint64(run.Level)))
}
func makeGuideNodeWithPriority(run protocol.ResidentGuideRun, left, right *residentGuideNode, priority uint64) *residentGuideNode {
	n := &residentGuideNode{start: run.Start, end: run.End, level: run.Level, priority: priority, left: left, right: right}
	n.covered = uint64(run.End - run.Start)
	n.first = run.Start
	n.last = run.End
	if left != nil {
		n.covered += left.covered
		n.first = left.first
	}
	if right != nil {
		n.covered += right.covered
		n.last = right.last
	}
	return n
}
func guideShift(n *residentGuideNode, delta int64) *residentGuideNode {
	if n == nil || delta == 0 {
		return n
	}
	start := int64(n.start) + delta
	end := int64(n.end) + delta
	if start < 0 || end < 0 || start > int64(^uint32(0)) || end > int64(^uint32(0)) {
		return nil
	}
	c := *n
	c.start = uint32(start)
	c.end = uint32(end)
	c.first = uint32(int64(n.first) + delta)
	c.last = uint32(int64(n.last) + delta)
	c.lazy += delta
	return &c
}
func guidePush(n *residentGuideNode) *residentGuideNode {
	if n == nil || n.lazy == 0 {
		return n
	}
	c := *n
	c.left = guideShift(n.left, n.lazy)
	c.right = guideShift(n.right, n.lazy)
	c.lazy = 0
	return &c
}
func guideMerge(a, b *residentGuideNode) *residentGuideNode {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	a = guidePush(a)
	b = guidePush(b)
	if a.priority >= b.priority {
		return makeGuideNodeWithPriority(protocol.ResidentGuideRun{Start: a.start, End: a.end, Level: a.level}, a.left, guideMerge(a.right, b), a.priority)
	}
	return makeGuideNodeWithPriority(protocol.ResidentGuideRun{Start: b.start, End: b.end, Level: b.level}, guideMerge(a, b.left), b.right, b.priority)
}
func guideSplit(n *residentGuideNode, pos uint32) (*residentGuideNode, *residentGuideNode) {
	if n == nil {
		return nil, nil
	}
	n = guidePush(n)
	if pos <= n.start {
		l, r := guideSplit(n.left, pos)
		return l, makeGuideNodeWithPriority(protocol.ResidentGuideRun{Start: n.start, End: n.end, Level: n.level}, r, n.right, n.priority)
	}
	if pos >= n.end {
		l, r := guideSplit(n.right, pos)
		return makeGuideNodeWithPriority(protocol.ResidentGuideRun{Start: n.start, End: n.end, Level: n.level}, n.left, l, n.priority), r
	}
	left := guideMerge(n.left, makeGuideNode(protocol.ResidentGuideRun{Start: n.start, End: pos, Level: n.level}, nil, nil))
	right := guideMerge(makeGuideNode(protocol.ResidentGuideRun{Start: pos, End: n.end, Level: n.level}, nil, nil), n.right)
	return left, right
}
func guideDeleteAndShift(root *residentGuideNode, start, end uint32, delta int64) *residentGuideNode {
	left, tail := guideSplit(root, start)
	_, right := guideSplit(tail, end)
	return guideMerge(left, guideShift(right, delta))
}
func buildGuideTree(runs []protocol.ResidentGuideRun) *residentGuideNode {
	var root *residentGuideNode
	for _, run := range runs {
		root = guideMerge(root, makeGuideNode(run, nil, nil))
	}
	return root
}
func guideLevelAt(n *residentGuideNode, row uint32, ancestorShift int64) (uint16, bool) {
	for n != nil {
		start := uint32(int64(n.start) + ancestorShift)
		end := uint32(int64(n.end) + ancestorShift)
		if row < start {
			ancestorShift += n.lazy
			n = n.left
		} else if row >= end {
			ancestorShift += n.lazy
			n = n.right
		} else {
			return n.level, true
		}
	}
	return 0, false
}

func makeAnnotationNode(row uint32, values []protocol.ResidentAnnotation, left, right *residentAnnotationNode) *residentAnnotationNode {
	return makeAnnotationNodeWithPriority(row, values, left, right, residentPriority(uint64(row)))
}
func makeAnnotationNodeWithPriority(row uint32, values []protocol.ResidentAnnotation, left, right *residentAnnotationNode, priority uint64) *residentAnnotationNode {
	return &residentAnnotationNode{row: row, values: append([]protocol.ResidentAnnotation(nil), values...), priority: priority, left: left, right: right}
}
func annotationShift(n *residentAnnotationNode, delta int64) *residentAnnotationNode {
	if n == nil || delta == 0 {
		return n
	}
	row := int64(n.row) + delta
	if row < 0 || row > int64(^uint32(0)) {
		return nil
	}
	c := *n
	c.row = uint32(row)
	c.lazy += delta
	return &c
}
func annotationPush(n *residentAnnotationNode) *residentAnnotationNode {
	if n == nil || n.lazy == 0 {
		return n
	}
	c := *n
	c.left = annotationShift(n.left, n.lazy)
	c.right = annotationShift(n.right, n.lazy)
	c.lazy = 0
	return &c
}
func annotationMerge(a, b *residentAnnotationNode) *residentAnnotationNode {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	a = annotationPush(a)
	b = annotationPush(b)
	if a.priority >= b.priority {
		return makeAnnotationNodeWithPriority(a.row, a.values, a.left, annotationMerge(a.right, b), a.priority)
	}
	return makeAnnotationNodeWithPriority(b.row, b.values, annotationMerge(a, b.left), b.right, b.priority)
}
func annotationSplit(n *residentAnnotationNode, row uint32) (*residentAnnotationNode, *residentAnnotationNode) {
	if n == nil {
		return nil, nil
	}
	n = annotationPush(n)
	if row <= n.row {
		l, r := annotationSplit(n.left, row)
		return l, makeAnnotationNodeWithPriority(n.row, n.values, r, n.right, n.priority)
	}
	l, r := annotationSplit(n.right, row)
	return makeAnnotationNodeWithPriority(n.row, n.values, n.left, l, n.priority), r
}
func annotationDeleteAndShift(root *residentAnnotationNode, start, end uint32, delta int64) *residentAnnotationNode {
	left, tail := annotationSplit(root, start)
	_, right := annotationSplit(tail, end)
	return annotationMerge(left, annotationShift(right, delta))
}
func buildAnnotationTree(values []protocol.ResidentAnnotation) *residentAnnotationNode {
	grouped := map[uint32][]protocol.ResidentAnnotation{}
	keys := make([]uint32, 0)
	for _, a := range values {
		if _, ok := grouped[a.Row]; !ok {
			keys = append(keys, a.Row)
		}
		grouped[a.Row] = append(grouped[a.Row], a)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	var root *residentAnnotationNode
	for _, row := range keys {
		root = annotationMerge(root, makeAnnotationNode(row, grouped[row], nil, nil))
	}
	return root
}
func annotationsAt(n *residentAnnotationNode, row uint32, ancestorShift int64) []protocol.ResidentAnnotation {
	for n != nil {
		effective := uint32(int64(n.row) + ancestorShift)
		if row < effective {
			ancestorShift += n.lazy
			n = n.left
		} else if row > effective {
			ancestorShift += n.lazy
			n = n.right
		} else {
			out := append([]protocol.ResidentAnnotation(nil), n.values...)
			for i := range out {
				out[i].Row = row
			}
			return out
		}
	}
	return nil
}

func makeDiagnosticNode(start uint32, values []protocol.ResidentDiagnostic, left, right *residentDiagnosticNode) *residentDiagnosticNode {
	return makeDiagnosticNodeWithPriority(start, values, left, right, residentPriority(uint64(start)))
}
func makeDiagnosticNodeWithPriority(start uint32, values []protocol.ResidentDiagnostic, left, right *residentDiagnosticNode, priority uint64) *residentDiagnosticNode {
	maxEnd := start
	for _, diagnostic := range values {
		if diagnostic.EndRow > maxEnd {
			maxEnd = diagnostic.EndRow
		}
	}
	if left != nil && left.maxEnd > maxEnd {
		maxEnd = left.maxEnd
	}
	if right != nil && right.maxEnd > maxEnd {
		maxEnd = right.maxEnd
	}
	return &residentDiagnosticNode{start: start, values: append([]protocol.ResidentDiagnostic(nil), values...), priority: priority, left: left, right: right, maxEnd: maxEnd}
}
func diagnosticShift(n *residentDiagnosticNode, delta int64) *residentDiagnosticNode {
	if n == nil || delta == 0 {
		return n
	}
	start, maxEnd := int64(n.start)+delta, int64(n.maxEnd)+delta
	if start < 0 || maxEnd < 0 || start > int64(^uint32(0)) || maxEnd > int64(^uint32(0)) {
		return nil
	}
	c := *n
	c.start, c.maxEnd, c.lazy = uint32(start), uint32(maxEnd), n.lazy+delta
	shifted := append([]protocol.ResidentDiagnostic(nil), n.values...)
	for i := range shifted {
		shifted[i].StartRow = uint32(int64(shifted[i].StartRow) + delta)
		shifted[i].EndRow = uint32(int64(shifted[i].EndRow) + delta)
	}
	c.values = shifted
	return &c
}
func diagnosticPush(n *residentDiagnosticNode) *residentDiagnosticNode {
	if n == nil || n.lazy == 0 {
		return n
	}
	c := *n
	c.left = diagnosticShift(n.left, n.lazy)
	c.right = diagnosticShift(n.right, n.lazy)
	c.lazy = 0
	return &c
}
func diagnosticMerge(a, b *residentDiagnosticNode) *residentDiagnosticNode {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	a, b = diagnosticPush(a), diagnosticPush(b)
	if a.priority >= b.priority {
		return makeDiagnosticNodeWithPriority(a.start, a.values, a.left, diagnosticMerge(a.right, b), a.priority)
	}
	return makeDiagnosticNodeWithPriority(b.start, b.values, diagnosticMerge(a, b.left), b.right, b.priority)
}
func diagnosticSplit(n *residentDiagnosticNode, row uint32) (*residentDiagnosticNode, *residentDiagnosticNode) {
	if n == nil {
		return nil, nil
	}
	n = diagnosticPush(n)
	if row <= n.start {
		left, remainder := diagnosticSplit(n.left, row)
		return left, makeDiagnosticNodeWithPriority(n.start, n.values, remainder, n.right, n.priority)
	}
	prefix, right := diagnosticSplit(n.right, row)
	return makeDiagnosticNodeWithPriority(n.start, n.values, n.left, prefix, n.priority), right
}
func diagnosticValuesAtStart(n *residentDiagnosticNode, row uint32) []protocol.ResidentDiagnostic {
	for n != nil {
		n = diagnosticPush(n)
		if row < n.start {
			n = n.left
		} else if row > n.start {
			n = n.right
		} else {
			return n.values
		}
	}
	return nil
}
func diagnosticSetStart(root *residentDiagnosticNode, row uint32, values []protocol.ResidentDiagnostic) *residentDiagnosticNode {
	left, tail := diagnosticSplit(root, row)
	var right *residentDiagnosticNode
	if row == ^uint32(0) {
		right = nil
	} else {
		_, right = diagnosticSplit(tail, row+1)
	}
	var middle *residentDiagnosticNode
	if len(values) > 0 {
		middle = makeDiagnosticNode(row, values, nil, nil)
	}
	return diagnosticMerge(diagnosticMerge(left, middle), right)
}
func diagnosticCrossingStarts(n *residentDiagnosticNode, spliceStart uint32, starts *[]uint32) {
	if n == nil || n.maxEnd < spliceStart {
		return
	}
	n = diagnosticPush(n)
	diagnosticCrossingStarts(n.left, spliceStart, starts)
	if n.start < spliceStart {
		for _, diagnostic := range n.values {
			if diagnostic.EndRow >= spliceStart {
				*starts = append(*starts, n.start)
				break
			}
		}
		diagnosticCrossingStarts(n.right, spliceStart, starts)
	}
}
func diagnosticSplice(root *residentDiagnosticNode, start, deleteCount, insertCount uint32) *residentDiagnosticNode {
	deleteEnd := start + deleteCount
	delta := int64(insertCount) - int64(deleteCount)
	var crossing []uint32
	diagnosticCrossingStarts(root, start, &crossing)
	for _, diagnosticStart := range crossing {
		values := append([]protocol.ResidentDiagnostic(nil), diagnosticValuesAtStart(root, diagnosticStart)...)
		kept := values[:0]
		for _, diagnostic := range values {
			if diagnostic.EndRow < start {
				kept = append(kept, diagnostic)
				continue
			}
			if deleteCount == 0 || diagnostic.EndRow >= deleteEnd {
				diagnostic.EndRow = uint32(int64(diagnostic.EndRow) + delta)
			} else if insertCount > 0 {
				diagnostic.EndRow = start + insertCount - 1
			} else {
				diagnostic.EndRow = start - 1
			}
			kept = append(kept, diagnostic)
		}
		root = diagnosticSetStart(root, diagnosticStart, kept)
	}
	left, tail := diagnosticSplit(root, start)
	_, right := diagnosticSplit(tail, deleteEnd)
	return diagnosticMerge(left, diagnosticShift(right, delta))
}
func buildDiagnosticTree(values []protocol.ResidentDiagnostic) *residentDiagnosticNode {
	grouped := map[uint32][]protocol.ResidentDiagnostic{}
	keys := make([]uint32, 0)
	for _, diagnostic := range values {
		if _, ok := grouped[diagnostic.StartRow]; !ok {
			keys = append(keys, diagnostic.StartRow)
		}
		grouped[diagnostic.StartRow] = append(grouped[diagnostic.StartRow], diagnostic)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	var root *residentDiagnosticNode
	for _, start := range keys {
		root = diagnosticMerge(root, makeDiagnosticNode(start, grouped[start], nil, nil))
	}
	return root
}
func diagnosticsAt(n *residentDiagnosticNode, row uint32, out *[]protocol.ResidentDiagnostic) {
	if n == nil || n.maxEnd < row {
		return
	}
	n = diagnosticPush(n)
	if n.left != nil && n.left.maxEnd >= row {
		diagnosticsAt(n.left, row, out)
	}
	if n.start <= row {
		for _, diagnostic := range n.values {
			if diagnostic.EndRow >= row {
				*out = append(*out, diagnostic)
			}
		}
		diagnosticsAt(n.right, row, out)
	}
}

func (s *residentSemanticStore) guideLevel(row uint32) (uint16, bool) {
	if s == nil {
		return 0, false
	}
	return guideLevelAt(s.guides, row, 0)
}
func (s *residentSemanticStore) rowAnnotations(row uint32) []protocol.ResidentAnnotation {
	if s == nil {
		return nil
	}
	return annotationsAt(s.annotations, row, 0)
}
func (s *residentSemanticStore) rowDiagnostics(row uint32) []protocol.ResidentDiagnostic {
	if s == nil {
		return nil
	}
	var out []protocol.ResidentDiagnostic
	diagnosticsAt(s.diagnostics, row, &out)
	return out
}
