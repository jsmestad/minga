package protocol

import (
	"encoding/binary"
	"fmt"
	"strings"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func skipString16(payload []byte, lengthOffset int, name string) (Command, error) {
	if len(payload) < lengthOffset+2 {
		return Command{}, fmt.Errorf("short %s", name)
	}
	size := lengthOffset + 2 + int(u16(payload, lengthOffset))
	if len(payload) < size {
		return Command{}, fmt.Errorf("short %s payload", name)
	}
	return Command{Kind: CommandNoop, Size: size}, nil
}

func skipFontFallback(payload []byte) (Command, error) {
	if len(payload) < 2 {
		return Command{}, fmt.Errorf("short set_font_fallback")
	}

	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		if len(payload) < offset+2 {
			return Command{}, fmt.Errorf("short set_font_fallback entry")
		}
		offset += 2 + int(u16(payload, offset))
		if len(payload) < offset {
			return Command{}, fmt.Errorf("short set_font_fallback name")
		}
	}
	return Command{Kind: CommandNoop, Size: offset}, nil
}

func sectionedSize(payload []byte) int {
	if len(payload) < 2 {
		return 0
	}

	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		if len(payload) < offset+3 {
			return 0
		}
		offset += 3 + int(u16(payload, offset+1))
		if len(payload) < offset {
			return 0
		}
	}
	return offset
}

func payloadLen16Size(payload []byte) int {
	if len(payload) < 3 {
		return 0
	}
	size := 3 + int(u16(payload, 1))
	if len(payload) < size {
		return 0
	}
	return size
}

func payloadLen32Size(payload []byte) int {
	if len(payload) < 5 {
		return 0
	}
	size := 5 + int(u32(payload, 1))
	if len(payload) < size {
		return 0
	}
	return size
}

func opcodeName(opcode byte) string {
	switch opcode {
	case generated.OPGuiTabBar:
		return "tabs"
	case generated.OPGuiWorkspaces:
		return "workspaces"
	case generated.OPGuiSidebars:
		return "sidebars"
	case generated.OPGuiFileTree:
		return "file tree"
	case generated.OPGuiPicker:
		return "picker"
	case generated.OPGuiPickerPreview:
		return "picker preview"
	case generated.OPGuiMinibuffer:
		return "minibuffer"
	case generated.OPGuiCompletion:
		return "completion"
	case generated.OPGuiStatusBar:
		return "status"
	case generated.OPGuiWhichKey:
		return "which-key"
	case generated.OPGuiBottomPanel:
		return "panel"
	case generated.OPGuiExtensionPanel:
		return "extension"
	case generated.OPGuiNotifications:
		return "notifications"
	case generated.OPGuiTheme:
		return "theme"
	case generated.OPGuiBreadcrumb:
		return "breadcrumb"
	case generated.OPGuiGitStatus:
		return "git"
	case generated.OPGuiSearchState:
		return "search"
	case generated.OPGuiHoverPopup:
		return "hover"
	case generated.OPGuiHoverAction:
		return "hover action"
	case generated.OPGuiSignatureHelp:
		return "signature"
	case generated.OPGuiFloatPopup:
		return "float"
	case generated.OPGuiExtensionOverlay:
		return "extension overlay"
	case generated.OPGuiObservatory:
		return "observatory"
	case generated.OPGuiAgentContext:
		return "agent context"
	case generated.OPGuiAgentChat:
		return "agent chat"
	case generated.OPGuiEditTimeline:
		return "edit timeline"
	case generated.OPGuiGutterSep:
		return "gutter separator"
	case generated.OPGuiCursorline:
		return "cursorline"
	case generated.OPGuiGutter:
		return "gutter"
	case generated.OPGuiIndentGuides:
		return "indent guides"
	case generated.OPGuiLineSpacing:
		return "line spacing"
	case generated.OPGuiFileTreeSelection:
		return "file tree selection"
	case generated.OPGuiCursorAnimation:
		return "cursor animation"
	case generated.OPGuiConfigState:
		return "config state"
	case generated.OPGuiSplitSeparators:
		return "split separators"
	case generated.OPGuiEmptyState:
		return "empty state"
	default:
		return fmt.Sprintf("0x%02X", opcode)
	}
}

func u16(data []byte, offset int) uint16 {
	return binary.BigEndian.Uint16(data[offset : offset+2])
}

func u24(data []byte, offset int) uint32 {
	return uint32(data[offset])<<16 | uint32(data[offset+1])<<8 | uint32(data[offset+2])
}

func u32(data []byte, offset int) uint32 {
	return binary.BigEndian.Uint32(data[offset : offset+4])
}

func readString8(data []byte, offset int) (string, int, bool) {
	if len(data) < offset+1 {
		return "", offset, false
	}
	size := int(data[offset])
	offset++
	if len(data) < offset+size {
		return "", offset, false
	}
	return string(data[offset : offset+size]), offset + size, true
}

func readString16(data []byte, offset int) (string, int, bool) {
	if len(data) < offset+2 {
		return "", offset, false
	}
	size := int(u16(data, offset))
	offset += 2
	if len(data) < offset+size {
		return "", offset, false
	}
	return string(data[offset : offset+size]), offset + size, true
}

func stringsJoin(parts []string, sep string) string {
	compact := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			compact = append(compact, part)
		}
	}
	return strings.Join(compact, sep)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
