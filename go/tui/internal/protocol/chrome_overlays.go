package protocol

import (
	"strings"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func decodeCompletion(payload []byte) (Completion, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return Completion{}, "", min(len(payload), 2)
	}
	if len(payload) < 10 {
		return Completion{Visible: true}, "", len(payload)
	}
	completion := Completion{
		Visible:  true,
		Row:      u16(payload, 2),
		Col:      u16(payload, 4),
		Selected: u16(payload, 6),
	}
	count := int(u16(payload, 8))
	completion.Items = make([]CompletionItem, 0, count)
	offset := 10
	labels := make([]string, 0, count)
	for i := 0; i < count && len(payload) >= offset+5; i++ {
		item := CompletionItem{Kind: payload[offset]}
		offset++
		var ok bool
		item.Label, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		item.Detail, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		completion.Items = append(completion.Items, item)
		labels = append(labels, item.Label)
	}
	// The selected item's documentation preview trails the item list as a
	// string16 (schema: gui_completion conditional_tail). A conformant BEAM
	// always emits it when visible==1 (empty string for items without docs), so
	// consume it as part of this command's bytes. A short/legacy packet that
	// omits it leaves Documentation empty and does not advance the offset.
	if doc, next, ok := readString16(payload, offset); ok {
		completion.Documentation = doc
		offset = next
	}
	return completion, stringsJoin(labels, "  "), offset
}

func decodeWhichKey(payload []byte) (WhichKey, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return WhichKey{}, "", min(len(payload), 2)
	}
	if len(payload) < 8 {
		return WhichKey{Visible: true}, "", len(payload)
	}
	prefix, offset, ok := readString16(payload, 2)
	if !ok || len(payload) < offset+4 {
		return WhichKey{Visible: true}, "", len(payload)
	}
	which := WhichKey{
		Visible:   true,
		Prefix:    prefix,
		Page:      payload[offset],
		PageCount: payload[offset+1],
	}
	count := int(u16(payload, offset+2))
	offset += 4
	which.Bindings = make([]WhichKeyBinding, 0, count)
	summary := make([]string, 0, count)
	for i := 0; i < count && len(payload) >= offset+6; i++ {
		binding := WhichKeyBinding{Kind: payload[offset]}
		offset++
		var ok bool
		binding.Key, offset, ok = readString8(payload, offset)
		if !ok {
			break
		}
		binding.Description, offset, ok = readString16(payload, offset)
		if !ok {
			break
		}
		binding.Icon, offset, ok = readString8(payload, offset)
		if !ok {
			break
		}
		which.Bindings = append(which.Bindings, binding)
		summary = append(summary, binding.Key+" "+binding.Description)
	}
	return which, stringsJoin(summary, "  "), offset
}

// decodePicker owns the outer section framing (read each section's id/len, skip
// unknown ids) by hand, then decodes every section body through the
// schema-generated, window-aware decoders. The section window
// [sectionStart, sectionEnd) bounds every generated read, so the header's
// optional title/marked_count tail degrades to its zero value when a section is
// short, reproducing the old length-tolerant ladder. This mirrors the Swift
// OP_GUI_PICKER path collapsed onto the generated decoders in #2262.
func decodePicker(payload []byte) (Picker, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return Picker{}, "", min(len(payload), 2)
	}
	size := sectionedSize(payload)
	if size == 0 {
		return Picker{Visible: true}, "", len(payload)
	}
	picker := Picker{}
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		sectionStart := offset + 3
		sectionEnd := sectionStart + sectionLen
		offset = sectionEnd

		switch sectionID {
		case 0x01: // Header
			if h, _, err := generated.DecodeGuiPickerHeader(payload, sectionStart, sectionEnd); err == nil {
				picker.Visible = h.Visible != 0
				picker.Selected = h.SelectedIndex
				picker.Filtered = h.FilteredCount
				picker.Total = h.TotalCount
				picker.HasPreview = h.HasPreview != 0
				picker.Title = h.Title
				picker.Marked = h.MarkedCount
			}
		case 0x02: // Query
			if q, _, err := generated.DecodeGuiPickerQuery(payload, sectionStart, sectionEnd); err == nil {
				picker.Query = q.Text
			}
		case 0x03: // Items
			if items, _, err := generated.DecodeGuiPickerItems(payload, sectionStart, sectionEnd); err == nil {
				picker.Items = mapPickerItems(items)
			}
		case 0x04: // Action menu
			if m, _, err := generated.DecodeGuiPickerActionMenu(payload, sectionStart, sectionEnd); err == nil {
				picker.ActionVisible = m.Visible != 0
				picker.ActionIndex = m.SelectedIndex
				picker.Actions = m.Actions
			}
		case 0x05: // Mode prefix
			if m, _, err := generated.DecodeGuiPickerModePrefix(payload, sectionStart, sectionEnd); err == nil {
				picker.ModePrefix = m.Text
			}
		case 0x06: // Load status
			if s, _, err := generated.DecodeGuiPickerLoadStatus(payload, sectionStart, sectionEnd); err == nil {
				picker.LoadStatus = s.Status
				if s.Status == 2 {
					picker.LoadError = s.Message
				}
			}
		}
	}
	summary := picker.Title
	if picker.Query != "" {
		summary = strings.TrimSpace(summary + " " + picker.Query)
	}
	return picker, summary, size
}

