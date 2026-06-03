package ui

import (
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

func fileTreeIcon(row protocol.FileTreeRow) uiIcon {
	if strings.TrimSpace(row.Icon) != "" {
		return uiIcon{glyph: strings.TrimSpace(row.Icon)}
	}
	path := row.Path
	if strings.TrimSpace(path) == "" {
		path = row.Name
	}
	return devIconForPath(path, row.Directory)
}

func pickerItemIcon(title string, item protocol.PickerItem) uiIcon {
	if labelHasIcon(item.Label) {
		return uiIcon{}
	}
	if strings.Contains(strings.ToLower(title), "project") {
		if strings.TrimSpace(item.Description) != "" {
			return devIconForPath(item.Description, true)
		}
		return uiIcon{glyph: "", color: "#61AFEF"}
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
		return uiIcon{glyph: "", color: "#61AFEF"}
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

func devIconForPath(path string, directory bool) uiIcon {
	if directory && strings.TrimSpace(path) == "" {
		return uiIcon{glyph: "", color: "#61AFEF"}
	}
	if directory {
		style := devicons.IconForPath(path)
		if style.Icon != "" {
			return uiIcon{glyph: style.Icon, color: style.Color}
		}
		return uiIcon{glyph: "", color: "#61AFEF"}
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
