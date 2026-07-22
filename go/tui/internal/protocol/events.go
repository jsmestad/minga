package protocol

import "github.com/jsmestad/minga/go/tui/internal/generated"

const (
	ModShift byte = 0x01
	ModCtrl  byte = 0x02
	ModAlt   byte = 0x04
	ModSuper byte = 0x08
)

// Mouse event types for the eventType byte of EncodeMouseEvent, matching the
// BEAM's decode_mouse_event_type (frontend/protocol.ex) and the macOS encoder
// (ProtocolConstants.swift). The BEAM treats a held-button drag (MouseDrag)
// and a free-pointer motion (MouseMotion) differently: only MouseDrag extends
// a selection; MouseMotion drives hover. The frontend must send the correct one.
const (
	MousePress   byte = 0x00
	MouseRelease byte = 0x01
	MouseMotion  byte = 0x02
	MouseDrag    byte = 0x03
)

// Log levels for EncodeLogMessage, matching the BEAM's decode_log_level.
const (
	LogLevelErr   byte = 0
	LogLevelWarn  byte = 1
	LogLevelInfo  byte = 2
	LogLevelDebug byte = 3
)

// EncodeLogMessage encodes a log_message event so the BEAM routes renderer
// diagnostics into Minga's *Messages* buffer, matching the Zig renderer.
// Wire format: <0x60, level:u8, msg_len:u16, msg>. The message is truncated to
// the u16 length ceiling.
func EncodeLogMessage(level byte, msg string) []byte {
	if len(msg) > 0xFFFF {
		msg = msg[:0xFFFF]
	}
	out := make([]byte, 0, 4+len(msg))
	out = append(out, generated.OPLogMessage, level, byte(len(msg)>>8), byte(len(msg)))
	return append(out, msg...)
}

func EncodeReady(width, height uint16) []byte {
	return []byte{
		generated.OPReady,
		byte(width >> 8), byte(width),
		byte(height >> 8), byte(height),
		2,          // capability format version
		20,         // original 7 fields plus resource-policy tail
		0,          // frontend_type: tui
		2,          // color_depth: rgb
		1,          // unicode_width: unicode_15
		0,          // image_support: none
		0,          // float_support: emulated
		0,          // text_rendering: monospace
		1,          // semantic_ui: true
		1,          // resource_policy_version
		4, 0, 0, 0, // max_frame_bytes: 64 MiB, enforced by ReadPacket
		0, 0, 0, 0, // max_frame_commands: unadvertised
		0, 0, 0, 0, // max_window_rows: unadvertised
		// protocol_version (u16): the wire contract this frontend was generated
		// against. The BEAM rejects a mismatch with an explicit protocol_error.
		byte(generated.ProtocolVersion >> 8), byte(generated.ProtocolVersion),
	}
}

func EncodeResize(width, height uint16) []byte {
	return []byte{generated.OPResize, byte(width >> 8), byte(width), byte(height >> 8), byte(height)}
}

// EncodeRequestKeyframe asks the BEAM to manually retry with a full keyframe.
// Automatic invalidation recovery uses frame_rejected alone; emitting both would
// advance the BEAM recovery generation twice. last_good_frame_seq is the last
// frame the frontend committed cleanly (informational under single-client scope;
// the BEAM forces the next frame full regardless). Wire format: fixed:5 =
// opcode(1) + last_good_frame_seq(u32), matching protocol.ex decode_event/1.
func EncodeRequestKeyframe(lastGoodFrameSeq, generation uint32) []byte {
	return []byte{
		generated.OPRequestKeyframe,
		byte(lastGoodFrameSeq >> 24), byte(lastGoodFrameSeq >> 16), byte(lastGoodFrameSeq >> 8), byte(lastGoodFrameSeq),
		byte(generation >> 24), byte(generation >> 16), byte(generation >> 8), byte(generation),
	}
}

const (
	RejectTruncation             byte = 1
	RejectCommitSequence         byte = 2
	RejectFrameSequence          byte = 3
	RejectBaseSequence           byte = 4
	RejectMissingTheme           byte = 5
	RejectIncompleteTheme        byte = 6
	RejectMissingWindowReference byte = 7
	RejectWindowEpoch            byte = 8
	RejectInvalidRetainedRows    byte = 9
	RejectMissingFont            byte = 10
	RejectTranscriptDesync       byte = 11
	RejectDecodeFailure          byte = 12
	RejectOutOfTransaction       byte = 13
	RejectInvalidRowSplice       byte = byte(generated.FrameRejectionReasonInvalidRowSplice)
	RejectResourcePolicy         byte = byte(generated.FrameRejectionReasonResourcePolicy)
)

