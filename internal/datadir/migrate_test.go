package datadir

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"testing"

	"agenthub.local/agenthub/internal/datadir/datadirtest"
	"agenthub.local/agenthub/internal/identity"
	"agenthub.local/agenthub/internal/registry"
)

// legacyMachine is a temporary configuration directory whose old directory
// holds a v0.1.x node and, when asked, another product's files.
type legacyMachine struct {
	layout  Layout
	legacy  datadirtest.Legacy
	key     []byte
	foreign map[string]string
}

func newLegacyMachine(t *testing.T, onlyInWAL, foreign bool) legacyMachine {
	t.Helper()
	l := tempLayout(t)
	legacy := datadirtest.WriteLegacy(t, l.Old, onlyInWAL)
	if foreign {
		datadirtest.WriteForeign(t, l.Old)
	}
	return legacyMachine{
		layout:  l,
		legacy:  legacy,
		key:     readFile(t, filepath.Join(l.Old, keyName)),
		foreign: datadirtest.Tree(t, l.Old, true),
	}
}

func migrate(l Layout, logs *logBuffer, edit func(*Options)) error {
	o := Options{LegacyRegistrations: none, Logf: logs.printf}
	if edit != nil {
		edit(&o)
	}
	return Migrate(context.Background(), l, o)
}

// requireMoved is the state a finished migration leaves: the new directory
// holds exactly the key and the renamed database, the old one holds none of
// this product's files, everything else in it is as it was, and opening the
// new directory the way the node does gives the same node, still paired.
func (m legacyMachine) requireMoved(t *testing.T) {
	t.Helper()
	l := m.layout
	if names := dirNames(t, l.New); !reflect.DeepEqual(names, []string{dbName, keyName}) {
		t.Errorf("%s holds %v, want exactly [%s %s]", l.New, names, dbName, keyName)
	}
	if !bytes.Equal(readFile(t, filepath.Join(l.New, keyName)), m.key) {
		t.Error("node.key in the new directory is not the key that was in the old one")
	}
	if runtime.GOOS != "windows" {
		if mode := statOf(t, filepath.Join(l.New, keyName)).Mode().Perm(); mode != 0o600 {
			t.Errorf("node.key is mode %o after the move, want 600", mode)
		}
	}
	if len(m.foreign) > 0 {
		datadirtest.RequireSameTree(t, "the other product's files in "+l.Old, m.foreign, datadirtest.Tree(t, l.Old, false))
	} else {
		requireAbsent(t, l.Old)
	}
	requireAbsent(t, filepath.Join(l.New, markerName))
	datadirtest.RequireIdentity(t, l.NewDB, m.legacy)
}

func dirNames(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	return names
}

func writeTestFile(t *testing.T, path string, content []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
}

// D6.
func TestMigrateMovesOnlyOurFilesAndKeepsTheIdentity(t *testing.T) {
	m := newLegacyMachine(t, false, true)
	stray := filepath.Join(m.layout.Old, ".node.key-123456")
	writeTestFile(t, stray, []byte("a seed that was never installed"))

	var logs logBuffer
	if err := migrate(m.layout, &logs, nil); err != nil {
		t.Fatalf("Migrate = %v\n%s", err, logs.String())
	}
	requireAbsent(t, stray)
	m.requireMoved(t)
	for _, want := range []string{
		"moved this node's identity from " + m.layout.Old + " to " + m.layout.New,
		"node.key; agenthub.db → agenthallway.db", "The node id is unchanged",
		"left " + m.layout.Old + " in place: it also holds 4 entries that are not this node's",
	} {
		if !logs.contains(want) {
			t.Errorf("the log lacks %q:\n%s", want, logs.String())
		}
	}

	// And a second start has nothing to do and says nothing.
	newBefore := datadirtest.Tree(t, m.layout.New, false)
	var again logBuffer
	if err := migrate(m.layout, &again, nil); err != nil {
		t.Fatalf("the second Migrate = %v", err)
	}
	if again.String() != "" {
		t.Errorf("the second start logged %q", again.String())
	}
	datadirtest.RequireSameTree(t, m.layout.New, newBefore, datadirtest.Tree(t, m.layout.New, false))
}

