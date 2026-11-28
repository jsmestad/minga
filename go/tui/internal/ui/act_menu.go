package ui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	actMenuMaxWidth = 73
	actMenuCaret    = 0xfffe
	actMenuCenter   = 0xffff
	actMenuHelp     = "↑↓ move · ↵ choose · esc close"
	actMenuFilterID = 0xffff
)

type actMenuRowHit struct {
	box uiRect
	id  uint16
}

// An offer and its row bounds are captured together by the View that painted them.
type actMenuPresentation struct {
	offer  uint64
	box    uiRect
	filter uiRect
	rows   []actMenuRowHit
}

func (m Model) actMenu() generated.GuiActMenuFields {
	return m.chrome[generated.OPGuiActMenu].ActMenu
}

func (menu actMenuPresentation) click(click tea.MouseClickMsg) []byte {
	if !menu.box.Contains(click.X, click.Y) {
		return protocol.EncodeGUIActMenuAction(menu.offer, 0)
	}
	if click.Button == tea.MouseLeft {
		if menu.filter.Contains(click.X, click.Y) {
			return protocol.EncodeGUIActMenuAction(menu.offer, actMenuFilterID)
		}
		for _, row := range menu.rows {
			if row.box.Contains(click.X, click.Y) {
				return protocol.EncodeGUIActMenuAction(menu.offer, row.id)
			}
		}
	}
	return nil
}

