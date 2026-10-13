package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// nodeDefaultPaths is a copy of what the standard library does, evaluated
// against another process's environment. Against this process's own it has to
// give exactly what os.UserConfigDir and os.UserHomeDir give — which is what
// the node's defaultPaths calls.
func TestNodeDefaultPathsMatchTheStandardLibraryHere(t *testing.T) {
	config, err := os.UserConfigDir()
	if err != nil {
		t.Skipf("this environment has no config directory: %v", err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skipf("this environment has no home directory: %v", err)
	}
	got, err := nodeDefaultPaths(runtime.GOOS, environmentLookup(runtime.GOOS, os.Environ()))
	if err != nil {
		t.Fatal(err)
	}
	want := nodePaths{
		database: filepath.Join(config, "agenthallway", "agenthallway.db"),
		claude:   filepath.Join(home, ".claude"),
		codex:    filepath.Join(home, ".codex"),
	}
	if got != want {
		t.Errorf("from this process's environment: %+v, the standard library says %+v", got, want)
	}
}

// Each platform's rule, including the one the review found: on Linux a node
// whose environment sets XDG_CONFIG_HOME keeps its database there, whatever
// HOME says.
func TestNodeDefaultPathsFollowEachPlatformsRule(t *testing.T) {
	cases := []struct {
		goos    string
		env     []string
		want    string // the database, or the error's text
		wantErr bool
	}{
		{goos: "linux", env: []string{"HOME=/home/me", "XDG_CONFIG_HOME=/srv/cfg"}, want: "/srv/cfg/agenthallway/agenthallway.db"},
		{goos: "linux", env: []string{"HOME=/home/me"}, want: "/home/me/.config/agenthallway/agenthallway.db"},
		{goos: "linux", env: []string{"HOME=/home/me", "XDG_CONFIG_HOME="}, want: "/home/me/.config/agenthallway/agenthallway.db"},
		{goos: "linux", env: []string{"HOME=/home/me", "XDG_CONFIG_HOME=cfg"}, want: "relative", wantErr: true},
		{goos: "linux", env: []string{"XDG_CONFIG_HOME=/srv/cfg"}, want: "HOME", wantErr: true},
		{goos: "darwin", env: []string{"HOME=/Users/me", "XDG_CONFIG_HOME=/srv/cfg"},
			want: "/Users/me/Library/Application Support/agenthallway/agenthallway.db"},
		{goos: "darwin", env: []string{"PATH=/usr/bin"}, want: "HOME", wantErr: true},
		// The first entry for a name wins, as in the node's own os.Getenv.
		{goos: "linux", env: []string{"HOME=/first", "HOME=/second"}, want: "/first/.config/agenthallway/agenthallway.db"},
		{goos: "windows", env: []string{`=C:=C:\somewhere`, `USERPROFILE=C:\Users\me`, `APPDATA=C:\Users\me\AppData\Roaming`},
			want: filepath.Join(`C:\Users\me\AppData\Roaming`, "agenthallway", "agenthallway.db")},
		{goos: "windows", env: []string{`USERPROFILE=C:\Users\me`}, want: "APPDATA", wantErr: true},
	}
	for _, tc := range cases {
		paths, err := nodeDefaultPaths(tc.goos, environmentLookup(tc.goos, tc.env))
		switch {
		case tc.wantErr && (err == nil || !strings.Contains(err.Error(), tc.want)):
			t.Errorf("%s %q: %+v, %v; want an error about %s", tc.goos, tc.env, paths, err, tc.want)
		case !tc.wantErr && err != nil:
			t.Errorf("%s %q: %v", tc.goos, tc.env, err)
		case !tc.wantErr && paths.database != tc.want:
			t.Errorf("%s %q: database %s, want %s", tc.goos, tc.env, paths.database, tc.want)
		}
	}
}

// W16. Where a pre-rename node keeps its database: the old directory and the
// old file name, under exactly the environment rules the current default
// follows — a node started with XDG_CONFIG_HOME had its database there too.
func TestLegacyDatabaseFollowsEachPlatformsRule(t *testing.T) {
	cases := []struct {
		goos    string
		env     []string
		want    string // the database, or the error's text
		wantErr bool
	}{
		{goos: "linux", env: []string{"HOME=/home/me", "XDG_CONFIG_HOME=/srv/cfg"}, want: "/srv/cfg/agenthub/agenthub.db"},
		{goos: "linux", env: []string{"HOME=/home/me"}, want: "/home/me/.config/agenthub/agenthub.db"},
		{goos: "linux", env: []string{"HOME=/home/me", "XDG_CONFIG_HOME="}, want: "/home/me/.config/agenthub/agenthub.db"},
		{goos: "linux", env: []string{"HOME=/home/me", "XDG_CONFIG_HOME=cfg"}, want: "relative", wantErr: true},
		{goos: "linux", env: []string{"PATH=/usr/bin"}, want: "HOME", wantErr: true},
		{goos: "darwin", env: []string{"HOME=/Users/me", "XDG_CONFIG_HOME=/srv/cfg"},
			want: "/Users/me/Library/Application Support/agenthub/agenthub.db"},
		{goos: "darwin", env: []string{"PATH=/usr/bin"}, want: "HOME", wantErr: true},
		{goos: "windows", env: []string{`USERPROFILE=C:\Users\me`, `AppData=C:\Users\me\AppData\Roaming`},
			want: filepath.Join(`C:\Users\me\AppData\Roaming`, "agenthub", "agenthub.db")},
		{goos: "windows", env: []string{`USERPROFILE=C:\Users\me`}, want: "APPDATA", wantErr: true},
	}
	for _, tc := range cases {
		lookup := environmentLookup(tc.goos, tc.env)
		database, err := legacyDatabase(tc.goos, lookup)
		switch {
		case tc.wantErr && (err == nil || !strings.Contains(err.Error(), tc.want)):
			t.Errorf("%s %q: %q, %v; want an error about %s", tc.goos, tc.env, database, err, tc.want)
		case !tc.wantErr && err != nil:
			t.Errorf("%s %q: %v", tc.goos, tc.env, err)
		case !tc.wantErr && database != tc.want:
			t.Errorf("%s %q: %s, want %s", tc.goos, tc.env, database, tc.want)
		}
		if err != nil {
			continue
		}
		// The same configuration directory as the current default: the node
		// moves the one into the other, and a node cannot move across two.
		current, err := nodeDefaultPaths(tc.goos, lookup)
		if err != nil {
			t.Fatal(err)
		}
		if filepath.Dir(filepath.Dir(current.database)) != filepath.Dir(filepath.Dir(database)) {
			t.Errorf("%s %q: the old database %s and the new %s are under different configuration directories",
				tc.goos, tc.env, database, current.database)
		}
	}
}

// Windows names are not case-sensitive, and os.UserConfigDir asks for
// "AppData" while Windows spells it APPDATA. Unix names are exact.
func TestEnvironmentLookupFollowsEachPlatformsNames(t *testing.T) {
	windows := environmentLookup("windows", []string{`=C:=C:\x`, `APPDATA=C:\roaming`})
	if got := windows("AppData"); got != `C:\roaming` {
		t.Errorf("windows AppData = %q, want the APPDATA entry", got)
	}
	if got := windows("C:"); got != "" {
		t.Errorf("windows per-drive entry was read as a name: %q", got)
	}
	unix := environmentLookup("linux", []string{"home=/lower", "HOME=/upper", "EMPTY=", "NOEQUALS"})
	if got := unix("HOME"); got != "/upper" {
		t.Errorf("linux HOME = %q, want /upper: names are exact", got)
	}
	if got := unix("NOEQUALS"); got != "" {
		t.Errorf("an entry without = named something: %q", got)
	}
	// The first entry for a name wins, as syscall.copyenv has it — and on
	// macOS the kernel's own strings come after every environment entry, so
	// first-wins is also what keeps them from standing in for one.
	duplicated := environmentLookup("darwin", []string{"PATH=/usr/bin", "HOME=/first", "XDG_CONFIG_HOME=/a", "HOME=/second", "XDG_CONFIG_HOME=/b"})
	if got := duplicated("HOME"); got != "/first" {
		t.Errorf("duplicated HOME = %q, want /first: the first entry wins", got)
	}
	if got := duplicated("XDG_CONFIG_HOME"); got != "/a" {
		t.Errorf("duplicated XDG_CONFIG_HOME = %q, want /a: the first entry wins", got)
	}
}
