package ui

import (
	"reflect"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestTranscriptPlanLateFrameFailuresPreserveCompleteOwner(t *testing.T) {
	tests := []struct {
		name     string
		command  protocol.Command
		reason   byte
		targeted bool
	}{
		{name: "missing window", command: protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{ID: 99, ContentEpoch: 9}}, targeted: true},
		{name: "window epoch", command: protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{ID: 7, ContentEpoch: 10}}, reason: protocol.RejectWindowEpoch},
		{name: "row splice", command: protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{ID: 7, ContentEpoch: 9, RowSplicesSet: true, BaseRowCount: 8, ResultRowCount: 8, RowSplices: []protocol.WindowRowSplice{{StartIndex: 99, DeleteCount: 1}}}}, reason: protocol.RejectInvalidRowSplice},
		{name: "gutter decode", command: protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiGutter, WindowGutter: protocol.Gutter{WindowID: 7, DecodeError: "malformed gutter"}}}, reason: protocol.RejectDecodeFailure},
		{name: "gutter extent", command: protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiGutter, WindowGutter: protocol.Gutter{WindowID: 7, Resident: &protocol.ResidentGutterEntries{ContentEpoch: 9, LineCount: 9}}}}, reason: protocol.RejectInvalidRetainedRows},
		{name: "semantic resource bound", command: protocol.Command{Kind: protocol.CommandResidentSemantics, ResidentSemantics: protocol.ResidentSemantics{ResidentSemanticsHeader: protocol.ResidentSemanticsHeader{Version: 1, Mode: 0, WindowID: 7, ContentEpoch: 9, Revision: 2, TargetRowRevision: 1, RowCount: maxResidentSemanticRows + 1}}}, reason: protocol.RejectInvalidRetainedRows},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			model, _ := residentSemanticFixture(t)
			out := make(chan []byte, 16)
			model.out = out
			model.lastCommittedSeq = 1
			model.transcript.apply(replaceFrame(1, msg(0, "zero"), msg(7, "first"), msg(7, "second"), msg(9, "footer")))
			model.transcript.pinned = false
			model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(2).slot, row: 5}
			model.transcript.pendingScroll = -3
			model.transcript.pinTransition = pinScrolledAway
			owner := model.transcript
			before := testTranscriptSnapshot(owner)
			pages := make(map[uint64]*transcriptPage, len(owner.pages))
			for number, page := range owner.pages {
				pages[number] = page
			}
			model.applyCommands([]protocol.Command{
				beginFrame(2, 1),
				transcriptCommand(appendFrame(1, 1, 2, msg(9, "reintroduced footer"), msg(0, "zero suffix"))),
				transcriptCommand(replaceFrame(1, msg(7, "second"), msg(7, "revision"), msg(9, "reintroduced footer"))),
				transcriptCommand(appendFrame(1, 0, 3, msg(7, "first duplicate patched"))),
				test.command,
				commitFrame(2),
			})
			if model.transcript != owner || !reflect.DeepEqual(model.transcript, before) || model.lastCommittedSeq != 1 {
				t.Fatal("later command failure changed transcript pages, indexes, resource totals, identity, or reading state")
			}
			for number, page := range pages {
				if model.transcript.pages[number] != page {
					t.Fatal("rejected frame replaced resident page")
				}
			}
			packets := drainOutboundPackets(out)
			rejected, recovery := 0, 0
			for _, packet := range packets {
				switch packet[0] {
				case generated.OPFrameApplied:
					t.Fatal("rejected frame acknowledged as applied")
				case generated.OPFrameRejected:
					rejected++
					if packet[13] != test.reason {
						t.Fatalf("rejection reason=%d want=%d", packet[13], test.reason)
					}
				case generated.OPWindowRefMiss:
					recovery++
				}
			}
			if test.targeted {
				if recovery != 1 || rejected != 0 {
					t.Fatalf("targeted recovery=%d rejection=%d", recovery, rejected)
				}
			} else if rejected != 1 || recovery != 0 {
				t.Fatalf("recovery=%d rejection=%d", recovery, rejected)
			}
			assertTranscriptIndexes(t, owner)
		})
	}
}

func TestTranscriptFrameCommitsSoleOwnerAndDropsConsumedChromePayload(t *testing.T) {
	model := New(40, 8, nil)
	owner := model.transcript
	model.applyCommands([]protocol.Command{
		beginFrame(1, 0), testThemeCommand(),
		transcriptCommand(replaceFrame(7, msg(1, "seed"), msg(2, "old footer"))),
		transcriptCommand(appendFrame(7, 0, 1, msg(2, "new footer"), msg(0, "zero"))),
		transcriptCommand(replaceFrame(7, msg(0, "zero"), msg(1, "revised seed"), msg(2, "new footer"))),
		commitFrame(1),
	})
	if model.transcript != owner || model.lastCommittedSeq != 1 {
		t.Fatal("frame replaced the sole transcript owner or failed to commit")
	}
	if _, retained := model.chrome[generated.OPGuiAgentTranscript]; retained {
		t.Fatal("chrome retains consumed transcript payload")
	}
	if got := testTranscriptMessages(owner); !reflect.DeepEqual(got, []protocol.AgentChatMessage{msg(0, "zero"), msg(1, "revised seed"), msg(2, "new footer")}) {
		t.Fatalf("mixed committed commands=%v", got)
	}
	assertTranscriptIndexes(t, owner)
	model.staging = &frameStaging{base: 1, commands: []protocol.Command{{Kind: protocol.CommandSetTitle, Title: "no transcript"}}}
	plan, reason := model.prepareTranscriptPlan()
	if plan != nil || reason != transcriptApplied {
		t.Fatal("transcript-free frame constructed a retained-history plan")
	}
	model.staging = nil
}
