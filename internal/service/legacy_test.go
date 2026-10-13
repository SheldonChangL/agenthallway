package service

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
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

// scriptedRunner answers each command line from a queue of its own, the last
// answer repeating, and otherwise the way fakeRunner does: launchd knows no
// such job, and everything else succeeds. before, when set, is called with
// each command line before it is answered, so a test can look at the disk at
// the moment a command is run.
type scriptedRunner struct {
	calls   []string
	answers map[string][]scriptedAnswer
	before  func(line string)
}

type scriptedAnswer struct {
	out string
	err error
}

func (s *scriptedRunner) Run(_ context.Context, name string, args ...string) (string, error) {
	line := strings.Join(append([]string{name}, args...), " ")
	s.calls = append(s.calls, line)
	if s.before != nil {
		s.before(line)
	}
	if queue := s.answers[line]; len(queue) > 0 {
		answer := queue[0]
		if len(queue) > 1 {
			s.answers[line] = queue[1:]
		}
		return answer.out, answer.err
	}
	if strings.HasPrefix(line, "launchctl print ") {
		return "Could not find service", errors.New("exit status 113")
	}
	return "", nil
}

var notFound = scriptedAnswer{out: "Could not find service", err: errors.New("exit status 113")}

// legacyPlistAt writes what a v0.1.x install wrote: this package's plist under
// the pre-rename label.
func legacyPlistAt(t *testing.T, home string, program string, args ...string) string {
	t.Helper()
	plist, err := LaunchdPlist(Config{NodeBinary: program, Args: args, LogPath: filepath.Join(home, "Library", "Logs", "agenthub", "node.log")})
	if err != nil {
		t.Fatal(err)
	}
	content := strings.Replace(string(plist), "<string>"+Label+"</string>", "<string>"+LegacyLabel+"</string>", 1)
	path := filepath.Join(home, "Library", "LaunchAgents", LegacyLabel+".plist")
	writeFile(t, path, content)
	return path
}

// legacyUnitAt writes what a v0.1.x install wrote on Linux: this package's
// unit under the pre-rename name.
func legacyUnitAt(t *testing.T, home string, program string, args ...string) string {
	t.Helper()
	content := strings.Replace(string(SystemdUnit(Config{NodeBinary: program, Args: args})), "Agent Hallway node (agenthallway-node)", "AgentHub node (agenthub-node)", 1)
	path := filepath.Join(home, ".config", "systemd", "user", LegacyUnitName+".service")
	writeFile(t, path, content)
	return path
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func gone(t *testing.T, path string) bool {
	t.Helper()
	_, err := os.Lstat(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("stat %s: %v", path, err)
	}
	return err != nil
}

// S1. The old job is booted out, waited for, and its plist removed before the
// new one is written and bootstrapped: a pre-rename job left loaded with
// KeepAlive would start the old node again after the new one moved the
// identity, and the old one would make a new identity in the emptied
// directory.
func TestInstallOnDarwinRetiresTheLegacyJobBeforeBootstrapping(t *testing.T) {
	home := t.TempDir()
	legacy := legacyPlistAt(t, home, "/Applications/agenthub-desktop.app/Contents/MacOS/agenthub-node")
	unitPath := filepath.Join(home, "Library", "LaunchAgents", Label+".plist")
	legacyTarget := "gui/501/" + LegacyLabel
	runner := &scriptedRunner{answers: map[string][]scriptedAnswer{
		// Still being torn down twice, then gone.
		"launchctl print " + legacyTarget: {{out: "state = running"}, {out: "state = running"}, notFound},
	}}
	runner.before = func(line string) {
		if strings.Contains(line, Label) || strings.HasPrefix(line, "launchctl bootstrap") {
			if !gone(t, legacy) {
				t.Errorf("%q ran while the pre-rename plist was still there", line)
			}
		}
	}
	manager := Manager{GOOS: "darwin", Home: home, UID: "501", Runner: runner, Sleep: noSleep}
	report, err := manager.Install(context.Background(), Config{NodeBinary: writeFakeNode(t)})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"launchctl bootout " + legacyTarget,
		"launchctl print " + legacyTarget,
		"launchctl print " + legacyTarget,
		"launchctl print " + legacyTarget,
		"launchctl bootout gui/501/" + Label,
		"launchctl print gui/501/" + Label,
		"launchctl bootstrap gui/501 " + unitPath,
	}
	if strings.Join(runner.calls, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls:\n%s\nwant:\n%s", strings.Join(runner.calls, "\n"), strings.Join(want, "\n"))
	}
	if !gone(t, legacy) {
		t.Error("the pre-rename plist is still there")
	}
	if gone(t, unitPath) {
		t.Error("the new plist was not written")
	}
	if len(report.Steps) == 0 || !strings.Contains(report.Steps[0],
		"stopped and removed the pre-rename service local.agenthub.node (it ran /Applications/agenthub-desktop.app/Contents/MacOS/agenthub-node)") {
		t.Errorf("the retirement was not reported first: %q", report.Steps)
	}
}

