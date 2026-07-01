// Command minga-supervisor is a dev-only hot-reload harness for the Minga TUI.
//
// It launches the BEAM editor in *connected* mode (MINGA_PORT_MODE=connected),
// owning BEAM's stdin/stdout as pipes exactly like the macOS GUI parent does,
// and sits between BEAM and the Go renderer forwarding the {:packet,4} protocol
// in both directions. Because the supervisor (not BEAM) owns BEAM's stdio, it
// can stop and respawn the renderer as many times as it likes WITHOUT BEAM ever
// seeing its frontend die: BEAM stays alive holding all editor state.
//
// On each respawn the fresh renderer sends its `ready` handshake, which the
// supervisor forwards to BEAM; BEAM re-runs its idempotent ready path (see
// MingaEditor.Startup.ensure_session_started/1) and dispatches a full keyframe,
// so the reloaded renderer instantly repaints the untouched editor state.
//
// Reload is triggered by watching the renderer binary's mtime: an external
// `go build` watcher rebuilds go/tui/bin/minga-renderer-go on source change,
// the supervisor notices the new binary, gracefully stops the current renderer
// (by closing its stdin, which the renderer's port reader turns into tea.Quit),
// and spawns the new one.
//
// This is a development tool. It is never spawned by BEAM and is not part of the
// production frontend lifecycle. See lib/minga_editor/frontend/manager.ex for
// the production spawn/connected port handling it deliberately does not touch.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	// mtimePollInterval is how often we stat the renderer binary to detect a
	// rebuild. 300ms keeps reloads feeling immediate without busy-spinning.
	mtimePollInterval = 300 * time.Millisecond

	// rendererStopTimeout bounds how long we wait for a renderer to exit after
	// closing its stdin before we SIGKILL it, so a wedged renderer can't stall a
	// reload forever.
	rendererStopTimeout = 3 * time.Second
)

func main() {
	log.SetFlags(0)
	if err := run(); err != nil {
		log.Printf("[minga-supervisor] fatal: %v", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		rendererPath string
		logPath      string
	)
	flag.StringVar(&rendererPath, "renderer", "", "path to the minga-renderer-go binary (default: <root>/go/tui/bin/minga-renderer-go)")
	flag.StringVar(&logPath, "log", "", "path to the supervisor log file (default: stderr)")
	flag.Parse()

	root, err := projectRoot()
	if err != nil {
		return err
	}
	if rendererPath == "" {
		rendererPath = filepath.Join(root, "go", "tui", "bin", "minga-renderer-go")
	}
	if _, err := os.Stat(rendererPath); err != nil {
		return fmt.Errorf("renderer binary not found at %s (build it first): %w", rendererPath, err)
	}

	// All child stderr and our own diagnostics go to the log file, never to the
	// terminal: the renderer owns the tty (alt-screen + raw mode) and stray
	// writes would corrupt its display. Default to stderr only when no log path
	// is given (e.g. running detached).
	logOut := os.Stderr
	if logPath != "" {
		f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return fmt.Errorf("open log file: %w", err)
		}
		defer f.Close()
		logOut = f
	}
	logger := log.New(logOut, "[minga-supervisor] ", log.LstdFlags)

	// Launch BEAM in connected mode. We own its stdio, so it survives every
	// renderer respawn and only shuts down when we close its stdin (on exit).
	beamCmd, beamIn, beamOut, err := launchBeam(root, flag.Args(), logOut, logger)
	if err != nil {
		return fmt.Errorf("launch BEAM: %w", err)
	}

	s := &supervisor{
		rendererPath: rendererPath,
		beamIn:       beamIn,
		logOut:       logOut,
		logger:       logger,
	}

	shutdown := make(chan struct{})
	var shutdownOnce sync.Once
	requestShutdown := func() { shutdownOnce.Do(func() { close(shutdown) }) }

	// BEAM death (crash, or a normal quit propagated through the port) tears the
	// whole session down.
	beamDone := make(chan struct{})
	go func() {
		_ = beamCmd.Wait()
		logger.Printf("BEAM exited")
		close(beamDone)
		requestShutdown()
	}()

	// Forward render frames BEAM -> current renderer. This runs for the whole
	// session; renderer swaps just change where it writes. If BEAM's stdout
	// closes, BEAM is gone and we shut down.
	go func() {
		s.forwardBeamToRenderer(beamOut)
		requestShutdown()
	}()

	// OS signals (Ctrl-C typically reaches the renderer as a raw byte, so this is
	// mostly a backstop) trigger a clean shutdown.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		logger.Printf("signal received; shutting down")
		requestShutdown()
	}()

	// Own the renderer lifecycle: spawn, watch for rebuilds, reload. Returns when
	// shutdown is requested or the renderer exits on its own (user quit).
	s.runRendererManager(shutdown, requestShutdown)

	// Tear down: closing BEAM's stdin is how connected mode learns its parent is
	// gone (the :eof port option), so BEAM shuts itself down cleanly.
	_ = beamIn.Close()
	select {
	case <-beamDone:
	case <-time.After(rendererStopTimeout):
		logger.Printf("BEAM did not exit in time; killing")
		_ = beamCmd.Process.Kill()
	}
	return nil
}

