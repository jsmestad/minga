package protocol

type CursorlineChrome struct {
	Visible bool
	Row     uint16
	BG      uint32
}

type IndentGuides struct {
	WindowID       uint16
	TabWidth       byte
	ActiveGuideCol uint16
	GuideCols      []uint16
	IndentLevels   []byte
}

type FileTreeSelection struct {
	Generation uint32
	Focused    bool
	SelectedID string
}

type CompletionSelection struct {
	Generation    uint32
	SelectedID    string
	Documentation string
}

type PickerSelection struct {
	Generation       uint32
	SelectedID       uint32
	SelectedActionID uint32
}

type CursorAnimation struct {
	Enabled bool
}

type LineSpacing struct {
	SpacingX100 uint16
}

type ConfigState struct {
	Present bool
}

func decodeCursorlineChrome(payload []byte) (CursorlineChrome, string, int) {
	if len(payload) < 6 {
		return CursorlineChrome{}, "", len(payload)
	}
	row := u16(payload, 1)
	if row == 0xFFFF {
		return CursorlineChrome{}, "hidden", 6
	}
	return CursorlineChrome{Visible: true, Row: row, BG: u24(payload, 3)}, "visible", 6
}

func decodeIndentGuides(payload []byte) (IndentGuides, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return IndentGuides{}, "", len(payload)
	}
	body := payload[3:size]
	if len(body) < 6 {
		return IndentGuides{}, "", len(payload)
	}
	guides := IndentGuides{WindowID: u16(body, 0), TabWidth: body[2], ActiveGuideCol: u16(body, 3)}
	count := int(body[5])
	offset := 6
	guides.GuideCols = make([]uint16, 0, count)
	for i := 0; i < count && len(body) >= offset+2; i++ {
		guides.GuideCols = append(guides.GuideCols, u16(body, offset))
		offset += 2
	}
	if len(body) >= offset+2 {
		levelCount := int(u16(body, offset))
		offset += 2
		if len(body) >= offset+levelCount {
			guides.IndentLevels = append(guides.IndentLevels, body[offset:offset+levelCount]...)
		}
	}
	return guides, "indent guides", size
}

func decodeFileTreeSelection(payload []byte) (FileTreeSelection, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 || len(payload) < 10 {
		return FileTreeSelection{}, "", len(payload)
	}
	selection := FileTreeSelection{Focused: payload[3]&0x01 != 0, Generation: u32(payload, 4)}
	selected, _, ok := readString16(payload, 8)
	if ok {
		selection.SelectedID = selected
	}
	return selection, selected, size
}

func decodeCompletionSelection(payload []byte) (CompletionSelection, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 || len(payload) < 10 {
		return CompletionSelection{}, "", len(payload)
	}
	selection := CompletionSelection{Generation: u32(payload, 3)}
	selected, offset, ok := readString8(payload, 7)
	if !ok {
		return CompletionSelection{}, "", size
	}
	documentation, _, ok := readString16(payload, offset)
	if !ok {
		return CompletionSelection{}, "", size
	}
	selection.SelectedID = selected
	selection.Documentation = documentation
	return selection, selected, size
}

func decodePickerSelection(payload []byte) (PickerSelection, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 || len(payload) < 15 {
		return PickerSelection{}, "", len(payload)
	}
	selection := PickerSelection{
		Generation:       u32(payload, 3),
		SelectedID:       u32(payload, 7),
		SelectedActionID: u32(payload, 11),
	}
	return selection, "picker selection", size
}

func decodeCursorAnimation(payload []byte) (CursorAnimation, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 || len(payload) < 4 {
		return CursorAnimation{}, "", len(payload)
	}
	return CursorAnimation{Enabled: payload[3] != 0}, "tui no-op", size
}

func decodeLineSpacing(payload []byte) (LineSpacing, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 || len(payload) < 5 {
		return LineSpacing{}, "", len(payload)
	}
	return LineSpacing{SpacingX100: u16(payload, 3)}, "tui no-op", size
}

func decodeConfigState(payload []byte) (ConfigState, string, int) {
	size := payloadLen16Size(payload)
	if size == 0 {
		return ConfigState{}, "", len(payload)
	}
	return ConfigState{Present: true}, "tui no-op", size
}
