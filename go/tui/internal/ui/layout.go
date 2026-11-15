package ui

// uiRect describes a rectangular region of the terminal in absolute screen
// coordinates. A zero-value rect (Width == 0 || Height == 0) means the region
// is absent this frame (e.g. no file tree visible).
type uiRect struct {
	X, Y, Width, Height int
}

func (r uiRect) Contains(x, y int) bool {
	return r.Width > 0 && r.Height > 0 &&
		x >= r.X && x < r.X+r.Width &&
		y >= r.Y && y < r.Y+r.Height
}

func (r uiRect) Translate(x, y int) (int, int) {
	return x - r.X, y - r.Y
}

// uiLayout describes the spatial arrangement of every top-level region for
// one frame. It is computed once per Update() from the current chrome state
// and terminal dimensions, then read by the renderer, the mouse router, and
// the viewport sizing code. This centralizes the scattered bodyHeight() /
// renderedHeaderHeight / leftChromeWidth() / semanticContentOffsets() calls
// into a single source of truth for region positions.
type uiLayout struct {
	header   uiRect
	body     uiRect
	footer   uiRect
	timeline uiRect // persistent BEAM-authored chrome, never an overlay candidate
	leftPane uiRect // file tree or sidebar; zero when neither is visible
}

func (m Model) computeLayout() uiLayout {
	width := max(m.width, 1)
	height := max(m.height, 1)

	headerHeight := min(len(m.headerLines()), height)
	footerHeight := min(len(m.footerLines()), height-headerHeight)
	footerY := height - footerHeight
	bodyBottom := footerY
	var timeline uiRect
	if _, visible := m.editTimeline(); visible {
		if rect, placed := m.surfacePlacementFor(surfaceIDEditTimeline); placed && rect.Width > 0 && rect.Height > 0 {
			timeline = uiRect{X: int(rect.Col), Y: int(rect.Row), Width: int(rect.Width), Height: int(rect.Height)}
			bodyBottom = min(bodyBottom, timeline.Y)
		}
	}
	bodyHeight := max(bodyBottom-headerHeight, 0)

	leftPaneWidth := m.leftChromeWidth()

	return uiLayout{
		header:   uiRect{X: leftPaneWidth, Y: 0, Width: max(width-leftPaneWidth, 1), Height: headerHeight},
		body:     uiRect{X: leftPaneWidth, Y: headerHeight, Width: max(width-leftPaneWidth, 1), Height: bodyHeight},
		footer:   uiRect{X: 0, Y: footerY, Width: width, Height: footerHeight},
		timeline: timeline,
		leftPane: uiRect{X: 0, Y: 0, Width: leftPaneWidth, Height: headerHeight + bodyHeight},
	}
}
