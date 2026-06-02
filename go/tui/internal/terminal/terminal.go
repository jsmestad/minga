package terminal

import (
	"os"
	"strconv"

	"github.com/charmbracelet/x/term"
)

func OpenTTY() (*os.File, error) {
	path := os.Getenv("MINGA_TTY")
	if path == "" {
		path = "/dev/tty"
	}
	return os.OpenFile(path, os.O_RDWR, 0)
}

func Size(tty *os.File) (uint16, uint16) {
	if tty != nil && term.IsTerminal(tty.Fd()) {
		width, height, err := term.GetSize(tty.Fd())
		if err == nil && width > 0 && height > 0 {
			return clampUint16(width), clampUint16(height)
		}
	}

	cols := envUint16("COLUMNS", defaultCols)
	rows := envUint16("LINES", defaultRows)
	return cols, rows
}

const (
	defaultCols uint16 = 80
	defaultRows uint16 = 24
)

func clampUint16(value int) uint16 {
	if value > int(^uint16(0)) {
		return ^uint16(0)
	}
	return uint16(value)
}

func envUint16(name string, fallback uint16) uint16 {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}

	parsed, err := strconv.ParseUint(value, 10, 16)
	if err != nil || parsed == 0 {
		return fallback
	}

	return uint16(parsed)
}
