//go:build !windows

package main

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"syscall"
	"testing"
)

// No test signals a real process. The machine running them may have a node of
// its own — a developer's Mac runs one, under the pre-rename name too — and a
// test that reached the real signal with a pid from a listing would end it.
// A test that means to watch a signal installs its own (watchSignals); one
// that reaches this has a bug, and fails here without signalling anything.
func init() {
	signalProcess = func(pid int, _ syscall.Signal) error {
		panic(fmt.Sprintf("a test reached the real signal, for pid %d", pid))
	}
}

// watchSignals replaces the signal with one that records, and the listing with
// processes, for one test.
func watchSignals(t *testing.T, processes []nodeProcess, fail map[int]error) *[]int {
	t.Helper()
	signalled := &[]int{}
	signalWas, listWas := signalProcess, listNodes
	t.Cleanup(func() { signalProcess, listNodes = signalWas, listWas })
	listNodes = func(context.Context) ([]nodeProcess, error) { return processes, nil }
	signalProcess = func(pid int, sig syscall.Signal) error {
		if sig != syscall.SIGTERM {
			t.Errorf("pid %d was sent %v, want SIGTERM: the node shuts down on it", pid, sig)
		}
		*signalled = append(*signalled, pid)
		return fail[pid]
	}
	return signalled
}

// W9. The stop is by pid, from the listing: pkill -x agenthallway-node
// matches nothing on Linux, whose comm keeps 15 bytes of the name, and the
// pre-rename agenthub-node has to be stopped as well. Each listed node is
// asked to stop, and what was asked is said, per pid.
func TestStopNodeSignalsEveryListedNodeByPID(t *testing.T) {
	signalled := watchSignals(t, []nodeProcess{
		{PID: 4242, Argv: []string{"/opt/agenthallway-node"}},
		{PID: 4343, Argv: []string{"/opt/agenthub-node"}, Legacy: true},
	}, map[int]error{4343: syscall.EPERM})
	output, err := stopNodeProcesses(context.Background())
	if !slices.Equal(*signalled, []int{4242, 4343}) {
		t.Errorf("signalled %v, want both listed pids", *signalled)
	}
	for _, want := range []string{"agenthallway-node (pid 4242)", "could not stop agenthub-node (pid 4343)"} {
		if !strings.Contains(output, want) {
			t.Errorf("output does not say %q:\n%s", want, output)
		}
	}
	if !errors.Is(err, syscall.EPERM) {
		t.Errorf("err = %v, want the failed signal's", err)
	}
}

// kill(2) reads 0 as the caller's process group and -1 as every process the
// caller may signal. No listing names them, and no stop sends them.
func TestStopNodeNeverSignalsAProcessGroup(t *testing.T) {
	signalled := watchSignals(t, []nodeProcess{{PID: 0}, {PID: -1}, {PID: 1}}, nil)
	if _, err := stopNodeProcesses(context.Background()); err == nil {
		t.Error("a listing with pids 0, -1 and 1 was stopped without complaint")
	}
	if len(*signalled) != 0 {
		t.Errorf("signalled %v", *signalled)
	}
}

// Nothing listed is nothing to stop, and no error: the restart then asks the
// port whether the node is gone, which is the question that matters.
func TestStopNodeWithNothingRunningStopsNothing(t *testing.T) {
	signalled := watchSignals(t, nil, nil)
	if output, err := stopNodeProcesses(context.Background()); err != nil || output != "" || len(*signalled) != 0 {
		t.Errorf("output %q, err %v, signalled %v", output, err, *signalled)
	}
}
