package protocol

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// Cross-language golden coverage (ticket #2225, AC 3).
//
// The fixtures in testdata/golden/manifest.json are produced by the production
// Elixir GUI adapter encoders (`mix protocol.golden`): each entry carries the
// payload bytes a frontend decodes plus the field values the generated decoder
// must produce. This test decodes every payload with the schema-generated Go
// decoder (generated.GoldenDecode) and compares it field-by-field against the
// expected values. Because both the bytes and the expected values come from the
// same Elixir model, any drift between the hand-written encoders and the
// generated decoders fails here: the structural anti-drift guarantee the ticket
// is after.
//
// This test lives in the protocol package (not internal/generated) so that
// `mix protocol.gen`, which rewrites generated/, can never clobber it. Keep the
// manifest in sync with `MIX_ENV=test mix protocol.golden`.

type goldenFixture struct {
	Name     string          `json:"name"`
	Decoder  string          `json:"decoder"`
	Payload  string          `json:"payload"`
	Expected json.RawMessage `json:"expected"`
}

func loadGoldenManifest(t *testing.T) []goldenFixture {
	t.Helper()

	path := filepath.Join("testdata", "golden", "manifest.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden manifest %s: %v", path, err)
	}

	var fixtures []goldenFixture
	if err := json.Unmarshal(raw, &fixtures); err != nil {
		t.Fatalf("parse golden manifest: %v", err)
	}
	if len(fixtures) == 0 {
		t.Fatal("golden manifest is empty")
	}
	return fixtures
}

func TestCrossLanguageGoldenDecode(t *testing.T) {
	for _, fixture := range loadGoldenManifest(t) {
		fixture := fixture
		t.Run(fixture.Name, func(t *testing.T) {
			payload, err := base64.StdEncoding.DecodeString(fixture.Payload)
			if err != nil {
				t.Fatalf("decode payload base64: %v", err)
			}

			decoded, consumed, err := generated.GoldenDecode(fixture.Decoder, payload)
			if err != nil {
				t.Fatalf("GoldenDecode(%q): %v", fixture.Decoder, err)
			}
			if consumed != len(payload) {
				t.Fatalf("decoder consumed %d bytes, payload has %d; trailing bytes indicate a framing mismatch", consumed, len(payload))
			}

			got := normalizeJSON(t, decoded)
			want := normalizeJSON(t, fixture.Expected)

			if !equalValues(got, want) {
				t.Fatalf("field mismatch for %q\n got: %#v\nwant: %#v", fixture.Name, got, want)
			}
		})
	}
}

// equalValues compares two JSON-normalized values, treating a JSON null and an
// empty array as equal. A counted_array a decoder leaves nil (e.g. the items
// tail of a hidden completion) marshals to null, while the same absent list in
// the expected fixture is an empty array; both mean "no elements".
func equalValues(a, b any) bool {
	a = coalesceEmptyList(a)
	b = coalesceEmptyList(b)

	switch av := a.(type) {
	case map[string]any:
		bv, ok := b.(map[string]any)
		if !ok || len(av) != len(bv) {
			return false
		}
		for key, aVal := range av {
			bVal, ok := bv[key]
			if !ok || !equalValues(aVal, bVal) {
				return false
			}
		}
		return true
	case []any:
		bv, ok := b.([]any)
		if !ok || len(av) != len(bv) {
			return false
		}
		for i := range av {
			if !equalValues(av[i], bv[i]) {
				return false
			}
		}
		return true
	default:
		return reflect.DeepEqual(a, b)
	}
}

// coalesceEmptyList normalizes a JSON null to an empty array so an absent and an
// empty counted_array compare equal.
func coalesceEmptyList(v any) any {
	if v == nil {
		return []any{}
	}
	return v
}

// normalizeJSON round-trips a value through JSON into a generic structure so the
// decoded Go struct (PascalCase fields, no tags) and the expected JSON compare
// purely on field names and values, independent of Go type identity.
func normalizeJSON(t *testing.T, value any) any {
	t.Helper()

	var encoded []byte
	var err error

	switch v := value.(type) {
	case json.RawMessage:
		encoded = v
	default:
		encoded, err = json.Marshal(value)
		if err != nil {
			t.Fatalf("marshal value: %v", err)
		}
	}

	var normalized any
	if err := json.Unmarshal(encoded, &normalized); err != nil {
		t.Fatalf("normalize value: %v", err)
	}
	return normalized
}
