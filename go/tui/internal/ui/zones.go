package ui

import (
	"strconv"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

const (
	zoneMarkerStart   = '\x1b'
	zoneMarkerBracket = '['
	zoneMarkerEnd     = 'z'
)

type zoneInfo struct {
	id     string
	StartX int
	StartY int
	EndX   int
	EndY   int
}

func (z *zoneInfo) InBounds(msg tea.MouseMsg) bool {
	if z == nil || z.id == "" {
		return false
	}
	mouse := msg.Mouse()
	return z.StartX <= z.EndX && z.StartY <= z.EndY && mouse.X >= z.StartX && mouse.Y >= z.StartY && mouse.X <= z.EndX && mouse.Y <= z.EndY
}

type zoneManager struct {
	nextID int
	ids    map[string]string
	rids   map[string]string
	zones  map[string]*zoneInfo
}

func newZoneManager() *zoneManager {
	return &zoneManager{
		nextID: 1000,
		ids:    map[string]string{},
		rids:   map[string]string{},
		zones:  map[string]*zoneInfo{},
	}
}

func (m *zoneManager) Mark(id string, value string) string {
	if id == "" || value == "" {
		return value
	}
	marker, ok := m.ids[id]
	if !ok {
		m.nextID++
		marker = string([]byte{zoneMarkerStart, zoneMarkerBracket}) + strconv.Itoa(m.nextID) + string(zoneMarkerEnd)
		m.ids[id] = marker
		m.rids[marker] = id
	}
	return marker + value + marker
}

func (m *zoneManager) Get(id string) *zoneInfo {
	return m.zones[id]
}

func (m *zoneManager) Scan(value string) string {
	out := make([]byte, 0, len(value))
	line := make([]byte, 0, 128)
	tracked := map[string]*zoneInfo{}
	zones := map[string]*zoneInfo{}
	y := 0

	for pos := 0; pos < len(value); {
		if marker, next, ok := readZoneMarker(value, pos); ok {
			id := m.rids[marker]
			if id != "" {
				if start, ok := tracked[marker]; ok {
					start.EndX = ansi.StringWidth(string(line)) - 1
					start.EndY = y
					zones[id] = start
					delete(tracked, marker)
				} else {
					tracked[marker] = &zoneInfo{id: id, StartX: ansi.StringWidth(string(line)), StartY: y}
				}
			}
			pos = next
			continue
		}

		r, width := utf8.DecodeRuneInString(value[pos:])
		if r == utf8.RuneError && width == 0 {
			break
		}
		chunk := value[pos : pos+width]
		out = append(out, chunk...)
		if r == '\n' {
			y++
			line = line[:0]
		} else {
			line = append(line, chunk...)
		}
		pos += width
	}

	m.zones = zones
	return string(out)
}

func readZoneMarker(value string, pos int) (string, int, bool) {
	if pos+4 > len(value) || value[pos] != zoneMarkerStart || value[pos+1] != zoneMarkerBracket {
		return "", pos, false
	}
	end := pos + 2
	for end < len(value) && value[end] >= '0' && value[end] <= '9' {
		end++
	}
	if end == pos+2 || end >= len(value) || value[end] != zoneMarkerEnd {
		return "", pos, false
	}
	return value[pos : end+1], end + 1, true
}
