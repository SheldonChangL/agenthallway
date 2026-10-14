package datadir

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"agenthub.local/agenthub/internal/datadir/datadirtest"
)

func TestLayoutForNamesBothDirectories(t *testing.T) {
	config := filepath.Join("base", "config")
	got := LayoutFor(config)
	want := Layout{
		Config: config,
		Old:    filepath.Join(config, "agenthub"),
		New:    filepath.Join(config, "agenthallway"),
		OldDB:  filepath.Join(config, "agenthub", "agenthub.db"),
		NewDB:  filepath.Join(config, "agenthallway", "agenthallway.db"),
	}
	if got != want {
		t.Errorf("LayoutFor(%q) = %+v, want %+v", config, got, want)
	}
}

// D1.
func TestResolveWithoutDBUsesTheNewDefault(t *testing.T) {
	l := tempLayout(t)
	var logs logBuffer
	db, managed, err := Resolve(l, l.NewDB, false, logs.printf)
	if err != nil || db != l.NewDB || !managed {
		t.Fatalf("Resolve without -db = %q, %v, %v; want %q, managed", db, managed, err, l.NewDB)
	}
	if logs.String() != "" {
		t.Errorf("logged %q for the ordinary case", logs.String())
	}
}

// D2. A v0.1.x service unit names the old default as an explicit -db, and
// install.sh, ah and the desktop pass it through untouched (X3). Opened as
// given, it would keep the identity in the old directory forever.
func TestResolveTranslatesTheLegacyDefaultGivenExplicitly(t *testing.T) {
	l := tempLayout(t)
	var logs logBuffer
	db, managed, err := Resolve(l, l.OldDB, true, logs.printf)
	if err != nil || db != l.NewDB || !managed {
		t.Fatalf("Resolve(-db %s) = %q, %v, %v; want %q, managed", l.OldDB, db, managed, err, l.NewDB)
	}
	for _, want := range []string{l.OldDB, "pre-rename default location", l.NewDB} {
		if !logs.contains(want) {
			t.Errorf("the translation was not explained (%q missing): %q", want, logs.String())
		}
	}
	// A relative spelling, from a working directory that may itself be named
	// through a symlink (/var is /private/var on macOS), is the same file.
	if err := os.MkdirAll(l.Old, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Chdir(l.Config)
	db, managed, err = Resolve(l, filepath.FromSlash("agenthub/./agenthub.db"), true, logs.printf)
	if err != nil || db != l.NewDB || !managed {
		t.Errorf("a relative spelling of the old default = %q, %v, %v", db, managed, err)
	}
}

// D3.
func TestResolveTranslatesTheLegacyDirectorySpelledThroughASymlink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	l := tempLayout(t)
	if err := os.MkdirAll(l.Old, 0o700); err != nil {
		t.Fatal(err)
	}
	elsewhere := t.TempDir()
	link := filepath.Join(elsewhere, "the same directory")
	if err := os.Symlink(l.Old, link); err != nil {
		t.Fatal(err)
	}
	var logs logBuffer
	given := filepath.Join(link, "agenthub.db")
	db, managed, err := Resolve(l, given, true, logs.printf)
	if err != nil || db != l.NewDB || !managed {
		t.Fatalf("Resolve(-db %s) = %q, %v, %v; want %q, managed", given, db, managed, err, l.NewDB)
	}
	if !logs.contains("pre-rename default location") {
		t.Errorf("the translation was not logged: %q", logs.String())
	}
	// Same directory, another file name: not the default, so left alone.
	other := filepath.Join(link, "mine.db")
	if db, managed, _ := Resolve(l, other, true, logs.printf); db != other || managed {
		t.Errorf("Resolve(-db %s) = %q, %v; another file in that directory is the owner's", other, db, managed)
	}
}

// D3, the spelling a case-insensitive volume allows: on macOS
// ~/Library/Application Support/AgentHub is the old directory itself.
func TestResolveTranslatesACaseVariantOfTheLegacyDirectoryWhereTheVolumeIgnoresCase(t *testing.T) {
	l := tempLayout(t)
	if err := os.MkdirAll(l.Old, 0o700); err != nil {
		t.Fatal(err)
	}
	variant := filepath.Join(l.Config, "AgentHub")
	if _, err := os.Stat(variant); err != nil {
		t.Skip("this volume is case-sensitive, so the variant is another directory")
	}
	var logs logBuffer
	db, managed, err := Resolve(l, filepath.Join(variant, "agenthub.db"), true, logs.printf)
	if err != nil || db != l.NewDB || !managed {
		t.Fatalf("a case variant of the old default = %q, %v, %v", db, managed, err)
	}
}