// D7.
func TestMigrateCarriesDataThatWasOnlyInTheWAL(t *testing.T) {
	m := newLegacyMachine(t, true, true)
	var logs logBuffer
	if err := migrate(m.layout, &logs, nil); err != nil {
		t.Fatalf("Migrate = %v\n%s", err, logs.String())
	}
	for _, sidecar := range legacySidecars {
		requireAbsent(t, filepath.Join(m.layout.Old, sidecar))
	}
	// The paired peer was only in the log; RequireIdentity reads it back.
	m.requireMoved(t)
}

// D8.
func TestMigrateRemovesTheOldDirectoryOnlyWhenEmpty(t *testing.T) {
	t.Run("nothing else there", func(t *testing.T) {
		m := newLegacyMachine(t, true, false)
		var logs logBuffer
		if err := migrate(m.layout, &logs, nil); err != nil {
			t.Fatal(err)
		}
		requireAbsent(t, m.layout.Old)
		if !logs.contains("removed the now-empty " + m.layout.Old) {
			t.Errorf("the removal was not logged:\n%s", logs.String())
		}
		m.requireMoved(t)
	})
	t.Run("another product's files there", func(t *testing.T) {
		m := newLegacyMachine(t, true, true)
		var logs logBuffer
		if err := migrate(m.layout, &logs, nil); err != nil {
			t.Fatal(err)
		}
		requirePresent(t, m.layout.Old)
		if !logs.contains("left " + m.layout.Old + " in place") {
			t.Errorf("keeping the directory was not logged:\n%s", logs.String())
		}
		m.requireMoved(t)
	})
}

// D10. A registered v0.1.x service would start the old node on the old
// directory after the identity left it, and the old node would make a new
// one there.
func TestMigrateRefusesWhileALegacyServiceIsRegistered(t *testing.T) {
	m := newLegacyMachine(t, true, true)
	before := datadirtest.Tree(t, m.layout.Old, false)
	registration := filepath.Join(m.layout.Config, "LaunchAgents", "local.agenthub.node.plist")
	var logs logBuffer
	err := migrate(m.layout, &logs, func(o *Options) {
		o.LegacyRegistrations = func() []string { return []string{registration} }
	})
	if !errors.Is(err, ErrLegacyServiceRegistered) {
		t.Fatalf("Migrate = %v, want ErrLegacyServiceRegistered", err)
	}
	for _, want := range []string{registration, "ah service install", "ah service uninstall", m.layout.Old} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q: %v", want, err)
		}
	}
	datadirtest.RequireSameTree(t, m.layout.Old, before, datadirtest.Tree(t, m.layout.Old, false))
	requireAbsent(t, m.layout.New)
}

var errCrash = errors.New("simulated crash")