// supervisor holds the pieces shared across the session: the persistent BEAM
// stdin writer and the swappable current-renderer stdin.
type supervisor struct {
	rendererPath string
	beamIn       io.Writer // BEAM stdin (persistent across renderer swaps)
	logOut       io.Writer // child stderr sink (the log file)
	logger       *log.Logger

	mu     sync.RWMutex
	rendIn io.WriteCloser // current renderer stdin; nil while swapping
}

func (s *supervisor) setRenderer(w io.WriteCloser) {
	s.mu.Lock()
	s.rendIn = w
	s.mu.Unlock()
}

func (s *supervisor) currentRenderer() io.WriteCloser {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.rendIn
}

// forwardBeamToRenderer reads whole protocol frames from BEAM and writes them to
// whichever renderer is currently attached. Frames that arrive while no renderer
// is attached (mid-swap) are dropped on purpose: the next renderer's `ready`
// makes BEAM send a full keyframe, so a dropped delta is always superseded.
func (s *supervisor) forwardBeamToRenderer(beamOut io.Reader) {
	for {
		pkt, err := protocol.ReadPacket(beamOut)
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
				s.logger.Printf("BEAM->renderer read error: %v", err)
			}
			return
		}
		w := s.currentRenderer()
		if w == nil {
			continue // swapping; keyframe on reconnect will rebuild state
		}
		if err := protocol.WritePacket(w, pkt); err != nil {
			// The renderer may be shutting down; drop and keep draining BEAM so
			// backpressure never stalls the editor.
			s.logger.Printf("write to renderer failed (likely swapping): %v", err)
		}
	}
}

// runRendererManager owns the renderer process across its whole lifecycle:
// spawn it, forward its input events to BEAM, watch the binary for rebuilds, and
// reload on change. It returns when shutdown is requested or the renderer exits
// on its own (which we treat as a user quit and propagate to shutdown).
func (s *supervisor) runRendererManager(shutdown <-chan struct{}, requestShutdown func()) {
	ticker := time.NewTicker(mtimePollInterval)
	defer ticker.Stop()

	lastMtime := s.rendererMtime()

	for {
		cmd, stdin, done, err := s.spawnRenderer()
		if err != nil {
			s.logger.Printf("spawn renderer failed: %v", err)
			requestShutdown()
			return
		}

		reload := false
		for !reload {
			select {
			case <-shutdown:
				s.stopRenderer(cmd, stdin, done)
				return

			case <-done:
				// The renderer exited without us asking (user quit with :q, or a
				// crash). Bring the whole session down.
				s.logger.Printf("renderer exited on its own; shutting down")
				s.setRenderer(nil)
				requestShutdown()
				return

			case <-ticker.C:
				m := s.rendererMtime()
				if m != lastMtime && m != 0 {
					lastMtime = m
					s.logger.Printf("renderer binary changed; reloading")
					s.stopRenderer(cmd, stdin, done)
					reload = true
				}
			}
		}
	}
}

