package datadir

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	_ "modernc.org/sqlite" // the driver the node's own registry uses
)

// Options are what Migrate needs from outside this package.
type Options struct {
	// LegacyRegistrations lists the pre-rename service registrations that exist
	// for this user (service.LegacyRegistrationsForCurrentUser). Required: a
	// migration that cannot ask would move the identity out from under a
	// service that starts the old node.
	LegacyRegistrations func() []string
	// Logf receives what the migration did and why it left something alone.
	// Nil means log.Printf.
	Logf func(string, ...any)

	// Test seams. Production leaves them nil: os.Link, os.Remove, nothing,
	// the platform's filesystem check, and the busy wait below.
	link           func(oldname, newname string) error
	remove         func(name string) error
	after          func(step string) error
	sameFilesystem func(a, b string) (bool, error)
	busyFor        time.Duration
	busyEvery      time.Duration
}

const (
	// busyFor is how long a database another connection holds is retried
	// before the node gives up and says so; busyEvery is the interval.
	busyFor   = 3 * time.Second
	busyEvery = 300 * time.Millisecond
	// maxMarkerSize bounds what is read as a marker. A real one is one path
	// and two words.
	maxMarkerSize = 64 << 10
)

// plan is what a migration moves and from where. It is what the marker
// records, so that a start after a crash finishes the same move.
type plan struct {
	old     string
	db, key bool
}

// transfer is one file of a plan.
type transfer struct {
	name     string // what the owner reads
	src, dst string
	step     string
}

type migration struct {
	layout  Layout
	options Options
}

// Migrate moves this node's identity from the pre-rename directory into the
// current one, when there is one to move. It is called only for the default
// database (Resolve's managed answer), before anything opens it.
//
// It returns nil when there is nothing to do, when it moved everything, and
// when the new directory already holds a node (which it then leaves alone).
// Any other outcome is an error the node must exit on: every error path
// leaves the files where a following start finds them, and none of them
// leaves an empty directory for the node to mint a new identity in.
func Migrate(ctx context.Context, l Layout, o Options) error {
	if o.LegacyRegistrations == nil {
		return errors.New("datadir.Migrate needs a way to find pre-rename service registrations")
	}
	if o.Logf == nil {
		o.Logf = log.Printf
	}
	if o.link == nil {
		o.link = os.Link
	}
	if o.remove == nil {
		o.remove = os.Remove
	}
	if o.after == nil {
		o.after = func(string) error { return nil }
	}
	if o.sameFilesystem == nil {
		o.sameFilesystem = sameFilesystem
	}
	if o.busyFor <= 0 {
		o.busyFor = busyFor
	}
	if o.busyEvery <= 0 {
		o.busyEvery = busyEvery
	}
	m := &migration{layout: l, options: o}
	return m.run(ctx)
}

func (m *migration) logf(format string, args ...any) { m.options.Logf(format, args...) }

// step marks the end of one step of the algorithm, where a test may stop the
// migration as a crash would.
func (m *migration) step(name string) error { return m.options.after(name) }