// S2. systemd: the old unit is disabled and stopped, and its file removed,
// before the daemon-reload that the new unit's registration starts with.
func TestInstallOnLinuxRetiresTheLegacyUnitFirst(t *testing.T) {
	home := t.TempDir()
	legacy := legacyUnitAt(t, home, "/home/me/.local/share/agenthub/agenthub-node")
	runner := &scriptedRunner{}
	runner.before = func(line string) {
		if line == "systemctl --user daemon-reload" && !gone(t, legacy) {
			t.Error("the daemon was reloaded with the pre-rename unit still on disk")
		}
	}
	manager := Manager{GOOS: "linux", Home: home, UID: "1000", Runner: runner, Sleep: noSleep}
	report, err := manager.Install(context.Background(), Config{NodeBinary: writeFakeNode(t)})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"systemctl --user disable --now " + LegacyUnitName,
		"systemctl --user daemon-reload",
		"systemctl --user enable " + UnitName,
		"systemctl --user restart " + UnitName,
	}
	if strings.Join(runner.calls, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls:\n%s\nwant:\n%s", strings.Join(runner.calls, "\n"), strings.Join(want, "\n"))
	}
	if !gone(t, legacy) {
		t.Error("the pre-rename unit is still there")
	}
	if !strings.Contains(strings.Join(report.Steps, "\n"), "stopped and removed the pre-rename service agenthub-node") {
		t.Errorf("steps = %q", report.Steps)
	}
}

