//go:build darwin || linux || windows

package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

// TestNodeProcessHelper is not a test: it is the body of the process
// TestListNodeProcessesReadsARealProcess starts under the node's name.
func TestNodeProcessHelper(t *testing.T) {
	if os.Getenv("AGENTHALLWAY_NODE_PROCESS_HELPER") != "1" {
		t.Skip("helper process")
	}
	time.Sleep(30 * time.Second)
}

// The fakes elsewhere say what the restart does with a command line; this asks
// the real operating system for one. Processes named agenthallway-node are
// started with arguments that have spaces and quotes in them — the default
// database on macOS lives under "Application Support", and on Windows the
// whole command line is one string that has to be split back the way the
// node's own os.Args is — and with an environment whose home and config
// directory are not this test's. The listing has to give every argument back
// whole, the environment as the process has it, and name the process the way
// the stop will find it.
//
// agenthallway-node is 17 bytes, longer than the kernel keeps of a process's
// name on macOS (16) or Linux (15), so this is also the test that the listing
// finds the node through the truncation. And some are named agenthub-node,
// the pre-rename name, which the listing has to find too and mark Legacy: an
// upgraded desktop that could not see a still-running old node would start a
// second one on its data.
//
// Eight of each new-name process, the last entry of each one's environment a
// byte longer than the last: on macOS the kernel pads the environment's end to
// eight bytes, and one that ends on the boundary has nothing between it and
// the kernel's own strings (nodeprocs_darwin.go parseProcargs2). Whichever
// length this environment happens to be, one of the eight ends there.
//
// Everything asserted is about the processes this test started, found by
// their pids: the machine running it may have nodes of its own — a
// developer's Mac runs one — and they are neither counted nor touched.
//
// The Windows half runs in CI's windows job, the macOS half in its macos job
// as well as on a developer's Mac.
func TestListNodeProcessesReadsARealProcess(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	binaries := map[bool]string{
		false: filepath.Join(dir, nodeExecutable),
		true:  filepath.Join(dir, legacyNodeExecutable),
	}
	for _, binary := range binaries {
		copyExecutable(t, self, binary)
	}
	home := filepath.Join(dir, "a home", `with "quotes"`)
	config := filepath.Join(dir, "a config dir")
	database := filepath.Join(dir, "Application Support", "not the default", "agenthallway.db")
	helperArgs := []string{"-test.run=^TestNodeProcessHelper$", "--", "--db", database,
		"--display-name", `say "hi" to me`, "", `trailing\`}
	wantPaths, _ := nodeDefaultPaths(runtime.GOOS, func(name string) string {
		return map[string]string{"HOME": home, "XDG_CONFIG_HOME": config, "AppData": config, "USERPROFILE": home}[name]
	})

	type started struct {
		fill   string
		legacy bool
	}
	ours := map[int]started{}
	var commands []*exec.Cmd
	for _, run := range []struct {
		legacy bool
		fills  int
	}{{legacy: false, fills: 8}, {legacy: true, fills: 4}} {
		for fill := range run.fills {
			command := startNodeHelper(t, binaries[run.legacy], helperArgs, "HOME="+home, "XDG_CONFIG_HOME="+config,
				"APPDATA="+config, "USERPROFILE="+home, "AGENTHALLWAY_TEST_FILL="+strings.Repeat("f", fill))
			commands = append(commands, command)
			ours[command.Process.Pid] = started{fill: strings.Repeat("f", fill), legacy: run.legacy}
		}
	}
	pids := map[int]string{}
	for pid := range ours {
		pids[pid] = ""
	}

	for _, process := range waitForListed(t, pids) {
		run := ours[process.PID]
		label := fmt.Sprintf("fill %d legacy %v", len(run.fill), run.legacy)
		if want := append([]string{binaries[run.legacy]}, helperArgs...); !slices.Equal(process.Argv, want) {
			t.Fatalf("%s: argv = %q, want %q", label, process.Argv, want)
		}
		if process.Legacy != run.legacy {
			t.Errorf("%s: listed with Legacy %v", label, process.Legacy)
		}
		if process.EnvErr != nil {
			t.Fatalf("%s: its environment was not read: %v", label, process.EnvErr)
		}
		if process.UserErr != nil {
			t.Errorf("%s: a process this test started is not this user's: %v", label, process.UserErr)
		}
		lookup := environmentLookup(runtime.GOOS, process.Env)
		if got := lookup("AGENTHALLWAY_TEST_FILL"); got != run.fill {
			t.Errorf("%s: the environment's last entry read back as %q", label, got)
		}
		paths, err := nodeDefaultPaths(runtime.GOOS, lookup)
		if err != nil {
			t.Fatalf("%s: its environment names no default paths: %v", label, err)
		}
		if paths != wantPaths {
			t.Errorf("%s: from its environment: %+v, want %+v", label, paths, wantPaths)
		}
	}

	// Killed and not yet waited for, each is a zombie on macOS and Linux —
	// what a node this app started and then stopped stays until the app
	// exits. It is not a running node, and it must not stop the listing. On
	// its way there a process can be caught exiting and not yet a zombie,
	// which macOS answers with EINVAL and Linux with an empty command line
	// (nodeprocs_linux.go, an error wrapping ESRCH): that error, and only that
	// kind (transientListError), is asked again rather than failed.
	for _, command := range commands {
		if err := command.Process.Kill(); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.Now().Add(15 * time.Second) // PowerShell again
	for {
		processes, err := listNodeProcesses(context.Background())
		if err != nil && !transientListError(err) {
			t.Fatalf("list with exited nodes about: %v", err)
		}
		if err == nil && !slices.ContainsFunc(processes, func(p nodeProcess) bool { _, mine := ours[p.PID]; return mine }) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the killed processes are still listed, or the listing still fails: %d listed, %v", len(processes), err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// W6. A program whose name shares the node's first 15 or 16 bytes is not a
// node: on Linux agenthallway-notes has the comm agenthallway-no, the same as
// agenthallway-node's, and on macOS agenthallway-nodeX has the p_comm
// agenthallway-nod. The kernel name lets it through; its own executable name
// keeps it out — and a restart that listed it would stop it. (Windows keeps
// whole names, so there the same check is that a near name is not taken.)
//
// A node is started beside it, so the listing that leaves the lookalike out is
// one that was able to see the processes this test started.
func TestListNodeProcessesIgnoresALookalikeName(t *testing.T) {
	lookalike := map[string]string{
		"darwin": "agenthallway-nodeX", "linux": "agenthallway-notes", "windows": "agenthallway-nodeX.exe",
	}[runtime.GOOS]
	if limit := map[string]int{"darwin": 16, "linux": 15}[runtime.GOOS]; limit > 0 &&
		truncatedName(lookalike, limit) != truncatedName(nodeExecutable, limit) {
		t.Fatalf("%s does not share %s's kernel name, so this would test nothing", lookalike, nodeExecutable)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	node, other := filepath.Join(dir, nodeExecutable), filepath.Join(dir, lookalike)
	copyExecutable(t, self, node)
	copyExecutable(t, self, other)
	args := []string{"-test.run=^TestNodeProcessHelper$"}
	control := startNodeHelper(t, node, args)
	stranger := startNodeHelper(t, other, args)

	deadline := time.Now().Add(15 * time.Second) // PowerShell can take seconds to start cold
	for {
		processes, err := listNodeProcesses(context.Background())
		if err != nil && !transientListError(err) {
			t.Fatalf("list: %v", err)
		}
		if err == nil && slices.ContainsFunc(processes, func(p nodeProcess) bool { return p.PID == control.Process.Pid }) {
			if slices.ContainsFunc(processes, func(p nodeProcess) bool { return p.PID == stranger.Process.Pid }) {
				t.Fatalf("%s (pid %d) was listed as a node", lookalike, stranger.Process.Pid)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("the node this test started (pid %d) was never listed (last error: %v)", control.Process.Pid, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// startNodeHelper starts binary — this test binary under another name — as
// TestNodeProcessHelper, with env appended to this process's environment, and
// kills it when the test ends. Only processes started here are ever killed.
func startNodeHelper(t *testing.T, binary string, args []string, env ...string) *exec.Cmd {
	t.Helper()
	// #nosec G204 -- this test's own binary, copied under the name the test needs.
	command := exec.Command(binary, args...)
	// The helper flag first and the caller's after, so that the caller's last
	// entry is where the environment ends.
	command.Env = append(append(os.Environ(), "AGENTHALLWAY_NODE_PROCESS_HELPER=1"), env...)
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = command.Process.Kill()
		_ = command.Wait()
	})
	return command
}

// waitForListed lists node processes until every pid in want is among them,
// and returns those, and only those. A listing that fails the way one fails on
// a process caught exiting — another node on this machine may be on its way
// out — is
// asked again until the deadline; any other failure is the test's. Asking
// again on every error would hide a misread: the kernel's strings after a new
// process's environment are wiped by the process itself moments after it
// starts, and a parse that fails only before that would pass on the retry.
func waitForListed(t *testing.T, want map[int]string) []nodeProcess {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second) // PowerShell can take seconds to start cold
	for {
		processes, err := listNodeProcesses(context.Background())
		if err != nil && !transientListError(err) {
			t.Fatalf("list: %v", err)
		}
		var found []nodeProcess
		for _, process := range processes {
			if _, ok := want[process.PID]; ok {
				found = append(found, process)
			}
		}
		if err == nil && len(found) == len(want) {
			return found
		}
		if time.Now().After(deadline) {
			t.Fatalf("%d of the %d processes this test started were listed among %d node processes (last error: %v)",
				len(found), len(want), len(processes), err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func copyExecutable(t *testing.T, from, to string) {
	t.Helper()
	source, err := os.Open(from) // #nosec G304 -- this test's own executable
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	target, err := os.OpenFile(to, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o700) // #nosec G302 G304 -- a temp copy that has to be executable
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(target, source); err != nil {
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
}