// spawnRenderer starts a renderer process wired to BEAM through the supervisor:
// its stdin receives forwarded frames, its stdout (input events + the ready
// handshake) is forwarded to BEAM, and it inherits the controlling terminal so
// its own /dev/tty open lands on the real terminal. The returned done channel
// closes when the process exits.
func (s *supervisor) spawnRenderer() (*exec.Cmd, io.WriteCloser, <-chan struct{}, error) {
	cmd := exec.Command(s.rendererPath)
	cmd.Env = os.Environ() // MINGA_TTY, if set, is inherited; else renderer uses /dev/tty
	cmd.Stderr = s.logOut

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, nil, nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, nil, nil, err
	}

	s.setRenderer(stdin)

	// Forward renderer -> BEAM (input events and the ready handshake). Only one
	// renderer runs at a time, so writes to BEAM's stdin stay serialized.
	go func() {
		for {
			pkt, err := protocol.ReadPacket(stdout)
			if err != nil {
				return
			}
			if err := protocol.WritePacket(s.beamIn, pkt); err != nil {
				s.logger.Printf("renderer->BEAM write error: %v", err)
				return
			}
		}
	}()

	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()

	return cmd, stdin, done, nil
}

// stopRenderer gracefully stops the current renderer. Closing its stdin makes
// the renderer's port reader hit EOF and issue tea.Quit, so bubbletea restores
// the terminal (leaves alt-screen, disables raw mode) on the way out. If it does
// not exit within rendererStopTimeout we SIGKILL it as a backstop.
func (s *supervisor) stopRenderer(cmd *exec.Cmd, stdin io.WriteCloser, done <-chan struct{}) {
	s.setRenderer(nil)
	_ = stdin.Close()
	select {
	case <-done:
	case <-time.After(rendererStopTimeout):
		s.logger.Printf("renderer did not exit after stdin close; killing")
		_ = cmd.Process.Kill()
		<-done
	}
}

// rendererMtime returns the renderer binary's mtime in nanoseconds, or 0 if it
// can't be stat'd (e.g. mid-rebuild, when the watcher has removed it briefly).
func (s *supervisor) rendererMtime() int64 {
	info, err := os.Stat(s.rendererPath)
	if err != nil {
		return 0
	}
	return info.ModTime().UnixNano()
}

// launchBeam starts the dev BEAM editor in connected mode with its stdio wired
// to pipes we own. We skip the Go renderer build (MINGA_SKIP_GO_TUI_BUILD=1)
// because the external watcher owns building it; letting mix rebuild it too
// would fight the watcher over the same binary.
func launchBeam(root string, args []string, stderr io.Writer, logger *log.Logger) (*exec.Cmd, io.WriteCloser, io.ReadCloser, error) {
	mixArgs := append([]string{"minga"}, args...)
	cmd := exec.Command("mix", mixArgs...)
	cmd.Dir = root
	cmd.Env = append(os.Environ(),
		"MINGA_PORT_MODE=connected",
		"MINGA_CONNECTED_BACKEND=tui",
		"MINGA_SKIP_GO_TUI_BUILD=1",
	)
	cmd.Stderr = stderr

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, nil, nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, nil, err
	}
	logger.Printf("launching BEAM: mix %v (cwd=%s)", mixArgs, root)
	if err := cmd.Start(); err != nil {
		return nil, nil, nil, err
	}
	return cmd, stdin, stdout, nil
}

// projectRoot walks up from the working directory to the nearest directory
// containing mix.exs, so the supervisor can be launched from anywhere in the
// tree and still run `mix minga` from the project root.
func projectRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "mix.exs")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("could not find project root (no mix.exs in any parent directory)")
		}
		dir = parent
	}
}
