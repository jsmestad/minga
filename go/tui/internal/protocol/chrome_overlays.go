package protocol

import "strings"

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
		offset += 3
		section := payload[offset : offset+sectionLen]
		offset += sectionLen
		switch sectionID {
		case 0x01:
			decodePickerHeader(section, &picker)
		case 0x02:
			if query, _, ok := readString16(section, 0); ok {
				picker.Query = query
			}
		case 0x03:
			picker.Items = decodePickerItems(section)
		case 0x04:
			decodePickerActions(section, &picker)
		case 0x05:
			if modePrefix, _, ok := readString16(section, 0); ok {
				picker.ModePrefix = modePrefix
			}
		case 0x06:
			decodePickerLoadStatus(section, &picker)
		}
	}
	summary := picker.Title
	if picker.Query != "" {
		summary = strings.TrimSpace(summary + " " + picker.Query)
	}
	return picker, summary, size
}

func decodePickerHeader(section []byte, picker *Picker) {
	if len(section) < 10 {
		return
	}
	picker.Visible = section[0] != 0
	picker.Selected = u16(section, 1)
	picker.Filtered = u16(section, 3)
	picker.Total = u16(section, 5)
	picker.HasPreview = section[7] != 0
	title, offset, ok := readString16(section, 8)
	if !ok {
		return
	}
	picker.Title = title
	if len(section) >= offset+2 {
		picker.Marked = u16(section, offset)
	}
}

func decodePickerItems(section []byte) []PickerItem {
	if len(section) < 2 {
		return nil
	}
	count := int(u16(section, 0))
	offset := 2
	items := make([]PickerItem, 0, count)
	for i := 0; i < count && len(section) >= offset+8; i++ {
		item := PickerItem{
			IconColor: u24(section, offset),
			Flags:     section[offset+3],
		}
		item.TwoLine = item.Flags&0x01 != 0
		item.Marked = item.Flags&0x02 != 0
		offset += 4
		var ok bool
		item.Label, offset, ok = readString16(section, offset)
		if !ok {
			break
		}
		item.Description, offset, ok = readString16(section, offset)
		if !ok {
			break
		}
		item.Annotation, offset, ok = readString16(section, offset)
		if !ok || len(section) < offset+1 {
			break
		}
		matchCount := int(section[offset])
		offset += 1 + matchCount*2
		if len(section) < offset {
			break
		}
		items = append(items, item)
	}
	return items
}

func decodePickerActions(section []byte, picker *Picker) {
	if len(section) < 1 {
		return
	}
	picker.ActionVisible = section[0] != 0
	if !picker.ActionVisible || len(section) < 3 {
		return
	}
	picker.ActionIndex = section[1]
	count := int(section[2])
	offset := 3
	picker.Actions = make([]string, 0, count)
	for i := 0; i < count; i++ {
		action, next, ok := readString16(section, offset)
		if !ok {
			break
		}
		picker.Actions = append(picker.Actions, action)
		offset = next
	}
}

func decodePickerLoadStatus(section []byte, picker *Picker) {
	if len(section) < 1 {
		return
	}
	picker.LoadStatus = section[0]
	if picker.LoadStatus == 2 {
		if err, _, ok := readString16(section, 1); ok {
			picker.LoadError = err
		}
	}
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
