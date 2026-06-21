package protocol

import (
	"encoding/binary"
	"fmt"
	"strings"
)

func decodeExtensionOverlay(payload []byte) (ExtensionOverlay, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return ExtensionOverlay{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 1 {
		return ExtensionOverlay{}, "", size
	}
	count := int(body[0])
	offset := 1
	overlay := ExtensionOverlay{Entries: make([]ExtensionOverlayEntry, 0, count)}
	for i := 0; i < count && len(body) >= offset+16; i++ {
		entry := ExtensionOverlayEntry{}
		var ok bool
		entry.Extension, offset, ok = readString8(body, offset)
		if !ok {
			break
		}
		entry.ID, offset, ok = readString8(body, offset)
		if !ok || len(body) < offset+12 {
			break
		}
		entry.WindowID = u16(body, offset)
		entry.Row = u16(body, offset+2)
		entry.Col = u16(body, offset+4)
		entry.Shape = body[offset+6]
		entry.FG = u24(body, offset+7)
		entry.Opacity = body[offset+10]
		offset += 11
		entry.Content, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		overlay.Entries = append(overlay.Entries, entry)
	}
	return overlay, fmt.Sprintf("%d overlays", len(overlay.Entries)), size
}

func decodeNotifications(payload []byte) (Notifications, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return Notifications{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 3 {
		return Notifications{}, "", size
	}
	notes := Notifications{Visible: body[0] != 0}
	count := int(u16(body, 1))
	offset := 3
	notes.Items = make([]Notification, 0, count)
	for i := 0; i < count; i++ {
		note, next, ok := decodeNotification(body, offset)
		if !ok {
			break
		}
		notes.Items = append(notes.Items, note)
		offset = next
	}
	return notes, fmt.Sprintf("%d notifications", len(notes.Items)), size
}

func decodeNotification(payload []byte, offset int) (Notification, int, bool) {
	note := Notification{}
	var ok bool
	note.ID, offset, ok = readString16(payload, offset)
	if !ok || len(payload) < offset+22 {
		return note, offset, false
	}
	note.Level = payload[offset]
	note.Dismissable = payload[offset+1]&0x01 != 0
	note.CreatedAt = binary.BigEndian.Uint64(payload[offset+2 : offset+10])
	note.UpdatedAt = binary.BigEndian.Uint64(payload[offset+10 : offset+18])
	note.AutoDismissMS = u32(payload, offset+18)
	offset += 22
	note.Title, offset, ok = readString16(payload, offset)
	if !ok {
		return note, offset, false
	}
	note.Body, offset, ok = readString16(payload, offset)
	if !ok {
		return note, offset, false
	}
	note.Source, offset, ok = readString16(payload, offset)
	if !ok || len(payload) < offset+1 {
		return note, offset, false
	}
	count := int(payload[offset])
	offset++
	note.Actions = make([]NotificationAction, 0, count)
	for i := 0; i < count; i++ {
		action := NotificationAction{}
		action.ID, offset, ok = readString16(payload, offset)
		if !ok {
			return note, offset, false
		}
		action.Label, offset, ok = readString16(payload, offset)
		if !ok {
			return note, offset, false
		}
		note.Actions = append(note.Actions, action)
	}
	return note, offset, true
}

func decodeBottomPanel(payload []byte) (BottomPanel, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return BottomPanel{}, "", min(len(payload), 2)
	}
	if len(payload) < 7 {
		return BottomPanel{Visible: true}, "", len(payload)
	}
	panel := BottomPanel{Visible: true, ActiveTab: payload[2], HeightPercent: payload[3], Filter: payload[4]}
	count := int(payload[5])
	offset := 6
	panel.Tabs = make([]PanelTab, 0, count)
	for i := 0; i < count && len(payload) >= offset+2; i++ {
		tab := PanelTab{Type: payload[offset]}
		offset++
		var ok bool
		tab.Name, offset, ok = readString8(payload, offset)
		if !ok {
			break
		}
		panel.Tabs = append(panel.Tabs, tab)
	}
	if len(payload) < offset+6 {
		return panel, bottomPanelSummary(panel), offset
	}
	panel.StreamInstance = u32(payload, offset)
	msgCount := int(u16(payload, offset+4))
	offset += 6
	panel.Messages = make([]PanelMessage, 0, msgCount)
	for i := 0; i < msgCount && len(payload) >= offset+14; i++ {
		msg := PanelMessage{ID: u32(payload, offset), Level: payload[offset+4], Subsystem: payload[offset+5], Timestamp: u32(payload, offset+6)}
		offset += 10
		var ok bool
		msg.Path, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		msg.Text, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		panel.Messages = append(panel.Messages, msg)
	}
	return panel, bottomPanelSummary(panel), offset
}

func bottomPanelSummary(panel BottomPanel) string {
	tab := ""
	if len(panel.Tabs) > int(panel.ActiveTab) {
		tab = panel.Tabs[panel.ActiveTab].Name
	}
	return strings.TrimSpace(fmt.Sprintf("%s %d messages", tab, len(panel.Messages)))
}

func decodeExtensionPanel(payload []byte) (ExtensionPanel, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return ExtensionPanel{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 1 {
		return ExtensionPanel{}, "", size
	}
	count := int(body[0])
	offset := 1
	panel := ExtensionPanel{Panels: make([]ExtensionPanelEntry, 0, count)}
	for i := 0; i < count; i++ {
		entry, next, ok := decodeExtensionPanelEntry(body, offset)
		if !ok {
			break
		}
		panel.Panels = append(panel.Panels, entry)
		offset = next
	}
	return panel, fmt.Sprintf("%d extension panels", len(panel.Panels)), size
}

func decodeExtensionPanelEntry(body []byte, offset int) (ExtensionPanelEntry, int, bool) {
	entry := ExtensionPanelEntry{}
	var ok bool
	entry.Extension, offset, ok = readString8(body, offset)
	if !ok {
		return entry, offset, false
	}
	entry.ID, offset, ok = readString8(body, offset)
	if !ok {
		return entry, offset, false
	}
	entry.Title, offset, ok = readString8(body, offset)
	if !ok || len(body) < offset+5 {
		return entry, offset, false
	}
	entry.Position = body[offset]
	entry.SizeType = body[offset+1]
	entry.SizeValue = body[offset+2]
	entry.Visible = body[offset+3] != 0
	count := int(body[offset+4])
	offset += 5
	entry.Blocks = make([]string, 0, count)
	for i := 0; i < count && offset < len(body); i++ {
		text, next, ok := decodePanelBlock(body, offset)
		if !ok {
			break
		}
		if text != "" {
			entry.Blocks = append(entry.Blocks, text)
		}
		offset = next
	}
	return entry, offset, true
}

func decodePanelBlock(body []byte, offset int) (string, int, bool) {
	if len(body) < offset+1 {
		return "", offset, false
	}
	kind := body[offset]
	offset++
	switch kind {
	case 0:
		return readString16(body, offset)
	case 1:
		if len(body) < offset+1 {
			return "", offset, false
		}
		count := int(body[offset])
		offset++
		parts := make([]string, 0, count)
		for i := 0; i < count; i++ {
			text, next, ok := readString16(body, offset)
			if !ok || len(body) < next+5 {
				return stringsJoin(parts, ""), offset, false
			}
			parts = append(parts, text)
			offset = next + 5
		}
		return stringsJoin(parts, ""), offset, true
	case 2:
		if len(body) < offset+5 {
			return "table", offset, false
		}
		cols := int(body[offset])
		rows := int(u16(body, offset+1))
		offset += 5
		headers := make([]string, 0, cols)
		var ok bool
		for i := 0; i < cols; i++ {
			var header string
			header, offset, ok = readString16(body, offset)
			if !ok {
				return "table", offset, false
			}
			headers = append(headers, header)
		}
		for i := 0; i < rows*cols; i++ {
			_, offset, ok = readString16(body, offset)
			if !ok {
				return stringsJoin(headers, "  "), offset, false
			}
		}
		return stringsJoin(headers, "  "), offset, true
	case 3:
		if len(body) < offset+1 {
			return "", offset, false
		}
		count := int(body[offset])
		offset++
		pairs := make([]string, 0, count)
		for i := 0; i < count; i++ {
			key, next, ok := readString16(body, offset)
			if !ok {
				return stringsJoin(pairs, "  "), offset, false
			}
			value, next, ok := readString16(body, next)
			if !ok {
				return stringsJoin(pairs, "  "), offset, false
			}
			pairs = append(pairs, key+": "+value)
			offset = next
		}
		return stringsJoin(pairs, "  "), offset, true
	case 4:
		return "-----", offset, true
	case 5:
		label, next, ok := readString16(body, offset)
		if !ok || len(body) < next+2 {
			return label, next, ok
		}
		return fmt.Sprintf("%s %d%%", label, u16(body, next)), next + 2, true
	case 6:
		if len(body) < offset+2 {
			return "tree", offset, false
		}
		size := int(u16(body, offset))
		offset += 2
		if len(body) < offset+size {
			return "tree", offset, false
		}
		return "tree", offset + size, true
	case 255:
		return "", offset, true
	default:
		return "", offset, true
	}
}

func decodeSidebars(payload []byte) (Sidebars, string, int) {
	size := payloadLen32Size(payload)
	if size == 0 {
		return Sidebars{}, "", len(payload)
	}
	body := payload[5:size]
	if len(body) < 3 {
		return Sidebars{}, "", size
	}
	sidebars := Sidebars{Visible: body[0] != 0}
	count := int(u16(body, 1))
	offset := 3
	var ok bool
	sidebars.ActiveID, offset, ok = readString16(body, offset)
	if !ok {
		return sidebars, "", size
	}
	sidebars.Items = make([]Sidebar, 0, count)
	for i := 0; i < count; i++ {
		sidebar := Sidebar{}
		sidebar.ID, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		sidebar.DisplayName, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		sidebar.SemanticKind, offset, ok = readString16(body, offset)
		if !ok {
			break
		}
		sidebar.Icon, offset, ok = readString16(body, offset)
		if !ok || len(body) < offset+7 {
			break
		}
		sidebar.Order = u16(body, offset)
		sidebar.Flags = body[offset+2]
		sidebar.PreferredWidth = u16(body, offset+3)
		sidebar.BadgeCount = u16(body, offset+5)
		sidebar.Visible = sidebar.Flags&0x01 != 0
		sidebar.Focused = sidebar.Flags&0x02 != 0
		offset += 7
		sidebars.Items = append(sidebars.Items, sidebar)
	}
	return sidebars, fmt.Sprintf("%d sidebars", len(sidebars.Items)), size
}

func decodeObservatory(payload []byte) (Observatory, string, int) {
	size := payloadLen32Size(payload)
	if size == 0 {
		return Observatory{}, "", len(payload)
	}
	body := payload[5:size]
	obs := Observatory{}
	offset := 0
	for offset+3 <= len(body) {
		sectionID := body[offset]
		sectionLen := int(u16(body, offset+1))
		offset += 3
		if len(body) < offset+sectionLen {
			return obs, observatorySummary(obs), size
		}
		section := body[offset : offset+sectionLen]
		offset += sectionLen
		switch sectionID {
		case 0x01:
			if len(section) >= 3 {
				obs.Visible = section[0] != 0
				obs.Count = u16(section, 1)
			}
		case 0x02:
			obs.Nodes = append(obs.Nodes, decodeObservatoryNodes(section)...)
		}
	}
	return obs, observatorySummary(obs), size
}

func decodeObservatoryNodes(section []byte) []ObservatoryNode {
	nodes := []ObservatoryNode{}
	offset := 0
	for offset < len(section) {
		node := ObservatoryNode{}
		var ok bool
		node.PID, offset, ok = readString8(section, offset)
		if !ok {
			break
		}
		node.ParentPID, offset, ok = readString8(section, offset)
		if !ok {
			break
		}
		node.Name, offset, ok = readString16(section, offset)
		if !ok || len(section) < offset+12 {
			break
		}
		node.ProcessClass = section[offset]
		node.Depth = section[offset+1]
		node.Memory = u32(section, offset+2)
		node.MessageQueueLen = u16(section, offset+6)
		node.Reductions = u32(section, offset+8)
		offset += 12
		nodes = append(nodes, node)
	}
	return nodes
}

func observatorySummary(obs Observatory) string {
	count := int(obs.Count)
	if count == 0 {
		count = len(obs.Nodes)
	}
	return fmt.Sprintf("%d processes", count)
}
