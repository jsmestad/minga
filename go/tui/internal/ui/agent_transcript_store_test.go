package ui

import (
	"fmt"
	"math"
	"math/rand/v2"
	"reflect"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func assertTranscriptIndexes(t *testing.T, tr *residentTranscript) {
	t.Helper()
	if len(tr.bySlot) != tr.len() {
		t.Fatalf("slot count=%d resident=%d", len(tr.bySlot), tr.len())
	}
	ids := map[uint32][]uint64{}
	var payload uint64
	var animated int
	var tools [3]int
	var latest [transcriptSummaryKinds]uint64
	var members [transcriptSummaryKinds]int
	for ordinal := tr.first; ordinal < tr.end; ordinal++ {
		entry := tr.at(ordinal)
		if entry.slot == 0 || tr.bySlot[entry.slot] != ordinal {
			t.Fatalf("ordinal %d lost local slot %d", ordinal, entry.slot)
		}
		if id := entry.message.ID; id != 0 {
			ids[id] = append(ids[id], ordinal)
		}
		payload += transcriptPayloadBytes(entry.message)
		if entry.payloadBytes != transcriptPayloadBytes(entry.message) {
			t.Fatalf("entry %d has stale byte total", ordinal)
		}
		animated += boolInt(agentMessageAnimated(entry.message))
		counts := transcriptToolCounts(entry.message)
		for kind := range tools {
			tools[kind] += counts[kind]
		}
		for kind, present := range transcriptSummaryMembership(entry.message) {
			if present {
				latest[kind] = ordinal
				members[kind]++
			}
		}
	}
	if tr.payloadBytes != payload || tr.animatedCount != animated || tr.toolCounts != tools {
		t.Fatalf("resource totals bytes=%d/%d animated=%d/%d tools=%v/%v", tr.payloadBytes, payload, tr.animatedCount, animated, tr.toolCounts, tools)
	}
	if len(tr.byID) != len(ids) {
		t.Fatalf("ID index retains dead keys: %v", tr.byID)
	}
	for id, ordinals := range ids {
		occurrences := tr.byID[id]
		if occurrences.first != ordinals[0] || occurrences.last != ordinals[len(ordinals)-1] {
			t.Fatalf("ID %d boundaries=%+v want=%v", id, occurrences, ordinals)
		}
		for index, ordinal := range ordinals {
			previous, next := uint64(0), uint64(0)
			if index > 0 {
				previous = ordinals[index-1]
			}
			if index+1 < len(ordinals) {
				next = ordinals[index+1]
			}
			if entry := tr.at(ordinal); entry.prevID != previous || entry.nextID != next {
				t.Fatalf("ID %d ordinal %d links=(%d,%d) want=(%d,%d)", id, ordinal, entry.prevID, entry.nextID, previous, next)
			}
		}
	}
	active := 0
	for number, page := range tr.pages {
		count := 0
		for offset, entry := range page.cells {
			ordinal := number*transcriptPageSize + uint64(offset)
			if ordinal >= tr.first && ordinal < tr.end {
				count++
				continue
			}
			if !reflect.DeepEqual(entry, transcriptEntry{}) {
				t.Fatalf("removed cell %d retains payload or index links", ordinal)
			}
		}
		if count == 0 || count != page.count {
			t.Fatalf("page %d count=%d want=%d", number, page.count, count)
		}
		active += count
	}
	if active != tr.len() {
		t.Fatalf("page interval has %d cells, want %d", active, tr.len())
	}
	for kind, summary := range tr.summaries {
		if len(summary.ordinals) != members[kind] || len(summary.positions) != members[kind] {
			t.Fatalf("summary %d retains dead indexes", kind)
		}
		for index, ordinal := range summary.ordinals {
			if summary.positions[ordinal] != index || ordinal < tr.first || ordinal >= tr.end || !transcriptSummaryMembership(tr.at(ordinal).message)[kind] {
				t.Fatalf("summary %d ordinal %d has stale position", kind, ordinal)
			}
			if index > 0 && summary.ordinals[(index-1)/2] < ordinal {
				t.Fatalf("summary %d heap order violated", kind)
			}
		}
		if len(summary.ordinals) > 0 && summary.ordinals[0] != latest[kind] {
			t.Fatalf("summary %d latest=%d want=%d", kind, summary.ordinals[0], latest[kind])
		}
	}
}

func TestTranscriptPlanMixedCommandsPreserveOccurrencesAndFreshSuffixSlots(t *testing.T) {
	tr := testTranscriptWithMessages([]protocol.AgentChatMessage{msg(0, "zero"), msg(7, "A"), msg(7, "B"), msg(9, "footer")})
	tr.pinned = false
	tr.anchor = transcriptAnchor{slot: tr.entry(2).slot, row: 3}
	anchor, footer := tr.anchor, tr.entry(3).slot
	oldFirst := tr.first
	before := testTranscriptSnapshot(tr)
	plan := tr.prepare()
	frames := []protocol.AgentTranscript{
		appendFrame(1, 1, 2, msg(7, "patched first"), msg(0, "new zero"), msg(9, "footer")),
		appendFrame(1, 1, 3, msg(7, "patched surviving duplicate"), msg(0, "another zero")),
		replaceFrame(1, msg(0, "another zero"), msg(7, "patched surviving duplicate"), msg(9, "footer"), msg(0, "new zero")),
	}
	for _, frame := range frames {
		if reason := plan.apply(frame); reason != transcriptApplied {
			t.Fatal(reason)
		}
	}
	if !reflect.DeepEqual(tr, before) {
		t.Fatal("mixed command preparation mutated resident state")
	}
	plan.commit()
	if tr.anchor != anchor || tr.pinned {
		t.Fatalf("mixed steps lost exact occurrence anchor: %+v", tr.anchor)
	}
	if tr.first <= oldFirst {
		t.Fatal("front trim/full replacement rebased ordinals")
	}
	if tr.entry(2).slot == footer {
		t.Fatal("dropped/reintroduced footer reused the removed local slot")
	}
	if got := testTranscriptMessages(tr); !reflect.DeepEqual(got, frames[2].Messages) {
		t.Fatalf("mixed prospective order=%v", got)
	}
	assertTranscriptIndexes(t, tr)
}

func TestTranscriptDeltaBoundaryAnchors(t *testing.T) {
	for _, test := range []struct {
		name              string
		rank              int
		trim, base        uint32
		wantRank, wantRow int
	}{
		{"removed front selects successor", 0, 2, 2, 0, 0},
		{"removed tail selects predecessor", 4, 1, 2, 1, 7},
		{"no survivors preserves approximate rank", 2, 5, 0, 1, 7},
	} {
		t.Run(test.name, func(t *testing.T) {
			tr := testTranscriptWithMessages([]protocol.AgentChatMessage{msg(1, "a"), msg(2, "b"), msg(3, "c"), msg(4, "d"), msg(5, "e")})
			tr.pinned = false
			tr.anchor = transcriptAnchor{slot: tr.entry(test.rank).slot, row: 7}
			if reason := tr.apply(appendFrame(1, test.trim, test.base, msg(8, "new"), msg(9, "last"))); reason != transcriptApplied {
				t.Fatal(reason)
			}
			if tr.pinned || tr.anchor != (transcriptAnchor{slot: tr.entry(test.wantRank).slot, row: test.wantRow}) {
				t.Fatalf("boundary anchor=%+v", tr.anchor)
			}
			assertTranscriptIndexes(t, tr)
		})
	}
}

func TestTranscriptRemovedPagesAndIndexesReleaseReferences(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1))
	random := rand.New(rand.NewPCG(7, 3573))
	const retained = 70
	for iteration := range 1800 {
		oldPages := make(map[uint64]*transcriptPage, len(tr.pages))
		for number, page := range tr.pages {
			oldPages[number] = page
		}
		message := msg(uint32(iteration+1), fmt.Sprintf("payload-%d", iteration))
		switch iteration % 5 {
		case 0:
			message.Kind = agentKindTool
			message.Status = byte(iteration % 3)
		case 1:
			message.Kind = agentKindUsage
			message.Usage.Input = uint32(iteration)
		case 2:
			message.Kind = agentKindSystem
			message.Status = 1
		case 3:
			message.Kind = agentKindThinking
		}
		message.StyledLines = []protocol.AgentStyledLine{{{Text: message.Text, URL: message.Text}}}
		message.PreviewLines = []string{message.Text}
		trim := uint32(0)
		if tr.len() >= retained {
			trim = 1
		}
		frame := appendFrame(1, trim, uint32(tr.len())-trim, message)
		if iteration%11 == 0 && tr.len() > 2 {
			frame.BaseCount--
			frame.Messages = append(frame.Messages, msg(0, "fresh zero suffix"))
		}
		plan := tr.prepare()
		if reason := plan.apply(frame); reason != transcriptApplied {
			t.Fatal(reason)
		}
		// Exercise summary membership changes at arbitrary retained positions too.
		if plan.end > plan.first && iteration%3 == 0 {
			ordinal := plan.first + uint64(random.IntN(int(plan.end-plan.first)))
			entry := plan.at(ordinal)
			if entry.message.ID != 0 {
				revised := entry.message
				revised.Kind = agentKindUsage
				revised.IsError = false
				revised.Text = "reclassified"
				if reason := plan.apply(appendFrame(1, 0, uint32(plan.end-plan.first), revised)); reason != transcriptApplied {
					t.Fatal(reason)
				}
			}
		}
		if iteration%17 == 0 {
			incoming := make([]protocol.AgentChatMessage, int(plan.end-plan.first))
			for index := range incoming {
				incoming[len(incoming)-1-index] = plan.at(plan.first + uint64(index)).message
			}
			if reason := plan.apply(replaceFrame(1, incoming...)); reason != transcriptApplied {
				t.Fatal(reason)
			}
		}
		plan.commit()
		for number, page := range oldPages {
			if tr.pages[number] != page {
				for _, cell := range page.cells {
					if !reflect.DeepEqual(cell, transcriptEntry{}) {
						t.Fatal("retired page retains a removed body")
					}
				}
			}
		}
		if len(tr.pages) > 3 || tr.len() > retained+1 || len(tr.bySlot) > retained+1 || len(tr.byID) > retained+1 {
			t.Fatalf("bounded workload grew ownership: pages=%d resident=%d slots=%d IDs=%d", len(tr.pages), tr.len(), len(tr.bySlot), len(tr.byID))
		}
		assertTranscriptIndexes(t, tr)
	}
	tr.apply(replaceFrame(2))
	assertTranscriptIndexes(t, tr)
	if len(tr.pages) != 0 || len(tr.byID) != 0 || len(tr.bySlot) != 0 || tr.payloadBytes != 0 {
		t.Fatal("reset retains resident payload ownership")
	}
}