// D11. The process is killed after each step (§5.5); the next start of the
// same binary finishes the move and the node is the same node. Every row
// first checks that the crash left what the table says it leaves, so a hook
// that fires at the wrong place cannot pass.
func TestMigrateResumesAfterDyingAtEveryStep(t *testing.T) {
	type state struct {
		old, new []string // names present in each directory
		gone     []string // names absent from the old one
		marker   bool
		newDir   bool
	}
	rows := []struct {
		step string
		want state
	}{
		{"M2", state{old: []string{keyName, legacyDBName, legacyDBName + "-wal"}}},
		{"M3", state{old: []string{keyName, legacyDBName}, gone: []string{legacyDBName + "-wal", legacyDBName + "-shm"}}},
		{"M4 directory", state{old: []string{keyName, legacyDBName}, newDir: true}},
		{"M4", state{old: []string{keyName, legacyDBName}, newDir: true, marker: true}},
		{"M5 link", state{old: []string{keyName, legacyDBName}, new: []string{dbName}, newDir: true, marker: true}},
		{"M5", state{old: []string{keyName}, gone: []string{legacyDBName}, new: []string{dbName}, newDir: true, marker: true}},
		{"M6 link", state{old: []string{keyName}, new: []string{dbName, keyName}, newDir: true, marker: true}},
		{"M6", state{gone: []string{keyName, legacyDBName}, new: []string{dbName, keyName}, newDir: true, marker: true}},
		{"M7", state{gone: []string{keyName, ".node.key-77"}, new: []string{dbName, keyName}, newDir: true, marker: true}},
		{"M8", state{gone: []string{keyName, legacyDBName}, new: []string{dbName, keyName}, newDir: true}},
	}
	for _, row := range rows {
		for _, foreign := range []bool{true, false} {
			name := row.step
			if !foreign {
				name += ", nothing else in the old directory"
			}
			t.Run(name, func(t *testing.T) {
				m := newLegacyMachine(t, true, foreign)
				l := m.layout
				stray := filepath.Join(l.Old, ".node.key-77")
				writeTestFile(t, stray, []byte("never installed"))

				var logs logBuffer
				err := migrate(l, &logs, func(o *Options) {
					o.after = func(step string) error {
						if step == row.step {
							return errCrash
						}
						return nil
					}
				})
				if !errors.Is(err, errCrash) {
					t.Fatalf("the crash after %s never came: %v\n%s", row.step, err, logs.String())
				}

				for _, name := range row.want.old {
					requirePresent(t, filepath.Join(l.Old, name))
				}
				for _, name := range row.want.gone {
					requireAbsent(t, filepath.Join(l.Old, name))
				}
				for _, name := range row.want.new {
					requirePresent(t, filepath.Join(l.New, name))
				}
				if row.want.newDir {
					requirePresent(t, l.New)
				} else {
					requireAbsent(t, l.New)
				}
				if row.want.marker {
					requirePresent(t, filepath.Join(l.New, markerName))
				} else {
					requireAbsent(t, filepath.Join(l.New, markerName))
				}
				if row.step == "M5 link" && !os.SameFile(statOf(t, l.OldDB), statOf(t, l.NewDB)) {
					t.Error("after the link the two names are not one file")
				}

				// The next start.
				var next logBuffer
				if err := migrate(l, &next, nil); err != nil {
					t.Fatalf("the start after dying at %s = %v\n%s", row.step, err, next.String())
				}
				requireAbsent(t, stray)
				m.requireMoved(t)
			})
		}
	}
}

// D12.
func TestMigrateNeverOverwritesADifferentFile(t *testing.T) {
	for _, which := range []string{legacyDBName, keyName} {
		t.Run(which, func(t *testing.T) {
			m := newLegacyMachine(t, false, false)
			l := m.layout
			other := t.TempDir()
			datadirtest.WriteLegacy(t, other, false)
			if which == legacyDBName {
				writeTestFile(t, l.NewDB, readFile(t, filepath.Join(other, legacyDBName)))
			} else {
				writeTestFile(t, filepath.Join(l.New, keyName), readFile(t, filepath.Join(other, keyName)))
			}
			if err := writeMarker(l.New, plan{old: l.Old, db: true, key: true}); err != nil {
				t.Fatal(err)
			}
			oldTree := datadirtest.Tree(t, l.Old, false)
			newTree := datadirtest.Tree(t, l.New, false)

			var logs logBuffer
			err := migrate(l, &logs, nil)
			if !errors.Is(err, ErrMigrationConflict) {
				t.Fatalf("Migrate = %v, want ErrMigrationConflict", err)
			}
			if !strings.Contains(err.Error(), "nothing was overwritten") {
				t.Errorf("the refusal does not say nothing was overwritten: %v", err)
			}
			datadirtest.RequireSameTree(t, l.Old, oldTree, datadirtest.Tree(t, l.Old, false))
			datadirtest.RequireSameTree(t, l.New, newTree, datadirtest.Tree(t, l.New, false))
		})
	}
}

