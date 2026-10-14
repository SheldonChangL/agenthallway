package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"agenthub.local/agenthub/internal/datadir"
	"agenthub.local/agenthub/internal/datadir/datadirtest"
	"agenthub.local/agenthub/internal/registry"
)

// runNodeEnv makes this test binary run the node itself — run(), with the
// arguments after "--" — instead of the tests, so a test can start the node
// as the service manager does: a process of its own, in an environment of
// its own, that exits with run()'s answer.
const runNodeEnv = "AGENTHALLWAY_TEST_RUN_NODE"

func TestMain(m *testing.M) {
	if os.Getenv(runNodeEnv) == "1" {
		args := os.Args[1:]
		for i, arg := range args {
			if arg == "--" {
				args = args[i+1:]
				break
			}
		}
		os.Args = append([]string{"agenthallway-node"}, args...)
		if err := run(); err != nil {
			log.Printf("agenthallway-node: %v", err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// machine is a temporary user: a home, a configuration directory, and the
// addresses a node started for it listens on. Every path is under the test's
// temporary directory and both ports are free ones, never 7462 or 7463: a
// developer's real node is there, and its data is what this code moves.
type machine struct {
	root   string
	home   string
	layout datadir.Layout
	env    []string
	listen string
	peer   string
	claude string
	codex  string
}

func newMachine(t *testing.T) *machine {
	t.Helper()
	root := t.TempDir()
	m := &machine{
		root:   root,
		home:   filepath.Join(root, "home"),
		claude: filepath.Join(root, "claude"),
		codex:  filepath.Join(root, "codex"),
	}
	appData := filepath.Join(root, "AppData", "Roaming")
	localAppData := filepath.Join(root, "AppData", "Local")
	xdgConfig := filepath.Join(root, "xdg-config")
	switch runtime.GOOS {
	case "darwin":
		m.layout = datadir.LayoutFor(filepath.Join(m.home, "Library", "Application Support"))
	case "windows":
		m.layout = datadir.LayoutFor(appData)
	default:
		m.layout = datadir.LayoutFor(xdgConfig)
	}
	for _, dir := range []string{m.home, m.claude, m.codex, m.layout.Config} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	m.listen, m.peer = freeLoopback(t), freeLoopback(t)
	for _, address := range []string{m.listen, m.peer} {
		if strings.HasSuffix(address, ":7462") || strings.HasSuffix(address, ":7463") {
			t.Fatalf("refusing to run: %s is the real node's port", address)
		}
	}

	overrides := map[string]string{
		"HOME": m.home, "USERPROFILE": m.home,
		"XDG_CONFIG_HOME": xdgConfig, "XDG_STATE_HOME": filepath.Join(root, "xdg-state"),
		"XDG_DATA_HOME": filepath.Join(root, "xdg-data"), "XDG_CACHE_HOME": filepath.Join(root, "xdg-cache"),
		"APPDATA": appData, "LOCALAPPDATA": localAppData,
	}
	for name, value := range overrides {
		datadirtest.RequireConfined(t, value)
		m.env = append(m.env, name+"="+value)
	}
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if _, overridden := overrides[strings.ToUpper(name)]; overridden ||
			strings.HasPrefix(name, "AGENTHUB_") || strings.HasPrefix(name, "AGENTHALLWAY_") {
			continue
		}
		m.env = append(m.env, entry)
	}
	m.env = append(m.env, runNodeEnv+"=1")
	datadirtest.RequireConfined(t, m.root, m.layout.Config)
	return m
}

func (m *machine) command(extra ...string) *exec.Cmd {
	args := append([]string{"--",
		"-listen", m.listen, "-peer-listen", m.peer,
		"-claude-root", m.claude, "-codex-root", m.codex,
	}, extra...)
	command := exec.Command(os.Args[0], args...) // #nosec G204 -- this test binary, re-executed as the node
	command.Env = m.env
	command.Dir = m.root
	return command
}

// syncBuffer is a bytes.Buffer two goroutines can share.
type syncBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.String()
}

// runningNode is a node process started by a test.
type runningNode struct {
	command *exec.Cmd
	output  *syncBuffer
	exited  chan error
	url     string
	client  *http.Client
}

// testClient opens a connection per request and closes it after. A shared
// keep-alive client can dial a spare connection it never sends on, and
// http.Server.Shutdown waits up to five seconds for such a connection — the
// node's whole shutdown budget — so a stop would fail for a reason that is
// the test's own.
func testClient() *http.Client {
	return &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
}

// start starts a node and returns once its owner API answers.
func (m *machine) start(t *testing.T, extra ...string) *runningNode {
	t.Helper()
	command := m.command(extra...)
	output := &syncBuffer{}
	command.Stdout, command.Stderr = output, output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	node := &runningNode{
		command: command, output: output, exited: make(chan error, 1),
		url: "http://" + m.listen, client: testClient(),
	}
	go func() { node.exited <- command.Wait() }()
	t.Cleanup(func() {
		if command.ProcessState == nil {
			_ = command.Process.Kill()
			<-node.exited
		}
	})

	deadline := time.Now().Add(30 * time.Second)
	for {
		select {
		case err := <-node.exited:
			node.exited <- err
			t.Fatalf("the node exited before it served (%v):\n%s", err, output.String())
		default:
		}
		response, err := node.client.Get(node.url + "/v1/node")
		if err == nil {
			_ = response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return node
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("the node did not answer in 30s:\n%s", output.String())
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// runToExit runs a node that is expected to refuse, and returns its output
// and exit error.
func (m *machine) runToExit(t *testing.T, extra ...string) (string, error) {
	t.Helper()
	command := m.command(extra...)
	output := &syncBuffer{}
	command.Stdout, command.Stderr = output, output
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- command.Wait() }()
	select {
	case err := <-exited:
		return output.String(), err
	case <-time.After(30 * time.Second):
		_ = command.Process.Kill()
		<-exited
		t.Fatalf("the node did not exit in 30s:\n%s", output.String())
	}
	return "", nil
}

// stop ends the node the way a service manager does, and waits.
func (n *runningNode) stop(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		_ = n.command.Process.Kill()
		<-n.exited
		return
	}
	if err := n.command.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-n.exited:
		if err != nil {
			t.Errorf("the node exited with %v after SIGTERM:\n%s", err, n.output.String())
		}
	case <-time.After(15 * time.Second):
		_ = n.command.Process.Kill()
		<-n.exited
		t.Fatalf("the node did not stop in 15s after SIGTERM:\n%s", n.output.String())
	}
}

func (n *runningNode) get(t *testing.T, path string, into any) {
	t.Helper()
	response, err := n.client.Get(n.url + path)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("GET %s = %d", path, response.StatusCode)
	}
	if err := json.NewDecoder(response.Body).Decode(into); err != nil {
		t.Fatal(err)
	}
}

// requireIdentity asks the running node who it is and whom it is paired with.
func (n *runningNode) requireIdentity(t *testing.T, want datadirtest.Legacy) {
	t.Helper()
	var self struct {
		ID          string `json:"id"`
		Fingerprint string `json:"fingerprint"`
	}
	n.get(t, "/v1/node", &self)
	if self.ID != want.NodeID || self.Fingerprint != want.Fingerprint {
		t.Errorf("the node is %s (%s), want %s (%s): it became a different node",
			self.ID, self.Fingerprint, want.NodeID, want.Fingerprint)
	}
	var paired struct {
		Nodes []struct {
			NodeID string `json:"nodeId"`
		} `json:"nodes"`
	}
	n.get(t, "/v1/nodes", &paired)
	for _, peer := range paired.Nodes {
		if peer.NodeID == want.PeerID {
			return
		}
	}
	t.Errorf("the paired peer %s is gone: %+v", want.PeerID, paired.Nodes)
}

func requireExists(t *testing.T, path string, want bool) {
	t.Helper()
	_, err := os.Lstat(path)
	switch {
	case want && err != nil:
		t.Errorf("%s is missing: %v", path, err)
	case !want && !errors.Is(err, os.ErrNotExist):
		t.Errorf("%s exists (%v); it should not", path, err)
	}
}

func readBytes(t *testing.T, path string) []byte {
	t.Helper()
	content, err := os.ReadFile(path) // #nosec G304 -- a test path under t.TempDir
	if err != nil {
		t.Fatal(err)
	}
	return content
}

// legacyRegistration is where the pre-rename service is registered for this
// machine's user, on the platform the test runs on.
func (m *machine) legacyRegistration(t *testing.T) string {
	t.Helper()
	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(m.home, "Library", "LaunchAgents", "local.agenthub.node.plist")
	case "linux":
		return filepath.Join(m.home, ".config", "systemd", "user", "agenthub-node.service")
	case "windows":
		return filepath.Join(m.root, "AppData", "Local", "agenthub", "node-task.xml")
	}
	t.Skipf("no service manager on %s", runtime.GOOS)
	return ""
}

