package protocol

import (
	"fmt"
	"strings"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func decodeTabBar(payload []byte) (TabBar, string, int) {
	if len(payload) < 3 {
		return TabBar{}, "", len(payload)
	}

	tabBar := TabBar{ActiveIndex: payload[1]}
	count := int(payload[2])
	offset := 3
	labels := make([]string, 0, count)
	tabBar.Tabs = make([]Tab, 0, count)

	for i := 0; i < count && len(payload) >= offset+8; i++ {
		flags := payload[offset]
		id := u32(payload, offset+1)
		groupID := u16(payload, offset+5)
		offset += 1 + 4 + 2
		icon, next, ok := readString8(payload, offset)
		if !ok {
			break
		}
		offset = next
		label, next, ok := readString16(payload, offset)
		if !ok || len(payload) < next+4 {
			break
		}
		tint := u32(payload, next)
		offset = next + 4
		// Bits 4-6 are kind-scoped: agent status for agent tabs, ephemeral
		// (not-on-disk) marker in bit 4 for file tabs.
		isAgent := flags&0x04 != 0
		agentStatus := byte(0)
		if isAgent {
			agentStatus = (flags >> 4) & 0x07
		}
		tab := Tab{
			Flags:       flags,
			ID:          id,
			GroupID:     groupID,
			Icon:        icon,
			Label:       label,
			Tint:        tint,
			Active:      flags&0x01 != 0,
			Dirty:       flags&0x02 != 0,
			Agent:       isAgent,
			Attention:   flags&0x08 != 0,
			AgentStatus: agentStatus,
			Ephemeral:   !isAgent && flags&0x10 != 0,
			Pinned:      flags&0x80 != 0,
		}
		tabBar.Tabs = append(tabBar.Tabs, tab)
		prefix := " "
		if byte(i) == tabBar.ActiveIndex || tab.Active {
			prefix = "*"
		}
		labels = append(labels, prefix+icon+" "+label)
	}

	return tabBar, stringsJoin(labels, "  "), offset
}

func decodeWorkspaces(payload []byte) (WorkspaceBar, string, int) {
	if len(payload) < 3 {
		return WorkspaceBar{}, "", len(payload)
	}
	size := 3 + int(u16(payload, 1))
	if len(payload) < size {
		return WorkspaceBar{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 6 {
		return WorkspaceBar{}, "", size
	}

	bar := WorkspaceBar{
		Version:  body[0],
		ActiveID: u16(body, 1),
		Mode:     body[3],
		Flags:    body[4],
	}
	offset := 6
	count := int(body[5])
	labels := make([]string, 0, count)
	bar.Spaces = make([]Workspace, 0, count)
	for i := 0; i < count && len(body) >= offset+19; i++ {
		space := Workspace{
			ID:              u16(body, offset),
			Kind:            body[offset+2],
			Status:          body[offset+3],
			Flags:           u16(body, offset+4),
			Color:           u24(body, offset+6),
			TabCount:        u16(body, offset+9),
			DraftCount:      u16(body, offset+11),
			ConflictCount:   u16(body, offset+13),
			BackgroundCount: u16(body, offset+15),
		}
		offset += 17
		label, next, ok := readString8(body, offset)
		if !ok {
			break
		}
		space.Label = label
		icon, next, ok := readString8(body, next)
		if !ok {
			break
		}
		offset = next
		space.Icon = icon
		space.Active = space.ID == bar.ActiveID
		space.Attention = space.Flags&0x01 != 0
		space.Closeable = space.Flags&0x02 != 0
		bar.Spaces = append(bar.Spaces, space)
		prefix := " "
		if space.Active {
			prefix = "*"
		}
		labels = append(labels, fmt.Sprintf("%s%s %s", prefix, space.Icon, space.Label))
	}
	if len(body) < offset+2 {
		return bar, stringsJoin(labels, "  "), size
	}
	tabCount := int(u16(body, offset))
	offset += 2
	bar.Tabs = make([]WorkspaceTab, 0, tabCount)
	for i := 0; i < tabCount && len(body) >= offset+18; i++ {
		tab := WorkspaceTab{
			ID:          u32(body, offset),
			WorkspaceID: u16(body, offset+4),
			Kind:        body[offset+6],
			Flags:       u16(body, offset+7),
			PathHash:    u32(body, offset+9),
		}
		offset += 13
		var ok bool
		tab.Icon, offset, ok = readString8(body, offset)
		if !ok {
			break
		}
		tab.Label, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		tab.Path, offset, ok = readString16(body, offset)
		if !ok || len(body) < offset+4 {
			break
		}
		tab.Tint = u32(body, offset)
		offset += 4
		bar.Tabs = append(bar.Tabs, tab)
	}
	return bar, stringsJoin(labels, "  "), size
}

func decodeMinibuffer(payload []byte) (Minibuffer, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return Minibuffer{}, "", min(len(payload), 2)
	}
	if len(payload) < 6 {
		return Minibuffer{Visible: true}, "", len(payload)
	}

	mini := Minibuffer{
		Visible:   true,
		Mode:      payload[2],
		CursorPos: u16(payload, 3),
	}
	offset := 5
	prompt, next, ok := readString8(payload, offset)
	if !ok {
		return mini, "", len(payload)
	}
	mini.Prompt = prompt
	input, next, ok := readString16(payload, next)
	if !ok {
		return mini, "", len(payload)
	}
	mini.Input = input
	context, next, ok := readString16(payload, next)
	if !ok || len(payload) < next+6 {
		return mini, "", len(payload)
	}
	mini.Context = context
	mini.SelectedIndex = u16(payload, next)
	mini.Candidates = u16(payload, next+2)
	mini.Total = u16(payload, next+4)
	return mini, strings.TrimSpace(prompt + input + " " + context), len(payload)
}

func decodeFileTree(payload []byte) (FileTree, string, int) {
	if len(payload) < 5 {
		return FileTree{}, "", len(payload)
	}

	size := 5 + int(u32(payload, 1))
	if len(payload) < size {
		return FileTree{}, "", len(payload)
	}
	body := payload[5:size]
	if len(body) < 3 {
		return FileTree{}, "", size
	}

	flags := body[1]
	status := body[2]
	tree := FileTree{Visible: flags&0x01 != 0, Focused: flags&0x02 != 0, Flags: flags, Status: status}
	offset := 3
	selected, next, ok := readString16(body, offset)
	if !ok {
		return tree, "", size
	}
	tree.Selected = selected
	root, next, ok := readString16(body, next)
	if !ok || len(body) < next+4 {
		return tree, "", size
	}
	tree.Root = root
	tree.Width = u16(body, next)
	rowCount := int(u16(body, next+2))
	next += 4
	errorReason, next, ok := readString16(body, next)
	if ok {
		tree.Error = errorReason
		tree.Rows = decodeFileTreeRows(body, next, rowCount)
	}
	statusText := map[byte]string{0: "hidden", 1: "loading", 2: "empty", 3: "ready", 4: "error"}[status]
	if selected != "" {
		return tree, fmt.Sprintf("%s %s (%d)", statusText, selected, rowCount), size
	}
	return tree, fmt.Sprintf("%s %s (%d)", statusText, root, rowCount), size
}

func decodeFileTreeRows(body []byte, offset int, count int) []FileTreeRow {
	rows := make([]FileTreeRow, 0, count)
	for i := 0; i < count && len(body) >= offset+17; i++ {
		flags := u16(body, offset+4)
		row := FileTreeRow{
			PathHash:  u32(body, offset),
			Flags:     flags,
			Depth:     body[offset+6],
			Directory: flags&0x01 != 0,
			Expanded:  flags&0x02 != 0,
			Selected:  flags&0x04 != 0,
			Focused:   flags&0x08 != 0,
			Active:    flags&0x10 != 0,
			Dirty:     flags&0x20 != 0,
		}
		offset += 17
		if len(body) < offset {
			break
		}
		guideCount := int(body[offset-1])
		offset += guideCount
		var ok bool
		row.ID, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		row.Path, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		_, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		row.Name, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		row.Icon, offset, ok = readString8(body, offset)
		if !ok || len(body) < offset+1 {
			break
		}
		offset++
		_, offset, ok = readString16(body, offset)
		if !ok || len(body) < offset+4 {
			break
		}
		// Per-row icon color (R,G,B) follows the editing payload and is applied by the UI renderer.
		row.IconColor = uint32(body[offset])<<16 | uint32(body[offset+1])<<8 | uint32(body[offset+2])
		offset += 3
		// Trailing heat-level byte (extension familiarity tint). Consumed for
		// framing; TUI heat rendering is deferred, so the value is not stored.
		offset++
		rows = append(rows, row)
	}
	return rows
}

func decodeStatus(payload []byte) (StatusBar, string, int) {
	size := sectionedSize(payload)
	if size == 0 {
		return StatusBar{}, "", len(payload)
	}

	status := StatusBar{}
	parts := make([]string, 0, 4)
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		offset += 3
		section := payload[offset : offset+sectionLen]
		offset += sectionLen

		switch sectionID {
		case 0x01:
			if len(section) >= 3 {
				status.ContentKind = section[0]
				status.Mode = section[1]
				status.Flags = section[2]
			}
		case 0x02:
			if len(section) >= 12 {
				status.Line = u32(section, 0)
				status.Column = u32(section, 4)
				status.LineCount = u32(section, 8)
				parts = append(parts, fmt.Sprintf("%d:%d", status.Line, status.Column))
			}
		case 0x06:
			icon, filename, filetype, ok := statusFile(section)
			if ok {
				status.Icon = icon
				status.Filename = filename
				status.Filetype = filetype
				parts = append(parts, filename)
			}
		case 0x07:
			if message, _, ok := readString16(section, 0); ok && message != "" {
				status.Message = message
				parts = append(parts, message)
			}
		case 0x0B:
			status.Left, status.Right = decodeStatusSegments(section)
		case 0x0E:
			if keys, _, ok := readString16(section, 0); ok {
				status.PendingKeys = keys
			}
		case 0x0F:
			operation, _, err := generated.DecodeGuiStatusBarOperation(section, 0, len(section))
			if err == nil {
				status.Operation = &operation
			}
		}
	}

	return status, stringsJoin(parts, "  "), size
}

func decodeStatusSegments(section []byte) ([]StatusSegment, []StatusSegment) {
	if len(section) < 5 {
		return nil, nil
	}
	offset := 1
	leftCount := int(u16(section, offset))
	offset += 2
	rightCount := int(u16(section, offset))
	offset += 2
	left, offset := decodeStatusSegmentList(section, offset, leftCount)
	right, _ := decodeStatusSegmentList(section, offset, rightCount)
	return left, right
}

func decodeStatusSegmentList(section []byte, offset int, count int) ([]StatusSegment, int) {
	segments := make([]StatusSegment, 0, count)
	for i := 0; i < count; i++ {
		segment, next, ok := decodeStatusSegment(section, offset)
		if !ok {
			break
		}
		segments = append(segments, segment)
		offset = next
	}
	return segments, offset
}

func decodeStatusSegment(section []byte, offset int) (StatusSegment, int, bool) {
	name, offset, ok := readString8(section, offset)
	if !ok || len(section) < offset+7 {
		return StatusSegment{}, offset, false
	}
	segment := StatusSegment{Name: name, FG: u24(section, offset), BG: u24(section, offset+3), Attrs: section[offset+6]}
	offset += 7
	segment.Text, offset, ok = readString16(section, offset)
	if !ok {
		return StatusSegment{}, offset, false
	}
	segment.Command, offset, ok = readString16(section, offset)
	return segment, offset, ok
}

func statusFile(section []byte) (string, string, string, bool) {
	if len(section) < 1 {
		return "", "", "", false
	}
	icon, offset, ok := readString8(section, 0)
	if !ok || len(section) < offset+3 {
		return "", "", "", false
	}
	offset += 3
	filename, offset, ok := readString16(section, offset)
	if !ok {
		return "", "", "", false
	}
	filetype, _, ok := readString8(section, offset)
	return icon, filename, filetype, ok
}

func decodeTheme(payload []byte) (Theme, string, int) {
	if len(payload) < 2 {
		return Theme{}, "", len(payload)
	}
	count := int(payload[1])
	offset := 2
	theme := Theme{Colors: map[byte]uint32{}}
	for i := 0; i < count && len(payload) >= offset+4; i++ {
		theme.Colors[payload[offset]] = u24(payload, offset+1)
		offset += 4
	}
	return theme, fmt.Sprintf("%d colors", len(theme.Colors)), offset
}

func decodeBreadcrumb(payload []byte) (Breadcrumb, string, int) {
	if len(payload) < 2 {
		return Breadcrumb{}, "", len(payload)
	}
	count := int(payload[1])
	offset := 2
	crumb := Breadcrumb{Segments: make([]string, 0, count)}
	for i := 0; i < count; i++ {
		segment, next, ok := readString16(payload, offset)
		if !ok {
			break
		}
		crumb.Segments = append(crumb.Segments, segment)
		offset = next
	}
	return crumb, stringsJoin(crumb.Segments, " / "), offset
}

func decodeGitStatus(payload []byte) (GitStatus, string, int) {
	if len(payload) < 13 {
		return GitStatus{}, "", len(payload)
	}
	git := GitStatus{
		RepoState: payload[1],
		Syncing:   payload[2] != 0,
		Ahead:     u16(payload, 3),
		Behind:    u16(payload, 5),
	}
	offset := 7
	branch, next, ok := readString16(payload, offset)
	if !ok || len(payload) < next+2 {
		return git, "", len(payload)
	}
	git.Branch = branch
	count := int(u16(payload, next))
	offset = next + 2
	git.Entries = make([]GitStatusEntry, 0, count)
	for i := 0; i < count && len(payload) >= offset+9; i++ {
		entry := GitStatusEntry{PathHash: u32(payload, offset), Section: payload[offset+4], Status: payload[offset+5]}
		offset += 6
		entry.Path, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		git.Entries = append(git.Entries, entry)
	}
	if len(payload) < offset+1 {
		return git, gitSummary(git), offset
	}
	if payload[offset] != 0 && len(payload) >= offset+5 {
		git.Toast.Visible = true
		git.Toast.Level = payload[offset+1]
		git.Toast.Action = payload[offset+2]
		git.Toast.Message, offset, ok = readString16(payload, offset+3)
		if !ok {
			return git, gitSummary(git), len(payload)
		}
	} else {
		offset++
	}
	if git.EntryBasePath, offset, ok = readString16(payload, offset); !ok {
		return git, gitSummary(git), len(payload)
	}
	if git.LastCommitMessage, offset, ok = readString16(payload, offset); !ok || len(payload) < offset+2 {
		return git, gitSummary(git), len(payload)
	}
	git.StashCount = u16(payload, offset)
	offset += 2
	return git, gitSummary(git), offset
}

func gitSummary(git GitStatus) string {
	parts := []string{git.Branch}
	if git.Ahead > 0 {
		parts = append(parts, fmt.Sprintf("ahead %d", git.Ahead))
	}
	if git.Behind > 0 {
		parts = append(parts, fmt.Sprintf("behind %d", git.Behind))
	}
	if len(git.Entries) > 0 {
		parts = append(parts, fmt.Sprintf("%d changes", len(git.Entries)))
	}
	if git.StashCount > 0 {
		parts = append(parts, fmt.Sprintf("%d stashes", git.StashCount))
	}
	return stringsJoin(parts, "  ")
}

func decodeSearchState(payload []byte) (SearchState, string, int) {
	if len(payload) < 4 {
		return SearchState{}, "", len(payload)
	}
	size := 3 + int(u16(payload, 1))
	if len(payload) < size || size < 9 {
		return SearchState{}, "", len(payload)
	}
	search := SearchState{Active: payload[3] != 0, Count: u16(payload, 4), CurrentIndex: u16(payload, 6), Flags: payload[8]}
	summary := ""
	if search.Active {
		summary = fmt.Sprintf("%d/%d", search.CurrentIndex, search.Count)
	}
	return search, summary, size
}

func decodeChangeSummary(payload []byte) (ChangeSummary, string, int) {
	if len(payload) < 6 {
		return ChangeSummary{}, "", len(payload)
	}
	change := ChangeSummary{Visible: payload[1] != 0, SelectedIndex: u16(payload, 2)}
	count := int(u16(payload, 4))
	offset := 6
	change.Entries = make([]ChangeEntry, 0, count)
	for i := 0; i < count && len(payload) >= offset+11; i++ {
		entry := ChangeEntry{}
		var ok bool
		entry.Path, offset, ok = readString16(payload, offset)
		if !ok || len(payload) < offset+9 {
			break
		}
		entry.Action = payload[offset]
		entry.LinesAdded = u32(payload, offset+1)
		entry.LinesRemoved = u32(payload, offset+5)
		offset += 9
		change.Entries = append(change.Entries, entry)
	}
	return change, fmt.Sprintf("%d changes", len(change.Entries)), offset
}

func decodeGutterSeparator(payload []byte) (GutterSeparator, string, int) {
	if len(payload) < 6 {
		return GutterSeparator{}, "", len(payload)
	}
	gutter := GutterSeparator{Col: u16(payload, 1), Color: u24(payload, 3)}
	return gutter, fmt.Sprintf("col %d", gutter.Col), 6
}

func decodeSplitSeparators(payload []byte) (SplitSeparators, string, int) {
	if len(payload) < 5 {
		return SplitSeparators{}, "", len(payload)
	}
	splits := SplitSeparators{Color: u24(payload, 1)}
	count := int(payload[4])
	offset := 5
	splits.Verticals = make([]VerticalSeparator, 0, count)
	for i := 0; i < count && len(payload) >= offset+6; i++ {
		splits.Verticals = append(splits.Verticals, VerticalSeparator{Col: u16(payload, offset), StartRow: u16(payload, offset+2), EndRow: u16(payload, offset+4)})
		offset += 6
	}
	if len(payload) < offset+1 {
		return splits, splitSummary(splits), offset
	}
	hCount := int(payload[offset])
	offset++
	splits.Horizontals = make([]HorizontalSeparator, 0, hCount)
	for i := 0; i < hCount && len(payload) >= offset+8; i++ {
		sep := HorizontalSeparator{Row: u16(payload, offset), Col: u16(payload, offset+2), Width: u16(payload, offset+4)}
		offset += 6
		var ok bool
		sep.Filename, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		splits.Horizontals = append(splits.Horizontals, sep)
	}
	return splits, splitSummary(splits), offset
}

func splitSummary(splits SplitSeparators) string {
	return fmt.Sprintf("%d vertical %d horizontal", len(splits.Verticals), len(splits.Horizontals))
}

// decodeEmptyState decodes the gui_empty_state (0xA5) launchpad frame. Framing
// is len16: opcode(1) + payload_len(2) + payload. The payload's first byte is
// the visibility flag; when 0 the frame is a single-byte hide and the rest of
// the struct is absent. Otherwise: flags(1, bit0=crashed), version(string8),
// focused_id(string8), section_count(1), then per section: id(1),
// title(string8), item_count(1), then per item: kind(1), id(string8),
// label(string16), detail(string16), jump_key(string8), chord(string8),
// icon(string8), icon_color(u32). Mirrors the BEAM encoder
// (Minga.Frontend.Adapter.GUI.EmptyStateEncoder).
func decodeEmptyState(payload []byte) (EmptyState, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return EmptyState{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 1 || body[0] == 0 {
		return EmptyState{Visible: false}, "hidden", size
	}

	state := EmptyState{Visible: true}
	if len(body) < 2 {
		return state, "empty", size
	}
	state.Crashed = body[1]&0x01 != 0
	offset := 2

	version, next, ok := readString8(body, offset)
	if !ok {
		return state, "empty", size
	}
	state.Version = version
	offset = next

	focused, next, ok := readString8(body, offset)
	if !ok {
		return state, "empty", size
	}
	state.FocusedID = focused
	offset = next

	if len(body) < offset+1 {
		return state, "empty", size
	}
	sectionCount := int(body[offset])
	offset++

	state.Sections = make([]EmptyStateSection, 0, sectionCount)
	for s := 0; s < sectionCount; s++ {
		if len(body) < offset+1 {
			break
		}
		section := EmptyStateSection{ID: body[offset]}
		offset++

		title, next, ok := readString8(body, offset)
		if !ok {
			break
		}
		section.Title = title
		offset = next

		if len(body) < offset+1 {
			break
		}
		itemCount := int(body[offset])
		offset++

		section.Items = make([]EmptyStateItem, 0, itemCount)
		for i := 0; i < itemCount; i++ {
			item, nextOffset, ok := decodeEmptyStateItem(body, offset)
			if !ok {
				break
			}
			section.Items = append(section.Items, item)
			offset = nextOffset
		}
		state.Sections = append(state.Sections, section)
	}

	return state, fmt.Sprintf("launchpad %d sections", len(state.Sections)), size
}

func decodeEmptyStateItem(body []byte, offset int) (EmptyStateItem, int, bool) {
	if len(body) < offset+1 {
		return EmptyStateItem{}, offset, false
	}
	item := EmptyStateItem{Kind: body[offset]}
	offset++

	id, next, ok := readString8(body, offset)
	if !ok {
		return EmptyStateItem{}, offset, false
	}
	item.ID = id
	offset = next

	label, next, ok := readString16(body, offset)
	if !ok {
		return EmptyStateItem{}, offset, false
	}
	item.Label = label
	offset = next

	detail, next, ok := readString16(body, offset)
	if !ok {
		return EmptyStateItem{}, offset, false
	}
	item.Detail = detail
	offset = next

	jumpKey, next, ok := readString8(body, offset)
	if !ok {
		return EmptyStateItem{}, offset, false
	}
	item.JumpKey = jumpKey
	offset = next

	chord, next, ok := readString8(body, offset)
	if !ok {
		return EmptyStateItem{}, offset, false
	}
	item.Chord = chord
	offset = next

	icon, next, ok := readString8(body, offset)
	if !ok {
		return EmptyStateItem{}, offset, false
	}
	item.Icon = icon
	offset = next

	if len(body) < offset+4 {
		return EmptyStateItem{}, offset, false
	}
	item.IconColor = u32(body, offset)
	offset += 4

	return item, offset, true
}
