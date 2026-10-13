package service

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
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