func (m *migration) run(ctx context.Context) error {
	l := m.layout
	marker := filepath.Join(l.New, markerName)

	// A. A marker means a move began and did not finish. It is resumed before
	// anything else is looked at: with a marker, the new directory holding a
	// database says nothing about where the key is.
	resumed, found, err := readMarker(marker, l.New)
	if err != nil {
		return err
	}
	if found {
		if filepath.Clean(resumed.old) != filepath.Clean(l.Old) {
			m.logf("the migration marker %s names %s as the pre-rename directory, not %s; "+
				"finishing the move from there", marker, resumed.old, l.Old)
		}
		return m.resume(ctx, resumed)
	}

	newHolds, err := holdsNode(l.New, l.NewDB)
	if err != nil {
		return err
	}
	oldHolds, err := holdsNode(l.Old, l.OldDB)
	if err != nil {
		return err
	}
	// B. The new directory already holds a node. Never merge, never delete.
	if newHolds {
		if oldHolds {
			m.logf("a pre-rename identity is still in %s (%s/%s); this node runs on %s and leaves it alone. "+
				"If %s is the identity your paired machines know, stop this node and see the upgrade notes.",
				l.Old, keyName, legacyDBName, l.New, l.Old)
			return nil
		}
		if outcome, _ := removeIfEmptyDirectory(l.Old); outcome.removed {
			m.logf("removed the now-empty %s", l.Old)
		}
		return nil
	}
	// C. Nothing to move. A fresh machine; the new directory is created by
	// whatever opens the database.
	if !oldHolds {
		return nil
	}

	// D. M1–M3.
	if err := m.preconditions(ctx, l.Old); err != nil {
		return err
	}
	moving := plan{old: l.Old}
	if moving.db, err = present(l.OldDB); err != nil {
		return err
	}
	if moving.key, err = present(filepath.Join(l.Old, keyName)); err != nil {
		return err
	}
	if !moving.db && !moving.key {
		return fmt.Errorf("the pre-rename identity in %s disappeared while it was being moved; nothing was moved", l.Old)
	}
	m.sayWhatIsMissing(moving)

	// M4. The marker goes down before the first file moves, and is fsynced
	// with its directory, so no crash can leave a key-less new directory
	// that looks like a finished one.
	if err := os.MkdirAll(l.New, 0o700); err != nil {
		return fmt.Errorf("create %s: %w; nothing was moved", l.New, err)
	}
	if err := syncDirectory(filepath.Dir(l.New)); err != nil {
		return err
	}
	if err := m.step("M4 directory"); err != nil {
		return err
	}
	if err := writeMarker(l.New, moving); err != nil {
		return err
	}
	if err := m.step("M4"); err != nil {
		return err
	}
	return m.finish(moving)
}

// resume finishes the move a marker describes.
func (m *migration) resume(ctx context.Context, p plan) error {
	pending := false
	for _, file := range m.transfers(p) {
		inOld, err := present(file.src)
		if err != nil {
			return err
		}
		inNew, err := present(file.dst)
		if err != nil {
			return err
		}
		if !inOld && !inNew {
			return fmt.Errorf("the migration marker %s says %s was being moved from %s, but it is in neither %s nor %s; "+
				"nothing was created. Restore it, or delete %s to start this machine as a new node.",
				filepath.Join(m.layout.New, markerName), file.name, p.old, p.old, m.layout.New,
				filepath.Join(m.layout.New, markerName))
		}
		// Two different files is refused here, before anything below touches
		// either of them; move() checks again, for the window in between.
		if inOld && inNew {
			if err := sameOrConflict(file); err != nil {
				return err
			}
		}
		pending = pending || inOld
	}
	// Something is still to move, so everything that had to hold before the
	// first move has to hold again: a crash is not a reason to skip a check.
	if pending {
		if err := m.preconditions(ctx, p.old); err != nil {
			return err
		}
	}
	return m.finish(p)
}

// preconditions are M1–M3 against the directory the files move out of.
func (m *migration) preconditions(ctx context.Context, old string) error {
	// M1 (P2). A registered pre-rename service starts the old node, which
	// would find this directory without the identity and make a new one.
	if files := m.options.LegacyRegistrations(); len(files) > 0 {
		return &refusal{kind: ErrLegacyServiceRegistered, text: fmt.Sprintf(
			"this node's identity is still in %s and the pre-rename background service is still registered (%s). "+
				"Moving the identity while that service can start the old node would leave the old node to create "+
				"a new identity there. Run `ah service install` (it replaces the old registration and keeps the "+
				"database; pass --db if the old one had one) or `ah service uninstall`, then start this node again.",
			old, strings.Join(files, ", "))}
	}

	// M2. Only regular files move. A link or anything else under one of
	// these names is not what this node wrote there.
	for _, name := range append([]string{keyName, legacyDBName}, legacySidecars...) {
		if err := requireRegularOrAbsent(filepath.Join(old, name)); err != nil {
			return err
		}
	}
	oldDB := filepath.Join(old, legacyDBName)
	dbPending, err := present(oldDB)
	if err != nil {
		return err
	}
	// A write-ahead log or rollback journal already under the new name
	// belongs to no database this node has, and SQLite would apply it to the
	// one about to be moved in as if it were that database's own. (A stray
	// shared-memory index is harmless: the first connection resets it.)
	if dbPending {
		for _, suffix := range []string{"-wal", "-journal"} {
			stray := m.layout.NewDB + suffix
			there, err := present(stray)
			if err != nil {
				return err
			}
			if there {
				return fmt.Errorf("%s is there, and SQLite would apply it to the database about to be moved to %s "+
					"as if it were that database's own; it belongs to no database this node has. Remove it and "+
					"start this again — nothing was moved", stray, m.layout.NewDB)
			}
		}
	}
	if err := m.requireOneFilesystem(old); err != nil {
		return err
	}
	if err := m.step("M2"); err != nil {
		return err
	}

	// M3 (P3). Folding the write-ahead log in is also the proof that nobody
	// else has the database open: SQLite refuses to leave WAL mode while any
	// other connection, in any process, holds the database.
	if dbPending {
		if err := m.consolidate(ctx, oldDB); err != nil {
			return err
		}
		if err := m.step("M3"); err != nil {
			return err
		}
	}
	return nil
}

