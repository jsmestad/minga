package ui

import (
	"fmt"
	"strings"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func finishApprovalZoneFrame(zones *zoneManager, renderer *agentTranscriptRenderer, content string) {
	zones.Scan(content)
	renderer.retainApprovalMarkers(zones)
	zones.retireUnreferencedApprovals()
}

func TestApprovalMarkersRetainCachedControlsWithoutRetainingTurnHistory(t *testing.T) {
	t.Parallel()
	zones := newZoneManager()
	renderer := newAgentTranscriptRenderer()
	renderer.begin(80, 1, 8)
	stable := zones.Mark("header", "Header")
	var lastID, lastRows string
	for index := range 500 {
		lastID = fmt.Sprintf("agent:approval:request-%d", index)
		lastRows = zones.MarkAgentApproval(lastID, "Approve")
		renderer.admit(transcriptCacheKey{slot: uint64(index + 1)}, []string{lastRows}, zones)
		finishApprovalZoneFrame(zones, renderer, lastRows)
		if len(zones.approvalMarkers) > renderer.rowCap+1 || zones.Get(lastID) == nil {
			t.Fatalf("approval history escaped the cache/presentation bounds at turn %d", index)
		}
	}

	// Cached text remains usable after leaving the current presentation.
	finishApprovalZoneFrame(zones, renderer, stable)
	finishApprovalZoneFrame(zones, renderer, lastRows)
	if zone := zones.Get(lastID); zone == nil || zone.StartX != 0 || zone.EndX != 6 {
		t.Fatal("a retained cached control lost its immutable marker")
	}

	// Cache replacement must not revoke the still-displayed frame before View replaces it.
	renderer.begin(81, 1, 8)
	if zones.Get(lastID) == nil {
		t.Fatal("cache replacement revoked a still-presented control")
	}
	finishApprovalZoneFrame(zones, renderer, stable)
	if len(zones.approvalMarkers) != 0 || len(zones.ids) != 1 || len(zones.rids) != 1 || zones.Get("header") == nil {
		t.Fatal("unreachable approval registrations survived or unrelated zones were retired")
	}
	fresh := zones.MarkAgentApproval("agent:approval:fresh", "Approve")
	if fresh == lastRows {
		t.Fatal("a retired numeric token was reused for another target")
	}
}

func TestApprovalMarkersRetainPartialAndDetachedPresentationRoots(t *testing.T) {
	t.Parallel()
	zones := newZoneManager()
	renderer := newAgentTranscriptRenderer()
	renderer.begin(80, 1, 8)
	id := "agent:approval:detached"
	marked := zones.MarkAgentApproval(id, "Approve")
	marker, _, ok := readZoneMarker(marked, 0)
	if !ok {
		t.Fatal("approval marker missing")
	}
	finishApprovalZoneFrame(zones, renderer, marker+"clipped")
	zones.Scan("")
	zones.ScanInto(marked, 10, 5)
	renderer.retainApprovalMarkers(zones)
	zones.retireUnreferencedApprovals()
	if zone := zones.Get(id); zone == nil || zone.StartX != 10 || zone.StartY != 5 {
		t.Fatal("partial or separately composited presentation lost its target")
	}
	finishApprovalZoneFrame(zones, renderer, "")
	if _, retained := zones.ids[id]; retained {
		t.Fatal("detached target survived after its presentation was removed")
	}
}

func TestMaximumApprovalIdentityBytesCannotEscapeTheRendererCacheBudget(t *testing.T) {
	t.Parallel()
	zones := newZoneManager()
	renderer := newAgentTranscriptRenderer()
	renderer.begin(80, 1, 8)
	target := protocol.AgentApprovalTarget{SessionID: strings.Repeat("/", 65535), RequestID: strings.Repeat("/", 65535), ToolCallID: strings.Repeat("/", 65535)}
	var row strings.Builder
	var ids []string
	for _, decision := range []generated.AgentApprovalDecision{generated.AgentApprovalDecisionApprove, generated.AgentApprovalDecisionReject, generated.AgentApprovalDecisionApproveSession, generated.AgentApprovalDecisionApproveTurn} {
		id := zoneIDAgentApproval(target, decision)
		ids = append(ids, id)
		row.WriteString(zones.MarkAgentApproval(id, "Act"))
	}
	key := transcriptCacheKey{slot: 1}
	renderer.admit(key, []string{row.String()}, zones)
	if _, cached := renderer.cached(key); cached {
		t.Fatal("approval identities exceeded the cache byte cap without preventing admission")
	}
	finishApprovalZoneFrame(zones, renderer, row.String())
	for _, id := range ids {
		if zones.Get(id) == nil {
			t.Fatal("uncached but presented control was prematurely retired")
		}
	}
	finishApprovalZoneFrame(zones, renderer, "")
	if len(zones.ids) != 0 || len(zones.rids) != 0 {
		t.Fatal("uncached identities survived their presentation")
	}
}
