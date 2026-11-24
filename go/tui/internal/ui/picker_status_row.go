package ui

import (
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/rivo/uniseg"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	// pickerActiveGlyph marks the current value, such as the current model.
	pickerActiveGlyph = "●"
	// pickerMinDescription is the narrowest description worth showing; anything shorter is dropped.
	pickerMinDescription = 8
	// pickerMinLabel is the narrowest a label is truncated to before the chip gives way.
	pickerMinLabel = 12
)

var (
	// pickerActiveSlotWidth is the active glyph plus a list row's glyph-to-title gap. Inactive siblings pad by the same width.
	pickerActiveSlotWidth = ansi.StringWidth(pickerActiveGlyph) + listRowGlyphToTitle.cols()
	// pickerStatusGap separates the label, annotation, description, and chip: a list row's title-to-meta gap.
	pickerStatusGap = listRowTitleToMeta.cols()
)

// pickerStatusRowLayout is the visible content of one status-chip row at a given width.
// Every field is display text; empty means the part is not shown.
type pickerStatusRowLayout struct {
	activeSlot  bool
	active      bool
	label       string
	annotation  string
	description string
	chip        string
	// gap is the number of spaces between the left content and the right-aligned chip.
	gap int
}

// pickerStatusGlyph shows a chip's tone without color, so a monochrome terminal still tells tones apart.
func pickerStatusGlyph(tone generated.PickerStatusTone) string {
	switch tone {
	case generated.PickerStatusToneReady:
		return "✓ "
	case generated.PickerStatusToneWarn:
		return "! "
	case generated.PickerStatusToneError:
		return "✗ "
	case generated.PickerStatusToneChecking:
		return "… "
	default:
		return ""
	}
}

func (p palette) pickerStatusColor(tone generated.PickerStatusTone) color.Color {
	switch tone {
	case generated.PickerStatusToneReady:
		return p.Hint()
	case generated.PickerStatusToneWarn:
		return p.Warning()
	case generated.PickerStatusToneError:
		return p.Error()
	default:
		return p.PopupMutedText()
	}
}

// layoutPickerStatusRow fits a status-chip row into `avail` display columns, the row width without the
// selection marker and its padding. The chip is right-aligned. When space runs out, parts give way in
// this order: the description shortens its end and is dropped below pickerMinDescription columns, the
// annotation shrinks to its first glyph and is then dropped, the current-value glyph goes, the label
// shortens to pickerMinLabel columns, and only then does the chip shorten.
func layoutPickerStatusRow(item protocol.PickerItem, activeSlot bool, avail int) pickerStatusRowLayout {
	layout := pickerStatusRowLayout{
		activeSlot:  activeSlot,
		active:      activeSlot && item.Active,
		label:       item.Label,
		annotation:  strings.TrimSpace(item.Annotation),
		description: strings.TrimSpace(item.Description),
		chip:        pickerStatusGlyph(item.StatusTone) + item.Status,
	}
	chip := displayWidth(layout.chip)

	if room := avail - layout.fixedWidth() - pickerStatusGap - chip; layout.description != "" {
		descRoom := room - pickerStatusGap
		switch {
		case descRoom >= displayWidth(layout.description):
		case descRoom >= pickerMinDescription:
			layout.description = ansi.TruncateWc(layout.description, descRoom, "…")
		default:
			layout.description = ""
		}
	}
	if layout.overflow(avail) > 0 && layout.annotation != "" {
		short, _, _, _ := uniseg.FirstGraphemeClusterInString(layout.annotation, -1)
		layout.annotation = short
	}
	if layout.overflow(avail) > 0 {
		layout.annotation = ""
	}
	if layout.overflow(avail) > 0 {
		layout.activeSlot, layout.active = false, false
	}
	if over := layout.overflow(avail); over > 0 {
		labelWidth := max(displayWidth(layout.label)-over, min(pickerMinLabel, displayWidth(layout.label)))
		layout.label = ansi.TruncateWc(layout.label, labelWidth, "…")
	}
	if over := layout.overflow(avail); over > 0 {
		layout.chip = ansi.TruncateWc(layout.chip, max(chip-over, 1), "…")
	}
	layout.gap = max(avail-layout.leftWidth()-displayWidth(layout.chip), 0)
	return layout
}

