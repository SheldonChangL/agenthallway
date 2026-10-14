// Package datadirtest builds what a v0.1.x node left on disk, for the tests of
// the migration that moves it, and checks what is there afterwards.
//
// The node directory is made by this repository's own registry and identity
// packages under the pre-rename names. Their code is v0.1.11's (the rename
// changed no schema and no key format), so what they write is what a v0.1.x
// node wrote. Only test code imports this package.
package datadirtest

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"agenthub.local/agenthub/internal/identity"
	"agenthub.local/agenthub/internal/registry"

	_ "modernc.org/sqlite" // read the copied database file on its own
)

// The real configuration and home directories of the user running the tests,
// read before any test can change the environment. No migration test may
// reach either.
var (
	realConfig, _ = os.UserConfigDir()
	realHome, _   = os.UserHomeDir()
)

// RequireConfined fails the test unless every path is inside the temporary
// directory and outside the real user's configuration directory and home.
//
// The migration under test moves the files of whatever directory it is
// pointed at, and on a developer's machine the default one holds a real node.
func RequireConfined(t testing.TB, paths ...string) {
	t.Helper()
	temporary := resolved(os.TempDir())
	for _, path := range paths {
		absolute := resolved(path)
		if !within(absolute, temporary) {
			t.Fatalf("refusing to run: %s is outside the temporary directory %s", path, temporary)
		}
		for _, real := range []string{realConfig, realHome} {
			if real != "" && within(absolute, resolved(real)) && !within(resolved(real), temporary) {
				t.Fatalf("refusing to run: %s is inside the real %s", path, real)
			}
		}
	}
}

func resolved(path string) string {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	// The longest existing prefix, resolved: /var and /private/var are one
	// directory on macOS, and a path not created yet still has to compare.
	rest := ""
	for current := absolute; ; {
		if real, err := filepath.EvalSymlinks(current); err == nil {
			return filepath.Join(real, rest)
		}
		parent := filepath.Dir(current)
		if parent == current {
			return absolute
		}
		rest = filepath.Join(filepath.Base(current), rest)
		current = parent
	}
}

func within(path, directory string) bool {
	return path == directory || strings.HasPrefix(path, directory+string(filepath.Separator))
}

// Legacy is what identifies the node a fixture holds.
type Legacy struct {
	NodeID      string
	Fingerprint string
	PeerID      string
}

// PeerID is the paired machine every fixture trusts.
const PeerID = "node_peer000000000001"

// WriteLegacy makes dir hold a v0.1.x node: node.key and agenthub.db, with one
// paired peer. With onlyInWAL, every committed row is still in agenthub.db-wal
// (beside its -shm), as a node that was killed leaves them; the function
// checks that the database file on its own does not have them.
func WriteLegacy(t testing.TB, dir string, onlyInWAL bool) Legacy {
	t.Helper()
	RequireConfined(t, dir)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	build := dir
	if onlyInWAL {
		build = t.TempDir()
	}
	ctx := context.Background()
	store, err := registry.Open(ctx, filepath.Join(build, "agenthub.db"))
	if err != nil {
		t.Fatal(err)
	}
	node, err := identity.LoadOrCreate(ctx, store, "", false)
	if err != nil {
		_ = store.Close()
		t.Fatal(err)
	}
	keypair, err := identity.LoadOrCreateKeypair(build)
	if err != nil {
		_ = store.Close()
		t.Fatal(err)
	}
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		_ = store.Close()
		t.Fatal(err)
	}
	if err := store.TrustNode(ctx, registry.TrustedNode{
		NodeID: PeerID, DisplayName: "the other machine", Platform: "linux/amd64",
		PublicKey: identity.EncodePublicKey(public), Fingerprint: identity.Fingerprint(public),
	}); err != nil {
		_ = store.Close()
		t.Fatal(err)
	}
	legacy := Legacy{NodeID: node.ID, Fingerprint: keypair.Fingerprint(), PeerID: PeerID}

	if onlyInWAL {
		// Copied while the database is still open, so nothing has been
		// checkpointed: closing it is what would fold the log in.
		for _, name := range []string{"node.key", "agenthub.db", "agenthub.db-wal", "agenthub.db-shm"} {
			copyFile(t, filepath.Join(build, name), filepath.Join(dir, name))
		}
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	if onlyInWAL {
		requireOnlyInWAL(t, dir)
	}
	return legacy
}

