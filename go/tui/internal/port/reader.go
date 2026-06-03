package port

import (
	"errors"
	"fmt"
	"io"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

type PacketMsg struct {
	Commands []protocol.Command
}

type ErrorMsg struct {
	Err error
}

// LogMsg carries a renderer diagnostic. The model forwards it to the BEAM as a
// log_message event so it lands in Minga's *Messages* buffer (matching Zig),
// instead of being lost on the renderer's stderr.
type LogMsg struct {
	Level byte
	Text  string
}

func StartReader(program *tea.Program, reader io.Reader) {
	warn := func(level byte, text string) { program.Send(LogMsg{Level: level, Text: text}) }
	go func() {
		for {
			packet, err := protocol.ReadPacket(reader)
			if err != nil {
				if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
					program.Send(tea.Quit())
					return
				}
				program.Send(ErrorMsg{Err: err})
				return
			}

			commands, err := decodePacket(packet, warn)
			if err != nil {
				warn(protocol.LogLevelWarn, fmt.Sprintf("protocol decode error: %v", err))
				continue
			}
			program.Send(PacketMsg{Commands: commands})
		}
	}()
}

// decodePacket walks a batch of concatenated commands. The schema-generated
// generated.CommandSize is the single authority for how far to advance after
// each command, so an opcode this build does not render still advances by the
// correct number of bytes instead of swallowing the rest of the frame.
func decodePacket(packet []byte, warn func(byte, string)) ([]protocol.Command, error) {
	commands := make([]protocol.Command, 0, 32)
	for offset := 0; offset < len(packet); {
		rest := packet[offset:]
		size, status := generated.CommandSize(rest)
		switch status {
		case generated.CommandSizeOK:
			// Sizing is authoritative. Decode for rendering within the exact
			// command bounds; a render-decode failure must not desync the
			// stream, so we warn and keep advancing.
			if command, err := protocol.DecodeCommand(rest[:size]); err == nil {
				commands = append(commands, command)
			} else {
				warn(protocol.LogLevelWarn, fmt.Sprintf("render decode failed for opcode 0x%02X (%d bytes): %v", rest[0], size, err))
			}
			offset += size
		case generated.CommandSizeCustom:
			command, err := protocol.DecodeCommand(rest)
			if err != nil {
				return commands, err
			}
			if command.Size <= 0 {
				return commands, io.ErrNoProgress
			}
			commands = append(commands, command)
			offset += command.Size
		case generated.CommandSizeIncomplete:
			return commands, io.ErrUnexpectedEOF
		default: // generated.CommandSizeUnknown
			return commands, fmt.Errorf("unknown opcode 0x%02X at offset %d", rest[0], offset)
		}
	}
	return commands, nil
}
