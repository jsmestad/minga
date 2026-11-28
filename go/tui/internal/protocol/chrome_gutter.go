package protocol

import (
	"cmp"
	"encoding/binary"
	"fmt"
	"slices"
	"sort"
)

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
		case 0x06:
			if gutter.AuthorshipUpdate != nil || !decodeGutterAuthorshipHeader(section, &gutter) {
				gutter.DecodeError = "malformed gutter authorship header"
			}
		case 0x07, 0x08:
			update := gutter.AuthorshipUpdate
			if update == nil || update.Kind == GutterAuthorshipRetain || (sectionID == 0x08 && update.Kind != GutterAuthorshipPatch) {
				gutter.DecodeError = "unexpected gutter authorship regions"
				continue
			}
			regions := &update.Added
			if sectionID == 0x08 {
				regions = &update.Removed
			}
			if !decodeGutterAuthorshipRegions(section, regions) {
				gutter.DecodeError = "malformed gutter authorship regions"
			}
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
	if gutter.AuthorshipUpdate != nil && (!sawWindow || !sawConfig) {
		gutter.DecodeError = "gutter authorship missing window or config"
	}

	return gutter, gutterSummary(gutter), offset
}

func decodeGutterAuthorshipHeader(section []byte, gutter *Gutter) bool {
	if len(section) != 17 {
		return false
	}
	kind := section[0]
	base, revision := binary.BigEndian.Uint64(section[1:9]), binary.BigEndian.Uint64(section[9:17])
	switch kind {
	case GutterAuthorshipSnapshot:
		if base != 0 || revision == 0 {
			return false
		}
	case GutterAuthorshipRetain:
		if base == 0 || revision != base {
			return false
		}
	case GutterAuthorshipPatch:
		if base == 0 || revision <= base {
			return false
		}
	default:
		return false
	}
	gutter.AuthorshipUpdate = &GutterAuthorshipUpdate{Kind: kind, Base: base, Revision: revision}
	return true
}

