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

	// beamStopTimeout bounds how long we wait for BEAM to exit after closing its
	// stdin before we kill it.
	beamStopTimeout = 3 * time.Second
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
		if err := beamCmd.Wait(); err != nil {
			logger.Printf("BEAM exited: %v", err)
		} else {
			logger.Printf("BEAM exited cleanly")
		}
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
	defer signal.Stop(sigCh)
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
	case <-time.After(beamStopTimeout):
		logger.Printf("BEAM did not exit in time; killing")
		_ = beamCmd.Process.Kill()
	}
	return nil
}

// supervisor holds the pieces shared across the session: the persistent BEAM
// stdin writer and the swappable current-renderer stdin.
type supervisor struct {
	rendererPath string
	logOut       io.Writer // child stderr sink (the log file)
	logger       *log.Logger

	// beamIn is BEAM's stdin (persistent across renderer swaps). It is io.Writer
	// so no forwarding code can Close it; only run()'s shutdown path does, via the
	// local WriteCloser. beamInMu serializes writes: a whole {:packet,4} frame is
	// two Write calls (header then payload), and during a swap the old and new
	// renderer forwarding goroutines can briefly overlap, so without the lock their
	// header/payload writes could interleave and corrupt the frame BEAM decodes.
	beamIn   io.Writer
	beamInMu sync.Mutex

	// rendIn is the current renderer's stdin, or nil while swapping. It is
	// io.Writer (not io.WriteCloser) so callers can only forward through it; the
	// renderer's lifecycle (including Close) is owned solely by spawnRenderer /
	// stopRenderer via the local WriteCloser they hold. A plain Mutex suffices:
	// the sole reader is forwardBeamToRenderer, so there's no read-parallelism to
	// gain from an RWMutex.
	mu     sync.Mutex
	rendIn io.Writer
}

func (s *supervisor) setRenderer(w io.Writer) {
	s.mu.Lock()
	s.rendIn = w
	s.mu.Unlock()
}

func (s *supervisor) currentRenderer() io.Writer {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rendIn
}

// writeBeam forwards a whole frame to BEAM under beamInMu, keeping header+payload
// atomic against a concurrently-quiescing renderer's forwarding goroutine.
func (s *supervisor) writeBeam(pkt []byte) error {
	s.beamInMu.Lock()
	defer s.beamInMu.Unlock()
	return protocol.WritePacket(s.beamIn, pkt)
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

// rendererHandle bundles a running renderer's process, its stdin (the local
// WriteCloser that owns Close), and a buffered channel delivering its exit error
// exactly once (nil on a clean status-0 exit).
type rendererHandle struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	done  <-chan error
}

// outcome is why a running renderer stopped, which decides what the manager does
// next.
type outcome int

const (
	outcomeShutdown outcome = iota // supervisor is shutting down
	outcomeUserQuit                // renderer exited cleanly; end the session
	outcomeReload                  // binary changed; respawn immediately
	outcomeCrash                   // renderer died on this build; keep BEAM alive
)

// runRendererManager owns the renderer process across its whole lifecycle: spawn
// it, watch the binary for rebuilds, reload on change, and crucially keep BEAM
// alive when a rebuilt renderer crashes (a broken build must not end the
// session). It returns when shutdown is requested or the renderer exits cleanly
// (user quit), which it propagates to shutdown.
func (s *supervisor) runRendererManager(shutdown <-chan struct{}, requestShutdown func()) {
	ticker := time.NewTicker(mtimePollInterval)
	defer ticker.Stop()

	lastMtime := s.rendererMtime()

	for {
		h, err := s.spawnRenderer()
		if err != nil {
			// A spawn failure (e.g. the freshly-built binary is corrupt) must not
			// kill the session either: log it and wait for the next rebuild.
			s.logger.Printf("spawn renderer failed: %v; keeping BEAM alive, waiting for a rebuild", err)
			if !s.awaitRebuild(shutdown, ticker, &lastMtime) {
				return
			}
			continue
		}

		switch s.superviseRenderer(h, shutdown, ticker, &lastMtime) {
		case outcomeShutdown:
			return
		case outcomeUserQuit:
			requestShutdown()
			return
		case outcomeReload:
			continue // binary already changed; respawn straight away
		case outcomeCrash:
			// The rebuilt renderer died. BEAM still holds all editor state, so wait
			// for the developer to fix the build and rebuild, then respawn.
			if !s.awaitRebuild(shutdown, ticker, &lastMtime) {
				return
			}
			continue
		}
	}
}

