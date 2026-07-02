package protocol

import "fmt"

// Resident agent transcript transport (gui_agent_transcript, 0x86, #2654).
//
// This carries the resident conversation (the display_start_index-scoped
// conversation, byte-capped by the encoder to a contiguous most-recent suffix)
// so a frontend scrolls the session from local data without a BEAM round-trip.
// The per-message body reuses the shared AgentChatMessageCodec, so a message
// decodes byte-identically to the 0x78 messages section (see
// decodeAgentMessageBody). See docs/GUI_PROTOCOL.md "0x86 — gui_agent_transcript"
// for the authoritative wire contract.
//
// Wire payload (after the len32 opcode + u32 length framing):
//
//	version(1) = 1
//	mode(1)              # 0 = full_replace, 1 = append
//	epoch(4)
//	truncated(1)         # 1 when older messages sit outside the resident window
//	# full_replace (mode 0):
//	count(4)
//	# append (mode 1):
//	trim_front(4)        # leading messages evicted from the store front this delta
//	base_count(4)        # unchanged leading messages of the remainder to keep
//	count(4)
//	# both modes:
//	count * [ id(4) + body_len(4) + body(body_len) ]
const (
	transcriptVersion     = 1
	transcriptModeReplace = 0
	transcriptModeAppend  = 1
	// Fixed header before the mode-specific counts: version + mode + epoch + truncated.
	transcriptHeaderLength = 7
)

// AgentTranscript is one decoded gui_agent_transcript frame: a full snapshot or
// an incremental delta the resident store folds. It is not the store itself; the
// store (residentTranscript in the ui package) applies successive frames.
type AgentTranscript struct {
	// Present is false when the frame could not be decoded (short/garbled); the
	// store leaves its prior state untouched rather than clobbering it.
	Present   bool
	Version   byte
	Mode      byte
	Epoch     uint32
	Truncated bool
	// TrimFront is the number of messages evicted from the store front this delta
	// (append only; 0 for full_replace).
	TrimFront uint32
	// BaseCount is the number of unchanged leading messages of the remainder to
	// keep after the trim_front drop (append only; 0 for full_replace).
	BaseCount uint32
	Messages  []AgentChatMessage
}

// FullReplace reports whether this frame swaps the whole store (first frame of an
// epoch, epoch change, or a non-prefix divergence the encoder resent as full).
func (t AgentTranscript) FullReplace() bool { return t.Mode == transcriptModeReplace }

func decodeAgentTranscript(payload []byte) (AgentTranscript, string, int) {
	// len32 framing: [opcode][len:u32][body]. command_size already validated the
	// total length, but decode defensively so a truncated survivor cannot panic.
	if len(payload) < 5 {
		return AgentTranscript{}, "", len(payload)
	}
	length := int(u32(payload, 1))
	end := 5 + length
	if end > len(payload) {
		end = len(payload)
	}
	body := payload[5:end]
	if len(body) < transcriptHeaderLength {
		return AgentTranscript{}, "", end
	}

	transcript := AgentTranscript{
		Present:   true,
		Version:   body[0],
		Mode:      body[1],
		Epoch:     u32(body, 2),
		Truncated: body[6] != 0,
	}
	offset := transcriptHeaderLength

	var count int
	if transcript.Mode == transcriptModeAppend {
		if len(body) < offset+12 {
			return AgentTranscript{}, "", end
		}
		transcript.TrimFront = u32(body, offset)
		transcript.BaseCount = u32(body, offset+4)
		count = int(u32(body, offset+8))
		offset += 12
	} else {
		if len(body) < offset+4 {
			return AgentTranscript{}, "", end
		}
		count = int(u32(body, offset))
		offset += 4
	}

	transcript.Messages = make([]AgentChatMessage, 0, count)
	for i := 0; i < count && len(body) >= offset+8; i++ {
		id := u32(body, offset)
		bodyLen := int(u32(body, offset+4))
		offset += 8
		if len(body) < offset+bodyLen {
			break
		}
		if msg, ok := decodeAgentMessageBody(id, body[offset:offset+bodyLen]); ok {
			transcript.Messages = append(transcript.Messages, msg)
		}
		offset += bodyLen
	}

	summary := fmt.Sprintf("transcript epoch:%d %s %d messages", transcript.Epoch, transcriptModeName(transcript.Mode), len(transcript.Messages))
	return transcript, summary, end
}

func transcriptModeName(mode byte) string {
	if mode == transcriptModeAppend {
		return "append"
	}
	return "full_replace"
}
