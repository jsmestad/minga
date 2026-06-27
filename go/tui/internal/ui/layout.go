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
	leftPane uiRect // file tree or sidebar; zero when neither is visible
}

func (m Model) computeLayout() uiLayout {
	width := max(m.width, 1)
	height := max(m.height, 1)

	headerHeight := len(m.headerLines())
	footerHeight := len(m.footerLines())
	bodyHeight := max(height-headerHeight-footerHeight, 1)

	leftPaneWidth := m.leftChromeWidth()

	return uiLayout{
		header:   uiRect{X: 0, Y: 0, Width: width, Height: headerHeight},
		body:     uiRect{X: leftPaneWidth, Y: headerHeight, Width: max(width-leftPaneWidth, 1), Height: bodyHeight},
		footer:   uiRect{X: 0, Y: headerHeight + bodyHeight, Width: width, Height: footerHeight},
		leftPane: uiRect{X: 0, Y: headerHeight, Width: leftPaneWidth, Height: bodyHeight},
	}
}
