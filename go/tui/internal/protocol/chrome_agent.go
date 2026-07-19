package protocol

import (
	"encoding/binary"
	"fmt"
	"strings"
)

func decodeAgentContext(payload []byte) (AgentContext, string, int) {
	if len(payload) >= 3 {
		payloadLen := int(u16(payload, 1))
		end := 3 + payloadLen
		if payloadLen >= 12 && len(payload) >= end {
			ctx, task, ok := decodeAgentContextBody(payload[3:end])
			if ok {
				return ctx, task, end
			}
		}
	}
	if len(payload) < 13 {
		return AgentContext{}, "", len(payload)
	}
	ctx, task, ok := decodeAgentContextBody(payload[1:])
	if !ok {
		return ctx, "", len(payload)
	}
	return ctx, task, 1 + agentContextLegacySize(payload[1:])
}

func decodeAgentContextBody(body []byte) (AgentContext, string, bool) {
	if len(body) < 12 {
		return AgentContext{}, "", false
	}
	ctx := AgentContext{Visible: body[0] != 0}
	task, offset, ok := readString16(body, 1)
	if !ok || len(body) < offset+10 {
		return ctx, "", false
	}
	ctx.Task = task
	ctx.Timestamp = binary.BigEndian.Uint64(body[offset : offset+8])
	ctx.Status = body[offset+8]
	ctx.CanApprove = body[offset+9] != 0
	offset += 10
	ctx, offset = decodeAgentContextProgress(ctx, body, offset)
	ctx, offset = decodeAgentContextTodos(ctx, body, offset)
	return ctx, task, true
}

func agentContextLegacySize(body []byte) int {
	if len(body) < 3 {
		return len(body)
	}
	taskLen := int(u16(body, 1))
	size := 3 + taskLen + 10
	return min(size, len(body))
}

func decodeAgentContextProgress(ctx AgentContext, payload []byte, offset int) (AgentContext, int) {
	action, next, ok := readString16(payload, offset)
	if !ok || len(payload) < next+4 {
		return ctx, offset
	}
	ctx.Progress.ActiveAction = action
	ctx.Progress.ToolCount = u16(payload, next)
	ctx.Progress.FileCount = u16(payload, next+2)
	next += 4
	reviewHint, next, ok := readString16(payload, next)
	if !ok {
		return ctx, offset
	}
	ctx.Progress.ReviewHint = reviewHint
	return ctx, next
}

func decodeAgentContextTodos(ctx AgentContext, payload []byte, offset int) (AgentContext, int) {
	if len(payload) < offset+1 {
		return ctx, offset
	}
	count := int(payload[offset])
	offset++
	ctx.Todos = make([]AgentTodo, 0, count)
	for i := 0; i < count && len(payload) > offset; i++ {
		todo := AgentTodo{Status: payload[offset]}
		offset++
		var ok bool
		todo.Description, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		ctx.Todos = append(ctx.Todos, todo)
	}
	return ctx, offset
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
			chat = decodeAgentPrompt(chat, section)
		case 0x04:
			chat.Pending = decodeAgentPending(section)
		case 0x07:
			chat.Completion = decodeAgentCompletion(section)
		case 0x08:
			if value, _, ok := readString16(section, 0); ok {
				chat.ThinkingLevel = value
			}
		case 0x09:
			if len(section) >= 1 {
				chat.InputFocused = section[0] != 0
			}
		}
	}
	return chat, chat.ModelName, size
}

