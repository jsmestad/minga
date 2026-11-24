package ui

import (
	"testing"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestPaletteResolvesDesignTokenRolesFromThemeSlots(t *testing.T) {
	theme := protocol.Theme{Colors: map[byte]uint32{
		byte(generated.ColorRoleNeedsYou): 0xEF9F76,
		byte(generated.ColorRoleMinga):    0xCA9EE6,
		byte(generated.ColorRoleFailure):  0xE78284,
	}}
	p := paletteFromTheme(theme)

	if got, want := p.Role(generated.ColorRoleNeedsYou), lipgloss.Color("#EF9F76"); got != want {
		t.Fatalf("needs_you role = %v, want %v", got, want)
	}
	if got, want := p.State(generated.StateNeedsYou), p.Role(generated.ColorRoleNeedsYou); got != want {
		t.Fatalf("needs_you state = %v, want the needs_you role %v", got, want)
	}
	if got, want := p.State(generated.StateWorking), p.Role(generated.ColorRoleMinga); got != want {
		t.Fatalf("working state = %v, want the minga role %v", got, want)
	}
	if got, want := p.State(generated.StateFailed), p.Role(generated.ColorRoleFailure); got != want {
		t.Fatalf("failed state = %v, want the failure role %v", got, want)
	}
}

func TestThemeRequiresEveryDesignTokenRoleSlot(t *testing.T) {
	missing := missingThemeSlots(protocol.Theme{Colors: map[byte]uint32{}})
	for _, role := range generated.ColorRoles {
		found := false
		for _, slot := range missing {
			if slot == byte(role) {
				found = true
			}
		}
		if !found {
			t.Fatalf("role %s (slot 0x%02X) is not a required theme slot", role.ID(), byte(role))
		}
	}
}

func TestAgentStatusWordsComeFromStateTokens(t *testing.T) {
	if got := agentChatStatusLabel(agentStatusNeedsYou); got != generated.StateNeedsYou.Token().Word {
		t.Fatalf("needs-you label = %q, want the token word", got)
	}
	if got := agentChatStatusLabel(3); got != generated.StateFailed.Token().Word {
		t.Fatalf("error label = %q, want the failed token word", got)
	}
	frames := generated.StateWorking.Token().Frames
	panel := agentPanel{}
	for i, want := range frames {
		panel.animationFrame = uint64(i)
		if got := panel.spinner(); got != want {
			t.Fatalf("spinner frame %d = %q, want working orbit frame %q", i, got, want)
		}
	}
}
