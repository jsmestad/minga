package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/jsmestad/minga/go/tui/internal/ui"
)

func TestWritePacketsPreservesFIFO(t *testing.T) {
	packets := make(chan []byte, 2)
	packets <- []byte("first")
	packets <- []byte("second")
	close(packets)
	var output bytes.Buffer

	if err := writePackets(&output, packets); err != nil {
		t.Fatalf("writePackets error = %v, want nil", err)
	}
	for _, want := range [][]byte{[]byte("first"), []byte("second")} {
		got, err := protocol.ReadPacket(&output)
		if err != nil {
			t.Fatalf("ReadPacket error = %v", err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("packet = %q, want %q", got, want)
		}
	}
}

func TestWritePacketsStopsAfterPartialFrameFailure(t *testing.T) {
	wantErr := errors.New("write failed")
	writer := &partialFailureWriter{err: wantErr}
	packets := make(chan []byte, 2)
	packets <- []byte("first")
	packets <- []byte("must not retry")

	err := writePackets(writer, packets)
	if !errors.Is(err, wantErr) {
		t.Fatalf("writePackets error = %v, want %v", err, wantErr)
	}
	if writer.calls != 2 {
		t.Fatalf("writer calls = %d, want header plus one failed payload write", writer.calls)
	}
	if got := len(packets); got != 1 {
		t.Fatalf("queued packets after failure = %d, want 1 unconsumed packet", got)
	}
}

func TestRunSessionReturnsWriterFailureAndStopsWorkers(t *testing.T) {
	wantErr := errors.New("output unavailable")
	reader, input := io.Pipe()
	defer input.Close()
	out := make(chan []byte, 1)
	out <- []byte("packet")
	done := make(chan struct{})
	ctx, stop := context.WithCancel(context.Background())
	model := ui.NewWithTransport(80, 24, out, done)
	program := tea.NewProgram(model, tea.WithContext(ctx), tea.WithInput(nil), tea.WithoutRenderer())

	err := runSession(program, reader, errorWriter{err: wantErr}, out, done, stop)
	if !errors.Is(err, wantErr) {
		t.Fatalf("runSession error = %v, want %v", err, wantErr)
	}
	select {
	case <-done:
	default:
		t.Fatal("transport termination was not signaled")
	}
}

func TestRunSessionReturnsReaderFailureAndStopsWorkers(t *testing.T) {
	wantErr := errors.New("input unavailable")
	out := make(chan []byte, 1)
	done := make(chan struct{})
	ctx, stop := context.WithCancel(context.Background())
	model := ui.NewWithTransport(80, 24, out, done)
	program := tea.NewProgram(model, tea.WithContext(ctx), tea.WithInput(nil), tea.WithoutRenderer())

	err := runSession(program, &errorReadCloser{err: wantErr}, io.Discard, out, done, stop)
	if !errors.Is(err, wantErr) {
		t.Fatalf("runSession error = %v, want %v", err, wantErr)
	}
	select {
	case <-done:
	default:
		t.Fatal("transport termination was not signaled")
	}
}

func TestRunSessionTreatsReaderEOFAsNormalTermination(t *testing.T) {
	out := make(chan []byte, 1)
	done := make(chan struct{})
	ctx, stop := context.WithCancel(context.Background())
	model := ui.NewWithTransport(80, 24, out, done)
	program := tea.NewProgram(model, tea.WithContext(ctx), tea.WithInput(nil), tea.WithoutRenderer())

	if err := runSession(program, io.NopCloser(bytes.NewReader(nil)), io.Discard, out, done, stop); err != nil {
		t.Fatalf("runSession error = %v, want nil for clean EOF", err)
	}
	select {
	case <-done:
	default:
		t.Fatal("transport termination was not signaled")
	}
}

func TestRunSessionConcurrentFailuresReturnOneTerminalCause(t *testing.T) {
	gate := make(chan struct{})
	started := make(chan struct{}, 2)
	inputErr := errors.New("input failed")
	outputErr := errors.New("output failed")
	out := make(chan []byte, 1)
	out <- []byte("packet")
	done := make(chan struct{})
	ctx, stop := context.WithCancel(context.Background())
	model := ui.NewWithTransport(80, 24, out, done)
	program := tea.NewProgram(model, tea.WithContext(ctx), tea.WithInput(nil), tea.WithoutRenderer())
	result := make(chan error, 1)
	go func() {
		result <- runSession(program, &gatedReadCloser{gate: gate, started: started, err: inputErr}, gatedWriter{gate: gate, started: started, err: outputErr}, out, done, stop)
	}()

	<-started
	<-started
	close(gate)
	err := <-result
	if !errors.Is(err, inputErr) && !errors.Is(err, outputErr) {
		t.Fatalf("runSession error = %v, want one of the concurrent transport failures", err)
	}
}

func TestRunSessionReaderFailureUnblocksProducerBehindFullQueue(t *testing.T) {
	readerGate := make(chan struct{})
	readerStarted := make(chan struct{})
	inputErr := errors.New("input failed")
	writer := newBlockingWriteCloser()
	out := make(chan []byte, 1)
	out <- []byte("being written")
	done := make(chan struct{})
	ctx, stop := context.WithCancel(context.Background())
	model := ui.NewWithTransport(80, 24, out, done)
	program := tea.NewProgram(model, tea.WithContext(ctx), tea.WithInput(nil), tea.WithoutRenderer())
	sessionResult := make(chan error, 1)
	go func() {
		sessionResult <- runSession(program, &gatedReadCloser{gate: readerGate, started: readerStarted, err: inputErr}, writer, out, done, stop)
	}()

	<-writer.started
	<-readerStarted
	out <- []byte("fills queue while writer is blocked")
	producerStarted := make(chan struct{})
	producerDone := make(chan struct{})
	go func() {
		close(producerStarted)
		_, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: 'a', Text: "a"}))
		close(producerDone)
	}()
	<-producerStarted
	select {
	case <-producerDone:
		t.Fatal("producer completed behind full queue before failure")
	default:
	}

	close(readerGate)
	if err := <-sessionResult; !errors.Is(err, inputErr) {
		t.Fatalf("runSession error = %v, want %v", err, inputErr)
	}
	<-producerDone
	if got := len(out); got != 1 {
		t.Fatalf("queued packets after cancellation = %d, want the already admitted packet only", got)
	}
}