func decodeGutterAuthorshipRegions(section []byte, regions *[]AuthoredGutterRegion) bool {
	const wireSize = 21
	if len(section) < 2 || len(section)-2 != int(u16(section, 0))*wireSize {
		return false
	}
	for offset := 2; offset < len(section); offset += wireSize {
		region := AuthoredGutterRegion{
			Role:        section[offset],
			Unit:        binary.BigEndian.Uint64(section[offset+1 : offset+9]),
			FirstLine:   u32(section, offset+9),
			FirstColumn: u32(section, offset+13),
			LastLine:    u32(section, offset+17),
		}
		if region.FirstLine > region.LastLine {
			return false
		}
		switch region.Role {
		case AuthoredGutterPending:
			if region.Unit == 0 {
				return false
			}
		case AuthoredGutterDeletion:
			if region.Unit == 0 || region.FirstLine != region.LastLine {
				return false
			}
		case AuthoredGutterKept, AuthoredGutterYou, AuthoredGutterShared:
			if region.Unit != 0 {
				return false
			}
		default:
			return false
		}
		*regions = append(*regions, region)
	}
	return true
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

type indexedGutterRegion struct {
	AuthoredGutterRegion
	maxLast uint32
}

// ResolveAuthorship resolves a wire update without mutating the committed
// revision. Ordinary cursor and scroll frames retain the existing index.
func (g Gutter) ResolveAuthorship(previous Gutter) (*GutterAuthorship, bool) {
	update := g.AuthorshipUpdate
	if update == nil {
		return nil, true
	}
	var base []indexedGutterRegion
	switch update.Kind {
	case GutterAuthorshipSnapshot:
	case GutterAuthorshipRetain, GutterAuthorshipPatch:
		if g.Resident == nil || previous.Resident == nil ||
			g.Resident.ContentEpoch != previous.Resident.ContentEpoch ||
			previous.Authorship == nil || update.Base != previous.Authorship.Revision {
			return nil, false
		}
		base = previous.Authorship.regions
		if len(update.Added) == 0 && len(update.Removed) == 0 {
			if len(base) != 0 && base[len(base)-1].maxLast >= g.Resident.LineCount {
				return nil, false
			}
			if update.Kind == GutterAuthorshipRetain {
				return previous.Authorship, true
			}
			return &GutterAuthorship{Revision: update.Revision, regions: base}, true
		}
	default:
		return nil, false
	}
	if len(update.Removed) > len(base) {
		return nil, false
	}

	removed := make(map[AuthoredGutterRegion]struct{}, len(update.Removed))
	for _, region := range update.Removed {
		removed[region] = struct{}{}
	}
	if len(removed) != len(update.Removed) {
		return nil, false
	}

	added := slices.Clone(update.Added)
	slices.SortFunc(added, compareAuthoredRegions)
	regions := make([]indexedGutterRegion, 0, len(base)-len(removed)+len(added))
	appendRegion := func(region AuthoredGutterRegion) bool {
		if g.Resident != nil && region.LastLine >= g.Resident.LineCount {
			return false
		}
		maxLast := region.LastLine
		if n := len(regions); n > 0 {
			if regions[n-1].AuthoredGutterRegion == region {
				return false
			}
			maxLast = max(maxLast, regions[n-1].maxLast)
		}
		regions = append(regions, indexedGutterRegion{AuthoredGutterRegion: region, maxLast: maxLast})
		return true
	}
	for _, entry := range base {
		if _, ok := removed[entry.AuthoredGutterRegion]; ok {
			delete(removed, entry.AuthoredGutterRegion)
			continue
		}
		for len(added) > 0 && compareAuthoredRegions(added[0], entry.AuthoredGutterRegion) < 0 {
			if !appendRegion(added[0]) {
				return nil, false
			}
			added = added[1:]
		}
		if !appendRegion(entry.AuthoredGutterRegion) {
			return nil, false
		}
	}
	if len(removed) != 0 {
		return nil, false
	}
	for _, region := range added {
		if !appendRegion(region) {
			return nil, false
		}
	}
	return &GutterAuthorship{Revision: update.Revision, regions: regions}, true
}

func compareAuthoredRegions(a, b AuthoredGutterRegion) int {
	if order := cmp.Compare(a.FirstLine, b.FirstLine); order != 0 {
		return order
	}
	if order := cmp.Compare(a.FirstColumn, b.FirstColumn); order != 0 {
		return order
	}
	if order := cmp.Compare(a.Role, b.Role); order != 0 {
		return order
	}
	if order := cmp.Compare(a.Unit, b.Unit); order != 0 {
		return order
	}
	return cmp.Compare(a.LastLine, b.LastLine)
}

// RegionAt returns the committed strand for a source line. A head on the
// line wins over a body, then kept and human ink. Pending ink on a line
// with human text uses that role for the shade without changing the head.
func (a *GutterAuthorship) RegionAt(line uint32, pin, continuation bool) (region AuthoredGutterRegion, head, shared, ok bool) {
	if a == nil {
		return AuthoredGutterRegion{}, false, false, false
	}
	regions := a.regions
	end := sort.Search(len(regions), func(i int) bool { return regions[i].FirstLine > line })
	start := sort.Search(end, func(i int) bool { return regions[i].maxLast >= line })
	priority := 0
	you := false
	for _, entry := range regions[start:end] {
		if entry.LastLine < line || (continuation && entry.Role == AuthoredGutterDeletion) {
			continue
		}
		rank := 1
		switch entry.Role {
		case AuthoredGutterYou:
			you = true
		case AuthoredGutterKept:
			rank = 2
		case AuthoredGutterShared:
			you = true
			rank = 3
		case AuthoredGutterPending, AuthoredGutterDeletion:
			rank = 4
			if entry.FirstLine == line && !continuation {
				rank = 6
			} else if pin {
				rank = 5
			}
		}
		if rank > priority {
			region, priority = entry.AuthoredGutterRegion, rank
		}
	}
	return region, priority >= 5, you && priority >= 3, priority != 0
}
