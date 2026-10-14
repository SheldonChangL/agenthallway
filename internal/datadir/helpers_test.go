package datadir

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"sync"
	"testing"

	"agenthub.local/agenthub/internal/datadir/datadirtest"
)

// tempLayout is a layout under a fresh temporary configuration directory, and
// never under the real one: the default one on a developer's machine holds a
// real node, and Migrate moves files.
func tempLayout(t *testing.T) Layout {
	t.Helper()
	config := t.TempDir()
	datadirtest.RequireConfined(t, config)
	return LayoutFor(config)
}

// none is a machine with no pre-rename service registered.
func none() []string { return nil }

// logBuffer collects what Migrate and Resolve log.
type logBuffer struct {
	mu    sync.Mutex
	lines []string
}

func (b *logBuffer) printf(format string, args ...any) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lines = append(b.lines, fmt.Sprintf(format, args...))
}

func (b *logBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return strings.Join(b.lines, "\n")
}

func (b *logBuffer) contains(text string) bool { return strings.Contains(b.String(), text) }

func readFile(t *testing.T, path string) []byte {
	t.Helper()
	content, err := os.ReadFile(path) // #nosec G304 -- a test path under t.TempDir
	if err != nil {
		t.Fatal(err)
	}
	return content
}

func statOf(t *testing.T, path string) os.FileInfo {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info
}

func requireAbsent(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("%s exists (%v); it should not", path, err)
	}
}

func requirePresent(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); err != nil {
		t.Errorf("%s is missing: %v", path, err)
	}
}
