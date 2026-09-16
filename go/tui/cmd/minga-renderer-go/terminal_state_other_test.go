//go:build !darwin

package main

func snapshotTerminalState(uintptr) (string, error) {
	return "", nil
}