func writeFileAt(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// N1. An upgraded machine, as v0.1.x left it: the identity in the old
// directory with the paired peer still only in the write-ahead log, and an
// unrelated product's files beside it. The first start moves the identity and
// is the same node; the second start finds nothing to do.
func TestUpgradeFromTheLegacyLayoutKeepsTheNodeID(t *testing.T) {
	m := newMachine(t)
	l := m.layout
	legacy := datadirtest.WriteLegacy(t, l.Old, true)
	datadirtest.WriteForeign(t, l.Old)
	foreign := datadirtest.Tree(t, l.Old, true)
	key := readBytes(t, filepath.Join(l.Old, "node.key"))

	first := m.start(t)
	first.requireIdentity(t, legacy)
	if !strings.Contains(first.output.String(), "moved this node's identity from "+l.Old+" to "+l.New) {
		t.Errorf("the move was not logged:\n%s", first.output.String())
	}
	requireExists(t, l.Old, true)
	datadirtest.RequireSameTree(t, "the old directory", foreign, datadirtest.Tree(t, l.Old, false))
	if !bytes.Equal(readBytes(t, filepath.Join(l.New, "node.key")), key) {
		t.Error("node.key in the new directory is not the old key")
	}
	requireExists(t, l.NewDB, true)
	requireExists(t, filepath.Join(l.New, ".migrating-from-agenthub"), false)
	first.stop(t)

	newKey := readBytes(t, filepath.Join(l.New, "node.key"))
	second := m.start(t)
	second.requireIdentity(t, legacy)
	for _, unwanted := range []string{"moved this node's", "pre-rename"} {
		if strings.Contains(second.output.String(), unwanted) {
			t.Errorf("the second start said %q, so it was not a no-op:\n%s", unwanted, second.output.String())
		}
	}
	datadirtest.RequireSameTree(t, "the old directory", foreign, datadirtest.Tree(t, l.Old, false))
	if !bytes.Equal(readBytes(t, filepath.Join(l.New, "node.key")), newKey) {
		t.Error("the second start changed node.key")
	}
	requireExists(t, filepath.Join(l.New, ".migrating-from-agenthub"), false)
	second.stop(t)
}

// N2, and the rest of Resolve's table at the node: a unit that names a
// default explicitly — the old one, as every v0.1.x unit with --db does, or
// the new one — is the default, and the identity moves.
func TestUpgradeWithTheDefaultPathGivenExplicitly(t *testing.T) {
	for _, tc := range []struct {
		name string
		db   func(datadir.Layout) string
		says string
	}{
		{"the pre-rename default", func(l datadir.Layout) string { return l.OldDB }, "is the pre-rename default location"},
		{"the new default", func(l datadir.Layout) string { return l.NewDB }, "moved this node's identity"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newMachine(t)
			l := m.layout
			legacy := datadirtest.WriteLegacy(t, l.Old, true)
			node := m.start(t, "-db", tc.db(l))
			node.requireIdentity(t, legacy)
			if !strings.Contains(node.output.String(), tc.says) {
				t.Errorf("the log lacks %q:\n%s", tc.says, node.output.String())
			}
			requireExists(t, l.Old, false)
			requireExists(t, filepath.Join(l.New, "node.key"), true)
			node.stop(t)
		})
	}
}

