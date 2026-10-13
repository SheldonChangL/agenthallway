package service

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"agenthub.local/agenthub/internal/product"
)

// The names the node was registered under through v0.1.x, when the product
// was called AgentHub. A machine upgraded from then can still have them, and
// each one starts the old agenthub-node.
const (
	// LegacyLabel is the pre-rename launchd job label.
	LegacyLabel = "local.agenthub.node"
	// LegacyUnitName is the pre-rename systemd user unit.
	LegacyUnitName = "agenthub-node"
	// LegacyTaskName is the pre-rename Windows scheduled task.
	LegacyTaskName = "AgentHub Node"
)

// legacyNodeImage is the pre-rename node's executable on Windows, which
// taskkill and tasklist address it by.
const legacyNodeImage = product.LegacyNodeBinary + ".exe"

// legacyNodeStartupShortcuts are the Startup-folder shortcuts the pre-rename
// Windows installers made when no task could be registered. Each starts the
// old node at logon.
var legacyNodeStartupShortcuts = []string{"AgentHub Node.lnk", "agenthub-desktop Node.lnk"}

// legacyUnitPath is where the pre-rename registration lives for this user: the
// launchd plist, the systemd unit, or the definition the scheduled task was
// registered from.
func (m Manager) legacyUnitPath() (string, error) {
	switch m.GOOS {
	case "darwin":
		return filepath.Join(m.Home, "Library", "LaunchAgents", LegacyLabel+".plist"), nil
	case "linux":
		return filepath.Join(m.Home, ".config", "systemd", "user", LegacyUnitName+".service"), nil
	case "windows":
		return filepath.Join(legacyWindowsDataDir(m.Home), "node-task.xml"), nil
	}
	return "", ErrUnsupported
}

// legacyWindowsDataDir is windowsDataDir under the pre-rename name.
func legacyWindowsDataDir(home string) string {
	if base := os.Getenv("LOCALAPPDATA"); base != "" {
		return filepath.Join(base, product.LegacySlug)
	}
	return filepath.Join(home, "AppData", "Local", product.LegacySlug)
}

// LegacyName is what this platform's service manager calls the pre-rename
// registration: the launchd label, the systemd unit or the scheduled task.
// Empty where there is no service manager this package drives.
func (m Manager) LegacyName() string {
	switch m.GOOS {
	case "darwin":
		return LegacyLabel
	case "linux":
		return LegacyUnitName
	case "windows":
		return LegacyTaskName
	}
	return ""
}

// legacyLogHint is where the pre-rename node's output went: the old log file,
// or the old unit's journal.
func (m Manager) legacyLogHint() string {
	switch m.GOOS {
	case "darwin":
		return filepath.Join(m.Home, "Library", "Logs", product.LegacySlug, "node.log")
	case "linux":
		return "journalctl --user -u " + LegacyUnitName
	case "windows":
		return filepath.Join(legacyWindowsDataDir(m.Home), "node.log")
	}
	return ""
}

// legacyCommand is the program and arguments the pre-rename unit starts, read
// from its file the way InstalledCommand reads the current one. Empty when
// there is no such unit, or on Windows, where the task's XML is not read back.
func (m Manager) legacyCommand() (string, []string) {
	path, err := m.legacyUnitPath()
	if err != nil {
		return "", nil
	}
	return m.commandIn(path)
}

// legacyOnly is whether the only registration here is the pre-rename one: its
// unit is present and the current one is not.
func (m Manager) legacyOnly() bool {
	current, err := m.UnitPath()
	if err != nil {
		return false
	}
	legacy, err := m.legacyUnitPath()
	if err != nil {
		return false
	}
	return !exists(current) && exists(legacy)
}

// legacyOnlyError is what Restart says on a machine whose only registration is
// the pre-rename one: restarting it would start the old node again, and the
// step that replaces it is a reinstall, not a restart.
func (m Manager) legacyOnlyError() error {
	return fmt.Errorf("the background service is registered under the pre-rename name %s; "+
		"`ah service install` replaces it and keeps its database (pass --db if it had one)", m.LegacyName())
}

// retireLegacy stops and removes the pre-rename registration before Install
// writes the current one.
//
// Order matters. The old node has to be down before the new one starts: a
// launchd job left registered with KeepAlive restarts the OLD node after the
// new one has moved the identity out of the old directory, and the old node
// then finds that directory empty, makes a new identity there and races the
// new node for the owner's port. The node refuses to move its identity while
// these files exist (internal/datadir, P2); this is what makes them not exist.
//
// Only when there is something to retire: the files LegacyRegistrations finds
// are both what this acts on and what the node's refusal is about, so one
// install clears exactly what blocks the move.
//
// The pre-rename unit is the only record of a database it was installed with
// (--db). An install that names none would replace it with a unit on the
// default database — a different node, and every pairing gone — so that is
// refused before anything is touched.
func (m Manager) retireLegacy(ctx context.Context, config Config) ([]string, error) {
	if len(LegacyRegistrations(m.GOOS, m.Home)) == 0 {
		return nil, nil
	}
	_, args := m.legacyCommand()
	if database := ArgumentValue(args, "db"); database != "" && ArgumentValue(config.Args, "db") == "" {
		return nil, fmt.Errorf("the pre-rename service %s ran the node on --db %s; pass --db %s (or the database you mean) to replace it",
			m.LegacyName(), database, database)
	}
	return m.unregisterLegacy(ctx)
}