// RejectionDisposition is generated from the shared schema vocabulary.
type RejectionDisposition = generated.FrameRejectionDisposition

const (
	DispositionRetryable = generated.FrameRejectionDispositionRetryableRecovery
	DispositionTargeted  = generated.FrameRejectionDispositionTargetedReplacement
	DispositionAdapted   = generated.FrameRejectionDispositionAdaptedRetry
	DispositionTerminal  = generated.FrameRejectionDispositionTerminalFrontendFailure
)

func EncodeFrameApplied(generation, frameSeq uint32) []byte {
	return encodeFrameStatus(generated.OPFrameApplied, generation, frameSeq)
}

func EncodeFrameRejected(generation, frameSeq, lastApplied uint32, reason byte, disposition RejectionDisposition) []byte {
	out := encodeFrameStatus(generated.OPFrameRejected, generation, frameSeq)
	out = append(out, byte(lastApplied>>24), byte(lastApplied>>16), byte(lastApplied>>8), byte(lastApplied), reason, byte(disposition))
	return out
}

// DefaultRejectionDisposition makes deterministic resource-policy failure terminal.
func DefaultRejectionDisposition(reason byte) RejectionDisposition {
	if reason == RejectResourcePolicy {
		return DispositionTerminal
	}
	return DispositionRetryable
}

func EncodeWindowRefMiss(generation, frameSeq, lastApplied uint32, windowID uint16) []byte {
	out := encodeFrameStatus(generated.OPWindowRefMiss, generation, frameSeq)
	return append(out, byte(lastApplied>>24), byte(lastApplied>>16), byte(lastApplied>>8), byte(lastApplied), byte(windowID>>8), byte(windowID))
}

func encodeFrameStatus(op byte, generation, frameSeq uint32) []byte {
	return []byte{op,
		byte(generation >> 24), byte(generation >> 16), byte(generation >> 8), byte(generation),
		byte(frameSeq >> 24), byte(frameSeq >> 16), byte(frameSeq >> 8), byte(frameSeq),
	}
}

// EncodeKeyPress encodes a key press carrying a u32 input correlation sequence
// (ticket #2215) appended after the modifiers byte. The BEAM echoes the sequence
// on commit_frame so the frontend can resolve an end-to-end keystroke-to-write
// latency sample. A sequence of 0 means "no correlation".
func EncodeKeyPress(codepoint rune, modifiers byte, seq uint32) []byte {
	value := uint32(codepoint)
	return []byte{
		generated.OPKeyPress,
		byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value),
		modifiers,
		byte(seq >> 24), byte(seq >> 16), byte(seq >> 8), byte(seq),
	}
}

func EncodeMouseEvent(row, col int16, button, mods, eventType, clickCount byte) []byte {
	return []byte{
		generated.OPMouseEvent,
		byte(uint16(row) >> 8), byte(row),
		byte(uint16(col) >> 8), byte(col),
		button,
		mods,
		eventType,
		clickCount,
	}
}

func EncodeGUIFileTreeClick(index uint16) []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionFileTreeClick, byte(index >> 8), byte(index)}
}

func EncodeGUISelectTab(id uint32) []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionSelectTab, byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)}
}

// EncodeGUITabReorder encodes a tab_reorder action. Wire format:
// <gui_action, 0x48, tab_id:u32, new_index:u16>. Moves the visible tab `id` to
// the zero-based slot `newIndex`, mirroring the macOS encoder
// (ProtocolEncoder.swift sendTabReorder) and the BEAM decoder
// (gui.ex decode_gui_action @gui_action_tab_reorder).
func EncodeGUITabReorder(id uint32, newIndex uint16) []byte {
	return []byte{
		generated.OPGuiAction, generated.GUIActionTabReorder,
		byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id),
		byte(newIndex >> 8), byte(newIndex),
	}
}