// requireOneFilesystem refuses a move that cannot be one hard link.
func (m *migration) requireOneFilesystem(old string) error {
	targets := []string{filepath.Dir(m.layout.New)}
	if info, err := os.Stat(m.layout.New); err == nil && info.IsDir() {
		targets = append(targets, m.layout.New)
	}
	for _, target := range targets {
		same, err := m.options.sameFilesystem(old, target)
		if err != nil {
			return fmt.Errorf("compare the filesystems of %s and %s: %w; nothing was moved", old, target, err)
		}
		if !same {
			return fmt.Errorf("%s and %s are on different filesystems, so this node's identity cannot be moved "+
				"into %s in one atomic step; nothing was moved. With no node running, move %s and %s from %s into %s "+
				"by hand, renaming %s to %s (and %s-wal, if there is one, to %s-wal), then start this again",
				old, target, m.layout.New, keyName, legacyDBName, old, m.layout.New,
				legacyDBName, dbName, legacyDBName, dbName)
		}
	}
	return nil
}

// consolidate folds the pre-rename database's write-ahead log into it and
// leaves it in rollback-journal mode, so the database is one file that can be
// moved by itself.
//
// Not registry.Open: that would run this build's schema migrations on a file
// that is not this build's yet, and set WAL mode right back.
func (m *migration) consolidate(ctx context.Context, path string) error {
	db, err := sql.Open("sqlite", sqliteURI(path))
	if err != nil {
		return fmt.Errorf("open %s: %w; nothing was moved", path, err)
	}
	db.SetMaxOpenConns(1)
	defer func() { _ = db.Close() }()

	deadline := time.Now().Add(m.options.busyFor)
	for {
		var mode string
		err := db.QueryRowContext(ctx, "PRAGMA journal_mode=DELETE").Scan(&mode)
		if err == nil && strings.EqualFold(mode, "delete") {
			break
		}
		if err != nil && !sqliteBusy(err) {
			return fmt.Errorf("fold the write-ahead log of %s into it: %w; nothing was moved", path, err)
		}
		if !time.Now().Before(deadline) {
			return &refusal{kind: ErrLegacyInUse, text: fmt.Sprintf(
				"the pre-rename database %s is open in another process (probably the old agenthub-node); "+
					"stop it and start this again — nothing was moved", path)}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(m.options.busyEvery):
		}
	}
	if err := db.Close(); err != nil {
		return fmt.Errorf("close %s: %w; nothing was moved", path, err)
	}
	for _, suffix := range []string{"-wal", "-journal"} {
		there, err := present(path + suffix)
		if err != nil {
			return err
		}
		if there {
			return fmt.Errorf("%s%s is still there after the write-ahead log was folded into %s, so the database "+
				"is not in a state this node can move safely; nothing was moved", path, suffix, path)
		}
	}
	// What is left of the shared-memory index describes a log that no longer
	// exists. Ours, and stale.
	if err := os.Remove(path + "-shm"); err != nil && !isAbsent(err) {
		return fmt.Errorf("remove the stale %s-shm: %w", path, err)
	}
	return nil
}

