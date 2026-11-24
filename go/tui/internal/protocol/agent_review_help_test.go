package protocol

import (
	"encoding/binary"
	"reflect"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func reviewHelpString16(value string) []byte {
	return append(binary.BigEndian.AppendUint16(nil, uint16(len(value))), []byte(value)...)
}

func reviewStatusPacket(section []byte) []byte {
	packet := []byte{generated.OPGuiStatusBar, 1, 0x10}
	packet = binary.BigEndian.AppendUint16(packet, uint16(len(section)))
	return append(packet, section...)
}

func reviewStatusSection(freshness byte) []byte {
	section := reviewHelpString16("/project/é/shared.ex")
	section = append(section, freshness)
	section = binary.BigEndian.AppendUint32(section, 0x1234ABCD)
	return append(section, reviewHelpString16("opaque:é/+% item\x00")...)
}

func agentHelpPacket(body []byte) []byte {
	packet := binary.BigEndian.AppendUint32([]byte{generated.OPGuiAgentHelp}, uint32(len(body)))
	return append(packet, body...)
}

func TestReviewStatusDecodesOpaqueOfferAndResetsOnAbsence(t *testing.T) {
	for _, freshness := range []ReviewFreshness{ReviewCurrent, ReviewStale} {
		packet := reviewStatusPacket(reviewStatusSection(byte(freshness)))
		command, err := DecodeCommand(packet)
		if err != nil {
			t.Fatal(err)
		}
		want := StatusReview{Path: "/project/é/shared.ex", Freshness: freshness, Generation: 0x1234ABCD, ItemID: "opaque:é/+% item\x00"}
		if command.Kind != CommandChrome || command.Size != len(packet) || command.Chrome.Status.Review == nil || *command.Chrome.Status.Review != want {
			t.Fatalf("Review consumer offer = %+v, want %+v", command, want)
		}
	}
	command, err := DecodeCommand([]byte{generated.OPGuiStatusBar, 0})
	if err != nil || command.Chrome.Status.Review != nil {
		t.Fatalf("ordinary status retained Review: %+v, %v", command, err)
	}
}

func TestReviewStatusRejectsUnknownFreshnessAndMalformedOffer(t *testing.T) {
	section := reviewStatusSection(0)
	for end := range len(section) {
		if _, err := DecodeCommand(reviewStatusPacket(section[:end])); err == nil {
			t.Fatalf("accepted truncated Review section at byte %d", end)
		}
	}
	for _, section := range [][]byte{reviewStatusSection(2), append(reviewStatusSection(0), 0)} {
		if _, err := DecodeCommand(reviewStatusPacket(section)); err == nil {
			t.Fatalf("accepted malformed Review: %x", section)
		}
	}
}

func TestConflictStatusRequiresAValidExactReviewOffer(t *testing.T) {
	conflict := []byte{0x11, 0, 4, 0, 0, 0, 2}
	offer := func(generation uint32, itemID string) []byte {
		section := append(reviewHelpString16("note.txt"), byte(ReviewCurrent))
		section = binary.BigEndian.AppendUint32(section, generation)
		return append(section, reviewHelpString16(itemID)...)
	}
	packet := func(generation uint32, itemID string) []byte {
		packet := reviewStatusPacket(offer(generation, itemID))
		packet[1] = 2
		return append(packet, conflict...)
	}
	command, err := DecodeCommand(packet(9, "hunk-B"))
	if err != nil || command.Chrome.Status.Review == nil || command.Chrome.Status.Review.ConflictIndex != 2 {
		t.Fatalf("valid conflict offer was lost: %+v, %v", command, err)
	}
	for _, invalid := range [][]byte{
		append([]byte{generated.OPGuiStatusBar, 1}, conflict...),
		packet(0, "hunk-B"),
		packet(9, ""),
	} {
		if _, err := DecodeCommand(invalid); err == nil {
			t.Fatalf("invalid conflict offer was accepted: %x", invalid)
		}
	}
}

func TestConflictStatusCarriesTheBEAMAuthoredDecisionKeys(t *testing.T) {
	section := append(reviewHelpString16("note.txt"), byte(ReviewCurrent))
	section = binary.BigEndian.AppendUint32(section, 9)
	section = append(section, reviewHelpString16("hunk-B")...)
	keys := append(reviewHelpString16("Ctrl+Backspace"), reviewHelpString16("Ctrl+Enter")...)
	packet := reviewStatusPacket(section)
	packet[1] = 3
	packet = append(packet, 0x11, 0, 4, 0, 0, 0, 2)
	packet = append(packet, 0x12, 0, byte(len(keys)))
	packet = append(packet, keys...)
	command, err := DecodeCommand(packet)
	if err != nil || command.Chrome.Status.Review == nil {
		t.Fatalf("conflict keys lost the offer: %+v, %v", command, err)
	}
	review := command.Chrome.Status.Review
	if review.KeepMineKey != "Ctrl+Backspace" || review.UseAgentKey != "Ctrl+Enter" {
		t.Fatalf("conflict keys = %q/%q", review.KeepMineKey, review.UseAgentKey)
	}
	truncated := append(packet[:len(packet)-len(keys)-3:len(packet)-len(keys)-3], 0x12, 0, 3, 0, 5, 'x')
	if _, err := DecodeCommand(truncated); err == nil {
		t.Fatalf("malformed conflict keys were accepted: %x", truncated)
	}
}

func TestAgentHelpDecodesIndependentLen32GroupsAndHiddenReset(t *testing.T) {
	body := []byte{1, 1, 2}
	body = append(body, reviewHelpString16("Review é")...)
	body = append(body, 2, 1, '?')
	body = append(body, reviewHelpString16("Show agent help")...)
	body = append(body, 3, 'E', 's', 'c')
	body = append(body, reviewHelpString16("Close help")...)
	body = append(body, reviewHelpString16("Empty group")...)
	body = append(body, 0)
	packet := agentHelpPacket(body)
	// The decoder consumes only this frame, not the following command.
	command, err := DecodeCommand(append(packet, generated.OPGuiStatusBar, 0))
	if err != nil {
		t.Fatal(err)
	}
	want := AgentHelp{Visible: true, Groups: []AgentHelpGroup{
		{Title: "Review é", Bindings: []AgentHelpBinding{{Key: "?", Description: "Show agent help"}, {Key: "Esc", Description: "Close help"}}},
		{Title: "Empty group", Bindings: []AgentHelpBinding{}},
	}}
	if command.Kind != CommandChrome || command.Size != len(packet) || !reflect.DeepEqual(command.Chrome.AgentHelp, want) {
		t.Fatalf("Help consumer model = %+v, want %+v", command, want)
	}
	for end := range len(packet) {
		if _, err := DecodeCommand(packet[:end]); err == nil {
			t.Fatalf("accepted truncated Help at byte %d", end)
		}
	}
	for _, body := range [][]byte{{1, 0}, {1, 1, 0}} {
		command, err := DecodeCommand(agentHelpPacket(body))
		if err != nil || command.Chrome.AgentHelp.Visible != (body[1] == 1) || len(command.Chrome.AgentHelp.Groups) != 0 {
			t.Fatalf("empty/hidden Help = %+v, %v", command, err)
		}
	}
}

func TestAgentHelpRejectsInvalidVersionsVisibilityCountsAndTrailingData(t *testing.T) {
	for _, body := range [][]byte{
		{}, {1}, {2, 0}, {1, 2}, {1, 0, 0}, {1, 1}, {1, 1, 1},
		{1, 1, 1, 0, 0, 1},               // One binding promised, none supplied.
		{1, 1, 1, 0, 0, 1, 1, 'k', 0, 1}, // Truncated description.
		{1, 1, 0, 0},                     // Trailing bytes after zero groups.
		{1, 1, 1, 0, 1, 0xFF, 0},         // Invalid UTF-8 group title.
	} {
		if _, err := DecodeCommand(agentHelpPacket(body)); err == nil {
			t.Fatalf("accepted malformed Help body: %x", body)
		}
	}
}
