package datadir

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"agenthub.local/agenthub/internal/datadir/datadirtest"
	"agenthub.local/agenthub/internal/registry"
)

// helperEnv makes this test binary hold a database open instead of running
// tests: the other process D9 needs, standing in for a running v0.1.x node.
const (
	helperEnv   = "AGENTHALLWAY_DATADIR_HELPER"
	helperDBEnv = "AGENTHALLWAY_DATADIR_DB"
)

func TestMain(m *testing.M) {
	if os.Getenv(helperEnv) == "1" {
		holdDatabaseOpen(os.Getenv(helperDBEnv))
		return
	}
	os.Exit(m.Run())
}

// holdDatabaseOpen opens path the way a v0.1.x node does, says so on stdout,
// and keeps it open until stdin closes.
func holdDatabaseOpen(path string) {
	store, err := registry.Open(context.Background(), path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "helper:", err)
		os.Exit(2)
	}
	fmt.Println("ready")
	_, _ = io.Copy(io.Discard, os.Stdin)
	if err := store.Close(); err != nil {
		fmt.Fprintln(os.Stderr, "helper:", err)
		os.Exit(3)
	}
	os.Exit(0)
}

// D9. P3 rests on this and on nothing else: SQLite refuses to leave WAL mode
// while any other connection, in this process or another, holds the database
// (a WAL connection keeps a SHARED lock on the database file for as long as it
// is open, and leaving WAL needs EXCLUSIVE). If it did not, a v0.1.x node
// still running on the old directory would have its database moved out from
// under it and go on writing into a file it no longer shares a log with.
//
// Each case ends with the positive control: once the holder lets go, the same
// migration goes through. Without it a refusal for any other reason would
// pass.
func TestMigrateRefusesWhileTheLegacyDatabaseIsOpen(t *testing.T) {
	t.Run("in this process", func(t *testing.T) {
		l := tempLayout(t)
		legacy := datadirtest.WriteLegacy(t, l.Old, true)
		store, err := registry.Open(context.Background(), l.OldDB)
		if err != nil {
			t.Fatal(err)
		}
		requireRefusedWhileHeld(t, l)
		if err := store.Close(); err != nil {
			t.Fatal(err)
		}
		requireMigratesOnceReleased(t, l, legacy)
	})

	t.Run("in another process", func(t *testing.T) {
		l := tempLayout(t)
		legacy := datadirtest.WriteLegacy(t, l.Old, true)
		release := holdInAnotherProcess(t, l.OldDB)
		requireRefusedWhileHeld(t, l)
		release()
		requireMigratesOnceReleased(t, l, legacy)
	})
}

func requireRefusedWhileHeld(t *testing.T, l Layout) {
	t.Helper()
	key := readFile(t, filepath.Join(l.Old, keyName))
	dbBefore := statOf(t, l.OldDB)
	var logs logBuffer
	started := time.Now()
	err := Migrate(context.Background(), l, Options{LegacyRegistrations: none, Logf: logs.printf})
	if !errors.Is(err, ErrLegacyInUse) {
		t.Fatalf("Migrate with the database held open = %v, want ErrLegacyInUse", err)
	}
	// The wait is the one the spec gives: a moment's contention from a node
	// that is exiting is not an answer.
	if waited := time.Since(started); waited < busyFor {
		t.Errorf("gave up after %s; the refusal is meant to come after %s of retries", waited, busyFor)
	}
	for _, want := range []string{l.OldDB, "another process", "nothing was moved"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q: %v", want, err)
		}
	}
	if !bytes.Equal(readFile(t, filepath.Join(l.Old, keyName)), key) {
		t.Error("node.key changed")
	}
	if !os.SameFile(dbBefore, statOf(t, l.OldDB)) {
		t.Error("agenthub.db is no longer the same file")
	}
	requireAbsent(t, l.New)
}

func requireMigratesOnceReleased(t *testing.T, l Layout, legacy datadirtest.Legacy) {
	t.Helper()
	var logs logBuffer
	if err := Migrate(context.Background(), l, Options{LegacyRegistrations: none, Logf: logs.printf}); err != nil {
		t.Fatalf("Migrate once the holder let go = %v\n%s", err, logs.String())
	}
	datadirtest.RequireIdentity(t, l.NewDB, legacy)
}

// holdInAnotherProcess starts this test binary as a v0.1.x node stand-in that
// holds db open, and returns once it says it has.
func holdInAnotherProcess(t *testing.T, db string) (release func()) {
	t.Helper()
	command := exec.Command(os.Args[0], "-test.run=^$") // #nosec G204 -- this test binary, re-executed
	command.Env = append(os.Environ(), helperEnv+"=1", helperDBEnv+"="+db)
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := false
	release = func() {
		if done {
			return
		}
		done = true
		_ = stdin.Close()
		if err := command.Wait(); err != nil {
			t.Errorf("the holding process: %v\n%s", err, stderr.String())
		}
	}
	t.Cleanup(release)
	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil || strings.TrimSpace(line) != "ready" {
		t.Fatalf("the holding process did not open the database: %q %v\n%s", line, err, stderr.String())
	}
	return release
}