// mapPickerItems lowers the generated PickerItem (raw flags only) into the
// protocol PickerItem the UI consumes, deriving the TwoLine/Marked booleans
// from the flag bits exactly as the old hand decode did.
func mapPickerItems(items []generated.PickerItem) []PickerItem {
	if items == nil {
		return nil
	}
	out := make([]PickerItem, 0, len(items))
	for _, item := range items {
		out = append(out, PickerItem{
			IconColor:   item.IconColor,
			Flags:       item.Flags,
			Label:       item.Label,
			Description: item.Description,
			Annotation:  item.Annotation,
			TwoLine:     item.Flags&0x01 != 0,
			Marked:      item.Flags&0x02 != 0,
		})
	}
	return out
}

func decodePickerPreview(payload []byte) (PickerPreview, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return PickerPreview{}, "", min(len(payload), 2)
	}
	if len(payload) < 4 {
		return PickerPreview{Visible: true}, "", len(payload)
	}
	count := int(u16(payload, 2))
	offset := 4
	preview := PickerPreview{Visible: true, Lines: make([]PreviewLine, 0, count)}
	summary := make([]string, 0, count)
	for i := 0; i < count && len(payload) >= offset+1; i++ {
		segmentCount := int(payload[offset])
		offset++
		line := PreviewLine{Segments: make([]PreviewSegment, 0, segmentCount)}
		var text strings.Builder
		for j := 0; j < segmentCount && len(payload) >= offset+6; j++ {
			segment := PreviewSegment{
				FG:   u24(payload, offset),
				Bold: payload[offset+3]&0x01 != 0,
			}
			offset += 4
			value, next, ok := readString16(payload, offset)
			if !ok {
				return preview, stringsJoin(summary, "  "), len(payload)
			}
			segment.Text = value
			offset = next
			line.Segments = append(line.Segments, segment)
			text.WriteString(value)
		}
		preview.Lines = append(preview.Lines, line)
		summary = append(summary, text.String())
	}
	return preview, stringsJoin(summary, "  "), offset
}

func decodeHoverPopup(payload []byte) (HoverPopup, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return HoverPopup{}, "", min(len(payload), 2)
	}
	if len(payload) < 11 {
		return HoverPopup{Visible: true}, "", len(payload)
	}
	hover := HoverPopup{
		Visible:      true,
		AnchorRow:    u16(payload, 2),
		AnchorCol:    u16(payload, 4),
		Focused:      payload[6] != 0,
		ScrollOffset: u16(payload, 7),
	}
	count := int(u16(payload, 9))
	offset := 11
	hover.Lines = make([]RichLine, 0, count)
	summary := make([]string, 0, count)
	for i := 0; i < count && len(payload) >= offset+3; i++ {
		offset++
		segmentCount := int(u16(payload, offset))
		offset += 2
		line, next, ok := decodeRichLine(payload, offset, segmentCount)
		if !ok {
			break
		}
		hover.Lines = append(hover.Lines, line)
		summary = append(summary, richLineText(line))
		offset = next
	}
	return hover, stringsJoin(summary, "  "), offset
}

