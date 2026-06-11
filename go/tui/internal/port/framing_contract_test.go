package port

// Per-frontend framing contract for the Go TUI (generalized from PR #2347).
//
// Why this exists: three times in this project's history a hand-written framing
// authority drifted from the generated schema and desynced a frontend's command
// stream. PR #2347 was the third: the macOS decoder assumed unknown 0x90+ opcodes
// were len16-prefixed, mis-sized the sectioned gui_surface_layout (0xA4), and
// looped the loader. The generated CommandSize table is now the single framing
// authority. PR #2347 added one opcode's regression; this test generalizes it so
// a fourth instance is impossible on the Go side.
//
// What it asserts: for EVERY beam_to_frontend opcode the live port reader can
// frame, a minimal payload followed by a commit_frame sentinel must be consumed
// EXACTLY up to the sentinel by decodePacket (the real reader loop), and the
// sentinel must decode as the next command. If the reader mis-sizes any opcode it
// either swallows the commit_frame (no sentinel) or warns; either fails the test.
//
// How opcodes are enumerated (self-updating on schema regen): the test parses the
// generated opcode constants file (generated/opcodes.go: `OP* byte = 0x..`) for
// the full real opcode set, then classifies each through the live
// generated.CommandSize. Opcodes it sizes (sized or custom) are framed by the
// reader and enter the contract; opcodes it reports unknown are input/parser
// opcodes the reader never frames and are skipped. Because the generated switch
// regenerates from docs/protocol_schema.toml, a newly added beam_to_frontend
// opcode automatically enters this loop the next time `mix protocol.gen` runs.
//
// How minimal payloads are synthesized: a single zero-fill synthesizer, kind- and
// shape-agnostic. For each framed opcode it searches the smallest zero-filled body
// (opcode byte + N zero bytes) such that `decodePacket(body ++ commit_frame)`
// decodes as exactly [opcode, commit_frame] with no warning. Zero bytes mean zero
// section/array counts and zero-length strings, so the search converges on each
// opcode's true minimal bounded frame for both generated-sized framings (fixed /
// len16 / len32 / sectioned) and the hand-written custom decoders (the chrome
// decoders the reader still owns). A decoder that returns len(payload) on a
// truncation fallback swallows the sentinel and is rejected, so a fallback can
// never fake a pass (the #2322 sentinel guarantee).
//
// FAILURE BY DEFAULT IS THE POINT: if a new opcode cannot be framed by any
// zero-filled body within the probe bound (e.g. a new custom decoder that needs
// nonzero structure, or one that mis-frames), the test FAILS loudly naming the
// opcode. Fix the framing or extend minimalBodyOverrides below; do not silence it.

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// commitFrameSentinel is a complete fixed:9 commit_frame. It is appended after
// each opcode's minimal body; the reader must leave it untouched and decode it as
// the second command, proving the first command was framed to its exact length.
var commitFrameSentinel = []byte{generated.OPCommitFrame, 0, 0, 0, 7, 0, 0, 0, 0}

// maxMinimalBodyProbe bounds the zero-fill search. The largest known minimal
// bounded frame (gui_git_status) is ~18 bytes; 48 leaves generous headroom while
// keeping a failed search fast and unambiguous.
const maxMinimalBodyProbe = 48

// minimalBodyOverrides supplies a hand-built minimal body for any opcode whose
// minimal bounded frame a zero-fill cannot express: opcodes whose decoder rejects
// an all-zero length-prefix and requires a nonzero inner length field. Keyed by
// opcode. A new opcode that needs nonzero structure goes here; until it does, the
// contract test fails and names it, which is the intended loud signal.
//
// Each override is validated against the live reader exactly like an auto-probed
// body (framesExactly), so a wrong override cannot silently pass.
var minimalBodyOverrides = map[byte][]byte{
	// clipboard_write (len16): decodeClipboardWrite requires payload_len >= 3 and a
	// consistent inner text_len, so an all-zero len16 body is rejected. Minimal:
	// opcode + payload_len(2)=3 + (text_len(2)=0, one filler byte) = 6 bytes.
	generated.OPClipboardWrite: {generated.OPClipboardWrite, 0x00, 0x03, 0x00, 0x00, 0x00},
	// gui_extension_runtime (len32): decodeExtensionRuntime reads two string16
	// fields (extension_id, channel) inside payload_len, so payload_len must be >= 4
	// for two zero-length strings. Minimal: opcode + payload_len(4)=4 + four zero
	// bytes (two empty string16) = 9 bytes.
	generated.OPGuiExtensionRuntime: {generated.OPGuiExtensionRuntime, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00},
}