// The same unit, started again after the move. A v0.1.x unit can name the old
// default by another spelling of its directory (`ah service install --db`
// makes the path absolute without resolving links), and the first start
// moves the identity and removes the emptied old directory. Every later start
// gets the same -db, of a directory that is no longer there: it has to be the
// default still, not an empty database made for it, which is a new node.
func TestTheNextStartUnderTheSameUnitIsTheSameNode(t *testing.T) {
	for _, tc := range []struct {
		name  string
		spell func(t *testing.T, m *machine) string
	}{
		{"the configuration directory through a symlink", func(t *testing.T, m *machine) string {
			if runtime.GOOS == "windows" {
				t.Skip("symlinks need privileges on Windows")
			}
			link := filepath.Join(m.root, "config-link")
			if err := os.Symlink(m.layout.Config, link); err != nil {
				t.Fatal(err)
			}
			return filepath.Join(link, "agenthub", "agenthub.db")
		}},
		{"another case", func(t *testing.T, m *machine) string {
			variant := filepath.Join(m.layout.Config, "AgentHub")
			if _, err := os.Stat(variant); err != nil {
				t.Skip("this volume honours case, so the variant is another directory")
			}
			return filepath.Join(variant, "agenthub.db")
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := newMachine(t)
			l := m.layout
			legacy := datadirtest.WriteLegacy(t, l.Old, true)
			given := tc.spell(t, m)

			first := m.start(t, "-db", given)
			first.requireIdentity(t, legacy)
			requireExists(t, l.Old, false)
			first.stop(t)

			second := m.start(t, "-db", given)
			second.requireIdentity(t, legacy)
			requireExists(t, l.Old, false)
			second.stop(t)
		})
	}
}

