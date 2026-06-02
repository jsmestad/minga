package ui

import (
	"fmt"
	"net/url"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	zonePrefixFileTreeRow     = "file-tree:row:"
	zonePrefixModelineCommand = "modeline:command:"
)

func zoneIDFileTreeRow(index int) string {
	return fmt.Sprintf("%s%d", zonePrefixFileTreeRow, index)
}

func zoneIDModelineCommand(command string) string {
	return zonePrefixModelineCommand + url.QueryEscape(command)
}

func (m Model) semanticMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	if msg.Button != tea.MouseButtonLeft || msg.Action != tea.MouseActionPress {
		return nil, false
	}
	if packet, ok := m.modelineMousePacket(msg); ok {
		return packet, true
	}
	if packet, ok := m.fileTreeMousePacket(msg); ok {
		return packet, true
	}
	return nil, false
}

func (m Model) modelineMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	status, ok := m.statusBar()
	if !ok {
		return nil, false
	}
	segments := make([]protocol.StatusSegment, 0, len(status.Left)+len(status.Right))
	segments = append(segments, status.Left...)
	segments = append(segments, status.Right...)
	for _, segment := range segments {
		if segment.Command == "" {
			continue
		}
		zoneInfo := m.zones.Get(zoneIDModelineCommand(segment.Command))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUIExecuteCommand(segment.Command), true
		}
	}
	return nil, false
}

func (m Model) fileTreeMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	tree, ok := m.fileTree()
	if !ok || !tree.Visible {
		return nil, false
	}
	for index := range tree.Rows {
		zoneInfo := m.zones.Get(zoneIDFileTreeRow(index))
		if zoneInfo != nil && zoneInfo.InBounds(msg) {
			return protocol.EncodeGUIFileTreeClick(uint16(index)), true
		}
	}
	return nil, false
}