func TestRunSessionNormalUIQuitDoesNotWaitForBlockedInput(t *testing.T) {
	// The BEAM keeps stdin open until the renderer exits, and closing a blocking
	// pipe does not interrupt a pending read. A UI quit must still return.
	reader := newUninterruptibleReader()
	defer reader.release()
	writer := &trackedWriteCloser{}
	out := make(chan []byte, 1)
	done := make(chan struct{})
	ctx, stop := context.WithCancel(context.Background())
	program := tea.NewProgram(quittingModel{}, tea.WithContext(ctx), tea.WithInput(nil), tea.WithoutRenderer())
	result := make(chan error, 1)
	go func() { result <- runSession(program, reader, writer, out, done, stop) }()

	select {
	case err := <-result:
		if err != nil {
			t.Fatalf("runSession error = %v, want nil for normal UI quit", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("runSession waited for an input read that closing cannot interrupt")
	}
	if got := reader.closeCount.Load(); got != 1 {
		t.Fatalf("reader close count = %d, want 1", got)
	}
	if got := writer.closeCount.Load(); got != 1 {
		t.Fatalf("writer close count = %d, want 1", got)
	}
}

// TestRendererRestoresTerminalOnEveryExitPath runs a real session on a PTY and
// ends it each way the renderer can be told to stop. Every path must leave the
// alternate screen and return without the BEAM closing stdin first, except the
// EOF path, which is the stdin close itself.
func TestRendererRestoresTerminalOnEveryExitPath(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("BSD script harness is available on macOS")
	}
	if raceEnabled {
		t.Skip("Bubble Tea v2.0.7 races inside cancelreader when a real PTY is closed; the session race suite uses controlled I/O")
	}
	if path := os.Getenv("MINGA_TEST_EXIT_PATH"); path != "" {
		runExitPathHelper(path)
		return
	}

	for _, path := range []string{"renderer_shutdown", "stdin_eof", "sigterm", "sighup"} {
		t.Run(path, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			command := exec.CommandContext(ctx, "/usr/bin/script", "-q", "/dev/null", os.Args[0], "-test.run=^TestRendererRestoresTerminalOnEveryExitPath$")
			command.Env = append(os.Environ(), "MINGA_TEST_EXIT_PATH="+path)
			output, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("exit-path helper failed: %v\n%q", err, output)
			}
			enter := bytes.Index(output, []byte(ansi.SetModeAltScreenSaveCursor))
			if enter < 0 {
				t.Fatalf("helper never entered the alternate screen: %q", output)
			}
			if !bytes.Contains(output[enter:], []byte(ansi.ResetModeAltScreenSaveCursor)) {
				t.Fatalf("%s left the terminal in the alternate screen: %q", path, output)
			}
			if !bytes.Contains(output[enter:], []byte(ansi.ShowCursor)) {
				t.Fatalf("%s left the cursor hidden: %q", path, output)
			}
		})
	}
}

