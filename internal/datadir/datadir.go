// Package datadir decides which database a node opens, and moves a node set up
// under the pre-rename name into the directory the current name uses.
//
// Through v0.1.x the node kept its identity in <config>/agenthub: node.key and
// agenthub.db. It now keeps it in <config>/agenthallway, with the database
// named agenthallway.db. Moving the two files is the whole migration, and it is
// done by the node itself at start-up, before it opens anything, because only
// the node knows which database it is about to open and in which environment.
//
// Two facts shape every rule below.
//
// The node mints a new identity when it finds none: identity.LoadOrCreateKeypair
// writes a new node.key when the file is absent, and identity.LoadOrCreate a new
// node id when the database is empty. So a move that went wrong does not look
// like an error, it looks like every pairing vanished. Whenever this package
// cannot move the identity safely it returns an error and the node exits; it
// never falls through to an empty directory.
//
// The old directory is not necessarily ours alone. On macOS
// ~/Library/Application Support/agenthub is the same directory, on a
// case-insensitive volume, as ~/Library/Application Support/AgentHub, which an
// unrelated product of that name uses for its own files. So only files this
// product writes are moved, nothing is ever deleted by directory, and the old
// directory is removed only when it is empty.
package datadir

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"agenthub.local/agenthub/internal/product"
)

const (
	// keyName is identity's keyFileName: the node's signing key, beside the
	// database.
	keyName = "node.key"
	// keyTempPrefix starts the temporary file identity writes a new key into
	// before linking it into place. One can survive a crash; it is never an
	// identity, only a seed that was never installed.
	keyTempPrefix = ".node.key-"

	legacyDBName = product.LegacySlug + ".db"
	dbName       = product.Slug + ".db"

	// markerName is written into the new directory before the first file
	// moves and removed after the last one has. While it exists, the new
	// directory holding a key or a database does not mean the move is over.
	markerName = ".migrating-from-" + product.LegacySlug
	// markerTemp is where the marker is written before it is renamed into
	// place, so that a marker is either absent or whole.
	markerTemp = markerName + ".tmp"
)

// legacySidecars are the files SQLite keeps beside a database. None of them is
// ever moved: the write-ahead log is folded into the database first, and what
// is left of them is stale.
var legacySidecars = []string{legacyDBName + "-wal", legacyDBName + "-shm", legacyDBName + "-journal"}

// Layout is where the node's data lives under one configuration directory,
// under the pre-rename name (Old) and the current one (New).
type Layout struct {
	// Config is os.UserConfigDir() of the process the layout is for.
	Config string
	// Old is <Config>/agenthub, where v0.1.x kept node.key and agenthub.db.
	Old string
	// New is <Config>/agenthallway.
	New string
	// OldDB is <Old>/agenthub.db and NewDB is <New>/agenthallway.db.
	OldDB string
	NewDB string
}

// LayoutFor is the layout under one configuration directory.
func LayoutFor(config string) Layout {
	old := filepath.Join(config, product.LegacySlug)
	current := filepath.Join(config, product.Slug)
	return Layout{
		Config: config,
		Old:    old,
		New:    current,
		OldDB:  filepath.Join(old, legacyDBName),
		NewDB:  filepath.Join(current, dbName),
	}
}

// DefaultLayout is the layout under this process's os.UserConfigDir().
func DefaultLayout() (Layout, error) {
	config, err := os.UserConfigDir()
	if err != nil {
		return Layout{}, fmt.Errorf("find config directory: %w", err)
	}
	return LayoutFor(config), nil
}

// Resolve decides which database the node opens, and whether that database is
// the default one this package manages (and so may migrate into).
//
// Without -db the answer is the new default. A -db that names the new default,
// or names the pre-rename default — exactly, or through another spelling of
// the same directory, such as a symlink or a different case on a
// case-insensitive volume — is the default too: a v0.1.x service unit carries
// the old default as an explicit -db, and opening it as given would leave the
// identity in the old directory forever. Any other -db is used exactly as
// given and never migrated, which is what v0.1.x did with it.
func Resolve(l Layout, given string, wasGiven bool, logf func(string, ...any)) (string, bool, error) {
	if logf == nil {
		logf = log.Printf
	}
	if !wasGiven {
		return l.NewDB, true, nil
	}
	absolute, err := filepath.Abs(given)
	if err != nil {
		return "", false, fmt.Errorf("resolve -db %s: %w", given, err)
	}
	absolute = filepath.Clean(absolute)
	directory, base := filepath.Dir(absolute), filepath.Base(absolute)
	switch {
	case absolute == filepath.Clean(l.NewDB):
		return l.NewDB, true, nil
	case absolute == filepath.Clean(l.OldDB),
		base == legacyDBName && sameDirectory(directory, l.Old):
		logf("-db %s is the pre-rename default location; using %s", given, l.NewDB)
		return l.NewDB, true, nil
	case base == dbName && sameDirectory(directory, l.New):
		// The new default spelled another way. Managed, so that a node that
		// still has its identity in the old directory moves it rather than
		// starting a new one beside it.
		return l.NewDB, true, nil
	}
	return given, false, nil
}

// sameDirectory reports whether two paths name one existing directory.
func sameDirectory(a, b string) bool {
	first, err := os.Stat(a)
	if err != nil || !first.IsDir() {
		return false
	}
	second, err := os.Stat(b)
	if err != nil || !second.IsDir() {
		return false
	}
	return os.SameFile(first, second)
}

var (
	// ErrLegacyInUse means the pre-rename database is open in another process,
	// most likely a v0.1.x node, so it cannot be moved.
	ErrLegacyInUse = errors.New("the pre-rename database is open in another process")
	// ErrLegacyServiceRegistered means a v0.1.x background service is still
	// registered for this user, and could start the old node on the old
	// directory after the identity left it.
	ErrLegacyServiceRegistered = errors.New("the pre-rename background service is still registered")
	// ErrMigrationConflict means a file is already where a pre-rename one
	// would move, and it is a different file. Nothing is ever overwritten.
	ErrMigrationConflict = errors.New("a different file is already where the pre-rename one would move")
)

// refusal is one of the errors above with the full explanation the owner reads.
type refusal struct {
	kind error
	text string
}

func (r *refusal) Error() string { return r.text }
func (r *refusal) Unwrap() error { return r.kind }
