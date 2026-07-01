// Command minga-supervisor is a dev-only hot-reload harness for the Minga TUI.
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
	mtimePollInterval   = 300 * time.Millisecond
	rendererStopTimeout = 3 * time.Second
	beamStopTimeout     = 3 * time.Second
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

	go func() {
		s.forwardBeamToRenderer(beamOut)
		requestShutdown()
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigCh)
	go func() {
		<-sigCh
		logger.Printf("signal received; shutting down")
		requestShutdown()
	}()

	s.runRendererManager(shutdown, requestShutdown)

	_ = beamIn.Close()
	select {
	case <-beamDone:
	case <-time.After(beamStopTimeout):
		logger.Printf("BEAM did not exit in time; killing")
		_ = beamCmd.Process.Kill()
	}
	return nil
}

type supervisor struct {
	rendererPath string
	logOut       io.Writer
	logger       *log.Logger

	beamIn   io.Writer
	beamInMu sync.Mutex

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

func (s *supervisor) writeBeam(pkt []byte) error {
	s.beamInMu.Lock()
	defer s.beamInMu.Unlock()
	return protocol.WritePacket(s.beamIn, pkt)
}

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
			continue
		}
		if err := protocol.WritePacket(w, pkt); err != nil {
			s.logger.Printf("write to renderer failed (likely swapping): %v", err)
		}
	}
}

type rendererHandle struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	done  <-chan error
}

type outcome int

const (
	outcomeShutdown outcome = iota
	outcomeUserQuit
	outcomeReload
	outcomeCrash
)

func (s *supervisor) runRendererManager(shutdown <-chan struct{}, requestShutdown func()) {
	ticker := time.NewTicker(mtimePollInterval)
	defer ticker.Stop()

	lastMtime := s.rendererMtime()

	for {
		h, err := s.spawnRenderer()
		if err != nil {
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
			continue
		case outcomeCrash:
			if !s.awaitRebuild(shutdown, ticker, &lastMtime) {
				return
			}
			continue
		}
	}
}

func (s *supervisor) superviseRenderer(h *rendererHandle, shutdown <-chan struct{}, ticker *time.Ticker, lastMtime *int64) outcome {
	for {
		select {
		case <-shutdown:
			s.stopRenderer(h)
			return outcomeShutdown

		case err := <-h.done:
			s.setRenderer(nil)
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

func (s *supervisor) mtimeChanged(last *int64) bool {
	m := s.rendererMtime()
	if m != *last && m != 0 {
		*last = m
		return true
	}
	return false
}

func (s *supervisor) spawnRenderer() (*rendererHandle, error) {
	cmd := exec.Command(s.rendererPath)
	cmd.Env = os.Environ()
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
		// os/exec's Wait closes stdout, so the read loop must finish before Wait;
		// reordering reintroduces the race the docs warn about.
		done <- cmd.Wait()
	}()

	return &rendererHandle{cmd: cmd, stdin: stdin, done: done}, nil
}

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

func (s *supervisor) rendererMtime() int64 {
	info, err := os.Stat(s.rendererPath)
	if err != nil {
		return 0
	}
	return info.ModTime().UnixNano()
}

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

	// Isolate BEAM in its own process group so a swap-window Ctrl-C hits the
	// supervisor, not BEAM's break handler. The renderer must NOT be isolated: a
	// background process group reading the tty takes SIGTTIN.
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

func projectRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	return findProjectRoot(dir)
}

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