// runExitPathHelper runs inside the PTY. stdin is a blocking pipe, like the
// pipe the BEAM gives the renderer, so a close cannot interrupt its read.
func runExitPathHelper(path string) {
	fail := func(err error) {
		fmt.Fprintf(os.Stderr, "exit-path helper: %v\n", err)
		os.Exit(2)
	}
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		fail(err)
	}
	defer tty.Close()
	var fds [2]int
	if err := syscall.Pipe(fds[:]); err != nil {
		fail(err)
	}
	stdin := os.NewFile(uintptr(fds[0]), "stdin")
	beam := os.NewFile(uintptr(fds[1]), "beam")
	defer beam.Close()

	entered := make(chan struct{})
	out := make(chan []byte, 128)
	done := make(chan struct{})
	ctx, stop := context.WithCancel(context.Background())
	model := ui.NewWithTransport(80, 24, out, done)
	program := tea.NewProgram(model, tea.WithContext(ctx), tea.WithInput(tty), tea.WithOutput(&altScreenWatcher{Writer: tty, entered: entered}))
	stopHangup := quitOnHangup(program)
	defer stopHangup()

	result := make(chan error, 1)
	go func() { result <- runSession(program, stdin, io.Discard, out, done, stop) }()
	select {
	case <-entered:
	case <-time.After(10 * time.Second):
		fail(errors.New("program never entered the alternate screen"))
	}

	switch path {
	case "renderer_shutdown":
		err = protocol.WritePacket(beam, []byte{generated.OPRendererShutdown})
	case "stdin_eof":
		err = beam.Close()
	case "sigterm":
		err = syscall.Kill(os.Getpid(), syscall.SIGTERM)
	case "sighup":
		err = syscall.Kill(os.Getpid(), syscall.SIGHUP)
	default:
		err = fmt.Errorf("unknown exit path %q", path)
	}
	if err != nil {
		fail(err)
	}
	select {
	case err := <-result:
		if err != nil {
			fail(err)
		}
	case <-time.After(10 * time.Second):
		fail(fmt.Errorf("session did not end after %s", path))
	}
}

// altScreenWatcher signals once the program has entered the alternate screen,
// so the helper never ends a session that has not drawn yet.
type altScreenWatcher struct {
	io.Writer
	entered chan struct{}
	once    sync.Once
}

func (watcher *altScreenWatcher) Write(payload []byte) (int, error) {
	n, err := watcher.Writer.Write(payload)
	if bytes.Contains(payload, []byte(ansi.SetModeAltScreenSaveCursor)) {
		watcher.once.Do(func() { close(watcher.entered) })
	}
	return n, err
}

func TestRunSessionRestoresPTYAfterWriterFailure(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("BSD script harness is available on macOS")
	}
	if raceEnabled {
		t.Skip("Bubble Tea v2.0.7 races inside cancelreader when a real PTY is closed; the session race suite uses controlled I/O")
	}
	if os.Getenv("MINGA_TEST_PTY_HELPER") != "1" {
		command := exec.Command("/usr/bin/script", "-q", "/dev/null", os.Args[0], "-test.run=^TestRunSessionRestoresPTYAfterWriterFailure$")
		command.Env = append(os.Environ(), "MINGA_TEST_PTY_HELPER=1")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("PTY helper failed: %v\n%s", err, output)
		}
		return
	}

	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer tty.Close()
	before, err := snapshotTerminalState(tty.Fd())
	if err != nil {
		t.Fatal(err)
	}
	reader, input := io.Pipe()
	defer input.Close()
	out := make(chan []byte, 1)
	done := make(chan struct{})
	ctx, stop := context.WithCancel(context.Background())
	model := ui.NewWithTransport(80, 24, out, done)
	program := tea.NewProgram(model, tea.WithContext(ctx), tea.WithInput(tty), tea.WithOutput(tty))
	wantErr := errors.New("output failed after raw mode")

	if err := runSession(program, reader, errorWriter{err: wantErr}, out, done, stop); !errors.Is(err, wantErr) {
		t.Fatalf("runSession error = %v, want %v", err, wantErr)
	}
	after, err := snapshotTerminalState(tty.Fd())
	if err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Fatalf("terminal state was not restored after transport failure: before=%s after=%s", before, after)
	}
}

