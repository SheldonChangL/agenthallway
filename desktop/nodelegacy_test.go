package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// legacyDefaultIn is where a pre-rename node with this environment keeps its
// database when its command line names none.
func legacyDefaultIn(t *testing.T, env []string) string {
	t.Helper()
	database, err := legacyDatabase(runtime.GOOS, environmentLookup(runtime.GOOS, env))
	if err != nil {
		t.Fatal(err)
	}
	return database
}

func makeFile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("sqlite"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// W10. A pre-rename agenthub-node started without --db has the pre-rename
// default open. The node started in its place — the current binary, beside
// this app — is given exactly that path: the current default is an empty
// database beside it, which would be a new identity. Given the old default,
// the node moves it on its first start and comes back as the same node.
func TestRestartNodeMovesALegacyNodeOntoTheNewBinary(t *testing.T) {
	node := withFakeNode(t)
	fake := &fakeRestart{
		answers: []bool{false, true},
		running: []nodeProcess{{PID: 2062, Legacy: true, Argv: []string{"/Applications/agenthub-desktop.app/Contents/MacOS/agenthub-node"}}},
	}
	fake.install(t)
	legacy := legacyDefaultIn(t, fake.nodeEnv)
	makeFile(t, legacy)

	result, err := restartAppProcess(t)
	if err != nil {
		t.Fatalf("restart: %v\n%s", err, result.Output)
	}
	want := []string{"--db", legacy, "--claude-root", fake.nodePaths.claude, "--codex-root", fake.nodePaths.codex}
	if len(fake.started) != 1 || !slices.Equal(fake.started[0], want) {
		t.Fatalf("started with %q, want %q", fake.started, want)
	}
	if !slices.Contains(fake.steps, "start "+node) {
		t.Errorf("the node started is not the one beside this app: %v", fake.steps)
	}
	for _, phrase := range []string{legacy, "pre-rename", "the node that was stopped"} {
		if !strings.Contains(result.Output, phrase) {
			t.Errorf("output does not say %q:\n%s", phrase, result.Output)
		}
	}
}

// W11. A node given the pre-rename default on its command line (a unit or a
// shell line written before the rename) moved that database to its own
// default when it started, and runs on it there. The path it was given now
// names nothing; that is not a misreading, and the restart carries it on as
// it is — the node started from here does the same move — so long as this
// app's environment, which that node inherits, has the same pre-rename
// default. Otherwise that node would open the path as given, and find
// nothing.
func TestPlanNodeRestartAcceptsALegacyPathTheNodeAlreadyMoved(t *testing.T) {
	fake := &fakeRestart{}
	fake.install(t)
	legacy := legacyDefaultIn(t, fake.nodeEnv)
	running := nodeProcess{PID: 7, Env: fake.nodeEnv, Argv: []string{"/opt/agenthallway-node", "--db", legacy, "-discover=true"}}

	fake.appLegacyDB = legacy
	plan, err := planNodeRestart(running, appPaths)
	if err != nil {
		t.Fatal(err)
	}
	if plan.db != fake.nodePaths.database {
		t.Errorf("plan.db = %s, want the database the node moved it to, %s", plan.db, fake.nodePaths.database)
	}
	if !strings.Contains(plan.dbFrom, "moved there by the node from the pre-rename location") {
		t.Errorf("dbFrom = %q", plan.dbFrom)
	}
	// Nothing outside the node rewrites a --db.
	if want := []string{"--db", legacy, "--claude-root", fake.nodePaths.claude, "--codex-root", fake.nodePaths.codex}; !slices.Equal(plan.args, want) {
		t.Errorf("args = %q, want %q", plan.args, want)
	}

	// This app's environment names another pre-rename default: the node it
	// starts would open the old path as a new database. Refused, with the
	// path that would work.
	fake.appLegacyDB = filepath.Join(t.TempDir(), "agenthub", "agenthub.db")
	_, err = planNodeRestart(running, appPaths)
	if err == nil || !strings.Contains(err.Error(), "start it with --db "+fake.nodePaths.database) {
		t.Errorf("err = %v, want a refusal naming the database the node moved it to", err)
	}
}

// W12. The one exception is that one: a database that is not there, and is
// not a pre-rename default the node has moved, is still the refusal it was.
func TestPlanNodeRestartStillRefusesAMissingDatabase(t *testing.T) {
	fake := &fakeRestart{}
	fake.install(t)
	legacy := legacyDefaultIn(t, fake.nodeEnv)
	fake.appLegacyDB = legacy
	// Some other path that is not there: not the node's to have moved, even
	// with the current default present.
	other := nodeProcess{PID: 8, Env: fake.nodeEnv, Argv: []string{"/opt/agenthallway-node", "--db", filepath.Join(t.TempDir(), "agenthub", "agenthub.db")}}
	if _, err := planNodeRestart(other, appPaths); err == nil || !strings.Contains(err.Error(), "is not there") {
		t.Errorf("another path: err = %v, want the missing database refused", err)
	}
	// The pre-rename default, and nothing at the current default either.
	if err := os.Remove(fake.nodePaths.database); err != nil {
		t.Fatal(err)
	}
	neither := nodeProcess{PID: 7, Env: fake.nodeEnv, Argv: []string{"/opt/agenthallway-node", "--db", legacy}}
	if _, err := planNodeRestart(neither, appPaths); err == nil || !strings.Contains(err.Error(), "is not there") {
		t.Errorf("neither: err = %v, want the missing database refused", err)
	}
}

// W13. ah's status says when the registration is the pre-rename one, and the
// window gets it as legacy — with the database the old unit names, which the
// re-registration carries over.
func TestServiceStatusCarriesTheLegacyFlag(t *testing.T) {
	withFakeTool(t, `{"service":{"Supported":true,"Installed":true,"Running":true,"PID":2062,`+
		`"UnitPath":"/Users/me/Library/LaunchAgents/local.agenthub.node.plist","Legacy":true,`+
		`"Program":"/old/agenthub-node","Arguments":["--db","/data/agenthub.db"]},"nodeAnswering":true}`, nil)
	findTool = func() (string, error) { return "/fake/ah", nil }
	app := NewApp()
	app.ctx = context.Background()
	status := app.ServiceStatus()
	if !status.Legacy || status.LegacyAlsoInstalled || !status.Installed || !status.DBPathKnown || status.DBPath != "/data/agenthub.db" {
		t.Errorf("status = %+v", status)
	}
	encoded, _ := json.Marshal(status)
	if !strings.Contains(string(encoded), `"legacy":true`) || !strings.Contains(string(encoded), `"legacyAlsoInstalled":false`) {
		t.Errorf("the window would not see it: %s", encoded)
	}

	withFakeTool(t, `{"service":{"Supported":true,"Installed":true,"LegacyAlsoInstalled":true,"Program":"/new/agenthallway-node"}}`, nil)
	findTool = func() (string, error) { return "/fake/ah", nil }
	if status := app.ServiceStatus(); status.Legacy || !status.LegacyAlsoInstalled {
		t.Errorf("status with both registrations = %+v", status)
	}
}

// W14. Restarting the pre-rename registration would start the old node again,
// and stopping its node by hand would only have launchd start it again. The
// restart says what replaces it, and stops nothing.
func TestRestartNodeRefusesALegacyRegistration(t *testing.T) {
	calls := withFakeTool(t, `{"service":{"Supported":true,"Installed":true,"Running":true,"PID":2062,"Legacy":true,`+
		`"Program":"/old/agenthub-node"}}`, nil)
	findTool = func() (string, error) { return "/fake/ah", nil }
	// Installed so that a restart that went on anyway would be seen, not
	// carried out.
	fake := &fakeRestart{answers: []bool{false, true}, running: []nodeProcess{{PID: 2062, Legacy: true, Argv: []string{"/old/agenthub-node"}}}}
	fake.install(t)
	app := restartApp(t)
	_, err := app.RestartNode()
	if err == nil || !strings.Contains(err.Error(), "pre-rename name "+legacyServiceNames[runtime.GOOS]) ||
		!strings.Contains(err.Error(), "ah service install") {
		t.Fatalf("err = %v, want the pre-rename name and what replaces it", err)
	}
	if len(fake.steps) != 0 {
		t.Errorf("the machine was touched: %v", fake.steps)
	}
	for _, call := range *calls {
		if !strings.HasSuffix(call, "service status") {
			t.Errorf("ah was asked %q", call)
		}
	}
}

// The pre-rename names this app says are internal/service's, which is what ah
// registered them under.
func TestLegacyServiceNamesMatchTheServicePackage(t *testing.T) {
	source, err := os.ReadFile(filepath.Join("..", "internal", "service", "legacy.go"))
	if err != nil {
		t.Fatal(err)
	}
	for goos, constant := range map[string]string{"darwin": "LegacyLabel", "linux": "LegacyUnitName", "windows": "LegacyTaskName"} {
		if want := constant + ` = "` + legacyServiceNames[goos] + `"`; !strings.Contains(string(source), want) {
			t.Errorf("internal/service/legacy.go does not say %s", want)
		}
	}
}
