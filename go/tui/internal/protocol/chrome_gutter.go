package protocol

import "fmt"

func decodeGutter(payload []byte) (Gutter, string, int) {
	if len(payload) < 2 {
		return Gutter{}, "", len(payload)
	}

	gutter := Gutter{}
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		if len(payload) < offset+3 {
			return gutter, gutterSummary(gutter), len(payload)
		}
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		offset += 3
		if len(payload) < offset+sectionLen {
			return gutter, gutterSummary(gutter), len(payload)
		}
		section := payload[offset : offset+sectionLen]
		offset += sectionLen

		switch sectionID {
		case 0x01:
			decodeGutterWindow(section, &gutter)
		case 0x02:
			decodeGutterConfig(section, &gutter)
		case 0x03:
			decodeGutterEntries(section, &gutter)
		}
	}

	return gutter, gutterSummary(gutter), offset
}

func decodeGutterWindow(section []byte, gutter *Gutter) {
	if len(section) < 11 {
		return
	}
	gutter.WindowID = u16(section, 0)
	gutter.ContentRow = u16(section, 2)
	gutter.ContentCol = u16(section, 4)
	gutter.ContentHeight = u16(section, 6)
	gutter.Active = section[8] != 0
	gutter.ContentWidth = u16(section, 9)
}

func decodeGutterConfig(section []byte, gutter *Gutter) {
	if len(section) < 7 {
		return
	}
	gutter.CursorLine = u32(section, 0)
	gutter.LineNumberStyle = section[4]
	gutter.LineNumberWidth = section[5]
	gutter.SignColWidth = section[6]
}

func decodeGutterEntries(section []byte, gutter *Gutter) {
	if len(section) < 2 {
		return
	}
	count := int(u16(section, 0))
	offset := 2
	entries := make([]GutterEntry, 0, count)
	for i := 0; i < count && len(section) >= offset+10; i++ {
		entry := GutterEntry{
			BufferLine:  u32(section, offset),
			DisplayType: section[offset+4],
			SignType:    section[offset+5],
			FoldEndLine: u32(section, offset+6),
		}
		offset += 10
		if entry.SignType == 8 && len(section) >= offset+4 {
			entry.SignFG = u24(section, offset)
			textLen := int(section[offset+3])
			offset += 4
			if len(section) < offset+textLen {
				break
			}
			entry.SignText = string(section[offset : offset+textLen])
			offset += textLen
		}
		entries = append(entries, entry)
	}
	gutter.Entries = entries
}

func gutterSummary(gutter Gutter) string {
	if gutter.WindowID == 0 && len(gutter.Entries) == 0 {
		return ""
	}
	return fmt.Sprintf("window %d, %d rows", gutter.WindowID, len(gutter.Entries))
}