// S3. Task Scheduler: the old task is ended and deleted, the old node stopped
// by its own image name, the old definition removed — then the new task is
// registered and run, and every Startup shortcut this product's installers
// ever made is removed.
func TestInstallOnWindowsRetiresTheLegacyTask(t *testing.T) {
	runner := &scriptedRunner{}
	manager := windowsManager(t, nil)
	manager.Runner = runner
	legacyXML := filepath.Join(os.Getenv("LOCALAPPDATA"), "agenthub", "node-task.xml")
	writeFile(t, legacyXML, "<Task/>")
	startup := filepath.Join(os.Getenv("APPDATA"), "Microsoft", "Windows", "Start Menu", "Programs", "Startup")
	shortcuts := []string{"AgentHub Node.lnk", "agenthub-desktop Node.lnk", "agenthallway-desktop Node.lnk"}
	for _, name := range append([]string{"Notepad.lnk"}, shortcuts...) {
		writeFile(t, filepath.Join(startup, name), "shortcut")
	}
	report, err := manager.Install(context.Background(), Config{NodeBinary: writeFakeNode(t), Launcher: `C:\ah.exe`})
	if err != nil {
		t.Fatal(err)
	}
	unitPath, _ := manager.UnitPath()
	want := []string{
		"schtasks /End /TN " + LegacyTaskName,
		"schtasks /Delete /TN " + LegacyTaskName + " /F",
		"taskkill /F /IM agenthub-node.exe",
		"schtasks /Create /TN " + TaskName + " /XML " + unitPath + " /F",
		"schtasks /Run /TN " + TaskName,
	}
	if strings.Join(runner.calls, "\n") != strings.Join(want, "\n") {
		t.Errorf("calls:\n%s\nwant:\n%s", strings.Join(runner.calls, "\n"), strings.Join(want, "\n"))
	}
	if TaskName != "Agent Hallway Node" {
		t.Errorf("the new task is called %q", TaskName)
	}
	if !gone(t, legacyXML) {
		t.Error("the pre-rename task definition is still there")
	}
	for _, name := range shortcuts {
		if !gone(t, filepath.Join(startup, name)) {
			t.Errorf("the startup shortcut %s survived the install", name)
		}
	}
	if gone(t, filepath.Join(startup, "Notepad.lnk")) {
		t.Error("a shortcut that is not this product's was removed")
	}
	steps := strings.Join(report.Steps, "\n")
	for _, want := range []string{"removed the pre-rename scheduled task AgentHub Node", "removed " + legacyXML} {
		if !strings.Contains(steps, want) {
			t.Errorf("steps do not say %q:\n%s", want, steps)
		}
	}
}

// S4. The pre-rename unit is the only record of the database it ran on. A
// bare install would replace it with a unit on the default database — a new
// identity — so it is refused, and nothing is touched: not the old unit, not
// the service manager, not the disk.
func TestInstallRefusesToDropTheLegacyUnitsDatabase(t *testing.T) {
	database := "/Volumes/data/my nodes/agenthub.db"
	for _, goos := range []string{"darwin", "linux"} {
		for _, spelling := range [][]string{{"--db", database}, {"-db=" + database}} {
			t.Run(goos+" "+spelling[0], func(t *testing.T) {
				home := t.TempDir()
				var legacy string
				if goos == "darwin" {
					legacy = legacyPlistAt(t, home, "/old/agenthub-node", spelling...)
				} else {
					legacy = legacyUnitAt(t, home, "/old/agenthub-node", spelling...)
				}
				before, _ := os.ReadFile(legacy)
				runner := &scriptedRunner{}
				manager := Manager{GOOS: goos, Home: home, UID: "501", Runner: runner, Sleep: noSleep}
				_, err := manager.Install(context.Background(), Config{NodeBinary: writeFakeNode(t), Args: []string{"--discover=true"}})
				if err == nil || !strings.Contains(err.Error(), "--db "+database) || !strings.Contains(err.Error(), manager.LegacyName()) {
					t.Fatalf("err = %v, want a refusal naming %s and --db %s", err, manager.LegacyName(), database)
				}
				if after, _ := os.ReadFile(legacy); string(after) != string(before) {
					t.Error("the pre-rename unit was changed by a refused install")
				}
				if len(runner.calls) != 0 {
					t.Errorf("a refused install ran %q", runner.calls)
				}
				unitPath, _ := manager.UnitPath()
				if !gone(t, unitPath) || !gone(t, filepath.Join(home, "Library", "Logs", "agenthallway")) {
					t.Error("a refused install wrote something")
				}
			})
		}
	}
}

