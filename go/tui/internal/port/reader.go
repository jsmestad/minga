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

			commands := decodePacket(packet, warn)
			program.Send(PacketMsg{Commands: commands})
		}
	}()
}

// decodePacket walks a batch of concatenated commands. The schema-generated
// generated.CommandSize is the single authority for how far to advance after
// each command, so an opcode this build does not render still advances by the
// correct number of bytes instead of swallowing the rest of the frame.
//
// A sizing or decode failure can no longer be silently dropped: once byte
// boundaries are untrustworthy the rest of the batch cannot be parsed, and if
// the failure lands inside an open frame transaction (#2219) the model must
// invalidate that transaction and request a keyframe rather than swap in a
// partial frame. decodePacket therefore appends a synthetic
// CommandStreamError marker at the point of failure (preserving in-order
// position so the model sees it mid-transaction) and stops, returning whatever
// it decoded up to that point. The model decides whether the marker aborts a
// transaction or is harmless out of band.
func decodePacket(packet []byte, warn func(byte, string)) []protocol.Command {
	commands := make([]protocol.Command, 0, 32)
	streamError := func(format string, args ...any) []protocol.Command {
		warn(protocol.LogLevelWarn, fmt.Sprintf(format, args...))
		return append(commands, protocol.Command{Kind: protocol.CommandStreamError})
	}
	for offset := 0; offset < len(packet); {
		rest := packet[offset:]
		size, status := generated.CommandSize(rest)
		switch status {
		case generated.CommandSizeOK:
			// Sizing is authoritative. Decode for rendering within the exact
			// command bounds; a render-decode failure inside an open transaction
			// must abort it rather than warn-and-continue (#2219).
			command, err := protocol.DecodeCommand(rest[:size])
			if err != nil {
				return streamError("render decode failed for opcode 0x%02X (%d bytes): %v", rest[0], size, err)
			}
			commands = append(commands, command)
			offset += size
		case generated.CommandSizeCustom:
			command, err := protocol.DecodeCommand(rest)
			if err != nil {
				return streamError("protocol decode error: %v", err)
			}
			if command.Size <= 0 {
				return streamError("protocol decode error: %v", io.ErrNoProgress)
			}
			commands = append(commands, command)
			offset += command.Size
		case generated.CommandSizeIncomplete:
			return streamError("protocol decode error: %v", io.ErrUnexpectedEOF)
		default: // generated.CommandSizeUnknown
			return streamError("unknown opcode 0x%02X at offset %d", rest[0], offset)
		}
	}
	return commands
}
