// Command terminal-width exports the scalar cell widths that x/ansi uses for grapheme rendering.
package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"unicode"
	"unicode/utf8"

	"github.com/clipperhouse/displaywidth"
)

const tablePath = "../../lib/minga/core/width_oracle/terminal_cell_widths.tsv"
const regenerate = "cd go/tui && go run ./cmd/terminal-width > " + tablePath

func main() {
	if err := writeWidths(os.Stdout); err != nil {
		log.Fatal(err)
	}
}

func writeWidths(w io.Writer) error {
	out := bufio.NewWriter(w)
	fmt.Fprintln(out, "# Generated from go/tui/go.mod's displaywidth:", regenerate)
	measure := displaywidth.Options{EastAsianWidth: false}
	start, previous := rune(0), 1
	for cp := rune(0); cp <= unicode.MaxRune+1; cp++ {
		width := 1
		if utf8.ValidRune(cp) {
			width = measure.Rune(cp)
		}
		if width == previous {
			continue
		}
		if previous != 1 {
			if _, err := fmt.Fprintf(out, "%X\t%X\t%d\n", start, cp-1, previous); err != nil {
				return err
			}
		}
		start, previous = cp, width
	}
	return out.Flush()
}
