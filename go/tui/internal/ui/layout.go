package ui

import "github.com/jsmestad/minga/go/tui/internal/generated"

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

// uiLayout describes one frame's regions in absolute screen coordinates.
// The primary grid starts below the local header and still includes the
// BEAM-authored footer and timeline reservations.
type uiLayout struct {
	header   uiRect
	grid     uiRect
	body     uiRect
	footer   uiRect
	timeline uiRect // persistent BEAM-authored chrome, never an overlay candidate
	drawer   uiRect // the tasks drawer's BEAM-reserved rows, a real split above the timeline and footer
	leftPane uiRect // file tree or sidebar; zero when neither is visible
}

func (m Model) computeLayout() uiLayout {
	width := max(m.width, 1)
	height := max(m.height, 1)

	headerHeight := min(m.headerChrome().height(), height)
	grid := uiRect{Y: headerHeight, Width: width, Height: height - headerHeight}
	footerHeight := min(m.footerRows(), grid.Height)
	footerY := height - footerHeight
	bodyBottom := footerY
	var timeline uiRect
	if _, visible := m.editTimeline(); visible {
		if rect, placed := m.surfaceRectOnGrid(surfaceIDEditTimeline, grid); placed {
			rect.Height = min(rect.Height, footerY-rect.Y)
			if rect.Width > 0 && rect.Height > 0 {
				timeline = rect
				bodyBottom = timeline.Y
			}
		}
	}
	var drawer uiRect
	if _, visible := m.tasksDrawer(); visible {
		if rect, placed := m.surfaceRectOnGrid(surfaceIDTasksDrawer, grid); placed {
			rect.Height = min(rect.Height, bodyBottom-rect.Y)
			if rect.Width > 0 && rect.Height > 0 {
				drawer = rect
				bodyBottom = min(bodyBottom, drawer.Y)
			}
		}
	}
	bodyHeight := max(bodyBottom-headerHeight, 0)

	leftPaneWidth := m.leftChromeWidth()

	return uiLayout{
		header:   uiRect{X: leftPaneWidth, Y: 0, Width: max(width-leftPaneWidth, 1), Height: headerHeight},
		grid:     grid,
		body:     uiRect{X: leftPaneWidth, Y: headerHeight, Width: max(width-leftPaneWidth, 1), Height: bodyHeight},
		footer:   uiRect{X: 0, Y: footerY, Width: width, Height: footerHeight},
		timeline: timeline,
		drawer:   drawer,
		leftPane: uiRect{X: 0, Y: 0, Width: leftPaneWidth, Height: headerHeight + bodyHeight},
	}
}

type gridSize struct {
	cols, rows uint16
}

func (l uiLayout) gridSize() gridSize {
	return gridSize{uint16(l.grid.Width), uint16(max(l.grid.Height, 1))}
}

// screenRect translates a BEAM rect from primary-grid coordinates to the
// terminal. A placement from before a resize may extend beyond the new grid.
func (r uiRect) screenRect(rect generated.Rect) uiRect {
	x, y := int(rect.Col), int(rect.Row)
	return uiRect{
		X: r.X + x, Y: r.Y + y,
		Width: min(int(rect.Width), max(r.Width-x, 0)), Height: min(int(rect.Height), max(r.Height-y, 0)),
	}
}
