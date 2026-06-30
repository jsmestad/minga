package ui

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"

	devicons "github.com/epilande/go-devicons"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

type uiIcon struct {
	glyph string
	color string
}

func tabIcon(tab protocol.Tab) uiIcon {
	if strings.TrimSpace(tab.Icon) != "" {
		return uiIcon{glyph: strings.TrimSpace(tab.Icon)}
	}
	return devIconForPath(tab.Label, false)
}

func fileTreeIcon(row protocol.FileTreeRow, selected bool) uiIcon {
	if strings.TrimSpace(row.Icon) != "" {
		// The BEAM sends the glyph plus a per-row icon color resolved from the
		// active theme's icon palette. Preserve it on unselected rows only so
		// selected rows keep the selection contrast.
		color := iconColorHex(row.IconColor)
		if selected {
			color = ""
		}
		return uiIcon{glyph: strings.TrimSpace(row.Icon), color: color}
	}
	path := row.Path
	if strings.TrimSpace(path) == "" {
		path = row.Name
	}
	return devIconForPath(path, row.Directory)
}

// iconColorHex formats a 24-bit RGB icon color as a lipgloss hex string.
func iconColorHex(rgb uint32) string {
	return fmt.Sprintf("#%06X", rgb&0xFFFFFF)
}

func pickerItemIcon(title string, item protocol.PickerItem) uiIcon {
	if labelHasIcon(item.Label) {
		return uiIcon{}
	}
	if strings.Contains(strings.ToLower(title), "project") {
		if strings.TrimSpace(item.Description) != "" {
			return devIconForPath(item.Description, true)
		}
		return uiIcon{glyph: "󰉖", color: "#78909C"}
	}
	name := item.Label
	if strings.TrimSpace(item.Description) != "" {
		name = item.Description + "/" + item.Label
	}
	return devIconForPath(name, false)
}

func whichKeyIcon(binding protocol.WhichKeyBinding) uiIcon {
	if strings.TrimSpace(binding.Icon) != "" {
		return uiIcon{glyph: strings.TrimSpace(binding.Icon)}
	}
	switch strings.TrimSpace(binding.Key) {
	case "/", "?":
		return uiIcon{glyph: "", color: "#51AFEF"}
	case "1", "2", "3", "4", "5", "6", "7", "8", "9":
		return uiIcon{glyph: "󰓩", color: "#C678DD"}
	}
	label := strings.ToLower(binding.Description)
	switch {
	case strings.Contains(label, "file"):
		return uiIcon{glyph: "󰈞", color: "#61AFEF"}
	case strings.Contains(label, "project"):
		return uiIcon{glyph: "󰉖", color: "#78909C"}
	case strings.Contains(label, "buffer"), strings.Contains(label, "tab"):
		return uiIcon{glyph: "󰓩", color: "#C678DD"}
	case strings.Contains(label, "git"):
		return uiIcon{glyph: "", color: "#E06C75"}
	case strings.Contains(label, "search"), strings.Contains(label, "find"):
		return uiIcon{glyph: "", color: "#51AFEF"}
	case strings.Contains(label, "quit"), strings.Contains(label, "close"):
		return uiIcon{glyph: "󰩈", color: "#E06C75"}
	case strings.Contains(label, "window"), strings.Contains(label, "split"):
		return uiIcon{glyph: "", color: "#98C379"}
	case strings.Contains(label, "toggle"):
		return uiIcon{glyph: "", color: "#98C379"}
	case strings.Contains(label, "agent"):
		return uiIcon{glyph: "󰚩", color: "#E5C07B"}
	default:
		return uiIcon{glyph: "•"}
	}
}

// modeIcon returns a nerd font icon for the given vi mode name. The mode name
// should be the trimmed text from a modeline segment (NORMAL, INSERT, etc.).
func modeIcon(mode string) string {
	switch mode {
	case "NORMAL":
		return ""
	case "INSERT":
		return ""
	case "VISUAL":
		return "󰈈"
	case "COMMAND":
		return ""
	case "OP":
		return ""
	case "SEARCH":
		return ""
	case "REPLACE":
		return "󰛔"
	default:
		return ""
	}
}

func devIconForPath(path string, directory bool) uiIcon {
	if directory {
		return uiIcon{glyph: "󰉖", color: "#78909C"}
	}
	style := devicons.IconForPath(path)
	return uiIcon{glyph: style.Icon, color: style.Color}
}

func labelHasIcon(label string) bool {
	label = strings.TrimSpace(label)
	if label == "" {
		return false
	}
	r, _ := utf8.DecodeRuneInString(label)
	return !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '.' && r != '_' && r != '-'
}