// D13. Two identities: the one in the new directory runs, and the old one is
// not merged, moved or deleted.
func TestMigrateLeavesBothWhenTheNewDirectoryAlreadyHoldsANode(t *testing.T) {
	m := newLegacyMachine(t, false, true)
	l := m.layout
	datadirtest.WriteLegacy(t, l.New, false)
	if err := os.Rename(filepath.Join(l.New, legacyDBName), l.NewDB); err != nil {
		t.Fatal(err)
	}
	oldTree := datadirtest.Tree(t, l.Old, false)
	newTree := datadirtest.Tree(t, l.New, false)

	for start := 1; start <= 2; start++ {
		var logs logBuffer
		if err := migrate(l, &logs, nil); err != nil {
			t.Fatalf("start %d: Migrate = %v", start, err)
		}
		// Every start, while it is true.
		for _, want := range []string{"a pre-rename identity is still in " + l.Old, "leaves it alone", "upgrade notes"} {
			if !logs.contains(want) {
				t.Errorf("start %d: the warning lacks %q:\n%s", start, want, logs.String())
			}
		}
	}
	datadirtest.RequireSameTree(t, l.Old, oldTree, datadirtest.Tree(t, l.Old, false))
	datadirtest.RequireSameTree(t, l.New, newTree, datadirtest.Tree(t, l.New, false))
}

// D14.
func TestMigrateRefusesASymlinkedKeyOrDatabase(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	for _, name := range []string{keyName, legacyDBName} {
		t.Run(name, func(t *testing.T) {
			m := newLegacyMachine(t, false, false)
			l := m.layout
			real := filepath.Join(t.TempDir(), name)
			if err := os.Rename(filepath.Join(l.Old, name), real); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(real, filepath.Join(l.Old, name)); err != nil {
				t.Fatal(err)
			}
			before := datadirtest.Tree(t, l.Old, false)
			var logs logBuffer
			err := migrate(l, &logs, nil)
			if err == nil || !strings.Contains(err.Error(), "not a regular file") ||
				!strings.Contains(err.Error(), "nothing was moved") {
				t.Fatalf("Migrate with a symlinked %s = %v", name, err)
			}
			datadirtest.RequireSameTree(t, l.Old, before, datadirtest.Tree(t, l.Old, false))
			requireAbsent(t, l.New)
		})
	}
}

// D15. Half an identity moves as it is, and the log says what v0.1.x would
// have made up for the other half.
func TestMigrateMovesWhateverHalfExists(t *testing.T) {
	t.Run("key only", func(t *testing.T) {
		m := newLegacyMachine(t, false, false)
		l := m.layout
		for _, name := range append([]string{legacyDBName}, legacySidecars...) {
			_ = os.Remove(filepath.Join(l.Old, name))
		}
		var logs logBuffer
		if err := migrate(l, &logs, nil); err != nil {
			t.Fatal(err)
		}
		if names := dirNames(t, l.New); !reflect.DeepEqual(names, []string{keyName}) {
			t.Errorf("%s holds %v", l.New, names)
		}
		if !bytes.Equal(readFile(t, filepath.Join(l.New, keyName)), m.key) {
			t.Error("the key changed")
		}
		requireAbsent(t, l.Old)
		if !logs.contains("a new database, with a new node id, will be created") {
			t.Errorf("the missing database was not explained:\n%s", logs.String())
		}
	})
	t.Run("database only", func(t *testing.T) {
		m := newLegacyMachine(t, false, false)
		l := m.layout
		if err := os.Remove(filepath.Join(l.Old, keyName)); err != nil {
			t.Fatal(err)
		}
		var logs logBuffer
		if err := migrate(l, &logs, nil); err != nil {
			t.Fatal(err)
		}
		if names := dirNames(t, l.New); !reflect.DeepEqual(names, []string{dbName}) {
			t.Errorf("%s holds %v", l.New, names)
		}
		requireAbsent(t, l.Old)
		// W-NOKEY.
		if !logs.contains("holds agenthub.db but no node.key") || !logs.contains("a new key will be generated") {
			t.Errorf("the missing key was not explained:\n%s", logs.String())
		}
		// The node id is in the database, and it moved with it.
		store, err := registry.Open(context.Background(), l.NewDB)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = store.Close() }()
		node, err := identity.LoadOrCreate(context.Background(), store, "", false)
		if err != nil {
			t.Fatal(err)
		}
		if node.ID != m.legacy.NodeID {
			t.Errorf("node id %s, want %s", node.ID, m.legacy.NodeID)
		}
	})
}