func (m Model) floatingActMenu() (*lipgloss.Layer, actMenuPresentation) {
	menu := m.actMenu()
	if menu.Visible != 1 {
		return nil, actMenuPresentation{}
	}
	painted := actMenuPresentation{offer: menu.OfferID}
	if m.width < 3 || m.height == 0 {
		return nil, painted
	}

	p := m.palette()
	role := p.PopupBorder()
	if menu.Role == 1 {
		role = p.Role(generated.ColorRoleMinga)
	} else if menu.Role == 2 {
		role = p.Role(generated.ColorRoleFailure)
	}
	base := lipgloss.NewStyle().Background(p.PopupSurface()).Foreground(p.PopupText())
	muted := base.Foreground(p.PopupMutedText())
	edge := base.Foreground(role)
	selected := edge.Background(m.editorBackground()).Reverse(true)
	border, _ := radiusLG.border()
	inset := gap(popoverRowInset)
	insetWidth := len(inset)
	query := "› filter"
	queryStyle := muted
	if menu.Query != "" {
		query = "› " + menu.Query
		queryStyle = base
	}
	keyWidth, hintWidth := 0, 0
	selectedInList := false
	for _, row := range menu.Rows {
		keyWidth = max(keyWidth, displayWidth(row.Key))
		hintWidth = max(hintWidth, displayWidth(row.Hint))
		selectedInList = selectedInList || (menu.Selected != 0 && row.ID == menu.Selected)
	}
	width := max(displayWidth(menu.Title)+displayWidth(query)+2*spaceXL.cols(), displayWidth(actMenuHelp)+2*insetWidth)
	for _, row := range menu.Rows {
		width = max(width, max(keyWidth+hintWidth+displayWidth(row.Label)+actMenuDetailWidth(row.Detail)+2*spaceXL.cols()+2*insetWidth, displayWidth(row.Section)+2*spaceXL.cols()))
	}
	for _, row := range menu.Lead {
		leadLabel := displayWidth(row.Key) + spaceMD.cols() + displayWidth(row.Label)
		if row.Hint != "" {
			leadLabel += 2 * (spaceMD.cols() + displayWidth(row.Hint))
		}
		lead := max(leadLabel, displayWidth(row.Detail)) + 2*insetWidth
		width = max(width, lead*len(menu.Lead)+len(menu.Lead)-1)
	}
	width = min(width+2, min(m.width, actMenuMaxWidth))
	if len(menu.Lead) == 2 && width%2 == 0 {
		width-- // One middle rule and two genuinely equal targets.
	}
	inside := width - 2
	insetWidth = min(insetWidth, max((inside-1)/2, 0))
	inset = strings.Repeat(" ", insetWidth)
	budget := max(m.height-2, 0)
	lines := make([]string, 0, min(m.height, len(menu.Rows)*2+decisionBarRows+2))
	queryWidth := min(displayWidth(query), max(inside/2, 1))
	title := clipWithEllipsis(sanitizeTerminalText(menu.Title), max(inside-queryWidth-2*spaceMD.cols(), 0))
	query = fitStyled(clipWithEllipsis(sanitizeTerminalText(query), queryWidth), queryWidth)
	header := edge.Render(border.TopLeft)
	if title != "" {
		header += edge.Render(border.Top) + base.Bold(true).Render(title)
	}
	header += edge.Render(strings.Repeat(border.Top, max(inside-displayWidth(title)-queryWidth-boolCell(title != ""), 0))) + queryStyle.Render(query) + edge.Render(border.TopRight)
	lines = append(lines, header)

	// In a cramped terminal, give the selected list row room before the
	// decision's consequence line; an ordinary-height menu always draws both.
	leadHeight := min(max(budget-boolCell(selectedInList), 0), decisionBarRows)
	if len(menu.Lead) > 0 && leadHeight > 0 {
		leadWidth := (inside - len(menu.Lead) + 1) / len(menu.Lead)
		if leadWidth > 0 {
			var leadLines [decisionBarRows]string
			for i, row := range menu.Lead {
				top, detail := base.Bold(true), muted
				if row.ID == menu.Selected {
					top = selected.Bold(true)
					detail = selected
				}
				label := actMenuLeadLabel(actMenuKeyLabel(row), row.Hint, leadWidth)
				texts := [decisionBarRows]string{label, sanitizeTerminalText(row.Detail)}
				styles := [decisionBarRows]lipgloss.Style{top, detail}
				for line := range leadHeight {
					if i != 0 {
						leadLines[line] += edge.Render(border.Left)
					}
					leadLines[line] += styles[line].Render(lipgloss.PlaceHorizontal(leadWidth, lipgloss.Center, clipWithEllipsis(texts[line], leadWidth)))
				}
				if row.ID != 0 {
					painted.rows = append(painted.rows, actMenuRowHit{uiRect{X: 1 + i*(leadWidth+1), Y: 1, Width: leadWidth, Height: leadHeight}, row.ID})
				}
			}
			for _, line := range leadLines[:leadHeight] {
				lines = append(lines, edge.Render(border.Left)+line+edge.Render(border.Right))
			}
			budget -= leadHeight
		}
	}

	rowWidth := inside - 2*insetWidth
	keyWidth = min(keyWidth, rowWidth/5)
	hintWidth = min(hintWidth, rowWidth/3)
	start := actMenuRowStart(menu, budget)
	section := ""
	for _, row := range menu.Rows[start:] {
		if budget == 0 {
			break
		}
		if row.Section != section && row.Section != "" {
			if budget == 1 && row.ID != menu.Selected {
				break
			}
			if budget > 1 {
				name := clipWithEllipsis(sanitizeTerminalText(row.Section), max(inside-2*insetWidth, 0))
				rule := strings.Repeat(border.Top, max(inside-displayWidth(name)-2*insetWidth, 0))
				lines = append(lines, edge.Render(border.Left)+muted.Render(inset+name+inset+rule)+edge.Render(border.Right))
				budget--
			}
		}
		section = row.Section
		style, quiet := base, muted
		if row.ID == menu.Selected {
			style, quiet = selected, selected
		}
		// Both key columns reserve the same space on every action row.
		key := fitStyled(clipWithEllipsis(sanitizeTerminalText(row.Key), keyWidth), keyWidth)
		hint := lipgloss.PlaceHorizontal(hintWidth, lipgloss.Right, clipWithEllipsis(sanitizeTerminalText(row.Hint), hintWidth))
		separator := spaceMD.cols()
		labelWidth := rowWidth - keyWidth - hintWidth - separator*boolCell(keyWidth > 0) - separator*boolCell(hintWidth > 0)
		gapKey := strings.Repeat(" ", separator*boolCell(keyWidth > 0))
		gapHint := strings.Repeat(" ", separator*boolCell(hintWidth > 0))
		label := clipWithEllipsis(sanitizeTerminalText(row.Label), labelWidth)
		consequence := ""
		if row.Detail != "" && displayWidth(label) < labelWidth {
			consequence = clipWithEllipsis(" · "+sanitizeTerminalText(row.Detail), labelWidth-displayWidth(label))
		}
		filler := strings.Repeat(" ", max(labelWidth-displayWidth(label)-displayWidth(consequence), 0))
		lines = append(lines, edge.Render(border.Left)+style.Render(inset+key+gapKey+label)+quiet.Render(consequence+filler+gapHint+hint+inset)+edge.Render(border.Right))
		if row.ID != 0 {
			painted.rows = append(painted.rows, actMenuRowHit{uiRect{X: 1, Y: len(lines) - 1, Width: inside, Height: 1}, row.ID})
		}
		budget--
	}
	if m.height > 1 {
		help := ansi.Truncate(actMenuHelp, inside, "…")
		lines = append(lines, edge.Render(border.BottomLeft)+muted.Render(help)+edge.Render(strings.Repeat(border.Bottom, inside-displayWidth(help))+border.BottomRight))
	}
	popup := strings.Join(lines, "\n")
	painted.box = m.actMenuBox(menu, width, len(lines))
	painted.filter = uiRect{X: painted.box.X + width - queryWidth - 1, Y: painted.box.Y, Width: queryWidth, Height: 1}
	for i := range painted.rows {
		painted.rows[i].box.X += painted.box.X
		painted.rows[i].box.Y += painted.box.Y
	}
	return lipgloss.NewLayer(popup).X(painted.box.X).Y(painted.box.Y).Z(actMenuLayerZ), painted
}

