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
	Focused    bool
	SelectedID string
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
	if size == 0 || len(payload) < 6 {
		return FileTreeSelection{}, "", len(payload)
	}
	selection := FileTreeSelection{Focused: payload[3]&0x01 != 0}
	selected, _, ok := readString16(payload, 4)
	if ok {
		selection.SelectedID = selected
	}
	return selection, selected, size
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
