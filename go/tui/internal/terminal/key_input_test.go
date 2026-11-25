package terminal

import (
	"context"
	"io"
	"testing"
	"time"

	uv "github.com/charmbracelet/ultraviolet"
)

// decodedKey is a key press as the frontend sees it after the mark is resolved.
type decodedKey struct {
	code rune
	mod  uv.KeyMod
}

// keyStream feeds writes through the input library's real reader and decoder, one read per write.
type keyStream struct {
	t      *testing.T
	writer *io.PipeWriter
	events chan uv.Event
}

// newKeyStream starts the decoder over a pipe. With marked false the pipe is read as the library reads a terminal
// today, which is the control that shows the fault.
func newKeyStream(t *testing.T, marked bool) *keyStream {
	t.Helper()
	reader, writer := io.Pipe()
	var source io.Reader = reader
	if marked {
		source = &keyBoundaryReader{source: reader}
	}
	ctx, cancel := context.WithCancel(context.Background())
	events := make(chan uv.Event, 64)
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = uv.NewTerminalReader(source, "xterm-256color").StreamEvents(ctx, events)
	}()
	t.Cleanup(func() {
		cancel()
		_ = writer.Close()
		<-done
	})
	return &keyStream{t: t, writer: writer, events: events}
}

// write delivers the bytes as one read. A pipe write returns when the reader has taken it.
func (s *keyStream) write(data string) {
	s.t.Helper()
	if _, err := s.writer.Write([]byte(data)); err != nil {
		s.t.Fatalf("write %q: %v", data, err)
	}
}

// next returns the next key press and how long it took to arrive, with the mark resolved as the frontend resolves it.
func (s *keyStream) next() (decodedKey, time.Duration) {
	s.t.Helper()
	start := time.Now()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case event := <-s.events:
			press, ok := event.(uv.KeyPressEvent)
			if !ok {
				continue
			}
			mark, escape := BoundaryKey(press.Code, press.Mod.Contains(uv.ModAlt))
			if mark && !escape {
				continue
			}
			if mark {
				return decodedKey{code: uv.KeyEscape}, time.Since(start)
			}
			return decodedKey{code: press.Code, mod: press.Mod}, time.Since(start)
		case <-deadline:
			s.t.Fatal("no key press arrived")
			return decodedKey{}, 0
		}
	}
}

// none fails when another key press arrives within the library's escape timeout and a margin.
func (s *keyStream) none() {
	s.t.Helper()
	select {
	case event := <-s.events:
		if press, ok := event.(uv.KeyPressEvent); ok {
			if mark, escape := BoundaryKey(press.Code, press.Mod.Contains(uv.ModAlt)); !mark || escape {
				s.t.Fatalf("unexpected key press %+v", press)
			}
		}
	case <-time.After(3 * uv.DefaultEscTimeout):
	}
}

var (
	escape   = decodedKey{code: uv.KeyEscape}
	enter    = decodedKey{code: uv.KeyEnter}
	altEnter = decodedKey{code: uv.KeyEnter, mod: uv.ModAlt}
)

func TestEscapeAndAKeyInOneReadAreAltKey(t *testing.T) {
	for name, tc := range map[string]struct {
		bytes string
		want  decodedKey
	}{
		"Alt+Enter": {"\x1b\r", altEnter},
		"Alt+Space": {"\x1b ", decodedKey{code: uv.KeySpace, mod: uv.ModAlt}},
		"Alt+j":     {"\x1bj", decodedKey{code: 'j', mod: uv.ModAlt}},
	} {
		t.Run(name, func(t *testing.T) {
			stream := newKeyStream(t, true)
			stream.write(tc.bytes)
			if got, _ := stream.next(); got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
			stream.none()
		})
	}
}

