package terminal

import (
	"os"
	"testing"
)

func TestSizeFallsBackToEnvironmentForNonTTY(t *testing.T) {
	file := tempFile(t)
	t.Setenv("COLUMNS", "132")
	t.Setenv("LINES", "43")

	width, height := Size(file)

	if width != 132 || height != 43 {
		t.Fatalf("Size() = %dx%d, want 132x43", width, height)
	}
}

func TestSizeFallsBackToDefaultsForInvalidEnvironment(t *testing.T) {
	file := tempFile(t)
	t.Setenv("COLUMNS", "0")
	t.Setenv("LINES", "not-a-number")

	width, height := Size(file)

	if width != defaultCols || height != defaultRows {
		t.Fatalf("Size() = %dx%d, want %dx%d", width, height, defaultCols, defaultRows)
	}
}

func TestSizeFallsBackToDefaultsWithoutTTYOrEnvironment(t *testing.T) {
	t.Setenv("COLUMNS", "")
	t.Setenv("LINES", "")

	width, height := Size(nil)

	if width != defaultCols || height != defaultRows {
		t.Fatalf("Size() = %dx%d, want %dx%d", width, height, defaultCols, defaultRows)
	}
}

func TestClampUint16(t *testing.T) {
	if got := clampUint16(70000); got != ^uint16(0) {
		t.Fatalf("clampUint16(70000) = %d, want %d", got, ^uint16(0))
	}
}

func tempFile(t *testing.T) *os.File {
	t.Helper()

	file, err := os.CreateTemp(t.TempDir(), "terminal")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := file.Close(); err != nil {
			t.Fatalf("failed to close temp file: %v", err)
		}
	})
	return file
}