func TestFramingContractEveryFramedOpcode(t *testing.T) {
	opcodes := loadGeneratedOpcodes(t)

	framed := 0
	for _, op := range opcodes {
		op := op
		// Classify via the live framing authority the reader uses. Probe with a
		// generously sized zero body so sized framings report .OK rather than
		// .Incomplete; the classification only needs sized-vs-custom-vs-unknown.
		probe := append([]byte{op.value}, make([]byte, maxMinimalBodyProbe)...)
		_, status := generated.CommandSize(probe)
		if status == generated.CommandSizeUnknown {
			// Input/parser opcodes the BEAM->frontend reader never frames.
			continue
		}

		framed++
		t.Run(op.name, func(t *testing.T) {
			body, ok := minimalBodyFor(op.value)
			if !ok {
				t.Fatalf("opcode %s (0x%02X) is framed by the reader but no minimal "+
					"zero-filled body within %d bytes yields an exact frame; its decoder "+
					"likely mis-frames or needs nonzero structure. Fix the framing or add "+
					"an entry to minimalBodyOverrides.", op.name, op.value, maxMinimalBodyProbe)
			}
			assertExactFrame(t, op, body)
		})
	}

	if framed == 0 {
		t.Fatal("no framed opcodes discovered; opcode enumeration is broken")
	}
}

// minimalBodyFor returns the smallest body (opcode + zero padding) that frames
// exactly, or an explicit override. ok is false when nothing within the probe
// bound produces an exact frame.
func minimalBodyFor(opcode byte) (body []byte, ok bool) {
	if override, found := minimalBodyOverrides[opcode]; found {
		if framesExactly(override) {
			return override, true
		}
		return nil, false
	}
	for n := 0; n <= maxMinimalBodyProbe; n++ {
		candidate := make([]byte, 1+n)
		candidate[0] = opcode
		if framesExactly(candidate) {
			return candidate, true
		}
	}
	return nil, false
}

// framesExactly reports whether body ++ commit_frame decodes as exactly
// [body's command, commit_frame] with no warning. A panic inside a hand decoder
// on a malformed probe length counts as "this length does not frame": recover and
// report false so the search continues to a valid length. A length that genuinely
// frames never panics, so a real opcode still converges.
func framesExactly(body []byte) (ok bool) {
	defer func() {
		if recover() != nil {
			ok = false
		}
	}()

	batch := make([]byte, 0, len(body)+len(commitFrameSentinel))
	batch = append(batch, body...)
	batch = append(batch, commitFrameSentinel...)

	warned := false
	cmds := decodePacket(batch, func(byte, string) { warned = true })
	if warned || len(cmds) != 2 {
		return false
	}
	return cmds[1].Kind == protocol.CommandCommitFrame
}

// assertExactFrame re-runs the frame for diagnostics, asserting the reader
// consumes the body to exactly the sentinel boundary.
func assertExactFrame(t *testing.T, op generatedOpcode, body []byte) {
	t.Helper()
	batch := make([]byte, 0, len(body)+len(commitFrameSentinel))
	batch = append(batch, body...)
	batch = append(batch, commitFrameSentinel...)

	var warnings []string
	cmds := decodePacket(batch, func(_ byte, text string) { warnings = append(warnings, text) })
	if len(warnings) != 0 {
		t.Fatalf("%s (0x%02X): reader warned while framing a minimal payload: %v",
			op.name, op.value, warnings)
	}
	if len(cmds) != 2 {
		t.Fatalf("%s (0x%02X): minimal frame of %d bytes + sentinel decoded into %d "+
			"commands, want 2 ([opcode, commit_frame]); the opcode was mis-sized and "+
			"swallowed or split the sentinel", op.name, op.value, len(body), len(cmds))
	}
	if cmds[len(cmds)-1].Kind != protocol.CommandCommitFrame {
		t.Fatalf("%s (0x%02X): trailing command is %v, want CommitFrame; the opcode "+
			"frame did not stop at the sentinel boundary", op.name, op.value, cmds[len(cmds)-1].Kind)
	}
}

type generatedOpcode struct {
	name  string
	value byte
}

var opcodeConstLine = regexp.MustCompile(`^\s*(OP[A-Za-z0-9]+)\s+byte\s*=\s*(0x[0-9A-Fa-f]+)`)

// loadGeneratedOpcodes parses generated/opcodes.go for the real opcode set. It
// reads the file from disk (located relative to this test source via
// runtime.Caller) so the list tracks whatever `mix protocol.gen` last wrote;
// there is no hand-maintained opcode list to rot.
func loadGeneratedOpcodes(t *testing.T) []generatedOpcode {
	t.Helper()

	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source to resolve the generated opcodes file")
	}
	// .../go/tui/internal/port/framing_contract_test.go -> .../go/tui/internal/generated/opcodes.go
	path := filepath.Join(filepath.Dir(thisFile), "..", "generated", "opcodes.go")
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open generated opcodes %s: %v", path, err)
	}
	defer f.Close()

	var opcodes []generatedOpcode
	seen := map[byte]bool{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		m := opcodeConstLine.FindStringSubmatch(scanner.Text())
		if m == nil {
			continue
		}
		// GUIAction* sub-opcodes share the byte space of real opcodes and are not
		// wire commands; the OP prefix excludes them (they are GUIAction*, not OP*).
		v, err := strconv.ParseUint(m[2], 0, 8)
		if err != nil {
			t.Fatalf("parse opcode value %q: %v", m[2], err)
		}
		if seen[byte(v)] {
			continue
		}
		seen[byte(v)] = true
		opcodes = append(opcodes, generatedOpcode{name: m[1], value: byte(v)})
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan generated opcodes: %v", err)
	}
	if len(opcodes) == 0 {
		t.Fatalf("no OP* constants parsed from %s; the generated format changed", path)
	}
	return opcodes
}
