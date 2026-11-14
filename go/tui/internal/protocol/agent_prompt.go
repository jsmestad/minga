package protocol

import (
	"encoding/binary"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

const AgentPromptWindowID uint16 = 65534

// AgentPromptFit observes the physical text aperture of a committed source presentation.
// Generation is TextPresentation.PresentationID, not ContentEpoch.
type AgentPromptFit struct {
	WindowID   uint16
	Generation uint64
	Columns    uint16
	MaxRows    uint16
}

func EncodeGUIAgentPromptFit(fit AgentPromptFit) []byte {
	out := make([]byte, 16)
	out[0], out[1] = generated.OPGuiAction, generated.GUIActionAgentPromptFit
	binary.BigEndian.PutUint16(out[2:4], fit.WindowID)
	binary.BigEndian.PutUint64(out[4:12], fit.Generation)
	binary.BigEndian.PutUint16(out[12:14], fit.Columns)
	binary.BigEndian.PutUint16(out[14:16], fit.MaxRows)
	return out
}

// AgentPromptScroll requests authoritative wrapped-row scrolling.
// Positive DeltaRows moves down; it does not navigate or edit the prompt cursor.
type AgentPromptScroll struct {
	WindowID   uint16
	Generation uint64
	DeltaRows  int32
}

func EncodeGUIAgentPromptScroll(scroll AgentPromptScroll) []byte {
	out := make([]byte, 16)
	out[0], out[1] = generated.OPGuiAction, generated.GUIActionAgentPromptScroll
	binary.BigEndian.PutUint16(out[2:4], scroll.WindowID)
	binary.BigEndian.PutUint64(out[4:12], scroll.Generation)
	binary.BigEndian.PutUint32(out[12:16], uint32(scroll.DeltaRows))
	return out
}
