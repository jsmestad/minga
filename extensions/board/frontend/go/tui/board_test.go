package board

import "testing"

func boardPacket() []byte {
	packet := []byte{0x87, 1, 0, 0, 0, 7, 0, 1, 0, 0, 0}
	packet = append(packet, []byte{0, 0, 0, 7, 3, 2, 0, 8}...)
	packet = append(packet, []byte("fix auth")...)
	packet = append(packet, byte(8))
	packet = append(packet, []byte("claude-4")...)
	packet = append(packet, []byte{0, 0, 0, 42, 1, 0, 8}...)
	packet = append(packet, []byte("lib/a.ex")...)
	packet = append(packet, []byte{2, 0, 0, 0xFF, 0xFF}...)
	// Trailing zoomed_card_id u32 (0 = grid view, not zoomed).
	packet = append(packet, []byte{0, 0, 0, 0}...)
	return packet
}

// zoomedBoardPacket mirrors boardPacket but with visible=0, status=working, and
// the trailing zoomed_card_id pointing at the single card: the BEAM's zoomed
// state (visible? false while a card is zoomed).
func zoomedBoardPacket() []byte {
	packet := []byte{0x87, 0, 0, 0, 0, 7, 0, 1, 0, 0, 0}
	packet = append(packet, []byte{0, 0, 0, 7, 1, 2, 0, 8}...)
	packet = append(packet, []byte("fix auth")...)
	packet = append(packet, byte(8))
	packet = append(packet, []byte("claude-4")...)
	packet = append(packet, []byte{0, 0, 0, 42, 1, 0, 8}...)
	packet = append(packet, []byte("lib/a.ex")...)
	packet = append(packet, []byte{2, 0, 0, 0xFF, 0xFF}...)
	packet = append(packet, []byte{0, 0, 0, 7}...)
	return packet
}

// legacyBoardPacket is boardPacket without the zoomed_card_id trailer: an older
// BEAM. The decoder must tolerate it and leave ZoomedCardID at zero.
func legacyBoardPacket() []byte {
	packet := []byte{0x87, 1, 0, 0, 0, 7, 0, 1, 0, 0, 0}
	packet = append(packet, []byte{0, 0, 0, 7, 3, 2, 0, 8}...)
	packet = append(packet, []byte("fix auth")...)
	packet = append(packet, byte(8))
	packet = append(packet, []byte("claude-4")...)
	packet = append(packet, []byte{0, 0, 0, 42, 1, 0, 8}...)
	packet = append(packet, []byte("lib/a.ex")...)
	packet = append(packet, []byte{2, 0, 0, 0xFF, 0xFF}...)
	return packet
}

func TestDecodeBoard(t *testing.T) {
	board, summary, size := DecodeBoard(boardPacket())
	if summary != "1 cards" || size != len(boardPacket()) {
		t.Fatalf("summary/size = %q/%d", summary, size)
	}
	if !board.Visible || board.FocusedCardID != 7 || len(board.Cards) != 1 {
		t.Fatalf("decoded board = %#v", board)
	}
	card := board.Cards[0]
	if card.ID != 7 || card.Status != 3 || card.Flags != 2 || card.Task != "fix auth" || card.Model != "claude-4" || len(card.RecentFiles) != 1 || card.RecentFiles[0] != "lib/a.ex" {
		t.Fatalf("decoded card = %#v", card)
	}
}

func TestRenderLines(t *testing.T) {
	board, _, _ := DecodeBoard(boardPacket())
	lines := RenderLines(board, 2)
	if len(lines) != 2 || lines[0] != "Board  1 cards" || lines[1] != "> needs you  fix auth" {
		t.Fatalf("rendered lines = %#v", lines)
	}
}

func TestDecodeBoardZoomedCardID(t *testing.T) {
	board, _, size := DecodeBoard(zoomedBoardPacket())
	if size != len(zoomedBoardPacket()) {
		t.Fatalf("size = %d, want %d", size, len(zoomedBoardPacket()))
	}
	if board.Visible {
		t.Fatalf("zoomed board should report Visible=false, got %#v", board)
	}
	if board.ZoomedCardID != 7 {
		t.Fatalf("ZoomedCardID = %d, want 7", board.ZoomedCardID)
	}
	card := board.ZoomedCard()
	if card == nil || card.ID != 7 || card.Task != "fix auth" {
		t.Fatalf("ZoomedCard = %#v", card)
	}
}

func TestDecodeBoardLegacyPacketWithoutTrailer(t *testing.T) {
	board, _, size := DecodeBoard(legacyBoardPacket())
	if size != len(legacyBoardPacket()) {
		t.Fatalf("size = %d, want %d", size, len(legacyBoardPacket()))
	}
	if board.ZoomedCardID != 0 {
		t.Fatalf("legacy packet should leave ZoomedCardID=0, got %d", board.ZoomedCardID)
	}
	if board.ZoomedCard() != nil {
		t.Fatalf("legacy packet should have no zoomed card")
	}
}

func TestZoomHeaderLine(t *testing.T) {
	board, _, _ := DecodeBoard(zoomedBoardPacket())
	const width = 60
	line := ZoomHeaderLine(board, width)
	if line == "" {
		t.Fatalf("expected a zoom header line for a zoomed board")
	}
	if got := []rune(line); len(got) != width {
		t.Fatalf("zoom header width = %d, want %d: %q", len(got), width, line)
	}
	wantLeft := " ● fix auth · claude-4"
	if got := string([]rune(line)[:len([]rune(wantLeft))]); got != wantLeft {
		t.Fatalf("zoom header left = %q, want %q", got, wantLeft)
	}
	if want := "ESC back to Board "; line[len(line)-len(want):] != want {
		t.Fatalf("zoom header should end with %q, got %q", want, line)
	}
}

func TestZoomHeaderLineEmptyWhenNotZoomed(t *testing.T) {
	board, _, _ := DecodeBoard(boardPacket())
	if line := ZoomHeaderLine(board, 40); line != "" {
		t.Fatalf("non-zoomed board should produce no header, got %q", line)
	}
}