// requireOnlyInWAL checks the fixture's own premise: the database file read
// without its log does not hold the paired peer.
func requireOnlyInWAL(t testing.TB, dir string) {
	t.Helper()
	info, err := os.Stat(filepath.Join(dir, "agenthub.db-wal"))
	if err != nil || info.Size() == 0 {
		t.Fatalf("the fixture has no write-ahead log to migrate: %v", err)
	}
	alone := t.TempDir()
	copyFile(t, filepath.Join(dir, "agenthub.db"), filepath.Join(alone, "agenthub.db"))
	db, err := sql.Open("sqlite", filepath.Join(alone, "agenthub.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = db.Close() }()
	var count int
	err = db.QueryRow(`SELECT count(*) FROM trusted_nodes`).Scan(&count)
	if err == nil && count > 0 {
		t.Fatalf("the database file holds %d paired peer(s) without its log; the fixture tests nothing", count)
	}
}

func copyFile(t testing.TB, from, to string) {
	t.Helper()
	source, err := os.Open(from) // #nosec G304 -- test fixture paths under t.TempDir
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = source.Close() }()
	info, err := source.Stat()
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, info.Mode().Perm()) // #nosec G304 -- test fixture
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(target, source); err != nil {
		_ = target.Close()
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
}

// RequireIdentity opens db and the key beside it the way the node does, and
// fails unless they are the node the fixture made, still paired.
func RequireIdentity(t testing.TB, db string, want Legacy) {
	t.Helper()
	ctx := context.Background()
	store, err := registry.Open(ctx, db)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = store.Close() }()
	node, err := identity.LoadOrCreate(ctx, store, "", false)
	if err != nil {
		t.Fatal(err)
	}
	if node.ID != want.NodeID {
		t.Errorf("node id after the move is %s, want %s: the node became a different node", node.ID, want.NodeID)
	}
	keypair, err := identity.LoadOrCreateKeypair(filepath.Dir(db))
	if err != nil {
		t.Fatal(err)
	}
	if keypair.Fingerprint() != want.Fingerprint {
		t.Errorf("fingerprint after the move is %s, want %s: a new key was made", keypair.Fingerprint(), want.Fingerprint)
	}
	trusted, err := store.TrustedNodes(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, peer := range trusted {
		if peer.NodeID == want.PeerID {
			return
		}
	}
	t.Errorf("the paired peer %s is gone after the move (%d trusted)", want.PeerID, len(trusted))
}

// ForeignNames are the files an unrelated product keeps in a directory that,
// on a case-insensitive volume, is also this product's pre-rename one.
var ForeignNames = []string{
	"session_metadata.sqlite", "approvals/a.json", "claims/b", "hooks/c.sh",
}

// WriteForeign puts those files in dir, with a fixed past modification time
// on every file and directory, so anything that touches them shows.
func WriteForeign(t testing.TB, dir string) {
	t.Helper()
	RequireConfined(t, dir)
	past := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, name := range ForeignNames {
		path := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("not agent hallway's: "+name+"\n"), 0o644); err != nil { // #nosec G306 -- a test file standing in for another product's
			t.Fatal(err)
		}
		if err := os.Chtimes(path, past, past); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range ForeignNames {
		if parent := filepath.Dir(filepath.Join(dir, filepath.FromSlash(name))); parent != filepath.Clean(dir) {
			if err := os.Chtimes(parent, past, past); err != nil {
				t.Fatal(err)
			}
		}
	}
}

// Ours reports whether a top-level name in a data directory is one this
// product writes.
func Ours(name string) bool {
	switch name {
	case "node.key", "agenthub.db", "agenthub.db-wal", "agenthub.db-shm", "agenthub.db-journal",
		"agenthallway.db", "agenthallway.db-wal", "agenthallway.db-shm", "agenthallway.db-journal",
		".migrating-from-agenthub", ".migrating-from-agenthub.tmp":
		return true
	}
	return strings.HasPrefix(name, ".node.key-")
}

// Tree describes every entry under dir — relative path, kind, mode, size,
// content hash and modification time — leaving out this product's own
// top-level files when withoutOurs is set.
func Tree(t testing.TB, dir string, withoutOurs bool) map[string]string {
	t.Helper()
	tree := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		if relative == "." {
			return nil
		}
		if withoutOurs && !strings.Contains(relative, string(filepath.Separator)) && Ours(relative) {
			return nil
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		description := fmt.Sprintf("%s size=%d mtime=%d", info.Mode(), info.Size(), info.ModTime().UnixNano())
		if info.Mode().IsRegular() {
			content, err := os.ReadFile(path) // #nosec G122 G304 -- a test's own temporary directory, nothing else writes it
			if err != nil {
				return err
			}
			sum := sha256.Sum256(content)
			description += " sha256=" + hex.EncodeToString(sum[:])
		}
		tree[filepath.ToSlash(relative)] = description
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return tree
}

// RequireSameTree fails unless two Trees are equal, naming what differs.
func RequireSameTree(t testing.TB, what string, before, after map[string]string) {
	t.Helper()
	var differences []string
	for path, description := range before {
		if after[path] != description {
			differences = append(differences, fmt.Sprintf("%s: was %q, now %q", path, description, after[path]))
		}
	}
	for path, description := range after {
		if _, ok := before[path]; !ok {
			differences = append(differences, fmt.Sprintf("%s: new, %q", path, description))
		}
	}
	sort.Strings(differences)
	if len(differences) > 0 {
		t.Errorf("%s changed:\n  %s", what, strings.Join(differences, "\n  "))
	}
}