func TestTranscriptPlanWorkTracksChangedEntries(t *testing.T) {
	for _, count := range []int{100, 1000, 10000} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			messages := make([]protocol.AgentChatMessage, count)
			for index := range messages {
				messages[index] = msg(uint32(index+1), "unchanged")
			}
			tr := testTranscriptWithMessages(messages)
			middle := tr.entry(count / 2)
			slot := middle.slot
			frame := appendFrame(1, 1, uint32(count-2), msg(uint32(count), "replacement tail"), msg(uint32(count+1), "appended"))
			plan := tr.prepare()
			if reason := plan.apply(frame); reason != transcriptApplied {
				t.Fatal(reason)
			}
			if len(plan.cells) > 5 || len(plan.slots) > 5 || len(plan.ids) > 5 {
				t.Fatalf("plan traversed/reindexed retained history: cells=%d slots=%d IDs=%d", len(plan.cells), len(plan.slots), len(plan.ids))
			}
			allocs := testing.AllocsPerRun(20, func() {
				candidate := tr.prepare()
				if reason := candidate.apply(frame); reason != transcriptApplied {
					panic(reason)
				}
			})
			if allocs > 40 {
				t.Fatalf("changed-entry preparation allocates %.0f objects at resident count %d", allocs, count)
			}
			t.Logf("resident=%d changed_cells=%d changed_slots=%d changed_IDs=%d prepare_allocs=%.0f", count, len(plan.cells), len(plan.slots), len(plan.ids), allocs)
			plan.commit()
			if tr.entry(count/2-1) != middle || middle.slot != slot {
				t.Fatal("retained cell moved or local slot changed")
			}
			assertTranscriptIndexes(t, tr)
		})
	}
}