func TestALoneEscapeThenAKeyInTheNextReadAreTwoKeysWithNoWait(t *testing.T) {
	for name, tc := range map[string]struct {
		next string
		want decodedKey
	}{
		"Esc then Enter": {"\r", enter},
		"Esc then Space": {" ", decodedKey{code: uv.KeySpace}},
		"Esc then j":     {"j", decodedKey{code: 'j'}},
		"Esc then Esc":   {"\x1b", escape},
		"Esc then Up":    {"\x1b[A", decodedKey{code: uv.KeyUp}},
	} {
		t.Run(name, func(t *testing.T) {
			stream := newKeyStream(t, true)
			stream.write("\x1b")
			stream.write(tc.next)

			first, firstWait := stream.next()
			if first != escape {
				t.Fatalf("first key = %+v, want the Esc key", first)
			}
			// The Esc key is delivered when the next key arrives, not when the escape timeout ends.
			if firstWait >= uv.DefaultEscTimeout {
				t.Fatalf("the Esc key waited %v, as long as the escape timeout", firstWait)
			}
			if tc.next == "\x1b" {
				// The second Esc is a lone ESC again, so it waits for the timeout like any lone Esc.
				if second, _ := stream.next(); second != escape {
					t.Fatalf("second key = %+v, want the Esc key", second)
				}
				return
			}
			second, secondWait := stream.next()
			if second != tc.want {
				t.Fatalf("second key = %+v, want %+v", second, tc.want)
			}
			if secondWait >= uv.DefaultEscTimeout {
				t.Fatalf("the second key waited %v, as long as the escape timeout", secondWait)
			}
			stream.none()
		})
	}
}

func TestWithoutTheMarkTwoReadsAreJoinedIntoAltEnter(t *testing.T) {
	// The control: this is the fault of #4302, read from the library as it is.
	stream := newKeyStream(t, false)
	stream.write("\x1b")
	stream.write("\r")
	if got, _ := stream.next(); got != altEnter {
		t.Fatalf("got %+v: the library no longer joins the two reads, so the mark may not be needed", got)
	}
}

func TestASequenceSplitAfterItsFirstByteIsStillOneKey(t *testing.T) {
	for name, tc := range map[string]struct {
		rest string
		want decodedKey
	}{
		"CSI: the up arrow":           {"[A", decodedKey{code: uv.KeyUp}},
		"SS3: the up arrow":           {"OA", decodedKey{code: uv.KeyUp}},
		"CSI: Alt+Enter as CSI u":     {"[13;3u", altEnter},
		"CSI: a modified other key":   {"[27;3;13~", altEnter},
		"CSI: the Esc key as CSI u":   {"[27u", escape},
		"CSI: a shifted arrow, split": {"[1;2A", decodedKey{code: uv.KeyUp, mod: uv.ModShift}},
	} {
		t.Run(name, func(t *testing.T) {
			stream := newKeyStream(t, true)
			stream.write("\x1b")
			stream.write(tc.rest)
			if got, _ := stream.next(); got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
			stream.none()
		})
	}
}

func TestWithEnhancedKeyReportingTheRuleDoesNothing(t *testing.T) {
	for name, tc := range map[string]struct {
		writes []string
		want   []decodedKey
	}{
		"Kitty: Esc then Enter, two writes":    {[]string{"\x1b[27u", "\r"}, []decodedKey{escape, enter}},
		"Kitty: Esc then Enter, one write":     {[]string{"\x1b[27u\r"}, []decodedKey{escape, enter}},
		"Kitty: Esc then Enter, both as CSI u": {[]string{"\x1b[27u", "\x1b[13u"}, []decodedKey{escape, enter}},
		"Kitty: Alt+Enter":                     {[]string{"\x1b[13;3u"}, []decodedKey{altEnter}},
		"modifyOtherKeys: Alt+Enter":           {[]string{"\x1b[27;3;13~"}, []decodedKey{altEnter}},
		"Kitty: Esc then Space, one write":     {[]string{"\x1b[27u "}, []decodedKey{escape, {code: uv.KeySpace}}},
		"Kitty: Super+s":                       {[]string{"\x1b[115;9u"}, []decodedKey{{code: 's', mod: uv.ModSuper}}},
		"Kitty: Ctrl+i is not Tab":             {[]string{"\x1b[105;5u", "\t"}, []decodedKey{{code: 'i', mod: uv.ModCtrl}, {code: uv.KeyTab}}},
		"Kitty: Esc then j":                    {[]string{"\x1b[27u", "j"}, []decodedKey{escape, {code: 'j'}}},
	} {
		t.Run(name, func(t *testing.T) {
			marked, plain := newKeyStream(t, true), newKeyStream(t, false)
			for _, write := range tc.writes {
				marked.write(write)
				plain.write(write)
			}
			for _, want := range tc.want {
				got, wait := marked.next()
				if got != want {
					t.Fatalf("got %+v, want %+v", got, want)
				}
				if wait >= uv.DefaultEscTimeout {
					t.Fatalf("%+v waited %v: with enhanced reporting no key waits for the escape timeout", got, wait)
				}
				// The same bytes decode the same way without the reader: it changed nothing.
				if control, _ := plain.next(); control != want {
					t.Fatalf("without the reader: got %+v, want %+v", control, want)
				}
			}
			marked.none()
		})
	}
}