// EncodeGUIFileTreeDrop encodes a file_tree_drop action. Wire format:
// <gui_action, 0x40, target_index:u16, target_path_hash:u32, target_kind:u8,
// modifiers:u8, target_id(string16), target_path(string16), source_count:u16,
// source_paths(string16)...>. target_kind is 1 for a directory, 0 for a file.
// The BEAM validates the drop against its own tree by re-hashing the target
// path, so target_path_hash must be the per-row hash the BEAM emitted for the
// target row (FileTreeRow.PathHash), and target_id/target_path must match that
// row. Mirrors the macOS encoder (ProtocolEncoder.swift sendFileTreeDrop) and
// the BEAM decoder (gui.ex decode_file_tree_drop).
func EncodeGUIFileTreeDrop(targetIndex uint16, targetPathHash uint32, targetIsDir bool, modifiers byte, targetID, targetPath string, sourcePaths []string) []byte {
	out := []byte{generated.OPGuiAction, generated.GUIActionFileTreeDrop}
	out = append(out, byte(targetIndex>>8), byte(targetIndex))
	out = append(out, byte(targetPathHash>>24), byte(targetPathHash>>16), byte(targetPathHash>>8), byte(targetPathHash))
	if targetIsDir {
		out = append(out, 1)
	} else {
		out = append(out, 0)
	}
	out = append(out, modifiers)
	out = appendString16(out, targetID)
	out = appendString16(out, targetPath)
	count := len(sourcePaths)
	if count > 0xFFFF {
		count = 0xFFFF
	}
	out = append(out, byte(count>>8), byte(count))
	for _, path := range sourcePaths[:count] {
		out = appendString16(out, path)
	}
	return out
}

func EncodeGUIExecuteCommand(command string) []byte {
	payload := []byte(command)
	if len(payload) > 65535 {
		payload = payload[:65535]
	}
	out := []byte{generated.OPGuiAction, generated.GUIActionExecuteCommand, byte(len(payload) >> 8), byte(len(payload))}
	return append(out, payload...)
}

func EncodeGUIAgentToolToggle(messageID uint32) []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionAgentToolToggle, byte(messageID >> 24), byte(messageID >> 16), byte(messageID >> 8), byte(messageID)}
}

// EncodeGUICompletionSelect encodes a completion_select action. Wire format:
// <gui_action, 0x05, index:u16>. The GUI sends the selected completion item
// index (CompletionOverlay.swift:93).
func EncodeGUICompletionSelect(index uint16) []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionCompletionSelect, byte(index >> 8), byte(index)}
}

// EncodeGUIHoverOpenAction encodes a hover_open_action. Wire format:
// <gui_action, 0x3F> with an empty payload, matching the GUI accept gesture
// (HoverPopupOverlay.swift:123).
func EncodeGUIHoverOpenAction() []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionHoverOpenAction}
}

// EncodeGUISidebarAction encodes a sidebar_action. Wire format:
// <gui_action, 0x57, sidebar_id_len:u16, sidebar_id, kind_len:u16, kind,
// action_len:u16, action>. Mirrors NativeSidebarRegistry's primary action,
// which sends "activate" for an inactive sidebar and "toggle" for the active
// one (NativeSidebarRegistry.swift:64, ProtocolEncoder.swift:624).
func EncodeGUISidebarAction(sidebarID, kind, action string) []byte {
	out := []byte{generated.OPGuiAction, generated.GUIActionSidebarAction}
	out = appendString16(out, sidebarID)
	out = appendString16(out, kind)
	out = appendString16(out, action)
	return out
}

// EncodeGUINotificationDismiss encodes a notification_dismiss action. Wire
// format: <gui_action, 0x45, id_len:u16, id>. Mirrors the macOS dismiss button
// (ProtocolEncoder.swift:1085 sendNotificationDismiss).
func EncodeGUINotificationDismiss(id string) []byte {
	out := []byte{generated.OPGuiAction, generated.GUIActionNotificationDismiss}
	return appendString16(out, id)
}

// EncodeGUINotificationAction encodes a notification_action. Wire format:
// <gui_action, 0x46, id_len:u16, id, action_len:u16, action_id>. Mirrors the
// macOS per-action button (ProtocolEncoder.swift:1094 sendNotificationAction).
func EncodeGUINotificationAction(id, actionID string) []byte {
	out := []byte{generated.OPGuiAction, generated.GUIActionNotificationAction}
	out = appendString16(out, id)
	return appendString16(out, actionID)
}

// EncodeGUIObservatoryInspect encodes an observatory_inspect action. Wire
// format: <gui_action, 0x4D, pid_len:u16, pid>. Mirrors the macOS info-circle
// button (ProtocolEncoder.swift:1104 sendObservatoryInspect): a click on an
// observatory row sends the node's BEAM PID string, which the BEAM resolves into
// the inspection float popup. An empty pid dismisses the inspection.
func EncodeGUIObservatoryInspect(pid string) []byte {
	out := []byte{generated.OPGuiAction, generated.GUIActionObservatoryInspect}
	return appendString16(out, pid)
}

