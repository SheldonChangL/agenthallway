package service

import (
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
)

func touch(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("registered"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// S11. What the node's migration refuses over: the files that start the old
// node, and nothing that starts the new one.
func TestLegacyRegistrationsFindsEachPlatformsFiles(t *testing.T) {
	t.Run("darwin", func(t *testing.T) {
		home := t.TempDir()
		touch(t, filepath.Join(home, "Library", "LaunchAgents", "local.agenthallway.node.plist"))
		if found := LegacyRegistrations("darwin", home); len(found) != 0 {
			t.Fatalf("the new registration was reported as the old one: %v", found)
		}
		legacy := filepath.Join(home, "Library", "LaunchAgents", "local.agenthub.node.plist")
		touch(t, legacy)
		if found := LegacyRegistrations("darwin", home); !reflect.DeepEqual(found, []string{legacy}) {
			t.Errorf("found %v, want [%s]", found, legacy)
		}
	})

	t.Run("linux", func(t *testing.T) {
		home := t.TempDir()
		touch(t, filepath.Join(home, ".config", "systemd", "user", "agenthallway-node.service"))
		if found := LegacyRegistrations("linux", home); len(found) != 0 {
			t.Fatalf("the new registration was reported as the old one: %v", found)
		}
		legacy := filepath.Join(home, ".config", "systemd", "user", "agenthub-node.service")
		touch(t, legacy)
		if found := LegacyRegistrations("linux", home); !reflect.DeepEqual(found, []string{legacy}) {
			t.Errorf("found %v, want [%s]", found, legacy)
		}
	})

	t.Run("windows", func(t *testing.T) {
		home, local, roaming := t.TempDir(), t.TempDir(), t.TempDir()
		t.Setenv("LOCALAPPDATA", local)
		t.Setenv("APPDATA", roaming)
		startup := filepath.Join(roaming, "Microsoft", "Windows", "Start Menu", "Programs", "Startup")
		// The new names, and somebody else's shortcut: none of them starts the
		// old node.
		touch(t, filepath.Join(local, "agenthallway", "node-task.xml"))
		for _, name := range []string{"Agent Hallway Node.lnk", "agenthallway-desktop Node.lnk", "Notepad.lnk"} {
			touch(t, filepath.Join(startup, name))
		}
		if found := LegacyRegistrations("windows", home); len(found) != 0 {
			t.Fatalf("new or foreign files were reported as the old registration: %v", found)
		}
		want := []string{
			filepath.Join(local, "agenthub", "node-task.xml"),
			filepath.Join(startup, "AgentHub Node.lnk"),
			filepath.Join(startup, "agenthub-desktop Node.lnk"),
		}
		for _, path := range want {
			touch(t, path)
		}
		if found := LegacyRegistrations("windows", home); !reflect.DeepEqual(found, want) {
			t.Errorf("found %v, want %v", found, want)
		}
	})

	t.Run("windows without LOCALAPPDATA or APPDATA", func(t *testing.T) {
		home := t.TempDir()
		t.Setenv("LOCALAPPDATA", "")
		t.Setenv("APPDATA", "")
		want := []string{
			filepath.Join(home, "AppData", "Local", "agenthub", "node-task.xml"),
			filepath.Join(home, "AppData", "Roaming", "Microsoft", "Windows", "Start Menu", "Programs", "Startup",
				"AgentHub Node.lnk"),
		}
		for _, path := range want {
			touch(t, path)
		}
		if found := LegacyRegistrations("windows", home); !reflect.DeepEqual(found, want) {
			t.Errorf("found %v, want %v", found, want)
		}
	})

	t.Run("a platform with no service manager", func(t *testing.T) {
		if found := LegacyRegistrations("plan9", t.TempDir()); len(found) != 0 {
			t.Errorf("found %v", found)
		}
	})
}

// A file that cannot be looked at is not a file that is absent: the answer
// gates moving the identity, so "could not tell" counts as registered.
func TestLegacyRegistrationsCountsWhatItCannotInspect(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("needs a directory its owner cannot search: not Windows, not root")
	}
	home := t.TempDir()
	agents := filepath.Join(home, "Library", "LaunchAgents")
	if err := os.MkdirAll(agents, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(agents, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(agents, 0o700) }) // #nosec G302 -- restoring a test directory
	found := LegacyRegistrations("darwin", home)
	if len(found) != 1 {
		t.Errorf("an unreadable LaunchAgents directory gave %v; it cannot rule the old job out", found)
	}
}

func TestTheLegacyNamesAreThePreRenameOnes(t *testing.T) {
	if LegacyLabel != "local.agenthub.node" || LegacyUnitName != "agenthub-node" || LegacyTaskName != "AgentHub Node" {
		t.Errorf("legacy names %q %q %q are not what v0.1.x registered", LegacyLabel, LegacyUnitName, LegacyTaskName)
	}
	if Label == LegacyLabel || UnitName == LegacyUnitName || TaskName == LegacyTaskName {
		t.Error("a current name equals its pre-rename one")
	}
}