func TestTranscriptArithmeticExhaustionRejectsWithoutAliasing(t *testing.T) {
	tr := testTranscriptWithMessages([]protocol.AgentChatMessage{msg(1, "one")})
	tr.nextSlot = math.MaxUint64
	before := testTranscriptSnapshot(tr)
	if reason := tr.apply(appendFrame(1, 0, 1, msg(2, "new"))); reason != transcriptDroppedDesync || !reflect.DeepEqual(tr, before) {
		t.Fatal("exhausted slot wrapped or mutated owner")
	}
	// An ID revision consumes no local slot and remains admissible.
	if reason := tr.apply(appendFrame(1, 0, 1, msg(1, "revised"))); reason != transcriptApplied {
		t.Fatal(reason)
	}
	tr.entry(0).revision = math.MaxUint64
	before = testTranscriptSnapshot(tr)
	if reason := tr.apply(replaceFrame(1, msg(1, "changed"))); reason != transcriptDroppedDesync || !reflect.DeepEqual(tr, before) {
		t.Fatal("exhausted revision wrapped or mutated owner")
	}
	empty := newResidentTranscript()
	empty.first = math.MaxUint64
	empty.end = math.MaxUint64
	before = testTranscriptSnapshot(empty)
	if reason := empty.apply(replaceFrame(1, msg(1, "new"))); reason != transcriptDroppedDesync || !reflect.DeepEqual(empty, before) {
		t.Fatal("exhausted ordinal wrapped or mutated owner")
	}
}

