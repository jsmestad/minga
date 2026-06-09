package board

import (
	"encoding/binary"
	"fmt"
)

// Board is the extension-owned copy of the experimental Board semantic payload. It was moved out of go/tui core so Charm parity does not require Board-specific rendering.
type Board struct {
	Visible       bool
	FocusedCardID uint32
	FilterMode    bool
	FilterText    string
	Cards         []BoardCard
}

// BoardCard is one Board card in the extension-owned legacy GUI payload.
type BoardCard struct {
	ID          uint32
	Status      byte
	Flags       byte
	Task        string
	Model       string
	Timestamp   uint32
	RecentFiles []string
}

// DecodeBoard decodes the legacy gui_board payload owned by the Board extension.
func DecodeBoard(payload []byte) (Board, string, int) {
	if len(payload) < 11 {
		return Board{}, "", len(payload)
	}
	count := int(binary.BigEndian.Uint16(payload[6:8]))
	board := Board{Visible: payload[1] != 0, FocusedCardID: binary.BigEndian.Uint32(payload[2:6]), FilterMode: payload[8] != 0}
	var ok bool
	offset := 9
	board.FilterText, offset, ok = readString16(payload, offset)
	if !ok {
		return board, "", len(payload)
	}
	board.Cards = make([]BoardCard, 0, count)
	for i := 0; i < count; i++ {
		if len(payload) < offset+11 {
			return board, "", len(payload)
		}
		card := BoardCard{ID: binary.BigEndian.Uint32(payload[offset : offset+4]), Status: payload[offset+4], Flags: payload[offset+5]}
		offset += 6
		card.Task, offset, ok = readString16(payload, offset)
		if !ok || len(payload) < offset+5 {
			return board, "", len(payload)
		}
		modelLen := int(payload[offset])
		offset++
		if len(payload) < offset+modelLen+5 {
			return board, "", len(payload)
		}
		card.Model = string(payload[offset : offset+modelLen])
		offset += modelLen
		card.Timestamp = binary.BigEndian.Uint32(payload[offset : offset+4])
		offset += 4
		fileCount := int(payload[offset])
		offset++
		card.RecentFiles = make([]string, 0, fileCount)
		for j := 0; j < fileCount; j++ {
			file, next, ok := readString16(payload, offset)
			if !ok {
				return board, "", len(payload)
			}
			card.RecentFiles = append(card.RecentFiles, file)
			offset = next
		}
		if len(payload) < offset+1 {
			return board, "", len(payload)
		}
		sparklineCount := int(payload[offset])
		offset++
		if len(payload) < offset+sparklineCount*2 {
			return board, "", len(payload)
		}
		offset += sparklineCount * 2
		board.Cards = append(board.Cards, card)
	}
	return board, fmt.Sprintf("%d cards", len(board.Cards)), offset
}

func readString16(payload []byte, offset int) (string, int, bool) {
	if len(payload) < offset+2 {
		return "", offset, false
	}
	length := int(binary.BigEndian.Uint16(payload[offset : offset+2]))
	offset += 2
	if len(payload) < offset+length {
		return "", offset, false
	}
	return string(payload[offset : offset+length]), offset + length, true
}
