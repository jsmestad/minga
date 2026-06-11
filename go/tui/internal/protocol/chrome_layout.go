package protocol

import (
	"fmt"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// decodeSurfaceLayout decodes gui_surface_layout (0xA4, #2268): the BEAM's
// authoritative per-frame surface placement list. It is sectioned framing
// (opcode, section_count, section{id, len16, body}) with a single section,
// placements (id 0x01), holding a counted array of surface_placement. Each
// placement carries a surface_id, a terminal-cell rect, a z band, and a
// hit_kind. The list IS the compositing order (sort by z) and the same list
// BEAM mouse hit-testing routes against, so a placement's rect is the surface's
// hit rect by construction.
//
// The section body is decoded with the schema-generated
// DecodeGuiSurfaceLayoutPlacements (the exact inverse of the Elixir
// SurfaceLayoutEncoder), bounded by [sectionStart, sectionEnd) so a short or
// malformed section degrades to an empty list rather than overrunning the
// batch.
func decodeSurfaceLayout(payload []byte) ([]generated.SurfacePlacement, string, int) {
	size := sectionedSize(payload)
	if size == 0 || len(payload) < 2 {
		return nil, "", min(len(payload), 2)
	}

	var placements []generated.SurfacePlacement
	offset := 2
	for i := 0; i < int(payload[1]); i++ {
		if len(payload) < offset+3 {
			break
		}
		sectionID := payload[offset]
		sectionLen := int(u16(payload, offset+1))
		sectionStart := offset + 3
		sectionEnd := sectionStart + sectionLen
		offset = sectionEnd
		if sectionEnd > len(payload) {
			break
		}

		if sectionID == 0x01 {
			if p, _, err := generated.DecodeGuiSurfaceLayoutPlacements(payload, sectionStart, sectionEnd); err == nil {
				placements = p
			}
		}
	}

	summary := fmt.Sprintf("%d surfaces", len(placements))
	return placements, summary, size
}