// Any other --db is the owner's: used as given, never moved, and not held
// back by a pre-rename registration — exactly what v0.1.x did with it.
func TestACustomDatabaseIsUsedAsGivenAndNothingMoves(t *testing.T) {
	m := newMachine(t)
	l := m.layout
	datadirtest.WriteLegacy(t, l.Old, true)
	writeFileAt(t, m.legacyRegistration(t), "the pre-rename service")
	before := datadirtest.Tree(t, l.Old, false)
	custom := filepath.Join(m.root, "custom", "agenthub", "agenthub.db")

	node := m.start(t, "-db", custom)
	node.stop(t)
	requireExists(t, custom, true)
	requireExists(t, filepath.Join(filepath.Dir(custom), "node.key"), true)
	requireExists(t, l.New, false)
	datadirtest.RequireSameTree(t, "the old directory", before, datadirtest.Tree(t, l.Old, false))
}

// N3. A registered pre-rename service could start the old node on the old
// directory once the identity left it, and that node would make a new one.
func TestTheNodeExitsRatherThanBecomeANewNode(t *testing.T) {
	m := newMachine(t)
	l := m.layout
	datadirtest.WriteLegacy(t, l.Old, true)
	registration := m.legacyRegistration(t)
	writeFileAt(t, registration, "the pre-rename service")
	before := datadirtest.Tree(t, l.Old, false)

	output, err := m.runToExit(t)
	if err == nil {
		t.Fatalf("the node started with a pre-rename service registered:\n%s", output)
	}
	for _, want := range []string{"ah service install", registration, "pre-rename background service is still registered"} {
		if !strings.Contains(output, want) {
			t.Errorf("the refusal does not say %q:\n%s", want, output)
		}
	}
	requireExists(t, l.New, false)
	datadirtest.RequireSameTree(t, "the old directory", before, datadirtest.Tree(t, l.Old, false))

	// Once the registration is gone, the same start moves the identity.
	if err := os.Remove(registration); err != nil {
		t.Fatal(err)
	}
	m.start(t).stop(t)
	requireExists(t, filepath.Join(l.New, "node.key"), true)
}

// N4. A second node stops at the owner's address, before it has touched any
// data: the pre-rename node listens on the same default address, and this
// one must not move the files that node has open.
func TestASecondNodeStopsBeforeTouchingData(t *testing.T) {
	m := newMachine(t)
	l := m.layout
	datadirtest.WriteLegacy(t, l.Old, true)
	before := datadirtest.Tree(t, l.Old, false)
	occupied, err := net.Listen("tcp", m.listen)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = occupied.Close() }()

	output, exitErr := m.runToExit(t)
	if exitErr == nil {
		t.Fatalf("the node started on an address another process holds:\n%s", output)
	}
	if !strings.Contains(output, "the owner address "+m.listen+" is in use") {
		t.Errorf("the refusal does not name the address:\n%s", output)
	}
	requireExists(t, l.New, false)
	datadirtest.RequireSameTree(t, "the old directory", before, datadirtest.Tree(t, l.Old, false))
}

