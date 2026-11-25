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

// noTimeout is an escape timeout that never ends within a test. A key that arrives under it was not delivered by the
// timeout, whatever the load on the machine, so no assertion here compares durations.
const noTimeout = time.Hour

// newKeyStream starts the decoder over a pipe. With marked false the pipe is read as the library reads a terminal
// today, which is the control that shows the fault.
func newKeyStream(t *testing.T, marked bool, escTimeout time.Duration) *keyStream {
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
		terminalReader := uv.NewTerminalReader(source, "xterm-256color")
		terminalReader.EscTimeout = escTimeout
		_ = terminalReader.StreamEvents(ctx, events)
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
			// The library delivers Alt and a key when its timeout ends, so this one runs with the real timeout.
			stream := newKeyStream(t, true, uv.DefaultEscTimeout)
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
			// The escape timeout never ends here, so both keys arriving at all shows neither waited for it.
			stream := newKeyStream(t, true, noTimeout)
			stream.write("\x1b")
			stream.write(tc.next)

			if first, _ := stream.next(); first != escape {
				t.Fatalf("first key = %+v, want the Esc key", first)
			}
			if tc.next == "\x1b" {
				// The second Esc is a lone ESC again, so it waits for the timeout like any lone Esc.
				stream.none()
				return
			}
			if second, _ := stream.next(); second != tc.want {
				t.Fatalf("second key = %+v, want %+v", second, tc.want)
			}
			stream.none()
		})
	}
}

func TestWithoutTheMarkTwoReadsAreJoinedIntoAltEnter(t *testing.T) {
	// The control: this is the fault of #4302, read from the library as it is.
	stream := newKeyStream(t, false, uv.DefaultEscTimeout)
	stream.write("\x1b")
	stream.write("\r")
	got, _ := stream.next()
	if got == escape {
		t.Skip("the machine was too slow to deliver the second read inside the library's escape timeout")
	}
	if got != altEnter {
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
			stream := newKeyStream(t, true, noTimeout)
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
			marked, plain := newKeyStream(t, true, noTimeout), newKeyStream(t, false, noTimeout)
			for _, write := range tc.writes {
				marked.write(write)
				plain.write(write)
			}
			for _, want := range tc.want {
				// Arriving at all under an escape timeout that never ends: no key waits for it.
				if got, _ := marked.next(); got != want {
					t.Fatalf("got %+v, want %+v", got, want)
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
	// The wait is what lets a sequence split after its first byte be joined. It is the library's, and unchanged.
	// Under an escape timeout that never ends, a lone Esc is held: nothing delivers it.
	held := newKeyStream(t, true, noTimeout)
	held.write("\x1b")
	held.none()

	// Under the real timeout it is delivered once the timeout ends.
	stream := newKeyStream(t, true, uv.DefaultEscTimeout)
	stream.write("\x1b")
	if got, _ := stream.next(); got != escape {
		t.Fatalf("got %+v, want the Esc key", got)
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

// pastedText returns the content of the next paste, with the mark removed as the frontend removes it.
func (s *keyStream) pastedText() string {
	s.t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		select {
		case event := <-s.events:
			if paste, ok := event.(uv.PasteEvent); ok {
				return StripKeyBoundaryMarks(paste.Content)
			}
		case <-deadline:
			s.t.Fatal("no paste arrived")
			return ""
		}
	}
}

func TestAMarkInsideAPasteIsNotPasted(t *testing.T) {
	for name, writes := range map[string][]string{
		"a lone ESC read inside the pasted bytes": {"\x1b[200~ab", "\x1b", "cd\x1b[201~"},
		"the paste ends right after a lone ESC":   {"\x1b[200~ab", "\x1b", "\x1b[201~"},
		"no lone ESC at all":                      {"\x1b[200~ab cd\x1b[201~"},
	} {
		t.Run(name, func(t *testing.T) {
			// The library delivers an ESC inside a paste only when its timeout ends, so this runs with the real one.
			// The pasted text is the same whether the timeout ended before or after the next read.
			marked, plain := newKeyStream(t, true, uv.DefaultEscTimeout), newKeyStream(t, false, uv.DefaultEscTimeout)
			for _, write := range writes {
				marked.write(write)
				plain.write(write)
			}
			// The paste is what the library alone would have pasted: the mark adds nothing to it.
			if got, want := marked.pastedText(), plain.pastedText(); got != want {
				t.Fatalf("pasted %q, want %q", got, want)
			}
		})
	}
}
