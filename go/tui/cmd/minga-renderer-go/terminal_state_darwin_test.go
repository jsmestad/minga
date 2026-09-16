//go:build darwin

package main

import (
	"fmt"

	"golang.org/x/sys/unix"
)

func snapshotTerminalState(fd uintptr) (string, error) {
	state, err := unix.IoctlGetTermios(int(fd), unix.TIOCGETA)
	if err != nil {
		return "", err
	}
	state.Lflag &^= unix.PENDIN
	return fmt.Sprintf("%#v", *state), nil
}
