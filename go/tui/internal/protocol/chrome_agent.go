package protocol

import (
	"encoding/binary"
	"fmt"
	"strings"
)

func decodeAgentContext(payload []byte) (AgentContext, string, int) {
	if len(payload) < 12 {
		return AgentContext{}, "", len(payload)
	}
	ctx := AgentContext{Visible: payload[1] != 0}
	task, offset, ok := readString16(payload, 2)
	if !ok || len(payload) < offset+10 {
		return ctx, "", len(payload)
	}
	ctx.Task = task
	ctx.Timestamp = binary.BigEndian.Uint64(payload[offset : offset+8])
	ctx.Status = payload[offset+8]
	ctx.CanApprove = payload[offset+9] != 0
	offset += 10
	return ctx, task, offset
}

func decodeAgentChat(payload []byte) (AgentChat, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return AgentChat{}, "", min(len(payload), 2)
	}
	size := sectionedSize(payload)
	if size == 0 {
		return AgentChat{Visible: true}, "", len(payload)
	}
	chat := AgentChat{}
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		offset += 3
		section := payload[offset : offset+sectionLen]
		offset += sectionLen
		switch sectionID {
		case 0x01:
			if len(section) >= 2 {
				chat.Visible = section[0] != 0
				chat.Status = section[1]
			}
		case 0x02:
			if value, _, ok := readString16(section, 0); ok {
				chat.ModelName = value
			}
		case 0x03:
			if value, _, ok := readString16(section, 0); ok {
				chat.Prompt = value
			}
		case 0x04:
			chat.Pending = decodeAgentPending(section)
		case 0x07:
			chat.Completion = decodeAgentCompletion(section)
		case 0x08:
			if value, _, ok := readString16(section, 0); ok {
				chat.ThinkingLevel = value
			}
		case 0x06:
			chat.Messages = decodeAgentMessages(section)
		}
	}
	return chat, fmt.Sprintf("%s %d messages", chat.ModelName, len(chat.Messages)), size
}

func decodeAgentPending(section []byte) string {
	if len(section) < 1 || section[0] == 0 {
		return ""
	}
	name, offset, ok := readString16(section, 1)
	if !ok {
		return ""
	}
	summary, _, ok := readString16(section, offset)
	if !ok {
		return name
	}
	return strings.TrimSpace(name + " " + summary)
}

func decodeAgentCompletion(section []byte) []string {
	if len(section) < 8 || section[0] == 0 {
		return nil
	}
	count := int(section[7])
	offset := 8
	items := make([]string, 0, count)
	for i := 0; i < count; i++ {
		name, next, ok := readString16(section, offset)
		if !ok {
			break
		}
		desc, next, ok := readString16(section, next)
		if !ok {
			break
		}
		items = append(items, strings.TrimSpace(name+" "+desc))
		offset = next
	}
	return items
}

func decodeAgentMessages(section []byte) []AgentChatMessage {
	if len(section) < 4 || section[0] != 0xFF {
		return nil
	}
	count := int(u16(section, 2))
	offset := 4
	messages := make([]AgentChatMessage, 0, count)
	for i := 0; i < count && len(section) >= offset+4; i++ {
		size := int(u32(section, offset))
		offset += 4
		if len(section) < offset+size {
			break
		}
		if msg, ok := decodeAgentMessage(section[offset : offset+size]); ok {
			messages = append(messages, msg)
		}
		offset += size
	}
	return messages
}

