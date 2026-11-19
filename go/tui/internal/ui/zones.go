package ui

import (
	"slices"
	"strconv"
	"strings"
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
	nextID          int
	ids             map[string]string
	rids            map[string]string
	zones           map[string]*zoneInfo
	approvalMarkers map[string]struct{}
	approvalRoots   map[string]struct{}
	picker          pickerPointerZones
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
	marker := m.marker(id)
	return marker + value + marker
}

func (m *zoneManager) marker(id string) string {
	marker, ok := m.ids[id]
	if !ok {
		m.nextID++
		marker = string([]byte{zoneMarkerStart, zoneMarkerBracket}) + strconv.Itoa(m.nextID) + string(zoneMarkerEnd)
		m.ids[id] = marker
		m.rids[marker] = id
	}
	return marker
}

func (m *zoneManager) markCachedTranscriptControl(id string, value string) string {
	if id == "" || value == "" {
		return value
	}
	marker := m.marker(id)
	if m.approvalMarkers == nil {
		m.approvalMarkers = map[string]struct{}{}
		m.approvalRoots = map[string]struct{}{}
	}
	m.approvalMarkers[marker] = struct{}{}
	return marker + value + marker
}

// cacheApprovalMarkers records references once at cache admission, including their retained identity bytes.
func (m *zoneManager) cacheApprovalMarkers(rows []string) (markers []string, bytes int) {
	if len(m.approvalMarkers) == 0 {
		return nil, 0
	}
	for _, row := range rows {
		for pos := 0; pos < len(row); {
			nextEscape := strings.IndexByte(row[pos:], zoneMarkerStart)
			if nextEscape < 0 {
				break
			}
			pos += nextEscape
			marker, next, ok := readZoneMarker(row, pos)
			if !ok {
				pos++
				continue
			}
			if _, approval := m.approvalMarkers[marker]; approval && !slices.Contains(markers, marker) {
				markers = append(markers, marker)
				bytes += len(m.rids[marker]) + len(marker)
			}
			pos = next
		}
	}
	return markers, bytes
}

func (m *zoneManager) retainApprovalMarker(marker string) {
	if _, approval := m.approvalMarkers[marker]; approval {
		m.approvalRoots[marker] = struct{}{}
	}
}

// Retirement follows complete frame composition, never Update: the old frame may still own a click.
func (m *zoneManager) retireUnreferencedApprovals() {
	for marker := range m.approvalMarkers {
		if _, retained := m.approvalRoots[marker]; retained {
			continue
		}
		delete(m.ids, m.rids[marker])
		delete(m.rids, marker)
		delete(m.approvalMarkers, marker)
	}
}

func (m *zoneManager) Get(id string) *zoneInfo {
	return m.zones[id]
}

func (m *zoneManager) Scan(value string) string {
	clear(m.approvalRoots)
	m.picker = pickerPointerZones{}
	out := make([]byte, 0, len(value))
	line := make([]byte, 0, 128)
	tracked := map[string]*zoneInfo{}
	zones := map[string]*zoneInfo{}
	y := 0

	for pos := 0; pos < len(value); {
		if marker, next, ok := readZoneMarker(value, pos); ok {
			m.retainApprovalMarker(marker)
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

// ScanInto scans a detached content block (a separately composited overlay
// layer, #2281) for zone markers, strips the markers, and merges the discovered
// zones into the existing zone map with their coordinates offset by (offsetX,
// offsetY). Unlike Scan it does NOT clobber the existing zones: the main frame
// content is scanned first via Scan, then each separately positioned layer adds
// its zones here so chrome zone routing (completion items, hover action) keeps
// working even though the overlay is no longer footer-appended into the main
// vertical layout. Returns the marker-stripped content for compositing.
func (m *zoneManager) ScanInto(value string, offsetX int, offsetY int) string {
	out := make([]byte, 0, len(value))
	line := make([]byte, 0, 128)
	tracked := map[string]*zoneInfo{}
	y := 0

	for pos := 0; pos < len(value); {
		if marker, next, ok := readZoneMarker(value, pos); ok {
			m.retainApprovalMarker(marker)
			id := m.rids[marker]
			if id != "" {
				if start, ok := tracked[marker]; ok {
					start.EndX = ansi.StringWidth(string(line)) - 1 + offsetX
					start.EndY = y + offsetY
					m.zones[id] = start
					delete(tracked, marker)
				} else {
					tracked[marker] = &zoneInfo{id: id, StartX: ansi.StringWidth(string(line)) + offsetX, StartY: y + offsetY}
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