func TestClosedStdoutPipeTerminatesWithSIGPIPE(t *testing.T) {
	if os.Getenv("MINGA_TEST_SIGPIPE_HELPER") == "1" {
		packets := make(chan []byte, 1)
		packets <- []byte("packet")
		close(packets)
		if err := writePackets(os.Stdout, packets); err != nil {
			os.Exit(42)
		}
		os.Exit(43)
	}

	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(os.Args[0], "-test.run=^TestClosedStdoutPipeTerminatesWithSIGPIPE$")
	command.Env = append(os.Environ(), "MINGA_TEST_SIGPIPE_HELPER=1")
	command.Stdout = writer
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	err = command.Wait()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("helper error = %v, want signal exit", err)
	}
	status, ok := exitErr.Sys().(syscall.WaitStatus)
	if !ok || status.Signal() != syscall.SIGPIPE {
		t.Fatalf("helper status = %v, want SIGPIPE", status)
	}
}

type partialFailureWriter struct {
	err   error
	calls int
}

func (writer *partialFailureWriter) Write(payload []byte) (int, error) {
	writer.calls++
	if writer.calls == 1 {
		return len(payload), nil
	}
	return min(1, len(payload)), writer.err
}

type errorWriter struct {
	err error
}

func (writer errorWriter) Write([]byte) (int, error) {
	return 0, writer.err
}

type errorReadCloser struct {
	err error
}

func (reader *errorReadCloser) Read([]byte) (int, error) {
	return 0, reader.err
}

func (reader *errorReadCloser) Close() error {
	return nil
}

type gatedReadCloser struct {
	gate    <-chan struct{}
	started chan<- struct{}
	err     error
}

func (reader *gatedReadCloser) Read([]byte) (int, error) {
	reader.started <- struct{}{}
	<-reader.gate
	return 0, reader.err
}

func (reader *gatedReadCloser) Close() error {
	return nil
}

type gatedWriter struct {
	gate    <-chan struct{}
	started chan<- struct{}
	err     error
}

func (writer gatedWriter) Write([]byte) (int, error) {
	writer.started <- struct{}{}
	<-writer.gate
	return 0, writer.err
}

type blockingWriteCloser struct {
	started chan struct{}
	closed  chan struct{}
}

type quittingModel struct{}

func (quittingModel) Init() tea.Cmd {
	return tea.Quit
}

func (model quittingModel) Update(tea.Msg) (tea.Model, tea.Cmd) {
	return model, nil
}

func (quittingModel) View() tea.View {
	return tea.NewView("")
}

// uninterruptibleReader models a blocking stdin pipe: Close does not wake a
// pending Read. release lets the test end the leaked read.
type uninterruptibleReader struct {
	released    chan struct{}
	releaseOnce sync.Once
	closeCount  atomic.Int32
}

func newUninterruptibleReader() *uninterruptibleReader {
	return &uninterruptibleReader{released: make(chan struct{})}
}

func (reader *uninterruptibleReader) Read([]byte) (int, error) {
	<-reader.released
	return 0, io.EOF
}

func (reader *uninterruptibleReader) Close() error {
	reader.closeCount.Add(1)
	return nil
}

func (reader *uninterruptibleReader) release() {
	reader.releaseOnce.Do(func() { close(reader.released) })
}

type trackedWriteCloser struct {
	closeCount atomic.Int32
}

func (writer *trackedWriteCloser) Write(payload []byte) (int, error) {
	return len(payload), nil
}

func (writer *trackedWriteCloser) Close() error {
	writer.closeCount.Add(1)
	return nil
}

func newBlockingWriteCloser() *blockingWriteCloser {
	return &blockingWriteCloser{started: make(chan struct{}), closed: make(chan struct{})}
}

func (writer *blockingWriteCloser) Write([]byte) (int, error) {
	select {
	case <-writer.started:
	default:
		close(writer.started)
	}
	<-writer.closed
	return 0, io.ErrClosedPipe
}

func (writer *blockingWriteCloser) Close() error {
	select {
	case <-writer.closed:
	default:
		close(writer.closed)
	}
	return nil
}
