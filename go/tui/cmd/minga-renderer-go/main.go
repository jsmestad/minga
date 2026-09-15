package main

import (
	"context"
	"fmt"
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

	done := make(chan struct{})
	out := make(chan []byte, 128)

	filter := ui.NewInputFilter()
	model := ui.NewWithTransport(width, height, out, done, filter)
	ctx, stop := context.WithCancel(context.Background())
	defer stop()
	program := tea.NewProgram(model, tea.WithContext(ctx), tea.WithInput(tty), tea.WithOutput(tty), tea.WithFilter(filter.Filter))
	return runSession(program, os.Stdin, os.Stdout, out, done, stop)
}

type programResult struct {
	err error
}

type workerResult struct {
	name string
	err  error
}

func runSession(program *tea.Program, reader io.ReadCloser, writer io.Writer, out chan []byte, done chan struct{}, stop func()) error {
	ended := make(chan workerResult, 3)
	programDone := make(chan programResult, 1)
	go func() {
		_, err := program.Run()
		programDone <- programResult{err: err}
		ended <- workerResult{name: "ui", err: err}
	}()

	readerDone := port.StartReader(program, reader)
	readerJoined := make(chan error, 1)
	go func() {
		err := <-readerDone
		readerJoined <- err
		ended <- workerResult{name: "input", err: err}
	}()
	writerDone := make(chan error, 1)
	go func() {
		err := writePackets(writer, out)
		writerDone <- err
		close(writerDone)
		ended <- workerResult{name: "output", err: err}
	}()

	first := <-ended
	close(done)

	if first.name != "ui" {
		stop()
		<-programDone
	}

	close(out)
	_ = reader.Close()
	if closer, ok := writer.(io.Closer); ok {
		_ = closer.Close()
	}
	if first.name != "input" {
		<-readerJoined
	}
	if first.name != "output" {
		<-writerDone
	}

	if first.err == nil {
		return nil
	}
	if first.name == "ui" {
		return first.err
	}
	return fmt.Errorf("%s transport failed: %w", first.name, first.err)
}

func writePackets(writer io.Writer, packets <-chan []byte) error {
	for packet := range packets {
		if err := protocol.WritePacket(writer, packet); err != nil {
			return err
		}
	}
	return nil
}