func TestALoneEscapeWithNothingAfterItIsTheEscKeyAfterTheEscapeTimeout(t *testing.T) {
	stream := newKeyStream(t, true)
	stream.write("\x1b")
	got, wait := stream.next()
	if got != escape {
		t.Fatalf("got %+v, want the Esc key", got)
	}
	// This wait is what lets a sequence split after its first byte be joined. It is the library's, and unchanged.
	if wait < uv.DefaultEscTimeout/2 || wait > 4*uv.DefaultEscTimeout {
		t.Fatalf("a lone Esc arrived after %v; the escape timeout is %v", wait, uv.DefaultEscTimeout)
	}
	stream.none()

	// A key long after it is not marked into anything else.
	stream.write("\r")
	if got, _ := stream.next(); got != enter {
		t.Fatalf("got %+v, want Enter", got)
	}
}

func TestOnlyALoneEscapeMarksTheNextRead(t *testing.T) {
	for name, tc := range map[string]struct {
		writes []string
		marked []bool
	}{
		"a lone ESC marks the next key":             {[]string{"\x1b", "\r"}, []bool{false, true}},
		"the mark is used once":                     {[]string{"\x1b", "a", "b"}, []bool{false, true, false}},
		"a continued sequence is not marked":        {[]string{"\x1b", "[A"}, []bool{false, false}},
		"a string terminator is not marked":         {[]string{"\x1b", "\\"}, []bool{false, false}},
		"text that ends with ESC marks nothing":     {[]string{"ab\x1b", "\r"}, []bool{false, false}},
		"a paste chunk that ends with ESC likewise": {[]string{"\x1b[200~text\x1b", "x\x1b[201~"}, []bool{false, false}},
		"two lone ESCs":                             {[]string{"\x1b", "\x1b", "\r"}, []bool{false, true, true}},
	} {
		t.Run(name, func(t *testing.T) {
			reader, writer := io.Pipe()
			defer writer.Close()
			marked := &keyBoundaryReader{source: reader}
			for i, write := range tc.writes {
				go func() { _, _ = writer.Write([]byte(write)) }()
				buf := make([]byte, 256)
				n, err := marked.Read(buf)
				if err != nil {
					t.Fatal(err)
				}
				got := string(buf[:n])
				want := write
				if tc.marked[i] {
					want = string(keyBoundaryMark) + write
				}
				if got != want {
					t.Fatalf("read %d = %q, want %q", i, got, want)
				}
			}
		})
	}
}

func TestAReadTooSmallForTheMarkPassesThrough(t *testing.T) {
	reader, writer := io.Pipe()
	defer writer.Close()
	marked := &keyBoundaryReader{source: reader}
	for _, write := range []string{"\x1b", "\r"} {
		go func() { _, _ = writer.Write([]byte(write)) }()
		buf := make([]byte, 4)
		n, err := marked.Read(buf)
		if err != nil || string(buf[:n]) != write {
			t.Fatalf("read = %q, %v; want %q", buf[:n], err, write)
		}
	}
}

func TestTheMarkStandsForEscOnlyWithAlt(t *testing.T) {
	if mark, escape := BoundaryKey(keyBoundaryCode, true); !mark || !escape {
		t.Fatal("the mark after a pending ESC is the Esc key")
	}
	if mark, escape := BoundaryKey(keyBoundaryCode, false); !mark || escape {
		t.Fatal("the mark after a delivered Esc key is dropped")
	}
	if mark, _ := BoundaryKey('j', true); mark {
		t.Fatal("Alt+j is a key, not the mark")
	}
}