// fixedWidth is the left content that never shortens: the active slot, the label, and the annotation.
func (l pickerStatusRowLayout) fixedWidth() int {
	width := displayWidth(l.label)
	if l.activeSlot {
		width += pickerActiveSlotWidth
	}
	if l.annotation != "" {
		width += pickerStatusGap + displayWidth(l.annotation)
	}
	return width
}

func (l pickerStatusRowLayout) leftWidth() int {
	width := l.fixedWidth()
	if l.description != "" {
		width += pickerStatusGap + displayWidth(l.description)
	}
	return width
}

func (l pickerStatusRowLayout) overflow(avail int) int {
	return l.leftWidth() + pickerStatusGap + displayWidth(l.chip) - avail
}

// renderPickerStatusRow draws a row whose item carries a status chip on one line:
// marker, current-value glyph, label, annotation, description, then the chip right-aligned.
func (m Model) renderPickerStatusRow(item protocol.PickerItem, selected bool, activeSlot bool, width int) string {
	theme := m.palette()
	rowBackground := theme.PopupSurface()
	rowForeground := theme.PopupText()
	if selected {
		rowBackground = theme.PopupSelection()
		rowForeground = theme.PopupSelectionText()
	}
	style := func(fg color.Color) lipgloss.Style {
		return lipgloss.NewStyle().Foreground(fg).Background(rowBackground).ColorWhitespace(true)
	}
	labelStyle := style(rowForeground)
	mutedStyle := style(theme.PopupMutedText())
	chipStyle := style(theme.pickerStatusColor(item.StatusTone))
	if selected {
		labelStyle = labelStyle.Bold(true)
		mutedStyle = style(rowForeground)
		chipStyle = style(rowForeground)
	}

	marker := " "
	markerStyle := mutedStyle
	switch {
	case selected:
		marker, markerStyle = "▌", style(theme.Accent()).Bold(true)
	case item.Marked:
		marker, markerStyle = "*", style(theme.Warning())
	}

	// " " + marker + " " + content + " ": four columns around the fitted content.
	layout := layoutPickerStatusRow(item, activeSlot, max(width-4, 1))
	var text strings.Builder
	text.WriteString(labelStyle.Render(" "))
	text.WriteString(markerStyle.Render(marker))
	text.WriteString(labelStyle.Render(" "))
	if layout.active {
		text.WriteString(style(theme.Accent()).Render(pickerActiveGlyph))
		text.WriteString(labelStyle.Render(gap(listRowGlyphToTitle)))
	} else if layout.activeSlot {
		text.WriteString(labelStyle.Render(strings.Repeat(" ", pickerActiveSlotWidth)))
	}
	text.WriteString(labelStyle.Render(layout.label))
	if layout.annotation != "" {
		text.WriteString(mutedStyle.Render(strings.Repeat(" ", pickerStatusGap) + layout.annotation))
	}
	if layout.description != "" {
		text.WriteString(mutedStyle.Render(strings.Repeat(" ", pickerStatusGap) + layout.description))
	}
	text.WriteString(labelStyle.Render(strings.Repeat(" ", layout.gap)))
	text.WriteString(chipStyle.Render(layout.chip))
	rowStyle := lipgloss.NewStyle().Background(rowBackground).Width(width).ColorWhitespace(true)
	return renderPadded(rowStyle, text.String(), width)
}

// pickerHasActiveItem reports whether any visible row is the current value, so siblings pad to align.
func pickerHasActiveItem(items []protocol.PickerItem) bool {
	for _, item := range items {
		if item.Active {
			return true
		}
	}
	return false
}