// sqliteURI opens path read-write without creating it, and without waiting on
// a lock: the retry above decides how long to wait, and SQLite's own busy
// handler does not cover leaving WAL mode anyway.
func sqliteURI(path string) string {
	slashed := filepath.ToSlash(path)
	if !strings.HasPrefix(slashed, "/") {
		// A Windows drive path, C:/..., is file:///C:/... as a URI.
		slashed = "/" + slashed
	}
	return (&url.URL{Scheme: "file", Path: slashed, RawQuery: "mode=rw&_pragma=busy_timeout(0)"}).String()
}

// sqliteBusy recognises SQLITE_BUSY and SQLITE_LOCKED, with any extended code.
func sqliteBusy(err error) bool {
	var coded interface{ Code() int }
	if !errors.As(err, &coded) {
		return false
	}
	switch coded.Code() & 0xff {
	case 5, 6: // SQLITE_BUSY, SQLITE_LOCKED
		return true
	}
	return false
}

// transfers are the plan's files, database first.
func (m *migration) transfers(p plan) []transfer {
	var files []transfer
	if p.db {
		files = append(files, transfer{
			name: legacyDBName, step: "M5",
			src: filepath.Join(p.old, legacyDBName), dst: m.layout.NewDB,
		})
	}
	if p.key {
		files = append(files, transfer{
			name: keyName, step: "M6",
			src: filepath.Join(p.old, keyName), dst: filepath.Join(m.layout.New, keyName),
		})
	}
	return files
}

// finish is M5–M9: move, tidy, retire the marker.
func (m *migration) finish(p plan) error {
	for _, file := range m.transfers(p) {
		if err := m.move(file); err != nil {
			return err
		}
	}

	// M7. Temporary key files are seeds that were never installed: never an
	// identity, and ours by construction.
	m.removeKeyTemporaries(p.old)
	if err := m.step("M7"); err != nil {
		return err
	}

	// M8. The move is over once the marker is gone, and only then.
	marker := filepath.Join(m.layout.New, markerName)
	if err := os.Remove(marker); err != nil && !isAbsent(err) {
		return fmt.Errorf("remove the migration marker %s: %w", marker, err)
	}
	if err := os.Remove(filepath.Join(m.layout.New, markerTemp)); err != nil && !isAbsent(err) {
		m.logf("could not remove %s: %v", filepath.Join(m.layout.New, markerTemp), err)
	}
	if err := syncDirectory(m.layout.New); err != nil {
		return err
	}
	if err := m.step("M8"); err != nil {
		return err
	}

	// M9.
	switch {
	case p.db && p.key:
		m.logf("moved this node's identity from %s to %s (%s; %s → %s). The node id is unchanged.",
			p.old, m.layout.New, keyName, legacyDBName, dbName)
	case p.db:
		m.logf("moved this node's database from %s to %s (%s → %s). The node id is unchanged.",
			p.old, m.layout.New, legacyDBName, dbName)
	default:
		m.logf("moved this node's key from %s to %s (%s).", p.old, m.layout.New, keyName)
	}
	outcome, err := removeIfEmptyDirectory(p.old)
	switch {
	case err != nil:
		m.logf("left %s in place: %v", p.old, err)
	case outcome.removed:
		m.logf("removed the now-empty %s", p.old)
	case outcome.notDirectory:
		m.logf("left %s in place: it is a link to a directory, not one this node made", p.old)
	case outcome.entries > 0:
		m.logf("left %s in place: it also holds %d entries that are not this node's", p.old, outcome.entries)
	}
	return nil
}

// sayWhatIsMissing explains a half identity, which moves as it is: v0.1.x
// would have made up the missing half too.
func (m *migration) sayWhatIsMissing(p plan) {
	switch {
	case p.db && !p.key:
		m.logf("%s holds %s but no %s; the database moves, and a new key will be generated in %s, "+
			"exactly as v0.1.x would have done", p.old, legacyDBName, keyName, m.layout.New)
	case p.key && !p.db:
		m.logf("%s holds %s but no %s; the key moves, and a new database, with a new node id, will be created "+
			"in %s, exactly as v0.1.x would have done", p.old, keyName, legacyDBName, m.layout.New)
	}
}