// D16. The files are where the marker says, whatever this start's
// configuration directory is.
func TestMigrateResumesFromTheDirectoryInTheMarker(t *testing.T) {
	l := tempLayout(t)
	elsewhere := filepath.Join(l.Config, "another config", "agenthub")
	legacy := datadirtest.WriteLegacy(t, elsewhere, true)
	key := readFile(t, filepath.Join(elsewhere, keyName))
	if err := os.MkdirAll(l.New, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := writeMarker(l.New, plan{old: elsewhere, db: true, key: true}); err != nil {
		t.Fatal(err)
	}
	var logs logBuffer
	if err := migrate(l, &logs, nil); err != nil {
		t.Fatalf("Migrate = %v\n%s", err, logs.String())
	}
	if !logs.contains("names " + elsewhere + " as the pre-rename directory") {
		t.Errorf("the other directory was not mentioned:\n%s", logs.String())
	}
	requireAbsent(t, elsewhere)
	m := legacyMachine{layout: l, legacy: legacy, key: key}
	if names := dirNames(t, l.New); !reflect.DeepEqual(names, []string{dbName, keyName}) {
		t.Errorf("%s holds %v", l.New, names)
	}
	requireAbsent(t, filepath.Join(l.New, markerName))
	datadirtest.RequireIdentity(t, l.NewDB, m.legacy)
}

// D17. A marker whose file is nowhere is not a reason to start fresh: the
// owner decides that, by deleting the marker.
func TestMigrateRefusesAMarkerWhoseFileIsMissing(t *testing.T) {
	t.Run("both missing", func(t *testing.T) {
		l := tempLayout(t)
		if err := os.MkdirAll(l.New, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := writeMarker(l.New, plan{old: l.Old, db: true, key: true}); err != nil {
			t.Fatal(err)
		}
		var logs logBuffer
		err := migrate(l, &logs, nil)
		if err == nil {
			t.Fatal("a marker whose files are nowhere was accepted")
		}
		for _, want := range []string{legacyDBName, "neither", "nothing was created", markerName} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("the refusal does not say %q: %v", want, err)
			}
		}
		requireAbsent(t, filepath.Join(l.New, keyName))
		requireAbsent(t, l.NewDB)
		requirePresent(t, filepath.Join(l.New, markerName))
	})
	t.Run("the key missing after the database moved", func(t *testing.T) {
		m := newLegacyMachine(t, false, false)
		l := m.layout
		if err := os.MkdirAll(l.New, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(l.OldDB, l.NewDB); err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(filepath.Join(l.Old, keyName)); err != nil {
			t.Fatal(err)
		}
		if err := writeMarker(l.New, plan{old: l.Old, db: true, key: true}); err != nil {
			t.Fatal(err)
		}
		var logs logBuffer
		err := migrate(l, &logs, nil)
		if err == nil || !strings.Contains(err.Error(), keyName) || !strings.Contains(err.Error(), "neither") {
			t.Fatalf("Migrate = %v; a key lost mid-move has to stop the node, not become a new key", err)
		}
		requireAbsent(t, filepath.Join(l.New, keyName))
	})
}

// D18.
func TestNothingToMigrateCreatesNothing(t *testing.T) {
	l := tempLayout(t)
	var logs logBuffer
	if err := migrate(l, &logs, nil); err != nil {
		t.Fatal(err)
	}
	requireAbsent(t, l.New)
	requireAbsent(t, l.Old)
	if logs.String() != "" {
		t.Errorf("logged %q with nothing to do", logs.String())
	}
}

// The new directory exists and holds the node; an empty old one left by an
// earlier start is tidied away, and anything else in it is left.
func TestAStartAfterTheMoveRemovesAnEmptyOldDirectoryOnly(t *testing.T) {
	m := newLegacyMachine(t, false, false)
	l := m.layout
	if err := migrate(l, &logBuffer{}, nil); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(l.Old, 0o700); err != nil {
		t.Fatal(err)
	}
	var logs logBuffer
	if err := migrate(l, &logs, nil); err != nil {
		t.Fatal(err)
	}
	requireAbsent(t, l.Old)
	if !logs.contains("removed the now-empty " + l.Old) {
		t.Errorf("the removal was not logged:\n%s", logs.String())
	}

	datadirtest.WriteForeign(t, l.Old)
	before := datadirtest.Tree(t, l.Old, false)
	if err := migrate(l, &logBuffer{}, nil); err != nil {
		t.Fatal(err)
	}
	datadirtest.RequireSameTree(t, l.Old, before, datadirtest.Tree(t, l.Old, false))
}

// Two filesystems cannot be bridged by a hard link, and a copy would leave
// two databases with one heartbeat sequence between them.
func TestMigrateRefusesWhenTheDirectoriesAreOnDifferentFilesystems(t *testing.T) {
	m := newLegacyMachine(t, true, true)
	l := m.layout
	before := datadirtest.Tree(t, l.Old, false)
	var logs logBuffer
	err := migrate(l, &logs, func(o *Options) {
		o.sameFilesystem = func(string, string) (bool, error) { return false, nil }
	})
	if err == nil || !strings.Contains(err.Error(), "different filesystems") ||
		!strings.Contains(err.Error(), "nothing was moved") || !strings.Contains(err.Error(), "by hand") {
		t.Fatalf("Migrate across filesystems = %v", err)
	}
	datadirtest.RequireSameTree(t, l.Old, before, datadirtest.Tree(t, l.Old, false))
	requireAbsent(t, l.New)
}

// A link that fails — EXDEV from a bind mount the device check cannot see,
// or a filesystem without hard links — removes nothing, and once it can
// succeed the next start finishes.
func TestMigrateRemovesNothingWhenTheLinkFails(t *testing.T) {
	m := newLegacyMachine(t, true, true)
	l := m.layout
	var logs logBuffer
	err := migrate(l, &logs, func(o *Options) {
		o.link = func(oldname, newname string) error {
			return &os.LinkError{Op: "link", Old: oldname, New: newname, Err: syscall.EXDEV}
		}
	})
	if err == nil || !strings.Contains(err.Error(), l.OldDB) || !strings.Contains(err.Error(), l.NewDB) ||
		!strings.Contains(err.Error(), "Nothing was removed") {
		t.Fatalf("Migrate with a failing link = %v", err)
	}
	if !errors.Is(err, syscall.EXDEV) {
		t.Errorf("the link's own error is lost: %v", err)
	}
	if !bytes.Equal(readFile(t, filepath.Join(l.Old, keyName)), m.key) {
		t.Error("node.key changed")
	}
	requirePresent(t, l.OldDB)
	requireAbsent(t, l.NewDB)
	requireAbsent(t, filepath.Join(l.New, keyName))

	if err := migrate(l, &logBuffer{}, nil); err != nil {
		t.Fatalf("the next start = %v", err)
	}
	m.requireMoved(t)
}

// A log already under the new name would be applied by SQLite to the
// database moved in beside it.
func TestMigrateRefusesAStrayLogUnderTheNewName(t *testing.T) {
	for _, suffix := range []string{"-wal", "-journal"} {
		t.Run(suffix, func(t *testing.T) {
			m := newLegacyMachine(t, true, false)
			l := m.layout
			stray := l.NewDB + suffix
			writeTestFile(t, stray, []byte("some other database's log"))
			before := datadirtest.Tree(t, l.Old, false)
			err := migrate(l, &logBuffer{}, nil)
			if err == nil || !strings.Contains(err.Error(), stray) || !strings.Contains(err.Error(), "nothing was moved") {
				t.Fatalf("Migrate beside %s = %v", stray, err)
			}
			datadirtest.RequireSameTree(t, l.Old, before, datadirtest.Tree(t, l.Old, false))
			requireAbsent(t, l.NewDB)
		})
	}
}

func TestMigrateRefusesAMarkerItCannotRead(t *testing.T) {
	for name, content := range map[string]string{
		"a relative directory": "agenthub\ndb\nkey\n",
		"an unknown file":      "/somewhere/agenthub\ndb\npasswords\n",
		"nothing at all":       "",
	} {
		t.Run(name, func(t *testing.T) {
			l := tempLayout(t)
			writeTestFile(t, filepath.Join(l.New, markerName), []byte(content))
			err := migrate(l, &logBuffer{}, nil)
			if err == nil || !strings.Contains(err.Error(), "cannot be read as one") {
				t.Fatalf("Migrate with marker %q = %v", content, err)
			}
			requireAbsent(t, filepath.Join(l.New, keyName))
			requireAbsent(t, l.NewDB)
		})
	}
}

// The check for a registered service cannot be left out by accident.
func TestMigrateNeedsToBeToldHowToFindRegistrations(t *testing.T) {
	m := newLegacyMachine(t, false, false)
	before := datadirtest.Tree(t, m.layout.Old, false)
	if err := Migrate(context.Background(), m.layout, Options{}); err == nil {
		t.Fatal("Migrate ran without a way to find pre-rename registrations")
	}
	datadirtest.RequireSameTree(t, m.layout.Old, before, datadirtest.Tree(t, m.layout.Old, false))
}

// The configuration directory is "Application Support" on macOS, and an
// owner's XDG_CONFIG_HOME can hold anything a file name can. The database is
// opened through a file: URI, where a space, # or % would otherwise end or
// change the path. (Not ?: registry.Open, which every node start goes
// through, already cuts a path there.)
func TestMigrateHandlesAwkwardDirectoryNames(t *testing.T) {
	l := LayoutFor(filepath.Join(t.TempDir(), "Application Support #x %41 y"))
	datadirtest.RequireConfined(t, l.Config)
	legacy := datadirtest.WriteLegacy(t, l.Old, true)
	m := legacyMachine{layout: l, legacy: legacy, key: readFile(t, filepath.Join(l.Old, keyName))}
	var logs logBuffer
	if err := migrate(l, &logs, nil); err != nil {
		t.Fatalf("Migrate = %v\n%s", err, logs.String())
	}
	m.requireMoved(t)
}

// One directory under both names would look like two directories that both
// hold a node; left at that, the node would open a new agenthallway.db beside
// the old database and become a new node.
func TestMigrateRefusesOneDirectoryUnderBothNames(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	t.Run("the new name links to the old directory", func(t *testing.T) {
		m := newLegacyMachine(t, false, false)
		l := m.layout
		if err := os.Symlink(l.Old, l.New); err != nil {
			t.Fatal(err)
		}
		before := datadirtest.Tree(t, l.Old, false)
		err := migrate(l, &logBuffer{}, nil)
		if err == nil || !strings.Contains(err.Error(), "same directory") {
			t.Fatalf("Migrate = %v", err)
		}
		datadirtest.RequireSameTree(t, l.Old, before, datadirtest.Tree(t, l.Old, false))
	})
	t.Run("a marker naming the new directory as the old one", func(t *testing.T) {
		m := newLegacyMachine(t, false, false)
		l := m.layout
		if err := os.Rename(l.Old, l.New); err != nil {
			t.Fatal(err)
		}
		if err := writeMarker(l.New, plan{old: l.New, key: true}); err != nil {
			t.Fatal(err)
		}
		err := migrate(l, &logBuffer{}, nil)
		if err == nil || !strings.Contains(err.Error(), "same directory") {
			t.Fatalf("Migrate = %v", err)
		}
		if !bytes.Equal(readFile(t, filepath.Join(l.New, keyName)), m.key) {
			t.Error("node.key is gone or changed")
		}
	})
}

// An old directory that is a symlink is the owner's arrangement: the files
// move out of it, and the link stays.
func TestMigrateLeavesASymlinkedOldDirectoryInPlace(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	l := tempLayout(t)
	target := filepath.Join(l.Config, "real data")
	legacy := datadirtest.WriteLegacy(t, target, true)
	key := readFile(t, filepath.Join(target, keyName))
	if err := os.Symlink(target, l.Old); err != nil {
		t.Fatal(err)
	}
	var logs logBuffer
	if err := migrate(l, &logs, nil); err != nil {
		t.Fatalf("Migrate = %v\n%s", err, logs.String())
	}
	if info, err := os.Lstat(l.Old); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Errorf("the symlink %s is gone or changed: %v", l.Old, err)
	}
	if !logs.contains("it is a link to a directory") {
		t.Errorf("keeping the link was not logged:\n%s", logs.String())
	}
	if !bytes.Equal(readFile(t, filepath.Join(l.New, keyName)), key) {
		t.Error("the key changed")
	}
	datadirtest.RequireIdentity(t, l.NewDB, legacy)
}
