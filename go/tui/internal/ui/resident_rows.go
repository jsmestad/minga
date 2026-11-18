package ui

import (
	"fmt"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// residentRows is the value-semantic authority for a window's decoded rows.
// Its rope leaves share immutable backing arrays and its radix locator is
// path-copied, so a splice copies metadata proportional to tree depth rather
// than copying or scanning the resident document.
type residentRows struct {
	root    *rowRope
	locator *rowLocator
	mode    rowStoreMode
}

type rowStoreMode byte

const (
	windowedRows rowStoreMode = iota
	sequentialRows
	wrappedRows
)

func (s residentRows) complete() bool { return s.mode != windowedRows }

type rowRope struct {
	left, right *rowRope
	rows        []protocol.WindowRow
	count       int
	starts      int
	height      int
}

const residentLeafRows = 256

func newResidentRows(rows []protocol.WindowRow, mode rowStoreMode) (residentRows, error) {
	if mode == wrappedRows && len(rows) > 0 && rows[0].Kind != protocol.WindowRowNormal {
		return residentRows{}, fmt.Errorf("wrapped rows must begin with a source line start")
	}
	store := residentRows{mode: mode}
	leaves := make([]*rowRope, 0, (len(rows)+residentLeafRows-1)/residentLeafRows)
	var previousBufferLine uint32
	hasPreviousBufferLine := false
	for start := 0; start < len(rows); start += residentLeafRows {
		end := min(start+residentLeafRows, len(rows))
		owned := append([]protocol.WindowRow(nil), rows[start:end]...)
		leaves = append(leaves, ropeLeaf(owned, mode == wrappedRows))
		for _, row := range owned {
			if mode == wrappedRows && !wrappedRowKind(row.Kind) {
				return residentRows{}, fmt.Errorf("invalid wrapped row kind")
			}
			if mode == windowedRows && hasPreviousBufferLine && row.BufferLine < previousBufferLine {
				return residentRows{}, fmt.Errorf("resident rows out of buffer-line order")
			}
			previousBufferLine = row.BufferLine
			hasPreviousBufferLine = true
			// ID zero is the protocol's uncached/synthetic row sentinel. It is
			// resident by index but intentionally absent from the ref locator.
			if row.ID == 0 {
				continue
			}
			if store.locator.get(row.ID) != nil {
				return residentRows{}, fmt.Errorf("duplicate row id")
			}
			store.locator = store.locator.put(row.ID, row)
		}
	}
	store.root = buildRope(leaves)
	return store, nil
}

func wrappedRowKind(kind byte) bool {
	return kind == protocol.WindowRowNormal || kind == protocol.WindowRowWrapContinuation
}

func buildRope(nodes []*rowRope) *rowRope {
	if len(nodes) == 0 {
		return nil
	}
	for len(nodes) > 1 {
		next := make([]*rowRope, 0, (len(nodes)+1)/2)
		for i := 0; i < len(nodes); i += 2 {
			if i+1 == len(nodes) {
				next = append(next, nodes[i])
				continue
			}
			next = append(next, ropeBranch(nodes[i], nodes[i+1]))
		}
		nodes = next
	}
	return nodes[0]
}

func ropeLeaf(rows []protocol.WindowRow, wrapped bool) *rowRope {
	if len(rows) == 0 {
		return nil
	}
	starts := 0
	if wrapped {
		for i := range rows {
			if rows[i].Kind == protocol.WindowRowNormal {
				starts++
			}
		}
	}
	return &rowRope{rows: rows, count: len(rows), starts: starts, height: 1}
}
func ropeCount(n *rowRope) int {
	if n == nil {
		return 0
	}
	return n.count
}
func ropeHeight(n *rowRope) int {
	if n == nil {
		return 0
	}
	return n.height
}
func ropeBranch(left, right *rowRope) *rowRope {
	if left == nil {
		return right
	}
	if right == nil {
		return left
	}
	return &rowRope{left: left, right: right, count: left.count + right.count, starts: left.starts + right.starts, height: max(left.height, right.height) + 1}
}
func ropeBalance(n *rowRope) int {
	if n == nil || n.rows != nil {
		return 0
	}
	return ropeHeight(n.left) - ropeHeight(n.right)
}
func ropeJoin(left, right *rowRope) *rowRope {
	if left == nil {
		return right
	}
	if right == nil {
		return left
	}
	if ropeHeight(left) > ropeHeight(right)+1 {
		return rebalance(ropeBranch(left.left, ropeJoin(left.right, right)))
	}
	if ropeHeight(right) > ropeHeight(left)+1 {
		return rebalance(ropeBranch(ropeJoin(left, right.left), right.right))
	}
	return ropeBranch(left, right)
}
func rebalance(n *rowRope) *rowRope {
	if ropeBalance(n) > 1 {
		if ropeBalance(n.left) < 0 {
			return ropeBranch(ropeBranch(n.left.left, n.left.right.left), ropeBranch(n.left.right.right, n.right))
		}
		return ropeBranch(n.left.left, ropeBranch(n.left.right, n.right))
	}
	if ropeBalance(n) < -1 {
		if ropeBalance(n.right) > 0 {
			return ropeBranch(ropeBranch(n.left, n.right.left.left), ropeBranch(n.right.left.right, n.right.right))
		}
		return ropeBranch(ropeBranch(n.left, n.right.left), n.right.right)
	}
	return n
}
func ropeSplit(n *rowRope, index int, wrapped bool) (*rowRope, *rowRope) {
	if n == nil {
		return nil, nil
	}
	if index <= 0 {
		return nil, n
	}
	if index >= n.count {
		return n, nil
	}
	if n.rows != nil {
		return ropeLeaf(n.rows[:index], wrapped), ropeLeaf(n.rows[index:], wrapped)
	}
	leftCount := ropeCount(n.left)
	if index < leftCount {
		a, b := ropeSplit(n.left, index, wrapped)
		return a, ropeJoin(b, n.right)
	}
	if index == leftCount {
		return n.left, n.right
	}
	a, b := ropeSplit(n.right, index-leftCount, wrapped)
	return ropeJoin(n.left, a), b
}
func ropeGet(n *rowRope, index int) (protocol.WindowRow, bool) {
	if n == nil || index < 0 || index >= n.count {
		return protocol.WindowRow{}, false
	}
	if n.rows != nil {
		return n.rows[index], true
	}
	if index < ropeCount(n.left) {
		return ropeGet(n.left, index)
	}
	return ropeGet(n.right, index-ropeCount(n.left))
}
func ropeRange(n *rowRope, start, end int, out *[]protocol.WindowRow) {
	if n == nil || start >= end || end <= 0 || start >= n.count {
		return
	}
	if n.rows != nil {
		lo, hi := max(start, 0), min(end, len(n.rows))
		*out = append(*out, n.rows[lo:hi]...)
		return
	}
	lc := ropeCount(n.left)
	ropeRange(n.left, start, end, out)
	ropeRange(n.right, start-lc, end-lc, out)
}

func (s residentRows) count() int { return ropeCount(s.root) }

func (s residentRows) lineCount() int {
	if s.mode != wrappedRows {
		return s.count()
	}
	if s.root == nil {
		return 0
	}
	return s.root.starts
}

// wrappedLineStart selects a source start by zero-based logical line. The
// end sentinel also gives the exclusive end of the final line group.
func (s residentRows) wrappedLineStart(line int) int {
	if line >= s.lineCount() {
		return s.count()
	}
	index := 0
	node := s.root
	for node.rows == nil {
		if line < node.left.starts {
			node = node.left
		} else {
			line -= node.left.starts
			index += node.left.count
			node = node.right
		}
	}
	for i := range node.rows {
		if node.rows[i].Kind == protocol.WindowRowNormal {
			if line == 0 {
				return index + i
			}
			line--
		}
	}
	panic("inconsistent wrapped row start count")
}

// wrappedAnchor translates a logical line and its continuation offset to an
// absolute visual rank without borrowing rows from the next line group.
func (s residentRows) wrappedAnchor(scroll protocol.ScrollPresentation) (int, bool) {
	line, offset := int(scroll.AnchorTop), int(scroll.AnchorVisualRowOffset)
	if s.count() == 0 {
		return 0, line == 0 && offset == 0
	}
	if line >= s.lineCount() {
		return 0, false
	}
	start := s.wrappedLineStart(line)
	end := s.wrappedLineStart(line + 1)
	return start + offset, offset < end-start
}

// wrappedRow projects the source line from the retained row's current rank;
// its raw BufferLine may belong to the document before a splice.
func (s residentRows) wrappedRow(index int) protocol.WindowRow {
	node, starts := s.root, 0
	for node.rows == nil {
		if index < node.left.count {
			node = node.left
		} else {
			index -= node.left.count
			starts += node.left.starts
			node = node.right
		}
	}
	for i := range node.rows[:index+1] {
		if node.rows[i].Kind == protocol.WindowRowNormal {
			starts++
		}
	}
	row := node.rows[index]
	row.BufferLine = uint32(starts - 1)
	return row
}

func (s residentRows) lowerBoundBufferLine(line uint32) int {
	switch s.mode {
	case wrappedRows:
		return s.wrappedLineStart(int(line))
	case sequentialRows:
		return min(int(line), s.count())
	}
	low, high := 0, s.count()
	for low < high {
		middle := low + (high-low)/2
		row, _ := s.get(middle)
		if row.BufferLine < line {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}
func (s residentRows) get(index int) (protocol.WindowRow, bool) {
	if s.mode == wrappedRows && index >= 0 && index < s.count() {
		return s.wrappedRow(index), true
	}
	row, ok := ropeGet(s.root, index)
	if ok && s.mode == sequentialRows {
		row.BufferLine = uint32(index)
	}
	return row, ok
}
func (s residentRows) rangeRows(start, count int) []protocol.WindowRow {
	out := make([]protocol.WindowRow, 0, max(count, 0))
	ropeRange(s.root, start, start+count, &out)
	base := max(start, 0)
	switch s.mode {
	case sequentialRows:
		for index := range out {
			out[index].BufferLine = uint32(base + index)
		}
	case wrappedRows:
		if len(out) > 0 {
			line := s.wrappedRow(base).BufferLine
			for index := range out {
				if index > 0 && out[index].Kind == protocol.WindowRowNormal {
					line++
				}
				out[index].BufferLine = line
			}
		}
	}
	return out
}
func (s residentRows) materialize() []protocol.WindowRow { return s.rangeRows(0, s.count()) }

func compatibilityRows(store residentRows) []protocol.WindowRow {
	// Legacy tests and non-hot helpers may inspect small windows directly. Large
	// production windows stay exclusively indexed so no frame materializes O(n).
	if store.count() <= residentLeafRows {
		return store.materialize()
	}
	return nil
}

func (s residentRows) resolveRows(rows []protocol.WindowRow) (residentRows, bool, error) {
	resolved := make([]protocol.WindowRow, len(rows))
	for i, row := range rows {
		if row.Ref {
			found := s.locator.get(row.ID)
			if found == nil || found.ContentHash != row.ContentHash {
				return s, true, fmt.Errorf("missing retained row ref")
			}
			row = *found
		}
		resolved[i] = row
	}
	next, err := newResidentRows(resolved, s.mode)
	return next, false, err
}

// splice returns a staged store. Ref rows resolve through the durable radix
// locator before any deletion, so a miss or malformed splice cannot publish a
// partially changed store.
func (s residentRows) splice(delta protocol.WindowContent, work *renderWorkCollector) (residentRows, bool, error) {
	if s.count() != int(delta.BaseRowCount) {
		return s, false, fmt.Errorf("row splice base count mismatch")
	}
	result := s
	offset := 0
	previousStart := -1
	previousEnd := 0
	for _, splice := range delta.RowSplices {
		start, deleteCount := int(splice.StartIndex), int(splice.DeleteCount)
		if start <= previousStart || start < previousEnd || start > s.count() || deleteCount < 0 || start+deleteCount > s.count() || (deleteCount == 0 && len(splice.InsertRows) == 0) {
			return s, false, fmt.Errorf("invalid row splice range")
		}
		resolved := make([]protocol.WindowRow, len(splice.InsertRows))
		seen := make(map[uint64]struct{}, len(resolved))
		for i, row := range splice.InsertRows {
			if row.Ref {
				found := s.locator.get(row.ID)
				if found == nil || found.ContentHash != row.ContentHash {
					return s, true, fmt.Errorf("missing retained row splice ref")
				}
				row = *found
			}
			if s.mode == wrappedRows && !wrappedRowKind(row.Kind) {
				return s, false, fmt.Errorf("invalid wrapped row kind")
			}
			if row.ID != 0 {
				if _, exists := seen[row.ID]; exists {
					return s, false, fmt.Errorf("duplicate inserted row id")
				}
				seen[row.ID] = struct{}{}
			}
			resolved[i] = row
		}
		actual := start + offset
		wrapped := s.mode == wrappedRows
		left, tail := ropeSplit(result.root, actual, wrapped)
		removed, right := ropeSplit(tail, deleteCount, wrapped)
		removedRows := make([]protocol.WindowRow, 0, deleteCount)
		ropeRange(removed, 0, deleteCount, &removedRows)
		locator := result.locator
		for _, row := range removedRows {
			if row.ID != 0 {
				locator = locator.delete(row.ID)
			}
		}
		for _, row := range resolved {
			if row.ID == 0 {
				continue
			}
			if existing := locator.get(row.ID); existing != nil {
				return s, false, fmt.Errorf("duplicate row id")
			}
			locator = locator.put(row.ID, row)
		}
		inserted := newRopeOnly(resolved, wrapped)
		result = residentRows{root: ropeJoin(ropeJoin(left, inserted), right), locator: locator, mode: s.mode}
		checkStart := max(actual-1, 0)
		checkEnd := min(actual+len(resolved)+1, result.count())
		if s.mode == windowedRows {
			for index := checkStart + 1; index < checkEnd; index++ {
				previous, _ := result.get(index - 1)
				current, _ := result.get(index)
				if current.BufferLine < previous.BufferLine {
					return s, false, fmt.Errorf("retained rows out of buffer-line order")
				}
			}
		}
		offset += len(resolved) - deleteCount
		previousStart = start
		previousEnd = start + deleteCount
		if work != nil {
			work.rowsFetched += deleteCount + len(resolved)
			work.rowChunksTouched += 1
		}
	}
	if result.count() != int(delta.ResultRowCount) {
		return s, false, fmt.Errorf("row splice result count mismatch")
	}
	if result.mode == wrappedRows && result.count() > 0 {
		first, _ := ropeGet(result.root, 0)
		if first.Kind != protocol.WindowRowNormal {
			return s, false, fmt.Errorf("wrapped rows must begin with a source line start")
		}
	}
	return result, false, nil
}

// rows is the owned, ref-resolved splice payload.
func newRopeOnly(rows []protocol.WindowRow, wrapped bool) *rowRope {
	if len(rows) == 0 {
		return nil
	}
	leaves := make([]*rowRope, 0, (len(rows)+residentLeafRows-1)/residentLeafRows)
	for i := 0; i < len(rows); i += residentLeafRows {
		leaves = append(leaves, ropeLeaf(rows[i:min(i+residentLeafRows, len(rows))], wrapped))
	}
	return buildRope(leaves)
}

// rowLocator is a persistent 16-way radix trie over uint64 IDs. Updating one
// ID path-copies 16 tiny metadata nodes and never clones the resident ID set.
type rowLocator struct {
	value *protocol.WindowRow
	child [16]*rowLocator
}

func (n *rowLocator) get(id uint64) *protocol.WindowRow {
	for depth := 0; depth < 16; depth++ {
		if n == nil {
			return nil
		}
		n = n.child[(id>>uint(60-depth*4))&15]
	}
	if n == nil {
		return nil
	}
	return n.value
}
func (n *rowLocator) put(id uint64, row protocol.WindowRow) *rowLocator {
	return locatorPut(n, id, 0, &row)
}
func locatorPut(n *rowLocator, id uint64, depth int, row *protocol.WindowRow) *rowLocator {
	copyNode := &rowLocator{}
	if n != nil {
		*copyNode = *n
	}
	if depth == 16 {
		copyNode.value = row
		return copyNode
	}
	slot := (id >> uint(60-depth*4)) & 15
	copyNode.child[slot] = locatorPut(copyNode.child[slot], id, depth+1, row)
	return copyNode
}
func (n *rowLocator) delete(id uint64) *rowLocator { return locatorPut(n, id, 0, nil) }
