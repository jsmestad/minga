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