// S5. The same database named on both sides is the reinstall install.sh and
// the desktop make: carried on.
func TestInstallCarriesOnWhenTheLegacyUnitNamesTheSameDatabase(t *testing.T) {
	database := "/Users/me/Library/Application Support/agenthub/agenthub.db"
	home := t.TempDir()
	legacy := legacyPlistAt(t, home, "/old/agenthub-node", "--db", database)
	manager := Manager{GOOS: "darwin", Home: home, UID: "501", Runner: &scriptedRunner{}, Sleep: noSleep}
	report, err := manager.Install(context.Background(), Config{NodeBinary: writeFakeNode(t), Args: []string{"--db", database}})
	if err != nil {
		t.Fatal(err)
	}
	if !gone(t, legacy) {
		t.Error("the pre-rename plist is still there")
	}
	if _, args := manager.InstalledCommand(); ArgumentValue(args, "db") != database {
		t.Errorf("the new unit runs %q, not the database the old one ran", args)
	}
	if !strings.Contains(strings.Join(report.Steps, "\n"), "--db "+database) {
		t.Errorf("the report does not say what the old service ran: %q", report.Steps)
	}
}

// S6. A machine that has only the pre-rename registration is described by it:
// installed, under the old name, running or not by the old label, with the
// program and database the old unit names — which is what a reinstall form
// is prefilled from.
func TestStatusReportsALegacyOnlyRegistration(t *testing.T) {
	t.Run("darwin", func(t *testing.T) {
		home := t.TempDir()
		legacy := legacyPlistAt(t, home, "/old/agenthub-node", "--db", "/data/agenthub.db")
		runner := &scriptedRunner{answers: map[string][]scriptedAnswer{
			"launchctl print gui/501/" + LegacyLabel: {{out: "gui/501/local.agenthub.node = {\n\tstate = running\n\tpid = 4242\n}"}},
		}}
		manager := Manager{GOOS: "darwin", Home: home, UID: "501", Runner: runner, Sleep: noSleep}
		status, err := manager.Status(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if !status.Installed || !status.Legacy || status.LegacyAlsoInstalled || status.UnitPath != legacy ||
			status.Program != "/old/agenthub-node" || ArgumentValue(status.Arguments, "db") != "/data/agenthub.db" ||
			!status.Running || status.PID != 4242 {
			t.Errorf("status = %+v", status)
		}
		if status.LogHint != filepath.Join(home, "Library", "Logs", "agenthub", "node.log") {
			t.Errorf("log hint = %q, want the pre-rename log", status.LogHint)
		}
		encoded, _ := json.Marshal(status)
		if !strings.Contains(string(encoded), `"Legacy":true`) {
			t.Errorf("JSON lacks Legacy: %s", encoded)
		}
	})
	t.Run("linux", func(t *testing.T) {
		home := t.TempDir()
		legacyUnitAt(t, home, "/old/agenthub-node")
		runner := &scriptedRunner{answers: map[string][]scriptedAnswer{
			"systemctl --user show " + LegacyUnitName + " -p ActiveState -p MainPID": {{out: "ActiveState=active\nMainPID=777\n"}},
		}}
		manager := Manager{GOOS: "linux", Home: home, UID: "1000", Runner: runner, Sleep: noSleep}
		status, _ := manager.Status(context.Background())
		if !status.Installed || !status.Legacy || !status.Running || status.PID != 777 || status.Program != "/old/agenthub-node" ||
			status.LogHint != "journalctl --user -u agenthub-node" {
			t.Errorf("status = %+v", status)
		}
	})
	t.Run("windows", func(t *testing.T) {
		runner := &scriptedRunner{answers: map[string][]scriptedAnswer{
			"tasklist /FI IMAGENAME eq agenthub-node.exe /FO CSV /NH": {{out: `"agenthub-node.exe","5150","Console","1","31,000 K"`}},
		}}
		manager := windowsManager(t, nil)
		manager.Runner = runner
		legacy := filepath.Join(os.Getenv("LOCALAPPDATA"), "agenthub", "node-task.xml")
		writeFile(t, legacy, "<Task/>")
		status, _ := manager.Status(context.Background())
		if !status.Installed || !status.Legacy || status.UnitPath != legacy || !status.Running || status.PID != 5150 {
			t.Errorf("status = %+v", status)
		}
	})
	// Nothing pre-rename: the fields are not there at all, so what install.sh
	// reads out of the JSON is what it always read.
	manager := Manager{GOOS: "darwin", Home: t.TempDir(), UID: "501", Runner: &scriptedRunner{}, Sleep: noSleep}
	status, _ := manager.Status(context.Background())
	if encoded, _ := json.Marshal(status); strings.Contains(string(encoded), `"Legacy`) {
		t.Errorf("a machine with no pre-rename registration says Legacy: %s", encoded)
	}
}

// S7. Both registrations: the current one is described, and the old one is
// noted rather than hidden.
func TestStatusPrefersTheNewRegistrationAndNotesTheOld(t *testing.T) {
	home := t.TempDir()
	legacyPlistAt(t, home, "/old/agenthub-node")
	manager := Manager{GOOS: "darwin", Home: home, UID: "501", Runner: &scriptedRunner{}, Sleep: noSleep}
	if _, err := manager.Install(context.Background(), Config{NodeBinary: writeFakeNode(t)}); err != nil {
		t.Fatal(err)
	}
	legacyPlistAt(t, home, "/old/agenthub-node") // back, as if a v0.1.x install ran again
	status, err := manager.Status(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	unitPath, _ := manager.UnitPath()
	if !status.Installed || status.Legacy || !status.LegacyAlsoInstalled || status.UnitPath != unitPath ||
		!strings.HasSuffix(status.Program, "agenthallway-node") {
		t.Errorf("status = %+v", status)
	}
}

// S8. Uninstall takes both registrations down, by each one's own name.
func TestUninstallRemovesBothRegistrations(t *testing.T) {
	t.Run("darwin", func(t *testing.T) {
		home := t.TempDir()
		manager := Manager{GOOS: "darwin", Home: home, UID: "501", Runner: &scriptedRunner{}, Sleep: noSleep}
		if _, err := manager.Install(context.Background(), Config{NodeBinary: writeFakeNode(t)}); err != nil {
			t.Fatal(err)
		}
		legacy := legacyPlistAt(t, home, "/old/agenthub-node", "--db", "/data/agenthub.db")
		runner := &scriptedRunner{}
		manager.Runner = runner
		report, err := manager.Uninstall(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		want := []string{
			"launchctl bootout gui/501/" + Label,
			"launchctl bootout gui/501/" + LegacyLabel,
			"launchctl print gui/501/" + LegacyLabel,
		}
		if strings.Join(runner.calls, "\n") != strings.Join(want, "\n") {
			t.Errorf("calls:\n%s\nwant:\n%s", strings.Join(runner.calls, "\n"), strings.Join(want, "\n"))
		}
		if !gone(t, report.UnitPath) || !gone(t, legacy) {
			t.Error("a registration survived the uninstall")
		}
	})
	t.Run("linux", func(t *testing.T) {
		home := t.TempDir()
		manager := Manager{GOOS: "linux", Home: home, UID: "1000", Runner: &scriptedRunner{}, Sleep: noSleep}
		if _, err := manager.Install(context.Background(), Config{NodeBinary: writeFakeNode(t)}); err != nil {
			t.Fatal(err)
		}
		legacy := legacyUnitAt(t, home, "/old/agenthub-node")
		runner := &scriptedRunner{}
		manager.Runner = runner
		report, err := manager.Uninstall(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		want := []string{
			"systemctl --user disable --now " + UnitName,
			"systemctl --user disable --now " + LegacyUnitName,
			"systemctl --user daemon-reload",
		}
		if strings.Join(runner.calls, "\n") != strings.Join(want, "\n") {
			t.Errorf("calls:\n%s\nwant:\n%s", strings.Join(runner.calls, "\n"), strings.Join(want, "\n"))
		}
		if !gone(t, report.UnitPath) || !gone(t, legacy) {
			t.Error("a registration survived the uninstall")
		}
	})
	t.Run("windows", func(t *testing.T) {
		runner := &scriptedRunner{}
		manager := windowsManager(t, nil)
		manager.Runner = runner
		unitPath, _ := manager.UnitPath()
		writeFile(t, unitPath, "<Task/>")
		legacyXML := filepath.Join(os.Getenv("LOCALAPPDATA"), "agenthub", "node-task.xml")
		writeFile(t, legacyXML, "<Task/>")
		startup := filepath.Join(os.Getenv("APPDATA"), "Microsoft", "Windows", "Start Menu", "Programs", "Startup")
		writeFile(t, filepath.Join(startup, "AgentHub Node.lnk"), "shortcut")
		if _, err := manager.Uninstall(context.Background()); err != nil {
			t.Fatal(err)
		}
		want := []string{
			"schtasks /End /TN " + TaskName,
			"schtasks /Delete /TN " + TaskName + " /F",
			"taskkill /F /IM agenthallway-node.exe",
			"schtasks /End /TN " + LegacyTaskName,
			"schtasks /Delete /TN " + LegacyTaskName + " /F",
			"taskkill /F /IM agenthub-node.exe",
		}
		if strings.Join(runner.calls, "\n") != strings.Join(want, "\n") {
			t.Errorf("calls:\n%s\nwant:\n%s", strings.Join(runner.calls, "\n"), strings.Join(want, "\n"))
		}
		if !gone(t, unitPath) || !gone(t, legacyXML) || !gone(t, filepath.Join(startup, "AgentHub Node.lnk")) {
			t.Error("a registration survived the uninstall")
		}
		if LegacyRegistrations("windows", manager.Home) != nil {
			t.Errorf("the node would still refuse to move its identity over %q", LegacyRegistrations("windows", manager.Home))
		}
	})
}

// S9. Restarting the pre-rename registration would start the old node again.
// It is refused with the step that replaces it, and nothing is asked of the
// service manager.
func TestRestartRefusesALegacyOnlyRegistration(t *testing.T) {
	for _, goos := range []string{"darwin", "linux", "windows"} {
		t.Run(goos, func(t *testing.T) {
			runner := &scriptedRunner{}
			manager := Manager{GOOS: goos, Home: t.TempDir(), UID: "501", Runner: runner, Sleep: noSleep}
			if goos == "windows" {
				manager = windowsManager(t, nil)
				manager.Runner = runner
			}
			legacy, _ := manager.legacyUnitPath()
			writeFile(t, legacy, "registered")
			_, err := manager.Restart(context.Background())
			if err == nil || !strings.Contains(err.Error(), "ah service install") || !strings.Contains(err.Error(), manager.LegacyName()) {
				t.Fatalf("err = %v, want the pre-rename name and how to replace it", err)
			}
			if len(runner.calls) != 0 {
				t.Errorf("the service manager was asked %q", runner.calls)
			}
		})
	}
}

// S10. On Windows the node is stopped by image name, and an upgraded machine
// can be running the pre-rename image: a restart that left it would find the
// owner's port taken, and an uninstall would leave it running.
func TestWindowsRestartAndUninstallStopBothNodeImages(t *testing.T) {
	runner := &scriptedRunner{}
	manager := windowsManager(t, nil)
	manager.Runner = runner
	unitPath, _ := manager.UnitPath()
	writeFile(t, unitPath, "<Task/>")
	if _, err := manager.Restart(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []string{"taskkill /F /IM agenthallway-node.exe", "taskkill /F /IM agenthub-node.exe", "schtasks /Run /TN " + TaskName}
	if strings.Join(runner.calls, " | ") != strings.Join(want, " | ") {
		t.Errorf("restart calls = %q, want %q", runner.calls, want)
	}
	runner.calls = nil
	if _, err := manager.Uninstall(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, image := range []string{"agenthallway-node.exe", "agenthub-node.exe"} {
		if !slices.Contains(runner.calls, "taskkill /F /IM "+image) {
			t.Errorf("uninstall did not stop %s: %q", image, runner.calls)
		}
	}
}