// P3 at the node: the old node still has its database open — here this test
// process stands in for it — so the new one exits and moves nothing.
func TestTheNodeExitsWhileThePreRenameDatabaseIsOpen(t *testing.T) {
	m := newMachine(t)
	l := m.layout
	legacy := datadirtest.WriteLegacy(t, l.Old, true)
	store, err := registry.Open(context.Background(), l.OldDB)
	if err != nil {
		t.Fatal(err)
	}
	key := readBytes(t, filepath.Join(l.Old, "node.key"))

	output, exitErr := m.runToExit(t)
	if exitErr == nil {
		t.Fatalf("the node moved a database another process has open:\n%s", output)
	}
	if !strings.Contains(output, "is open in another process") {
		t.Errorf("the refusal does not say why:\n%s", output)
	}
	requireExists(t, l.New, false)
	if !bytes.Equal(readBytes(t, filepath.Join(l.Old, "node.key")), key) {
		t.Error("node.key changed")
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	node := m.start(t)
	node.requireIdentity(t, legacy)
	node.stop(t)
}

// Two identities: the new directory's runs, the old one is left alone, and
// every start says so.
func TestTheNodeRunsOnTheNewDirectoryWhenBothHoldANode(t *testing.T) {
	m := newMachine(t)
	l := m.layout
	datadirtest.WriteLegacy(t, l.Old, false)
	current := datadirtest.WriteLegacy(t, l.New, false)
	if err := os.Rename(filepath.Join(l.New, "agenthub.db"), l.NewDB); err != nil {
		t.Fatal(err)
	}
	before := datadirtest.Tree(t, l.Old, false)

	node := m.start(t)
	node.requireIdentity(t, current)
	if !strings.Contains(node.output.String(), "a pre-rename identity is still in "+l.Old) {
		t.Errorf("the second identity went unmentioned:\n%s", node.output.String())
	}
	node.stop(t)
	datadirtest.RequireSameTree(t, "the old directory", before, datadirtest.Tree(t, l.Old, false))
}

// The crash §5.5 is about: the database has moved, the key has not. Without
// the marker the new directory would look like a node, and the start would
// make a new key beside the old database; with it, the start finishes the
// move and is the same node.
func TestTheNodeFinishesAMoveACrashInterrupted(t *testing.T) {
	m := newMachine(t)
	l := m.layout
	legacy := datadirtest.WriteLegacy(t, l.Old, false)
	if err := os.MkdirAll(l.New, 0o700); err != nil {
		t.Fatal(err)
	}
	writeFileAt(t, filepath.Join(l.New, ".migrating-from-agenthub"), l.Old+"\ndb\nkey\n")
	if err := os.Rename(l.OldDB, l.NewDB); err != nil {
		t.Fatal(err)
	}

	node := m.start(t)
	node.requireIdentity(t, legacy)
	node.stop(t)
	requireExists(t, filepath.Join(l.New, ".migrating-from-agenthub"), false)
	requireExists(t, l.Old, false)
}

// N5. The order run() does things in is the safety argument: the owner's
// address is held before the identity moves, and the identity moves before
// anything opens a database. That is text, not behaviour — the behaviour on
// each side is covered above — and it pins the seams between them.
func TestRunBindsAndMigratesBeforeItOpensTheDatabase(t *testing.T) {
	body := functionBody(t, "main.go", "func run() error {")
	order := []string{
		"net.Listen(", "datadir.DefaultLayout(", "datadir.Resolve(", "datadir.Migrate(",
		"registry.Open(ctx, db)", "identity.LoadOrCreate(", "identity.LoadOrCreateKeypair(filepath.Dir(db))",
		"server.Serve(ownerListener)",
	}
	at := -1
	for _, needle := range order {
		next := strings.Index(body, needle)
		if next < 0 {
			t.Errorf("run() has no %q", needle)
			continue
		}
		if next < at {
			t.Errorf("run() reaches %q earlier than what precedes it in %v", needle, order)
		}
		at = next
	}
	for _, unwanted := range []string{"ListenAndServe", "*dbPath)"} {
		if strings.Contains(body, unwanted) {
			t.Errorf("run() still contains %q", unwanted)
		}
	}
	if strings.Count(body, "registry.Open(") != 1 {
		t.Errorf("run() opens a database %d times", strings.Count(body, "registry.Open("))
	}
}

// -h shows the new default, so an owner reading it is told where the node
// keeps its data now.
func TestTheDefaultDatabaseIsTheNewOne(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(t.TempDir(), "config"))
	t.Setenv("APPDATA", t.TempDir())
	defaults, err := defaultPaths()
	if err != nil {
		t.Fatal(err)
	}
	config, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(config, "agenthallway", "agenthallway.db"); defaults.database != want {
		t.Errorf("default database %s, want %s", defaults.database, want)
	}
}