// D4. Any other -db is the owner's, used exactly as given and never moved:
// v0.1.x did the same with it.
func TestResolveLeavesACustomPathAlone(t *testing.T) {
	l := tempLayout(t)
	custom := filepath.Join(t.TempDir(), "x", "agenthub", "agenthub.db")
	var logs logBuffer
	for _, given := range []string{custom, "relative/agenthub.db", ""} {
		db, managed, err := Resolve(l, given, true, logs.printf)
		if err != nil || db != given || managed {
			t.Errorf("Resolve(-db %q) = %q, %v, %v; want it as given, unmanaged", given, db, managed, err)
		}
	}
	if logs.String() != "" {
		t.Errorf("a custom path was commented on: %q", logs.String())
	}
}

// D5.
func TestResolveTreatsTheNewDefaultGivenExplicitlyAsTheDefault(t *testing.T) {
	l := tempLayout(t)
	var logs logBuffer
	db, managed, err := Resolve(l, l.NewDB, true, logs.printf)
	if err != nil || db != l.NewDB || !managed {
		t.Fatalf("Resolve(-db %s) = %q, %v, %v; want managed", l.NewDB, db, managed, err)
	}
	if strings.Contains(logs.String(), "pre-rename") {
		t.Errorf("the new default was described as the old one: %q", logs.String())
	}
}

