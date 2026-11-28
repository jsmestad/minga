package ui

import (
	"image"
	"image/color"
	"math"
	"strings"

	"charm.land/lipgloss/v2"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
)

func (m Model) composeFrameWithLayers(content string, menu *lipgloss.Layer) (string, []*lipgloss.Layer, []gutterActHit) {
	layers := []*lipgloss.Layer{
		lipgloss.NewLayer(m.windowBackground()).X(0).Y(0).Z(0),
		lipgloss.NewLayer(content).X(0).Y(0).Z(1),
	}
	if timeline := m.timelineLayer(); timeline != nil {
		layers = append(layers, timeline)
	}
	if drawer := m.tasksDrawerLayer(); drawer != nil {
		layers = append(layers, drawer)
	}
	layers = append(layers, m.floatingOverlayLayers()...)
	compositor := lipgloss.NewCompositor(layers...)
	if menu == nil && len(m.gutterHits) == 0 {
		return compositor.Render(), layers[2:], nil
	}
	if menu != nil {
		canvas := lipgloss.NewCanvas(m.width, m.height).Compose(compositor)
		dimActMenuBackdrop(canvas, m.palette().Text(), m.editorBackground())
		x, y := menu.GetX(), menu.GetY()
		menu.Draw(canvas, image.Rect(x, y, x+menu.Width(), y+menu.Height()))
		return canvas.Render(), append(layers[2:], menu), nil
	}
	size := compositor.Bounds().Size()
	canvas := lipgloss.NewCanvas(size.X, size.Y).Compose(compositor)
	// Check the final cells: split separators, clipping, and higher layers
	// can replace a sign after the editor row renderer emitted it.
	hits := m.gutterHits
	for i, hit := range m.gutterHits {
		cell := canvas.CellAt(hit.x, hit.y)
		if cell == nil || cell.Content != hit.glyph {
			hits = append([]gutterActHit(nil), m.gutterHits[:i]...)
			for _, next := range m.gutterHits[i+1:] {
				if cell := canvas.CellAt(next.x, next.y); cell != nil && cell.Content == next.glyph {
					hits = append(hits, next)
				}
			}
			break
		}
	}
	return canvas.Render(), layers[2:], hits
}

// Tint composed cells instead of replacing them with an opaque layer. Using
// the editor's own background keeps both light and dark themes legible.
func dimActMenuBackdrop(canvas *lipgloss.Canvas, text, background color.Color) {
	r, g, b, _ := background.RGBA()
	type shadeKey struct {
		r, g, b, keep uint32
	}
	colors := make(map[shadeKey]color.Color)
	inks := make(map[[2]ansi.RGBColor]color.Color)
	mix := func(value color.Color, keep uint32) color.Color {
		cr, cg, cb, _ := value.RGBA()
		if cr == r && cg == g && cb == b {
			return background
		}
		key := shadeKey{cr, cg, cb, keep}
		if mixed, ok := colors[key]; ok {
			return mixed
		}
		rr := ((cr*keep + r*(4-keep)) / 4) >> 8
		gg := ((cg*keep + g*(4-keep)) / 4) >> 8
		bb := ((cb*keep + b*(4-keep)) / 4) >> 8
		mixed := ansi.RGBColor{R: uint8(rr), G: uint8(gg), B: uint8(bb)}
		colors[key] = mixed
		return mixed
	}
	for y := range canvas.Height() {
		for x := range canvas.Width() {
			cell := canvas.CellAt(x, y)
			if cell == nil || cell.Width == 0 {
				continue
			}
			style := &cell.Style
			if style.Fg == nil {
				style.Fg = text
			}
			if style.Bg == nil {
				style.Bg = background
			}
			if style.Attrs&uv.AttrReverse != 0 {
				style.Fg, style.Bg = style.Bg, style.Fg
				style.Attrs &^= uv.AttrReverse
			}
			style.Fg = mix(style.Fg, 2)
			style.Bg = mix(style.Bg, 1)
			if cell.Content != "" && cell.Content != " " {
				pair := [2]ansi.RGBColor{backdropRGB(style.Fg), backdropRGB(style.Bg)}
				legible, ok := inks[pair]
				if !ok {
					legible = legibleBackdropInk(pair[0], pair[1])
					inks[pair] = legible
				}
				style.Fg = legible
				style.Attrs &^= uv.AttrFaint
			}
			if style.UnderlineColor != nil {
				style.UnderlineColor = mix(style.UnderlineColor, 2)
			}
		}
	}
}

func backdropRGB(c color.Color) ansi.RGBColor {
	r, g, b, _ := c.RGBA()
	return ansi.RGBColor{R: uint8(r >> 8), G: uint8(g >> 8), B: uint8(b >> 8)}
}

// Dim as far as the text contrast target allows. The search runs once per
// colour pair, not per cell, and retains as much of the tinted ink as possible.
func legibleBackdropInk(ink, paper ansi.RGBColor) ansi.RGBColor {
	const textContrast = 4.5
	background := backdropLuminance(paper)
	contrast := func(c ansi.RGBColor) float64 {
		foreground := backdropLuminance(c)
		if foreground < background {
			return (background + 0.05) / (foreground + 0.05)
		}
		return (foreground + 0.05) / (background + 0.05)
	}
	if contrast(ink) >= textContrast {
		return ink
	}

	endpoint := 0
	if (background+0.05)/0.05 < 1.05/(background+0.05) {
		endpoint = 255
	}
	toward := func(amount int) ansi.RGBColor {
		mix := func(channel uint8) uint8 {
			return uint8((int(channel)*(255-amount) + endpoint*amount + 127) / 255)
		}
		return ansi.RGBColor{R: mix(ink.R), G: mix(ink.G), B: mix(ink.B)}
	}
	lo, hi := 1, 255
	for lo < hi {
		mid := (lo + hi) / 2
		if contrast(toward(mid)) >= textContrast {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return toward(lo)
}

func backdropLuminance(c ansi.RGBColor) float64 {
	linear := func(channel uint8) float64 {
		srgb := float64(channel) / 255
		if srgb <= 0.04045 {
			return srgb / 12.92
		}
		return math.Pow((srgb+0.055)/1.055, 2.4)
	}
	return 0.2126*linear(c.R) + 0.7152*linear(c.G) + 0.0722*linear(c.B)
}

func (m Model) windowBackground() string {
	width := max(m.width, 1)
	height := max(m.height, 1)
	line := strings.Repeat(" ", width)
	lines := make([]string, height)
	style := lipgloss.NewStyle().Background(m.editorBackground()).Width(width)
	for i := range lines {
		lines[i] = style.Render(line)
	}
	return strings.Join(lines, "\n")
}