// EncodeGUITimelineNavigate encodes a timeline_navigate action. Wire format:
// <gui_action, 0x4F, index:u16 big-endian>. Mirrors the macOS timeline circle
// tap (ProtocolEncoder.swift:1123 sendTimelineNavigate): a click on a timeline
// entry sends that entry's index, the same destination the keyboard
// timeline_next_edit/timeline_prev_edit commands land on.
func EncodeGUITimelineNavigate(index uint16) []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionTimelineNavigate, byte(index >> 8), byte(index)}
}

// EncodeGUIFloatPopupDismiss encodes a float_popup_dismiss action. Wire format:
// <gui_action, 0x59> with an empty payload (#2338). There is no macOS sender:
// the macOS FloatPopupOverlay is display-only with no dismiss gesture, so this
// is a TUI-originated intent that maps to the same BEAM dismiss the keyboard
// quit key reaches (MingaEditor.Input.Popup). A click in the float popup's
// overlay band but outside the rendered popup content sends it; the BEAM clears
// the observatory inspection float or closes the :float popup window.
func EncodeGUIFloatPopupDismiss() []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionFloatPopupDismiss}
}

// EncodeGUIEmptyStateActivate encodes an empty_state_activate action. Wire
// format: <gui_action, 0x5B, id_len:u8, id> (#2689). The BEAM decodes the item
// id as a string8 (gui.ex decode_gui_action @gui_action_empty_state_activate:
// <<len::8, id::binary-size(len)>>), so the id is u8-prefixed, unlike the
// string16 gui_actions. Activation is authoritative on the BEAM: the frontend
// only echoes the clicked/selected row's item id.
func EncodeGUIEmptyStateActivate(itemID string) []byte {
	payload := []byte(itemID)
	if len(payload) > 255 {
		payload = payload[:255]
	}
	out := []byte{generated.OPGuiAction, generated.GUIActionEmptyStateActivate, byte(len(payload))}
	return append(out, payload...)
}

// EncodeGUIChatScrolledAwayFromBottom reports that the agent-chat transcript
// left the bottom (the reader scrolled up), so the BEAM disengages follow-bottom
// (#2654). Zero payload: the frontend owns the local scroll offset and only
// reports the pin transition so the BEAM's authoritative state matches.
func EncodeGUIChatScrolledAwayFromBottom() []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionChatScrolledAwayFromBottom}
}

// EncodeGUIChatReturnedToBottom reports that the transcript returned to the
// bottom (follow-bottom re-engaged). Pairs with the scrolled-away report (#2654).
func EncodeGUIChatReturnedToBottom() []byte {
	return []byte{generated.OPGuiAction, generated.GUIActionChatReturnedToBottom}
}

// appendString16 appends a length-prefixed string (len:u16 big-endian, then
// utf8 bytes) to out, truncating to the u16 ceiling, matching the macOS
// appendString16 helper used by every string-bearing gui_action.
func appendString16(out []byte, value string) []byte {
	payload := []byte(value)
	if len(payload) > 65535 {
		payload = payload[:65535]
	}
	out = append(out, byte(len(payload)>>8), byte(len(payload)))
	return append(out, payload...)
}

// EncodeGUIFoldToggleAtLine encodes a fold_toggle_at_line action. Wire format:
// <gui_action, 0x41, window_id:u16, buffer_line:u32>, matching the macOS encoder
// (ProtocolEncoder.swift sendFoldToggleAtLine) and the BEAM decoder
// (gui.ex decode_gui_action @gui_action_fold_toggle_at_line).
func EncodeGUIFoldToggleAtLine(windowID uint16, bufferLine uint32) []byte {
	return []byte{
		generated.OPGuiAction, generated.GUIActionFoldToggleAtLine,
		byte(windowID >> 8), byte(windowID),
		byte(bufferLine >> 24), byte(bufferLine >> 16), byte(bufferLine >> 8), byte(bufferLine),
	}
}

func EncodeScrollBatch(windowID uint16, deltaLines int16, direction byte) []byte {
	return []byte{
		generated.OPScrollBatch,
		byte(windowID >> 8), byte(windowID),
		byte(uint16(deltaLines) >> 8), byte(deltaLines),
		direction,
	}
}

func EncodePaste(text string) []byte {
	payload := []byte(text)
	if len(payload) > 65535 {
		payload = payload[:65535]
	}
	return append([]byte{generated.OPPasteEvent, byte(len(payload) >> 8), byte(len(payload))}, payload...)
}