func (m Model) actMenuBox(menu generated.GuiActMenuFields, width, height int) uiRect {
	x, y := (m.width-width)/2, (m.height-height)/2
	switch {
	case menu.AnchorRow == actMenuCenter && menu.AnchorColumn == actMenuCenter:
	case menu.AnchorRow == actMenuCaret && menu.AnchorColumn == actMenuCaret:
		if cursor := m.residentCursor(); cursor != nil {
			x, y = cursor.X, cursor.Y+1
		}
	default:
		x, y = m.layout.grid.X+int(menu.AnchorColumn), m.layout.grid.Y+int(menu.AnchorRow)
	}
	return uiRect{X: clampInt(x, 0, m.width-width), Y: clampInt(y, 0, m.height-height), Width: width, Height: height}
}

// On a short terminal, keep the BEAM-selected list row visible. This chooses a
// viewport, not a selection, and never changes the offered ordering or filter.
func actMenuRowStart(menu generated.GuiActMenuFields, budget int) int {
	section := ""
	for i, row := range menu.Rows {
		if row.Section != "" && row.Section != section {
			budget--
		}
		budget--
		if row.ID == menu.Selected {
			if budget < 0 {
				return i
			}
			break
		}
		section = row.Section
	}
	return 0
}

func actMenuKeyLabel(row generated.ActMenuRow) string {
	return sanitizeTerminalText(strings.TrimSpace(row.Key + gap(spaceMD) + row.Label))
}

func actMenuDetailWidth(detail string) int {
	if detail == "" {
		return 0
	}
	return displayWidth(" · ") + displayWidth(detail)
}

func actMenuLeadLabel(label, hint string, width int) string {
	hint = sanitizeTerminalText(hint)
	hintWidth := displayWidth(hint)
	side := hintWidth + spaceMD.cols()
	if hintWidth == 0 || displayWidth(label)+2*side > width {
		return label
	}
	return strings.Repeat(" ", side) + lipgloss.PlaceHorizontal(width-2*side, lipgloss.Center, label) + gap(spaceMD) + hint
}

func boolCell(on bool) int {
	if on {
		return 1
	}
	return 0
}
