package ui

import (
	"strings"
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
	for wire, want := range map[byte]string{0: "Idle", 1: "Working", 2: "Working", 4: "Working", 5: "Needs you", 6: "Needs you"} {
		if got := agentChatStatusLabel(wire); got != want {
			t.Fatalf("status %d label = %q, want %q from the shared state table", wire, got, want)
		}
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

func TestAgentContextCardStatusMatchesMacOSCardStatus(t *testing.T) {
	cases := []struct {
		status byte
		label  string
		role   generated.ColorRole
	}{
		{0, "Idle", generated.ColorRoleWaiting},
		{1, generated.StateWorking.Token().Word, generated.ColorRoleMinga},
		{2, generated.StateWorking.Token().Word, generated.ColorRoleMinga},
		{3, generated.StateNeedsYou.Token().Word, generated.ColorRoleNeedsYou},
		{4, generated.StateDone.Token().Word, generated.ColorRoleDone},
		{5, generated.StateFailed.Token().Word, generated.ColorRoleFailure},
		{9, "Idle", generated.ColorRoleWaiting},
	}
	for _, tc := range cases {
		if got := cardStatusLabel(tc.status); got != tc.label {
			t.Errorf("status %d label = %q, want %q", tc.status, got, tc.label)
		}
		if got := cardStatusRole(tc.status); got != tc.role {
			t.Errorf("status %d role = %s, want %s", tc.status, got.ID(), tc.role.ID())
		}
	}
}

func TestAgentContextCardDrawsStatusInItsStateRole(t *testing.T) {
	model := New(60, 12, nil)
	model.activePalette = paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{byte(generated.ColorRoleNeedsYou): 0xEF9F76}})
	lines := model.renderAgentContext(protocol.AgentContext{Visible: true, Status: 3, Task: "Review diff"})
	rendered := strings.Join(lines, "\n")
	word := generated.StateNeedsYou.Token().Word
	at := strings.Index(rendered, word)
	if at < 0 {
		t.Fatalf("agent context card missing %q: %q", word, rendered)
	}
	if colour := "38;2;239;159;118"; !strings.Contains(rendered[:at], colour) {
		t.Fatalf("agent context status should be drawn in the needs_you role %s: %q", colour, rendered)
	}
}

func TestAgentContextCardKeepsListTitleColourWithoutRoleSlot(t *testing.T) {
	// The bootstrap palette, drawn before the BEAM sends a theme, has popup slots but no colour roles.
	model := New(60, 12, nil)
	themed := strings.Join(model.renderAgentContext(protocol.AgentContext{Visible: true, Status: 0, Task: "Review diff"}), "\n")
	plain := strings.Join(model.charmList("Agent context", []componentItem{{title: "Idle", description: "Review diff"}}, 0, model.maxOverlayHeight(), true), "\n")
	if themed != plain {
		t.Fatalf("a missing waiting role should keep the list title colour:\n%q\nwant\n%q", themed, plain)
	}
}
