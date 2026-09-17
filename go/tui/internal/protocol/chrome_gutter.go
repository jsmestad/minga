package protocol

import "fmt"

func decodeGutter(payload []byte) (Gutter, string, int) {
	if len(payload) < 2 {
		return Gutter{DecodeError: "short gutter envelope"}, "", len(payload)
	}

	gutter := Gutter{}
	sawWindow := false
	sawConfig := false
	sawDenseEntries := false
	sawResidentHeader := false
	sawOverrideChunk := false
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		if len(payload) < offset+3 {
			gutter.DecodeError = "short gutter section header"
			return gutter, gutterSummary(gutter), len(payload)
		}
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		offset += 3
		if len(payload) < offset+sectionLen {
			gutter.DecodeError = "short gutter section payload"
			return gutter, gutterSummary(gutter), len(payload)
		}
		section := payload[offset : offset+sectionLen]
		offset += sectionLen

		switch sectionID {
		case 0x01:
			sawWindow = sawWindow || len(section) >= 11
			decodeGutterWindow(section, &gutter)
		case 0x02:
			sawConfig = sawConfig || len(section) >= 7
			decodeGutterConfig(section, &gutter)
		case 0x03:
			decodeGutterEntries(section, &gutter)
			sawDenseEntries = true
		case 0x04:
			if sawResidentHeader || sawDenseEntries || !decodeResidentGutterHeader(section, &gutter) {
				gutter.DecodeError = "malformed resident gutter header"
				continue
			}
			sawResidentHeader = true
		case 0x05:
			if !sawResidentHeader || gutter.Resident == nil || gutter.Resident.RetainOverrides || !decodeResidentGutterOverrides(section, gutter.Resident) {
				gutter.DecodeError = "malformed resident gutter overrides"
				continue
			}
			sawOverrideChunk = true
		}
	}
	if sawResidentHeader && sawDenseEntries {
		gutter.DecodeError = "mixed dense and resident gutter entries"
	}
	if sawResidentHeader && (!sawWindow || !sawConfig) {
		gutter.DecodeError = "resident gutter missing window or config section"
	}
	if gutter.Resident != nil && !gutter.Resident.RetainOverrides && !sawOverrideChunk {
		gutter.DecodeError = "resident gutter snapshot missing override section"
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

func decodeResidentGutterHeader(section []byte, gutter *Gutter) bool {
	if len(section) != 9 || section[8] > 1 {
		return false
	}
	gutter.Resident = &ResidentGutterEntries{
		ContentEpoch:    u32(section, 0),
		LineCount:       u32(section, 4),
		RetainOverrides: section[8] == 1,
		Overrides:       make(map[uint32]GutterEntry),
	}
	return true
}

func decodeResidentGutterOverrides(section []byte, resident *ResidentGutterEntries) bool {
	if len(section) < 2 {
		return false
	}
	count := int(u16(section, 0))
	offset := 2
	for i := 0; i < count; i++ {
		entry, next, ok := decodeGutterEntry(section, offset)
		if !ok || entry.BufferLine >= resident.LineCount {
			return false
		}
		if _, duplicate := resident.Overrides[entry.BufferLine]; duplicate {
			return false
		}
		resident.Overrides[entry.BufferLine] = entry
		offset = next
	}
	return offset == len(section)
}

func decodeGutterEntry(section []byte, offset int) (GutterEntry, int, bool) {
	if len(section) < offset+10 {
		return GutterEntry{}, offset, false
	}
	entry := GutterEntry{
		BufferLine:  u32(section, offset),
		DisplayType: section[offset+4],
		SignType:    section[offset+5],
		FoldEndLine: u32(section, offset+6),
	}
	offset += 10
	if entry.SignType != 8 {
		return entry, offset, true
	}
	if len(section) < offset+4 {
		return GutterEntry{}, offset, false
	}
	entry.SignFG = u24(section, offset)
	textLen := int(section[offset+3])
	offset += 4
	if len(section) < offset+textLen {
		return GutterEntry{}, offset, false
	}
	entry.SignText = string(section[offset : offset+textLen])
	return entry, offset + textLen, true
}

func gutterSummary(gutter Gutter) string {
	if gutter.WindowID == 0 && gutter.EntryCount() == 0 {
		return ""
	}
	return fmt.Sprintf("window %d, %d rows", gutter.WindowID, gutter.EntryCount())
}
