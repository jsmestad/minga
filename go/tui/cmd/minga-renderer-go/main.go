package main

import (
	"io"
	"log"
	"os"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/jsmestad/minga/go/tui/internal/terminal"
	"github.com/jsmestad/minga/go/tui/internal/ui"
)

func main() {
	log.SetOutput(os.Stderr)
	if err := run(); err != nil {
		log.Printf("[GO_TUI/error] %v", err)
		os.Exit(1)
	}
}

func run() error {
	tty, err := terminal.OpenTTY()
	if err != nil {
		return err
	}
	defer tty.Close()

	width, height := terminal.Size(tty)
	if err := protocol.WritePacket(os.Stdout, protocol.EncodeReady(width, height)); err != nil {
		return err
	}

	out := make(chan []byte, 128)
	go writePackets(os.Stdout, out)

	model := ui.New(width, height, out)
	filter := ui.NewInputFilter()
	program := tea.NewProgram(model, tea.WithInput(tty), tea.WithOutput(tty), tea.WithFilter(filter.Filter))
	port.StartReader(program, os.Stdin)

	_, err = program.Run()
	close(out)
	return err
}

func writePackets(writer io.Writer, packets <-chan []byte) {
	for packet := range packets {
		if err := protocol.WritePacket(writer, packet); err != nil {
			log.Printf("[GO_TUI/warn] failed to write port packet: %v", err)
			return
		}
	}
}