func decodeHoverAction(payload []byte) (HoverAction, string, int) {
	if len(payload) < 4 {
		return HoverAction{}, "", len(payload)
	}
	size := 3 + int(u16(payload, 1))
	if len(payload) < size || payload[3] == 0 {
		return HoverAction{}, "", min(len(payload), size)
	}
	name, _, ok := readString16(payload, 4)
	if !ok {
		return HoverAction{Visible: true}, "", size
	}
	return HoverAction{Visible: true, Name: name}, name, size
}

func decodeSignatureHelp(payload []byte) (SignatureHelp, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return SignatureHelp{}, "", min(len(payload), 2)
	}
	if len(payload) < 10 {
		return SignatureHelp{Visible: true}, "", len(payload)
	}
	help := SignatureHelp{
		Visible:         true,
		AnchorRow:       u16(payload, 2),
		AnchorCol:       u16(payload, 4),
		ActiveSignature: payload[6],
		ActiveParameter: payload[7],
	}
	count := int(payload[8])
	offset := 9
	help.Signatures = make([]Signature, 0, count)
	for i := 0; i < count; i++ {
		sig, next, ok := decodeSignature(payload, offset)
		if !ok {
			break
		}
		help.Signatures = append(help.Signatures, sig)
		offset = next
	}
	summary := ""
	if len(help.Signatures) > 0 {
		summary = help.Signatures[min(int(help.ActiveSignature), len(help.Signatures)-1)].Label
	}
	return help, summary, offset
}

func decodeSignature(payload []byte, offset int) (Signature, int, bool) {
	var ok bool
	sig := Signature{}
	sig.Label, offset, ok = readString16(payload, offset)
	if !ok {
		return sig, offset, false
	}
	sig.Doc, offset, ok = readString16(payload, offset)
	if !ok || len(payload) < offset+1 {
		return sig, offset, false
	}
	count := int(payload[offset])
	offset++
	sig.Parameters = make([]SignatureParameter, 0, count)
	for i := 0; i < count; i++ {
		param := SignatureParameter{}
		param.Label, offset, ok = readString16(payload, offset)
		if !ok {
			return sig, offset, false
		}
		param.Doc, offset, ok = readString16(payload, offset)
		if !ok {
			return sig, offset, false
		}
		sig.Parameters = append(sig.Parameters, param)
	}
	return sig, offset, true
}

func decodeFloatPopup(payload []byte) (FloatPopup, string, int) {
	if len(payload) < 2 || payload[1] == 0 {
		return FloatPopup{}, "", min(len(payload), 2)
	}
	if len(payload) < 8 {
		return FloatPopup{Visible: true}, "", len(payload)
	}
	float := FloatPopup{Visible: true, Width: u16(payload, 2), Height: u16(payload, 4)}
	offset := 6
	var ok bool
	float.Title, offset, ok = readString16(payload, offset)
	if !ok || len(payload) < offset+2 {
		return float, float.Title, len(payload)
	}
	count := int(u16(payload, offset))
	offset += 2
	float.Lines = make([]string, 0, count)
	for i := 0; i < count; i++ {
		line, next, ok := readString16(payload, offset)
		if !ok {
			break
		}
		float.Lines = append(float.Lines, line)
		offset = next
	}
	return float, strings.TrimSpace(float.Title + " " + stringsJoin(float.Lines, " ")), offset
}

func decodeRichLine(payload []byte, offset int, count int) (RichLine, int, bool) {
	line := RichLine{Segments: make([]RichSegment, 0, count)}
	for i := 0; i < count && offset < len(payload); i++ {
		segment := RichSegment{Style: payload[offset]}
		offset++
		if segment.Style == 13 {
			if len(payload) < offset+6 {
				return line, offset, false
			}
			segment.FG = u24(payload, offset)
			segment.Flags = payload[offset+3]
			offset += 4
		}
		text, next, ok := readString16(payload, offset)
		if !ok {
			return line, offset, false
		}
		segment.Text = text
		offset = next
		line.Segments = append(line.Segments, segment)
	}
	return line, offset, true
}

func richLineText(line RichLine) string {
	parts := make([]string, 0, len(line.Segments))
	for _, segment := range line.Segments {
		parts = append(parts, segment.Text)
	}
	return stringsJoin(parts, "")
}
