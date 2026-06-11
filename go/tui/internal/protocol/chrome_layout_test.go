package protocol

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// surfacePlacement builds a 13-byte surface_placement body:
// surface_id(u16) rect(row,col,width,height : u16) z(u16) hit_kind(u8).
func surfacePlacement(surfaceID, row, col, width, height, z uint16, hitKind byte) []byte {
	be16 := func(v uint16) []byte { return []byte{byte(v >> 8), byte(v)} }
	out := be16(surfaceID)
	out = append(out, be16(row)...)
	out = append(out, be16(col)...)
	out = append(out, be16(width)...)
	out = append(out, be16(height)...)
	out = append(out, be16(z)...)
	return append(out, hitKind)
}

func TestDecodeSurfaceLayoutDecodesPlacements(t *testing.T) {
	body := []byte{0, 2} // count = 2
	body = append(body, surfacePlacement(1, 0, 0, 80, 24, 0, 1)...)
	body = append(body, surfacePlacement(16, 5, 10, 40, 12, 301, 8)...)

	packet := []byte{generated.OPGuiSurfaceLayout, 1}
	packet = append(packet, section(0x01, body)...)
	// A following command must not be swallowed: the layout command must report
	// its own bounded size.
	packet = append(packet, generated.OPCommitFrame, 0, 0, 0, 0, 0, 0, 0, 0)

	first, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if first.Kind != CommandChrome {
		t.Fatalf("kind = %v, want chrome", first.Kind)
	}
	if first.Size != len(packet)-9 {
		t.Fatalf("surface layout size = %d, want %d (must not swallow commit_frame)", first.Size, len(packet)-9)
	}

	placements := first.Chrome.Placements
	if len(placements) != 2 {
		t.Fatalf("placements = %d, want 2", len(placements))
	}
	want0 := generated.SurfacePlacement{SurfaceID: 1, Rect: generated.Rect{Row: 0, Col: 0, Width: 80, Height: 24}, Z: 0, HitKind: 1}
	want1 := generated.SurfacePlacement{SurfaceID: 16, Rect: generated.Rect{Row: 5, Col: 10, Width: 40, Height: 12}, Z: 301, HitKind: 8}
	if placements[0] != want0 {
		t.Fatalf("placement[0] = %+v, want %+v", placements[0], want0)
	}
	if placements[1] != want1 {
		t.Fatalf("placement[1] = %+v, want %+v", placements[1], want1)
	}

	second, err := DecodeCommand(packet[first.Size:])
	if err != nil {
		t.Fatalf("following commit_frame decode error: %v", err)
	}
	if second.Kind != CommandCommitFrame {
		t.Fatalf("second kind = %v, want commit frame", second.Kind)
	}
}

func TestDecodeSurfaceLayoutEmptyList(t *testing.T) {
	packet := []byte{generated.OPGuiSurfaceLayout, 1}
	packet = append(packet, section(0x01, []byte{0, 0})...) // count = 0

	cmd, err := DecodeCommand(packet)
	if err != nil {
		t.Fatalf("DecodeCommand returned error: %v", err)
	}
	if len(cmd.Chrome.Placements) != 0 {
		t.Fatalf("empty layout decoded %d placements, want 0", len(cmd.Chrome.Placements))
	}
	if cmd.Size != len(packet) {
		t.Fatalf("empty layout size = %d, want %d", cmd.Size, len(packet))
	}
}
