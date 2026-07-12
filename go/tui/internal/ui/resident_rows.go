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
}

type rowRope struct {
	left, right *rowRope
	rows        []protocol.WindowRow
	count       int
	height      int
}

const residentLeafRows = 256

func newResidentRows(rows []protocol.WindowRow) (residentRows, error) {
	var store residentRows
	leaves := make([]*rowRope, 0, (len(rows)+residentLeafRows-1)/residentLeafRows)
	var previousBufferLine uint32
	hasPreviousBufferLine := false
	for start := 0; start < len(rows); start += residentLeafRows {
		end := min(start+residentLeafRows, len(rows))
		owned := append([]protocol.WindowRow(nil), rows[start:end]...)
		leaves = append(leaves, ropeLeaf(owned))
		for _, row := range owned {
			if hasPreviousBufferLine && row.BufferLine < previousBufferLine {
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

func ropeLeaf(rows []protocol.WindowRow) *rowRope {
	if len(rows) == 0 {
		return nil
	}
	return &rowRope{rows: rows, count: len(rows), height: 1}
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
	return &rowRope{left: left, right: right, count: left.count + right.count, height: max(left.height, right.height) + 1}
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
func ropeSplit(n *rowRope, index int) (*rowRope, *rowRope) {
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
		return ropeLeaf(n.rows[:index]), ropeLeaf(n.rows[index:])
	}
	leftCount := ropeCount(n.left)
	if index < leftCount {
		a, b := ropeSplit(n.left, index)
		return a, ropeJoin(b, n.right)
	}
	if index == leftCount {
		return n.left, n.right
	}
	a, b := ropeSplit(n.right, index-leftCount)
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

func (s residentRows) count() int                               { return ropeCount(s.root) }
func (s residentRows) get(index int) (protocol.WindowRow, bool) { return ropeGet(s.root, index) }
func (s residentRows) rangeRows(start, count int) []protocol.WindowRow {
	out := make([]protocol.WindowRow, 0, max(count, 0))
	ropeRange(s.root, start, start+count, &out)
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
	next, err := newResidentRows(resolved)
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
			if row.ID != 0 {
				if _, exists := seen[row.ID]; exists {
					return s, false, fmt.Errorf("duplicate inserted row id")
				}
				seen[row.ID] = struct{}{}
			}
			resolved[i] = row
		}
		actual := start + offset
		left, tail := ropeSplit(result.root, actual)
		removed, right := ropeSplit(tail, deleteCount)
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
		inserted, err := newRopeOnly(resolved)
		if err != nil {
			return s, false, err
		}
		result = residentRows{root: ropeJoin(ropeJoin(left, inserted), right), locator: locator}
		checkStart := max(actual-1, 0)
		checkEnd := min(actual+len(resolved)+1, result.count())
		for index := checkStart + 1; index < checkEnd; index++ {
			previous, _ := result.get(index - 1)
			current, _ := result.get(index)
			if current.BufferLine < previous.BufferLine {
				return s, false, fmt.Errorf("retained rows out of buffer-line order")
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
	return result, false, nil
}
func newRopeOnly(rows []protocol.WindowRow) (*rowRope, error) {
	if len(rows) == 0 {
		return nil, nil
	}
	owned := append([]protocol.WindowRow(nil), rows...)
	leaves := make([]*rowRope, 0, (len(owned)+residentLeafRows-1)/residentLeafRows)
	for i := 0; i < len(owned); i += residentLeafRows {
		leaves = append(leaves, ropeLeaf(owned[i:min(i+residentLeafRows, len(owned))]))
	}
	return buildRope(leaves), nil
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