func decodeAgentPrompt(chat AgentChat, section []byte) AgentChat {
	value, offset, ok := readString16(section, 0)
	if !ok {
		return chat
	}
	chat.Prompt = value
	if len(section) >= offset+7 {
		chat.PromptLineCount = section[offset]
		chat.PromptCursorLine = u16(section, offset+1)
		chat.PromptCursorCol = u16(section, offset+3)
		chat.PromptVimMode = section[offset+5]
		chat.PromptVisibleRows = section[offset+6]
	}
	return chat
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

// decodeAgentMessageBody decodes a message from its id and its kind-first body
// (the shared per-message body codec, <<kind::8, ...>>). The 0x86 resident
// transcript frames the id separately and hands the raw body straight in.
func decodeAgentMessageBody(id uint32, body []byte) (AgentChatMessage, bool) {
	if len(body) < 1 {
		return AgentChatMessage{}, false
	}
	msg := AgentChatMessage{ID: id, Kind: body[0]}
	offset := 1
	switch msg.Kind {
	case 0x01, 0x02:
		text, ok := decodeAgentTextBody(body, offset)
		msg.Text = text
		return msg, ok
	case 0x03:
		if len(body) < offset+5 {
			return msg, false
		}
		msg.Collapsed = body[offset] != 0
		size := int(u32(body, offset+1))
		offset += 5
		if len(body) != offset+size {
			return msg, false
		}
		msg.Text = string(body[offset : offset+size])
	case 0x04:
		return decodeToolCallMessage(msg, body, offset, false)
	case 0x05:
		if len(body) < offset+5 {
			return msg, false
		}
		msg.Status = body[offset]
		size := int(u32(body, offset+1))
		offset += 5
		if len(body) != offset+size {
			return msg, false
		}
		msg.Text = string(body[offset : offset+size])
	case 0x06:
		if len(body) != offset+20 {
			return msg, false
		}
		msg.Usage = AgentUsage{Input: u32(body, offset), Output: u32(body, offset+4), CacheRead: u32(body, offset+8), CacheWrite: u32(body, offset+12), CostMicros: u32(body, offset+16)}
		msg.Text = fmt.Sprintf("usage in:%d out:%d", msg.Usage.Input, msg.Usage.Output)
	case 0x07:
		lines, next, ok := decodeStyledLines(body, offset)
		if !ok || next != len(body) {
			return msg, false
		}
		msg.StyledLines = lines
		msg.Text = plainStyledLines(lines)
	case 0x08:
		return decodeToolCallMessage(msg, body, offset, true)
	case 0x09:
		return decodeApprovalMessage(msg, body, offset)
	case 0x0A:
		blocks, next, ok := decodeMarkdownBlocks(body, offset)
		if !ok || next != len(body) {
			return msg, false
		}
		msg.MarkdownBlocks = blocks
		msg.Text = plainMarkdownBlocks(blocks)
	}
	return msg, true
}

func decodeAgentTextBody(body []byte, offset int) (string, bool) {
	if len(body) < offset+4 {
		return "", false
	}
	size := int(u32(body, offset))
	offset += 4
	if len(body) != offset+size {
		return "", false
	}
	return string(body[offset : offset+size]), true
}

func decodeToolCallMessage(msg AgentChatMessage, body []byte, offset int, styled bool) (AgentChatMessage, bool) {
	if len(body) < offset+7 {
		return msg, false
	}
	msg.Status = body[offset]
	msg.IsError = body[offset+1] != 0
	msg.Collapsed = body[offset+2] != 0
	msg.DurationMS = u32(body, offset+3)
	offset += 7

	name, next, ok := readString16(body, offset)
	if !ok {
		return msg, false
	}
	msg.Name = name
	summary, next, ok := readString16(body, next)
	if !ok {
		return msg, false
	}
	msg.Summary = summary
	msg.Text = strings.TrimSpace(name + " " + summary)

	if styled {
		lines, afterLines, ok := decodeStyledLines(body, next)
		if !ok {
			return msg, false
		}
		msg.StyledLines = lines
		if text := plainStyledLines(lines); text != "" {
			msg.Result = text
		}
		next = afterLines
		if len(body) > next {
			msg.AutoApprovedScope = body[next]
			next++
		}
		return decodeToolPreview(msg, body, next)
	}

	if len(body) < next+4 {
		return msg, false
	}
	resultLen := int(u32(body, next))
	next += 4
	if len(body) < next+resultLen {
		return msg, false
	}
	msg.Result = string(body[next : next+resultLen])
	next += resultLen
	if len(body) > next {
		msg.AutoApprovedScope = body[next]
		next++
	}
	return decodeToolPreview(msg, body, next)
}

func decodeToolPreview(msg AgentChatMessage, body []byte, offset int) (AgentChatMessage, bool) {
	if len(body) == offset {
		return msg, true
	}
	if len(body) < offset+3 {
		return msg, false
	}
	msg.PreviewKind = body[offset]
	lineCount := int(u16(body, offset+1))
	offset += 3
	msg.PreviewLines = make([]string, 0, lineCount)
	for i := 0; i < lineCount; i++ {
		line, next, ok := readString16(body, offset)
		if !ok {
			return msg, false
		}
		msg.PreviewLines = append(msg.PreviewLines, line)
		offset = next
	}
	return msg, offset == len(body)
}

func decodeApprovalMessage(msg AgentChatMessage, body []byte, offset int) (AgentChatMessage, bool) {
	if len(body) < offset+1 {
		return msg, false
	}
	msg.Status = body[offset]
	offset++

	name, next, ok := readString16(body, offset)
	if !ok {
		return msg, false
	}
	msg.Name = name
	summary, next, ok := readString16(body, next)
	if !ok {
		return msg, false
	}
	msg.Summary = summary
	toolCallID, next, ok := readString16(body, next)
	if !ok {
		return msg, false
	}
	if toolCallID != "" {
		msg.Result = toolCallID
	}
	msg.Text = strings.TrimSpace(name + " " + summary)
	return decodeToolPreview(msg, body, next)
}

func decodeStyledLines(body []byte, offset int) ([]AgentStyledLine, int, bool) {
	if len(body) < offset+2 {
		return nil, offset, false
	}
	count := int(u16(body, offset))
	offset += 2
	lines := make([]AgentStyledLine, 0, count)
	for i := 0; i < count; i++ {
		if len(body) < offset+2 {
			return lines, offset, false
		}
		runCount := int(u16(body, offset))
		offset += 2
		line := make(AgentStyledLine, 0, runCount)
		for j := 0; j < runCount; j++ {
			text, next, ok := readString16(body, offset)
			if !ok || len(body) < next+7 {
				return lines, offset, false
			}
			run := AgentStyledRun{Text: text, FG: u24(body, next), BG: u24(body, next+3), Flags: body[next+6]}
			offset = next + 7
			if run.Flags&0x08 != 0 {
				url, next, ok := readString16(body, offset)
				if !ok {
					return lines, offset, false
				}
				run.URL = url
				offset = next
			}
			line = append(line, run)
		}
		lines = append(lines, line)
	}
	return lines, offset, true
}

func decodeMarkdownBlocks(body []byte, offset int) ([]AgentMarkdownBlock, int, bool) {
	if len(body) < offset+2 {
		return nil, offset, false
	}
	count := int(u16(body, offset))
	offset += 2
	blocks := make([]AgentMarkdownBlock, 0, count)
	for i := 0; i < count; i++ {
		if len(body) < offset+6 {
			return blocks, offset, false
		}
		block := AgentMarkdownBlock{ID: u32(body, offset), Kind: body[offset+4], Flags: body[offset+5], Height: 1}
		offset += 6
		switch block.Kind {
		case 0x01, 0x04:
			lines, next, ok := decodeStyledLines(body, offset)
			if !ok {
				return blocks, offset, false
			}
			block.Lines = lines
			offset = next
		case 0x02:
			if len(body) < offset+1 {
				return blocks, offset, false
			}
			block.Level = body[offset]
			lines, next, ok := decodeStyledLines(body, offset+1)
			if !ok {
				return blocks, offset, false
			}
			block.Lines = lines
			offset = next
		case 0x03:
			if len(body) < offset+6 {
				return blocks, offset, false
			}
			block.Indent = body[offset]
			block.Ordered = body[offset+1] != 0
			block.Ordinal = u32(body, offset+2)
			lines, next, ok := decodeStyledLines(body, offset+6)
			if !ok {
				return blocks, offset, false
			}
			block.Lines = lines
			offset = next
		case 0x05:
		case 0x06:
			if len(body) < offset+1 {
				return blocks, offset, false
			}
			block.Height = body[offset]
			offset++
		case 0x07:
			var ok bool
			block.Language, offset, ok = readString16(body, offset)
			if !ok {
				return blocks, offset, false
			}
			block.Label, offset, ok = readString16(body, offset)
			if !ok {
				return blocks, offset, false
			}
			block.TargetPath, offset, ok = readString16(body, offset)
			if !ok || len(body) < offset+1 {
				return blocks, offset, false
			}
			block.CapabilityFlags = body[offset]
			offset++
			lines, next, ok := decodeStyledLines(body, offset)
			if !ok {
				return blocks, offset, false
			}
			block.Lines = lines
			offset = next
		default:
			return blocks, offset, false
		}
		blocks = append(blocks, block)
	}
	return blocks, offset, true
}

func plainMarkdownBlocks(blocks []AgentMarkdownBlock) string {
	parts := make([]string, 0, len(blocks))
	for _, block := range blocks {
		switch block.Kind {
		case 0x05:
			parts = append(parts, "---")
		case 0x06:
			parts = append(parts, "")
		default:
			text := plainStyledLines(block.Lines)
			if text != "" {
				parts = append(parts, text)
			}
		}
	}
	return strings.Join(parts, "\n")
}

func plainStyledLines(lines []AgentStyledLine) string {
	plainLines := make([]string, 0, len(lines))
	for _, line := range lines {
		parts := make([]string, 0, len(line))
		for _, run := range line {
			parts = append(parts, run.Text)
		}
		plainLines = append(plainLines, stringsJoin(parts, ""))
	}
	return stringsJoin(plainLines, " ")
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
	timeline, offset = decodeTimelineFiles(timeline, body, offset)
	return timeline, fmt.Sprintf("%d edits", len(timeline.Entries)), size
}

func decodeTimelineFiles(timeline EditTimeline, body []byte, offset int) (EditTimeline, int) {
	if len(body) < offset+1 {
		return timeline, offset
	}
	count := int(body[offset])
	offset++
	timeline.Files = make([]TimelineFile, 0, count)
	for i := 0; i < count && len(body) >= offset+12; i++ {
		file := TimelineFile{}
		var ok bool
		file.Path, offset, ok = readString16(body, offset)
		if !ok || len(body) < offset+10 {
			break
		}
		file.EntryCount = body[offset]
		file.LinesAdded = u32(body, offset+1)
		file.LinesRemoved = u32(body, offset+5)
		file.ReviewStatus = body[offset+9]
		offset += 10
		timeline.Files = append(timeline.Files, file)
	}
	return timeline, offset
}
