package ui

import "testing"

// The BEAM sends the agent model as provider:model. Status text that contains a colon arrives with an empty
// provider (":text"), so no part of it is shown as the provider.
func TestSplitAgentModelNameReadsProviderOnlyBeforeTheFirstColon(t *testing.T) {
	cases := []struct {
		value, provider, model string
	}{
		{"Claude (subscription):haiku", "Claude (subscription)", "haiku"},
		{"anthropic:claude-sonnet-4", "anthropic", "claude-sonnet-4"},
		{"Resolving model…", "", "Resolving model…"},
		{`:Model "anthropic:claude-x" is not in the catalog`, "", `Model "anthropic:claude-x" is not in the catalog`},
	}
	for _, c := range cases {
		provider, model := splitAgentModelName(c.value)
		if provider != c.provider || model != c.model {
			t.Errorf("splitAgentModelName(%q) = (%q, %q), want (%q, %q)", c.value, provider, model, c.provider, c.model)
		}
	}
}