func decodeAgentMessage(body []byte) (AgentChatMessage, bool) {
	if len(body) < 5 {
		return AgentChatMessage{}, false
	}
	msg := AgentChatMessage{ID: u32(body, 0), Kind: body[4]}
	offset := 5
	switch msg.Kind {
	case 0x01, 0x02:
		if len(body) < offset+4 {
			return msg, true
		}
		size := int(u32(body, offset))
		offset += 4
		if len(body) >= offset+size {
			msg.Text = string(body[offset : offset+size])
		}
	case 0x03:
		if len(body) < offset+5 {
			return msg, true
		}
		size := int(u32(body, offset+1))
		offset += 5
		if len(body) >= offset+size {
			msg.Text = string(body[offset : offset+size])
		}
	case 0x04:
		if len(body) < offset+7 {
			return msg, true
		}
		offset += 7
		name, next, ok := readString16(body, offset)
		if !ok {
			return msg, true
		}
		summary, _, ok := readString16(body, next)
		if ok {
			msg.Text = strings.TrimSpace(name + " " + summary)
		} else {
			msg.Text = name
		}
	case 0x05:
		if len(body) < offset+5 {
			return msg, true
		}
		size := int(u32(body, offset+1))
		offset += 5
		if len(body) >= offset+size {
			msg.Text = string(body[offset : offset+size])
		}
	case 0x06:
		if len(body) >= offset+20 {
			msg.Text = fmt.Sprintf("usage in:%d out:%d", u32(body, offset), u32(body, offset+4))
		}
	case 0x07:
		msg.Text = decodeStyledLines(body[offset:])
	case 0x08:
		if len(body) < offset+7 {
			return msg, true
		}
		offset += 7
		name, next, ok := readString16(body, offset)
		if !ok {
			return msg, true
		}
		summary, _, ok := readString16(body, next)
		if ok {
			msg.Text = strings.TrimSpace(name + " " + summary)
		} else {
			msg.Text = name
		}
	case 0x09:
		if len(body) < offset+1 {
			return msg, true
		}
		name, next, ok := readString16(body, offset+1)
		if !ok {
			return msg, true
		}
		summary, _, ok := readString16(body, next)
		if ok {
			msg.Text = strings.TrimSpace(name + " " + summary)
		} else {
			msg.Text = name
		}
	}
	return msg, true
}

func decodeStyledLines(body []byte) string {
	if len(body) < 2 {
		return ""
	}
	count := int(u16(body, 0))
	offset := 2
	lines := make([]string, 0, count)
	for i := 0; i < count && len(body) >= offset+2; i++ {
		runCount := int(u16(body, offset))
		offset += 2
		parts := make([]string, 0, runCount)
		for j := 0; j < runCount; j++ {
			text, next, ok := readString16(body, offset)
			if !ok || len(body) < next+7 {
				return stringsJoin(lines, " ")
			}
			flags := body[next+6]
			offset = next + 7
			if flags&0x08 != 0 {
				_, next, ok = readString16(body, offset)
				if !ok {
					return stringsJoin(lines, " ")
				}
				offset = next
			}
			parts = append(parts, text)
		}
		lines = append(lines, stringsJoin(parts, ""))
	}
	return stringsJoin(lines, " ")
}

func decodeBoard(payload []byte) (Board, string, int) {
	if len(payload) < 10 {
		return Board{}, "", len(payload)
	}
	board := Board{Visible: payload[1] != 0, FocusedCardID: u32(payload, 2), FilterMode: payload[8] != 0}
	count := int(u16(payload, 6))
	offset := 9
	var ok bool
	board.FilterText, offset, ok = readString16(payload, offset)
	if !ok {
		return board, "", len(payload)
	}
	board.Cards = make([]BoardCard, 0, count)
	for i := 0; i < count && len(payload) >= offset+16; i++ {
		card := BoardCard{ID: u32(payload, offset), Status: payload[offset+4], Flags: payload[offset+5]}
		offset += 6
		card.Task, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		card.Model, offset, ok = readString8(payload, offset)
		if !ok || len(payload) < offset+5 {
			break
		}
		card.Timestamp = u32(payload, offset)
		fileCount := int(payload[offset+4])
		offset += 5
		card.RecentFiles = make([]string, 0, fileCount)
		for j := 0; j < fileCount; j++ {
			file, next, ok := readString16(payload, offset)
			if !ok {
				break
			}
			card.RecentFiles = append(card.RecentFiles, file)
			offset = next
		}
		if len(payload) < offset+1 {
			break
		}
		sparkCount := int(payload[offset])
		offset += 1 + sparkCount*2
		if len(payload) < offset {
			break
		}
		board.Cards = append(board.Cards, card)
	}
	return board, fmt.Sprintf("%d cards", len(board.Cards)), offset
}

func decodeEditTimeline(payload []byte) (EditTimeline, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return EditTimeline{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 4 {
		return EditTimeline{}, "", size
	}
	timeline := EditTimeline{Visible: body[0] != 0, ViewingIndex: u16(body, 1)}
	count := int(body[3])
	offset := 4
	timeline.Entries = make([]TimelineEntry, 0, count)
	for i := 0; i < count && len(body) >= offset+6; i++ {
		entry := TimelineEntry{Index: body[offset]}
		offset++
		var ok bool
		entry.ToolName, offset, ok = readString8(body, offset)
		if !ok || len(body) < offset+4 {
			break
		}
		entry.TimestampDelta = u32(body, offset)
		offset += 4
		timeline.Entries = append(timeline.Entries, entry)
	}
	return timeline, fmt.Sprintf("%d edits", len(timeline.Entries)), size
}
