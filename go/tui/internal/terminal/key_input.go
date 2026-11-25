package terminal

import (
	"io"
	"os"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// Without enhanced key reporting (the Kitty keyboard protocol or modifyOtherKeys) the Esc key and the Alt modifier
// are the same byte: Esc is ESC, and Alt+Enter is ESC CR. The input library holds a lone ESC for its escape timeout
// and joins whatever arrives in that time, so Esc then Enter typed quickly became Alt+Enter.
//
// KeyInput tells the two apart by how the bytes arrive, with no clock. A terminal writes the bytes of one key
// together, so:
//
//   - ESC and a key in one read are Alt+key.
//   - A read that is only ESC is the Esc key. What the next read brings is a separate key.
//   - The exception is a next read that starts with a byte that continues an escape sequence (see continuesSequence):
//     a slow link may have split the sequence after its first byte, so the library's timeout joins it as before.
//
// With the Kitty keyboard protocol the Esc key is never a lone ESC, so none of this applies. xterm's modifyOtherKeys
// still sends the Esc key as a lone ESC, so the rule applies there too.
//
// The rule cannot see two things. ESC and the key delivered in a single read are Alt+key by definition: a script
// that writes both, a multiplexer that joins them inside its own escape time, a remote link that merges two key
// presses, or a frontend too busy to read between them. And Esc followed inside the escape timeout by a byte that
// continues a sequence reads as it did before.

// keyBoundaryCode is the key code of the mark KeyInput puts between a lone ESC and the separate key after it.
// It is the last private-use code point, which no keyboard produces.
const keyBoundaryCode rune = 0x10FFFD

// keyBoundaryMark is the mark as the Kitty keyboard protocol writes a key press, which the decoder reads in any mode.
//
// After a pending ESC the decoder reads it as Alt + the mark and delivers it at once, because the sequence is
// complete; BoundaryKey turns that into the Esc key. When the library's timeout has already delivered the Esc key, the
// mark arrives without Alt and is dropped. Either way the next key is read on its own, and nothing waits on a clock.
var keyBoundaryMark = []byte("\x1b[1114109u")

// BoundaryKey reports whether a decoded key press is KeyInput's mark, and whether it stands for the Esc key.
// A mark that does not stand for the Esc key is dropped: the Esc key was already delivered.
func BoundaryKey(code rune, alt bool) (mark bool, escape bool) {
	if code != keyBoundaryCode {
		return false, false
	}
	return true, alt
}

// StripKeyBoundaryMarks removes the mark from pasted text. Inside a bracketed paste the decoder keeps the bytes of
// every key that types no text, so a mark put after a lone ESC in the pasted bytes would otherwise be pasted.
func StripKeyBoundaryMarks(text string) string {
	return strings.ReplaceAll(text, string(keyBoundaryMark), "")
}

// continuesSequence reports whether a byte after ESC continues an escape sequence: the introducers of CSI, SS3, DCS,
// OSC, APC, PM and SOS, and the second byte of a string terminator.
func continuesSequence(b byte) bool {
	switch b {
	case '[', 'O', 'P', ']', '_', '^', 'X', '\\':
		return true
	}
	return false
}

// KeyInput is the terminal's input with key boundaries marked. It is the terminal file in every other respect, so
// Bubble Tea still puts it in raw mode and can still cancel a read.
type KeyInput struct {
	*os.File
	keys keyBoundaryReader
}

// NewKeyInput wraps the terminal file the frontend reads its keys from.
func NewKeyInput(tty *os.File) *KeyInput {
	return &KeyInput{File: tty, keys: keyBoundaryReader{source: tty}}
}

// Read reads from the terminal and marks the boundary after a lone ESC.
func (in *KeyInput) Read(p []byte) (int, error) {
	return in.keys.Read(p)
}

// keyBoundaryReader applies the rule to any stream of reads.
type keyBoundaryReader struct {
	source io.Reader
	// afterLoneEscape is true when the previous read was only the ESC byte.
	afterLoneEscape bool
}

func (r *keyBoundaryReader) Read(p []byte) (int, error) {
	mark := len(keyBoundaryMark)
	if len(p) <= mark {
		// No room for a mark. The input library reads with a large buffer, so this is only a guard.
		n, err := r.source.Read(p)
		if n > 0 {
			r.afterLoneEscape = n == 1 && p[0] == ansi.ESC
		}
		return n, err
	}

	// Read past the room a mark needs, so a marked read never has to be returned in two parts.
	n, err := r.source.Read(p[mark:])
	if n == 0 {
		return 0, err
	}
	data := p[mark : mark+n]
	marked := r.afterLoneEscape && !continuesSequence(data[0])
	r.afterLoneEscape = n == 1 && data[0] == ansi.ESC
	if marked {
		copy(p, keyBoundaryMark)
		return mark + n, err
	}
	copy(p, data)
	return n, err
}
