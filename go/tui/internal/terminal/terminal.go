package terminal

import (
	"os"
	"strconv"
)

func OpenTTY() (*os.File, error) {
	path := os.Getenv("MINGA_TTY")
	if path == "" {
		path = "/dev/tty"
	}
	return os.OpenFile(path, os.O_RDWR, 0)
}

func Size() (uint16, uint16) {
	cols := envUint16("COLUMNS", 80)
	rows := envUint16("LINES", 24)
	return cols, rows
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
