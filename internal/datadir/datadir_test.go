package datadir

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
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
