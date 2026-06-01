package port

import (
	"errors"
	"io"
	"log"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

type PacketMsg struct {
	Commands []protocol.Command
}

type ErrorMsg struct {
	Err error
}

func StartReader(program *tea.Program, reader io.Reader) {
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

			commands, err := decodePacket(packet)
			if err != nil {
				log.Printf("[GO_TUI/warn] protocol decode error: %v", err)
				continue
			}
			program.Send(PacketMsg{Commands: commands})
		}
	}()
}

func decodePacket(packet []byte) ([]protocol.Command, error) {
	commands := make([]protocol.Command, 0, 32)
	for offset := 0; offset < len(packet); {
		command, err := protocol.DecodeCommand(packet[offset:])
		if err != nil {
			return commands, err
		}
		if command.Size <= 0 {
			return commands, io.ErrNoProgress
		}
		commands = append(commands, command)
		offset += command.Size
	}
	return commands, nil
}