func TestTranscriptProspectiveDeltasMatchOrderedSliceOracle(t *testing.T) {
	random := rand.New(rand.NewPCG(3573, 3443))
	tr := testTranscriptWithMessages([]protocol.AgentChatMessage{msg(7, "A"), msg(0, "zero"), msg(7, "B")})
	want := testTranscriptEntries(tr)
	nextSlot := tr.nextSlot
	for batch := range 100 {
		plan := tr.prepare()
		for command := range 4 {
			trim := random.IntN(len(want) + 1)
			base := random.IntN(len(want) - trim + 1)
			incoming := make([]protocol.AgentChatMessage, random.IntN(5))
			for index := range incoming {
				incoming[index] = msg(uint32(random.IntN(4)), fmt.Sprintf("batch %d command %d item %d", batch, command, index))
			}
			kept := append([]transcriptEntry(nil), want[trim:trim+base]...)
			for _, message := range incoming {
				match := -1
				if message.ID != 0 {
					for index, entry := range kept {
						if entry.message.ID == message.ID {
							match = index
							break
						}
					}
				}
				if match < 0 {
					nextSlot++
					kept = append(kept, transcriptEntry{slot: nextSlot, revision: 1, message: message})
				} else {
					if !reflect.DeepEqual(kept[match].message, message) {
						kept[match].revision++
					}
					kept[match].message = message
				}
			}
			want = kept
			if reason := plan.apply(appendFrame(1, uint32(trim), uint32(base), incoming...)); reason != transcriptApplied {
				t.Fatal(reason)
			}
		}
		plan.commit()
		if tr.len() != len(want) || tr.nextSlot != nextSlot {
			t.Fatalf("batch %d counts/slot allocator diverged", batch)
		}
		for index, expected := range want {
			actual := tr.entry(index)
			if actual.slot != expected.slot || actual.revision != expected.revision || !reflect.DeepEqual(actual.message, expected.message) {
				t.Fatalf("batch %d entry %d differs from ordered occurrence oracle", batch, index)
			}
		}
		assertTranscriptIndexes(t, tr)
	}
}