// The new default spelled through a symlink is the new default too. Left
// unmanaged, a node whose identity is still in the old directory would start
// a new one beside it.
func TestResolveTreatsTheNewDirectorySpelledThroughASymlinkAsTheDefault(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	l := tempLayout(t)
	if err := os.MkdirAll(l.New, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(t.TempDir(), "new")
	if err := os.Symlink(l.New, link); err != nil {
		t.Fatal(err)
	}
	db, managed, err := Resolve(l, filepath.Join(link, "agenthallway.db"), true, nil)
	if err != nil || db != l.NewDB || !managed {
		t.Fatalf("a symlinked spelling of the new default = %q, %v, %v", db, managed, err)
	}
}

// symlink makes link name target, or skips where links need privileges.
func symlink(t *testing.T, target, link string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
}

// startAs is one start of the node with -db given, as run() takes it:
// Resolve, Migrate when the answer is the default, then open what Resolve
// chose and check it is still the node the fixture made.
func startAs(t *testing.T, l Layout, given string, want datadirtest.Legacy) {
	t.Helper()
	var logs logBuffer
	db, managed, err := Resolve(l, given, true, logs.printf)
	if err != nil {
		t.Fatalf("Resolve(-db %s): %v", given, err)
	}
	if db != l.NewDB || !managed {
		t.Errorf("Resolve(-db %s) = %q, managed %v; want %q, managed", given, db, managed, l.NewDB)
	}
	if managed {
		if err := Migrate(context.Background(), l, Options{LegacyRegistrations: none, Logf: logs.printf}); err != nil {
			t.Fatalf("Migrate: %v", err)
		}
	}
	datadirtest.RequireIdentity(t, db, want)
}

// D3 after the move. The start that moved the identity removed the emptied
// old directory, and a unit is never rewritten, so every later start is given
// the same spelling of a directory that is no longer there — where the old
// rule found nothing to compare, opened the path as given, and the database
// and key made for it there were a new node, with nothing said.
func TestASpellingOfTheLegacyDefaultIsStillTheDefaultAfterTheMove(t *testing.T) {
	for _, tc := range []struct {
		name string
		// spell returns the layout and the -db the unit carries; the old
		// directory does not exist yet.
		spell func(t *testing.T) (Layout, string)
	}{
		{"another case", func(t *testing.T) (Layout, string) {
			l := tempLayout(t)
			return l, filepath.Join(l.Config, "AgentHub", "agenthub.db")
		}},
		{"the configuration directory through a symlink", func(t *testing.T) (Layout, string) {
			l := tempLayout(t)
			link := filepath.Join(t.TempDir(), "config")
			symlink(t, l.Config, link)
			return l, filepath.Join(link, "agenthub", "agenthub.db")
		}},
		{"the physical path, where the home is named through a symlink", func(t *testing.T) (Layout, string) {
			// HOME=/home/u where /home is a link to /var/home, and a unit
			// written with /var/home/u: the configuration directory is the
			// link's spelling, the -db the physical one.
			physical := t.TempDir()
			if err := os.MkdirAll(filepath.Join(physical, "config"), 0o700); err != nil {
				t.Fatal(err)
			}
			link := filepath.Join(t.TempDir(), "home")
			symlink(t, physical, link)
			l := LayoutFor(filepath.Join(link, "config"))
			datadirtest.RequireConfined(t, l.Config)
			return l, filepath.Join(physical, "config", "agenthub", "agenthub.db")
		}},
		{"a symlink to the old directory itself", func(t *testing.T) (Layout, string) {
			l := tempLayout(t)
			link := filepath.Join(t.TempDir(), "data")
			symlink(t, l.Old, link)
			return l, filepath.Join(link, "agenthub.db")
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			l, given := tc.spell(t)
			legacy := datadirtest.WriteLegacy(t, l.Old, true)
			if _, err := os.Stat(filepath.Dir(given)); err != nil {
				t.Skipf("%s is not the old directory on this volume (%v)", filepath.Dir(given), err)
			}

			startAs(t, l, given, legacy)
			requireAbsent(t, l.Old)

			// The next start, under the same unit, with the old directory gone.
			startAs(t, l, given, legacy)
			requireAbsent(t, l.Old)
			// Nor was the spelling's own directory made again. (A link to
			// the old directory is left as it was, leading nowhere.)
			if info, err := os.Lstat(filepath.Dir(given)); err == nil && info.Mode()&os.ModeSymlink == 0 {
				t.Errorf("%s was made again", filepath.Dir(given))
			}
		})
	}
}

// The new default spelled another way, before the new directory exists — the
// first start after an upgrade, under a unit written for the new name through
// a symlink. It is the default, so the identity in the old directory moves
// into it instead of a new one starting beside it.
func TestASpellingOfTheNewDefaultIsTheDefaultBeforeItExists(t *testing.T) {
	l := tempLayout(t)
	legacy := datadirtest.WriteLegacy(t, l.Old, true)
	link := filepath.Join(t.TempDir(), "config")
	symlink(t, l.Config, link)
	given := filepath.Join(link, "agenthallway", "agenthallway.db")

	startAs(t, l, given, legacy)
	requireAbsent(t, l.Old)
	startAs(t, l, given, legacy)
}

// A name that differs from the old directory's only in case is that directory
// only where the volume ignores case. Here it does not: another directory,
// used as given, exactly as v0.1.x did.
func TestACaseVariantIsAnotherDirectoryWhereTheVolumeHonoursCase(t *testing.T) {
	l := tempLayout(t)
	datadirtest.WriteLegacy(t, l.Old, false)
	variant := filepath.Join(l.Config, "AgentHub")
	if _, err := os.Stat(variant); err == nil {
		t.Skip("this volume ignores case, so the variant is the old directory")
	}
	given := filepath.Join(variant, "agenthub.db")
	db, managed, err := Resolve(l, given, true, nil)
	if err != nil || db != given || managed {
		t.Errorf("Resolve(-db %s) = %q, %v, %v; want it as given, unmanaged", given, db, managed, err)
	}
}

// With neither default directory there, nothing says whether the volume
// ignores case, and each answer would open a database the other would not:
// refused, and nothing created.
func TestACaseVariantThatCannotBePlacedIsRefused(t *testing.T) {
	l := tempLayout(t)
	given := filepath.Join(l.Config, "AgentHub", "agenthub.db")
	db, managed, err := Resolve(l, given, true, nil)
	if err == nil {
		t.Fatalf("Resolve(-db %s) = %q, %v; want a refusal", given, db, managed)
	}
	for _, want := range []string{"only in case", l.NewDB} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not say %q: %v", want, err)
		}
	}
	entries, err := os.ReadDir(l.Config)
	if err != nil || len(entries) != 0 {
		t.Errorf("the configuration directory holds %v (%v); nothing should have been made", entries, err)
	}
}