// unregisterLegacy takes the pre-rename registration down by the platform's
// own means and removes its file. Install calls it through retireLegacy;
// Uninstall calls it directly, with no question about the database, because
// nothing replaces the unit afterwards.
func (m Manager) unregisterLegacy(ctx context.Context) ([]string, error) {
	unit, err := m.legacyUnitPath()
	if err != nil {
		return nil, err
	}
	program, args := m.legacyCommand()
	var steps []string
	switch m.GOOS {
	case "darwin":
		domain := "gui/" + m.UID
		if out, err := m.Runner.Run(ctx, "launchctl", "bootout", domain+"/"+LegacyLabel); err != nil && !notLoaded(out, err) {
			return steps, fmt.Errorf("launchctl bootout %s: %w: %s", LegacyLabel, err, strings.TrimSpace(out))
		}
		// bootout returns before the job is gone, and the old node is still
		// shutting down until it is.
		m.waitUntilUnloaded(ctx, domain, LegacyLabel)
	case "linux":
		// --now waits for the stop job, so the old node has exited when this
		// returns.
		if out, err := m.Runner.Run(ctx, "systemctl", "--user", "disable", "--now", LegacyUnitName); err != nil && !notLoaded(out, err) {
			return steps, fmt.Errorf("systemctl disable --now %s: %w: %s", LegacyUnitName, err, strings.TrimSpace(out))
		}
	case "windows":
		// The same tolerance as Uninstall's for the current task: nothing
		// running and no such task are both ordinary here.
		_, _ = m.Runner.Run(ctx, "schtasks", "/End", "/TN", LegacyTaskName)
		out, err := m.Runner.Run(ctx, "schtasks", "/Delete", "/TN", LegacyTaskName, "/F")
		switch {
		case err == nil:
			steps = append(steps, "removed the pre-rename scheduled task "+LegacyTaskName)
		case !taskAbsent(out, err):
			return steps, fmt.Errorf("schtasks /Delete %s: %w: %s", LegacyTaskName, err, strings.TrimSpace(out))
		}
		// The task starts the node and returns, and a pre-rename Startup
		// shortcut starts one too; either way the old node outlives its
		// registration until it is stopped by name.
		if _, err := m.Runner.Run(ctx, "taskkill", "/F", "/IM", legacyNodeImage); err == nil {
			steps = append(steps, "stopped the pre-rename "+product.LegacyNodeBinary)
		}
	default:
		return steps, ErrUnsupported
	}
	removed, err := removeIfPresent(unit)
	if err != nil {
		return steps, fmt.Errorf("remove the pre-rename unit: %w", err)
	}
	switch {
	case m.GOOS == "windows":
		if removed {
			steps = append(steps, "removed "+unit)
		}
	case removed:
		ran := ""
		if program != "" {
			ran = " (it ran " + strings.Join(append([]string{program}, args...), " ") + ")"
		}
		steps = append(steps, "stopped and removed the pre-rename service "+m.LegacyName()+ran)
	}
	return steps, nil
}

// removeIfPresent removes path and says whether there was anything to remove.
// Absent is not an error.
func removeIfPresent(path string) (bool, error) {
	// #nosec G703 -- path is one of this package's own unit paths, built from
	// a constant name and the user's own home or LOCALAPPDATA.
	switch err := os.Remove(path); {
	case err == nil:
		return true, nil
	case errors.Is(err, fs.ErrNotExist):
		return false, nil
	default:
		return false, err
	}
}

// exists is whether path names something that can be stat'ed.
func exists(path string) bool {
	// #nosec G703 -- path is one of this package's own unit paths, built from
	// a constant name and the user's own home or LOCALAPPDATA.
	_, err := os.Stat(path)
	return err == nil
}

// LegacyRegistrations returns which of the pre-rename registration files exist
// for the user whose home is home: the legacy unit and, on Windows, the legacy
// Startup shortcuts. Files only — nothing is run, and nothing is asked of
// launchd, systemd or Task Scheduler.
//
// The node refuses to move its identity out of the pre-rename directory while
// any of these exists (internal/datadir, P2): a registration that can start
// the old node would have it find that directory without the identity, and
// make a new one there.
//
// A file that cannot be inspected for any reason but its absence is reported
// as present. The answer gates a move that cannot be taken back, and "could
// not tell" is not "no".
func LegacyRegistrations(goos, home string) []string {
	m := Manager{GOOS: goos, Home: home}
	var candidates []string
	if unit, err := m.legacyUnitPath(); err == nil {
		candidates = append(candidates, unit)
	}
	if goos == "windows" {
		startup := windowsStartupDirectory(home)
		for _, name := range legacyNodeStartupShortcuts {
			candidates = append(candidates, filepath.Join(startup, name))
		}
	}
	var found []string
	for _, path := range candidates {
		_, err := os.Lstat(path)
		if err == nil || !(errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ENOTDIR)) {
			found = append(found, path)
		}
	}
	return found
}

// LegacyRegistrationsForCurrentUser is LegacyRegistrations for the user this
// process runs as. When the home directory cannot be found, the registration
// files cannot be ruled out, and that is what it says.
func LegacyRegistrationsForCurrentUser() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		return []string{"the files under the home directory, which could not be checked: " + err.Error()}
	}
	return LegacyRegistrations(runtime.GOOS, home)
}
