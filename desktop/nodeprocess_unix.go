//go:build !windows

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

// nodeExecutable is what the running node is called in a process list.
const nodeExecutable = productNodeBinary

// legacyNodeExecutable is what the pre-rename node is called there.
const legacyNodeExecutable = productLegacyNodeBinary

// stopNodeProcesses ends every node on this machine: each agenthallway-node
// and pre-rename agenthub-node listNodeProcesses finds, by its pid.
//
// By pid from this app's own listing, not `pkill -x` by name: the kernel keeps
// 15 or 16 bytes of a process's name (truncatedName), so `pkill -x
// agenthallway-node` matches nothing on Linux, and a pattern short enough to
// match would match someone else's agenthallway-no... as well. The listing
// confirms each process by its full executable name first.
//
// This path is only reached when no service manager holds the node — a
// registered launchd job or systemd unit is restarted through ah instead, so
// nothing here races a KeepAlive that would start the node behind this.
func stopNodeProcesses(ctx context.Context) (string, error) {
	processes, err := listNodesSettled(ctx)
	if err != nil {
		return "", fmt.Errorf("list the nodes to stop: %w", err)
	}
	var lines []string
	var failures []error
	for _, process := range processes {
		// 0, -1 and the init process are not processes to signal: kill(2)
		// reads 0 and -1 as "every process in the group" and "every process
		// this user may signal". A listing never names them; this makes sure.
		if process.PID <= 1 {
			failures = append(failures, fmt.Errorf("%s was listed with pid %d, which is not one to signal", process.name(), process.PID))
			continue
		}
		if err := signalProcess(process.PID, syscall.SIGTERM); err != nil {
			lines = append(lines, fmt.Sprintf("could not stop %s (pid %d): %v", process.name(), process.PID, err))
			failures = append(failures, err)
			continue
		}
		lines = append(lines, fmt.Sprintf("asked %s (pid %d) to stop", process.name(), process.PID))
	}
	return strings.Join(lines, "\n"), errors.Join(failures...)
}

// signalProcess sends sig to pid. A variable so that the tests can see what
// would be signalled without signalling anything: the machine running them
// may have a node of its own, and it is not theirs to stop.
var signalProcess = func(pid int, sig syscall.Signal) error {
	return syscall.Kill(pid, sig)
}

// startNodeDetached starts the node so that it outlives this window.
//
// Setsid puts it in its own session, so it is not killed with the app's
// process group and has no controlling terminal to be stopped by.
func startNodeDetached(binary, logPath string, args []string) error {
	log, err := openNodeLog(logPath)
	if err != nil {
		return err
	}
	defer log.Close()
	// #nosec G204 -- binary is what findNode resolved: named by the owner in
	// the environment, or sitting beside this executable where the packaging
	// step put it. PATH is deliberately not among the places it looks. args
	// are the stopped node's own command line, parsed against the node's flag
	// table and less its remembered settings (planNodeRestart); nothing the
	// window or the network supplies reaches them.
	command := exec.Command(binary, args...)
	command.Dir = filepath.Dir(binary)
	command.Stdout = log
	command.Stderr = log
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		return err
	}
	// Released rather than waited on: this app is a front end for a node that
	// keeps running, not its parent.
	return command.Process.Release()
}

// nodeLogDir is where a node started by this app writes its output. macOS has
// one place for a user's logs; on Linux the state directory is where a file
// the owner may want to read after a reboot belongs.
func nodeLogDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("find a place for the node log: %w", err)
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Logs", "agenthallway"), nil
	}
	if state := os.Getenv("XDG_STATE_HOME"); state != "" {
		return filepath.Join(state, "agenthallway"), nil
	}
	return filepath.Join(home, ".local", "state", "agenthallway"), nil
}