// superviseRenderer blocks until the running renderer must stop, and reports why.
// On a reload or shutdown it stops the renderer first; on an exit it classifies
// the exit as a clean user quit or a crash.
func (s *supervisor) superviseRenderer(h *rendererHandle, shutdown <-chan struct{}, ticker *time.Ticker, lastMtime *int64) outcome {
	for {
		select {
		case <-shutdown:
			s.stopRenderer(h)
			return outcomeShutdown

		case err := <-h.done:
			s.setRenderer(nil)
			// A renderer only exits status 0 when its stdin hits EOF, which only
			// stopRenderer causes (and that path drains done itself, never reaching
			// here). So a *spontaneous* exit through this case is a crash: the
			// renderer os.Exit(1)s on any run error, and a genuine user quit unwinds
			// through BEAM shutdown -> outcomeShutdown, not this branch. Classify on
			// exit status alone; nil still means "clean, treat as quit" defensively.
			if err == nil {
				s.logger.Printf("renderer exited cleanly (user quit)")
				return outcomeUserQuit
			}
			s.logger.Printf("renderer exited unexpectedly (%v); keeping BEAM alive, waiting for a rebuild", err)
			return outcomeCrash

		case <-ticker.C:
			if s.mtimeChanged(lastMtime) {
				s.logger.Printf("renderer binary changed; reloading")
				s.stopRenderer(h)
				return outcomeReload
			}
		}
	}
}

// awaitRebuild waits, with no renderer running, for the binary to change so we
// can respawn. Returns false if shutdown is requested first.
func (s *supervisor) awaitRebuild(shutdown <-chan struct{}, ticker *time.Ticker, lastMtime *int64) bool {
	for {
		select {
		case <-shutdown:
			return false
		case <-ticker.C:
			if s.mtimeChanged(lastMtime) {
				s.logger.Printf("renderer rebuilt; respawning")
				return true
			}
		}
	}
}

// mtimeChanged reports whether the renderer binary's mtime differs from *last,
// updating *last when it does. A zero mtime (mid-rebuild, binary briefly absent)
// is ignored so a transient stat failure doesn't count as a change.
func (s *supervisor) mtimeChanged(last *int64) bool {
	m := s.rendererMtime()
	if m != *last && m != 0 {
		*last = m
		return true
	}
	return false
}

// spawnRenderer starts a renderer process wired to BEAM through the supervisor:
// its stdin receives forwarded frames, its stdout (input events + the ready
// handshake) is forwarded to BEAM, and it inherits the controlling terminal so
// its own /dev/tty open lands on the real terminal. The returned handle's done
// channel delivers the process's exit exactly once.
func (s *supervisor) spawnRenderer() (*rendererHandle, error) {
	cmd := exec.Command(s.rendererPath)
	cmd.Env = os.Environ() // MINGA_TTY, if set, is inherited; else renderer uses /dev/tty
	cmd.Stderr = s.logOut

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	s.setRenderer(stdin)

	// One goroutine owns the renderer's stdout for its whole life: forward every
	// frame (input events + the ready handshake) to BEAM, then Wait once the read
	// loop drains. Draining before Wait honors the os/exec contract (Wait closes
	// the pipe, so reads must finish first) and guarantees this goroutine is done
	// before stopRenderer returns, so it can't overlap the next renderer's
	// forwarder. writeBeam still holds beamInMu to keep a frame's header+payload
	// atomic. done is buffered so the exit is delivered even if no one is reading
	// yet (e.g. stopRenderer's timeout path).
	done := make(chan error, 1)
	go func() {
		for {
			pkt, err := protocol.ReadPacket(stdout)
			if err != nil {
				break
			}
			if err := s.writeBeam(pkt); err != nil {
				s.logger.Printf("renderer->BEAM write error: %v", err)
				break
			}
		}
		done <- cmd.Wait()
	}()

	return &rendererHandle{cmd: cmd, stdin: stdin, done: done}, nil
}

// stopRenderer gracefully stops the current renderer. Closing its stdin makes
// the renderer's port reader hit EOF and issue tea.Quit, so bubbletea restores
// the terminal (leaves alt-screen, disables raw mode) on the way out. If it does
// not exit within rendererStopTimeout we SIGKILL it as a backstop. It drains the
// handle's done channel, so callers must not read it again.
func (s *supervisor) stopRenderer(h *rendererHandle) {
	s.setRenderer(nil)
	_ = h.stdin.Close()
	select {
	case <-h.done:
	case <-time.After(rendererStopTimeout):
		s.logger.Printf("renderer did not exit after stdin close; killing")
		_ = h.cmd.Process.Kill()
		<-h.done
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

	// Put BEAM in its own process group. During a renderer swap raw mode is
	// briefly torn down, so a Ctrl-C on the terminal is delivered to the whole
	// foreground group as SIGINT; isolating BEAM keeps that signal from reaching
	// its break handler mid-session. The supervisor catches the signal itself and
	// shuts BEAM down cleanly by closing its stdin (:eof). The renderer is
	// deliberately NOT isolated — it needs the controlling terminal, and a
	// background process group reading the tty would take SIGTTIN.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

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
	return findProjectRoot(dir)
}

// findProjectRoot walks up from start to the nearest ancestor containing mix.exs.
func findProjectRoot(start string) (string, error) {
	dir := start
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
