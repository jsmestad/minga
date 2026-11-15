package protocol

import (
	"fmt"
	"unicode/utf8"
)

func decodeStatusReview(section []byte) (StatusReview, error) {
	path, offset, ok := readString16(section, 0)
	if !ok || !utf8.ValidString(path) || len(section) < offset+5 {
		return StatusReview{}, fmt.Errorf("malformed gui_status_bar review")
	}
	freshness := ReviewFreshness(section[offset])
	if freshness != ReviewCurrent && freshness != ReviewStale {
		return StatusReview{}, fmt.Errorf("unknown gui_status_bar review freshness %d", freshness)
	}
	generation := u32(section, offset+1)
	itemID, end, ok := readString16(section, offset+5)
	if !ok || end != len(section) || !utf8.ValidString(itemID) {
		return StatusReview{}, fmt.Errorf("malformed gui_status_bar review identity")
	}
	return StatusReview{Path: path, Freshness: freshness, Generation: generation, ItemID: itemID}, nil
}

func decodeAgentHelp(payload []byte) (AgentHelp, int, error) {
	invalid := func() (AgentHelp, int, error) {
		return AgentHelp{}, 0, fmt.Errorf("malformed gui_agent_help")
	}
	size := payloadLen32Size(payload)
	if size < 7 {
		return invalid()
	}
	body := payload[5:size]
	if body[0] != 1 {
		return AgentHelp{}, 0, fmt.Errorf("unsupported gui_agent_help version %d", body[0])
	}
	if body[1] > 1 {
		return invalid()
	}
	if body[1] == 0 {
		if len(body) != 2 {
			return invalid()
		}
		return AgentHelp{}, size, nil
	}
	if len(body) < 3 {
		return invalid()
	}
	help := AgentHelp{Visible: true}
	count := int(body[2])
	help.Groups = make([]AgentHelpGroup, 0, count)
	offset := 3
	for range count {
		title, next, ok := readString16(body, offset)
		if !ok || !utf8.ValidString(title) || len(body) <= next {
			return invalid()
		}
		bindingCount := int(body[next])
		offset = next + 1
		group := AgentHelpGroup{Title: title, Bindings: make([]AgentHelpBinding, 0, bindingCount)}
		for range bindingCount {
			key, next, ok := readString8(body, offset)
			if !ok || !utf8.ValidString(key) {
				return invalid()
			}
			description, next, ok := readString16(body, next)
			if !ok || !utf8.ValidString(description) {
				return invalid()
			}
			offset = next
			group.Bindings = append(group.Bindings, AgentHelpBinding{Key: key, Description: description})
		}
		help.Groups = append(help.Groups, group)
	}
	if offset != len(body) {
		return invalid()
	}
	return help, size, nil
}
