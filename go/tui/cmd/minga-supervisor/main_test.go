package main

import (
	"bytes"
	"io"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func discardLogger() *log.Logger { return log.New(io.Discard, "", 0) }

func TestFindProjectRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "mix.exs"), []byte("# marker"), 0o644); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "go", "tui", "cmd")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := findProjectRoot(nested)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resolve(t, got) != resolve(t, root) {
		t.Fatalf("findProjectRoot = %q, want %q", got, root)
	}
}

func TestFindProjectRoot_NoMarker(t *testing.T) {
	dir := t.TempDir()
	if _, err := findProjectRoot(dir); err == nil {
		t.Fatal("expected an error when no mix.exs exists in any parent, got nil")
	}
}

func resolve(t *testing.T, path string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatalf("EvalSymlinks(%q): %v", path, err)
	}
	return r
}

func TestRendererMtime(t *testing.T) {
	s := &supervisor{logger: discardLogger()}

	s.rendererPath = filepath.Join(t.TempDir(), "does-not-exist")
	if got := s.rendererMtime(); got != 0 {
		t.Fatalf("mtime of missing binary = %d, want 0", got)
	}

	bin := filepath.Join(t.TempDir(), "renderer")
	if err := os.WriteFile(bin, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	s.rendererPath = bin
	if got := s.rendererMtime(); got == 0 {
		t.Fatal("mtime of existing binary = 0, want non-zero")
	}
}

func TestMtimeChanged(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "renderer")
	if err := os.WriteFile(bin, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := &supervisor{logger: discardLogger(), rendererPath: bin}

	var last int64
	if !s.mtimeChanged(&last) {
		t.Fatal("first check against a zero baseline should report changed")
	}
	if s.mtimeChanged(&last) {
		t.Fatal("no rebuild between checks should report unchanged")
	}

	future := time.Now().Add(time.Second)
	if err := os.Chtimes(bin, future, future); err != nil {
		t.Fatal(err)
	}
	if !s.mtimeChanged(&last) {
		t.Fatal("after an mtime bump should report changed")
	}
}

func TestForwardBeamToRenderer_DeliversWhenAttached(t *testing.T) {
	s := &supervisor{logger: discardLogger()}
	var out bytes.Buffer
	s.setRenderer(&out)

	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() {
		s.forwardBeamToRenderer(pr)
		close(done)
	}()

	frames := [][]byte{{0x01, 0x02}, {0x03}, {0xAA, 0xBB, 0xCC}}
	for _, f := range frames {
		if err := protocol.WritePacket(pw, f); err != nil {
			t.Fatal(err)
		}
	}
	_ = pw.Close()
	<-done

	got := readAllPackets(t, out.Bytes())
	if len(got) != len(frames) {
		t.Fatalf("delivered %d frames, want %d", len(got), len(frames))
	}
	for i := range frames {
		if !bytes.Equal(got[i], frames[i]) {
			t.Fatalf("frame %d = %v, want %v", i, got[i], frames[i])
		}
	}
}

func TestForwardBeamToRenderer_DropsWhenDetached(t *testing.T) {
	s := &supervisor{logger: discardLogger()}
	s.setRenderer(nil)

	pr, pw := io.Pipe()
	done := make(chan struct{})
	go func() {
		s.forwardBeamToRenderer(pr)
		close(done)
	}()

	if err := protocol.WritePacket(pw, []byte{0x01, 0x02}); err != nil {
		t.Fatal(err)
	}
	_ = pw.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("forwarder did not return after EOF while detached (possible block on nil renderer)")
	}
}

func readAllPackets(t *testing.T, data []byte) [][]byte {
	t.Helper()
	var out [][]byte
	r := bytes.NewReader(data)
	for {
		pkt, err := protocol.ReadPacket(r)
		if err == io.EOF {
			return out
		}
		if err != nil {
			t.Fatalf("ReadPacket: %v", err)
		}
		out = append(out, pkt)
	}
}