// move is one file of the plan: link the new name, then remove the old one.
//
// Not os.Rename, which replaces whatever is at the destination on every
// platform. A hard link fails if the name exists, so nothing is ever
// overwritten; and a crash between the two halves leaves one file under two
// names, which the next start recognises and finishes.
func (m *migration) move(file transfer) error {
	_, err := os.Lstat(file.dst)
	switch {
	case err == nil:
		inOld, err := present(file.src)
		if err != nil {
			return err
		}
		if !inOld {
			return nil // moved before a crash
		}
		if err := sameOrConflict(file); err != nil {
			return err
		}
		// The link landed before a crash and the old name did not go.
		return m.removeOld(file)
	case !isAbsent(err):
		return fmt.Errorf("inspect %s: %w", file.dst, err)
	}

	if err := m.options.link(file.src, file.dst); err != nil {
		return fmt.Errorf("could not move %s to %s: this is done with a hard link, which needs both on one "+
			"local filesystem (APFS, ext4, NTFS), and that failed: %w. Nothing was removed. With no node running, "+
			"move the file there by hand (renaming %s to %s), then start this again",
			file.src, file.dst, err, legacyDBName, dbName)
	}
	if err := syncDirectory(filepath.Dir(file.dst)); err != nil {
		return err
	}
	if err := m.step(file.step + " link"); err != nil {
		return err
	}
	return m.removeOld(file)
}

// sameOrConflict accepts a file that is under both names because its link
// landed and its old name had not gone yet, and refuses two different files.
func sameOrConflict(file transfer) error {
	srcInfo, err := os.Lstat(file.src)
	if err != nil {
		return fmt.Errorf("inspect %s: %w", file.src, err)
	}
	dstInfo, err := os.Lstat(file.dst)
	if err != nil {
		return fmt.Errorf("inspect %s: %w", file.dst, err)
	}
	if os.SameFile(srcInfo, dstInfo) {
		return nil
	}
	return &refusal{kind: ErrMigrationConflict, text: fmt.Sprintf(
		"%s and %s are different files, and moving the first would overwrite the second; nothing was "+
			"overwritten. One of them is not this node's identity: with no node running, find out which, "+
			"move it out of the way, and start this again", file.src, file.dst)}
}

func (m *migration) removeOld(file transfer) error {
	if err := m.options.remove(file.src); err != nil {
		return fmt.Errorf("remove %s after linking it to %s: %w", file.src, file.dst, err)
	}
	if err := syncDirectory(filepath.Dir(file.src)); err != nil {
		return err
	}
	return m.step(file.step)
}

func (m *migration) removeKeyTemporaries(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), keyTempPrefix) {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		if err := os.Remove(path); err != nil {
			m.logf("could not remove %s, a temporary key file that was never installed: %v", path, err)
		}
	}
}

// directoryOutcome is what removeIfEmptyDirectory found.
type directoryOutcome struct {
	removed      bool
	notDirectory bool
	entries      int
}

// removeIfEmptyDirectory removes dir when it is a plain, empty directory, and
// otherwise says why it stayed. Never recursive: whatever else is in there is
// not this node's.
func removeIfEmptyDirectory(dir string) (directoryOutcome, error) {
	info, err := os.Lstat(dir)
	if isAbsent(err) {
		return directoryOutcome{}, nil
	}
	if err != nil {
		return directoryOutcome{}, err
	}
	if !info.IsDir() {
		return directoryOutcome{notDirectory: true}, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return directoryOutcome{}, err
	}
	if len(entries) > 0 {
		return directoryOutcome{entries: len(entries)}, nil
	}
	if err := os.Remove(dir); err != nil {
		return directoryOutcome{}, err
	}
	return directoryOutcome{removed: true}, nil
}

// holdsNode reports whether a directory holds a node: its key or its database.
func holdsNode(dir, db string) (bool, error) {
	for _, path := range []string{filepath.Join(dir, keyName), db} {
		there, err := present(path)
		if err != nil || there {
			return there, err
		}
	}
	return false, nil
}

// present reports whether a name exists, without following a link.
func present(path string) (bool, error) {
	_, err := os.Lstat(path)
	switch {
	case err == nil:
		return true, nil
	case isAbsent(err):
		return false, nil
	}
	return false, fmt.Errorf("inspect %s: %w", path, err)
}

func requireRegularOrAbsent(path string) error {
	info, err := os.Lstat(path)
	switch {
	case isAbsent(err):
		return nil
	case err != nil:
		return fmt.Errorf("inspect %s: %w; nothing was moved", path, err)
	case !info.Mode().IsRegular():
		return fmt.Errorf("%s is not a regular file (mode %s), so it is not what this node wrote there; "+
			"refusing to move it — nothing was moved", path, info.Mode())
	}
	return nil
}

// isAbsent is "no such file", including a path through something that is not
// a directory.
func isAbsent(err error) bool {
	return errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR)
}

// writeMarker records a plan in dir, atomically: a marker is either absent or
// whole, and it is durable before this returns.
func writeMarker(dir string, p plan) error {
	if strings.ContainsAny(p.old, "\r\n") {
		return fmt.Errorf("the pre-rename directory %q has a line break in its name; nothing was moved", p.old)
	}
	var content strings.Builder
	content.WriteString(p.old + "\n")
	if p.db {
		content.WriteString("db\n")
	}
	if p.key {
		content.WriteString("key\n")
	}

	temporary := filepath.Join(dir, markerTemp)
	// A temporary marker left by a crash is ours and was never in effect.
	if err := os.Remove(temporary); err != nil && !isAbsent(err) {
		return fmt.Errorf("remove the stale %s: %w", temporary, err)
	}
	// #nosec G304 -- the fixed temporary marker name in the node's own data
	// directory, created exclusively.
	file, err := os.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("write the migration marker: %w; nothing was moved", err)
	}
	if _, err := file.WriteString(content.String()); err != nil {
		_ = file.Close()
		return fmt.Errorf("write the migration marker: %w; nothing was moved", err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return fmt.Errorf("flush the migration marker: %w; nothing was moved", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close the migration marker: %w; nothing was moved", err)
	}
	if err := os.Rename(temporary, filepath.Join(dir, markerName)); err != nil {
		return fmt.Errorf("put the migration marker in place: %w; nothing was moved", err)
	}
	return syncDirectory(dir)
}

// readMarker reads a plan back. found is false when there is no marker.
func readMarker(path, dir string) (plan, bool, error) {
	unreadable := func(reason string) (plan, bool, error) {
		return plan{}, false, fmt.Errorf("the migration marker %s cannot be read as one (%s); nothing was changed. "+
			"This node writes it while it moves its identity out of the pre-rename directory: look for %s and %s "+
			"there and in %s before deleting it", path, reason, keyName, legacyDBName, dir)
	}
	info, err := os.Lstat(path)
	if isAbsent(err) {
		return plan{}, false, nil
	}
	if err != nil {
		return plan{}, false, fmt.Errorf("inspect the migration marker %s: %w", path, err)
	}
	if !info.Mode().IsRegular() {
		return unreadable("it is not a regular file")
	}
	if info.Size() > maxMarkerSize {
		return unreadable("it is far larger than any marker")
	}
	// #nosec G304 -- the fixed marker name in the node's own data directory,
	// checked above to be a small regular file.
	data, err := os.ReadFile(path)
	if err != nil {
		return plan{}, false, fmt.Errorf("read the migration marker %s: %w", path, err)
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	p := plan{old: lines[0]}
	if p.old == "" || !filepath.IsAbs(p.old) {
		return unreadable("its first line is not an absolute directory")
	}
	for _, line := range lines[1:] {
		switch line {
		case "db":
			p.db = true
		case "key":
			p.key = true
		default:
			return unreadable(fmt.Sprintf("it lists %q, which is not a file this node moves", line))
		}
	}
	return p, true, nil
}
