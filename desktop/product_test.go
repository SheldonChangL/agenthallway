package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// product.go is a copy of internal/product/product.go, and a copy has to be
// checked: this module cannot import the root one, so the test reads its source.
// A constant added or changed on one side only fails here.
func TestDesktopProductNamesMatchTheRoot(t *testing.T) {
	content, err := os.ReadFile(filepath.Join("..", "internal", "product", "product.go"))
	if err != nil {
		t.Fatalf("read the root module's product names: %v", err)
	}
	root := map[string]string{}
	for _, match := range regexp.MustCompile(`(?m)^\s*([A-Z]\w*)\s*=\s*"([^"]*)"`).FindAllStringSubmatch(string(content), -1) {
		root[match[1]] = match[2]
	}
	mine := map[string]string{
		"Name":             productName,
		"Slug":             productSlug,
		"NodeBinary":       productNodeBinary,
		"MCPBinary":        productMCPBinary,
		"DesktopBinary":    productDesktopBinary,
		"LegacySlug":       productLegacySlug,
		"LegacyNodeBinary": productLegacyNodeBinary,
		"LegacyMCPBinary":  productLegacyMCPBinary,
		"EnvPrefix":        productEnvPrefix,
		"LegacyEnvPrefix":  productLegacyEnvPrefix,
	}
	if len(root) == 0 {
		t.Fatal("no constants were read from internal/product/product.go; this check would pass on an empty list")
	}
	for name, value := range root {
		have, ok := mine[name]
		switch {
		case !ok:
			t.Errorf("internal/product has %s = %q and desktop/product.go does not", name, value)
		case have != value:
			t.Errorf("%s is %q in internal/product and %q in desktop/product.go", name, value, have)
		}
	}
	for name := range mine {
		if _, ok := root[name]; !ok {
			t.Errorf("desktop/product.go has %s, which internal/product does not", name)
		}
	}
}

func TestGetenvCompatPrefersTheNewName(t *testing.T) {
	t.Setenv("AGENTHALLWAY_URL", "http://new")
	t.Setenv("AGENTHUB_URL", "http://old")
	if got := getenvCompat("URL"); got != "http://new" {
		t.Errorf("getenvCompat(URL) = %q, want the value of AGENTHALLWAY_URL", got)
	}
}

func TestGetenvCompatFallsBackToTheOldName(t *testing.T) {
	t.Setenv("AGENTHALLWAY_URL", "")
	t.Setenv("AGENTHUB_URL", "http://old")
	if got := getenvCompat("URL"); got != "http://old" {
		t.Errorf("getenvCompat(URL) = %q, want the value of AGENTHUB_URL", got)
	}
	t.Setenv("AGENTHUB_URL", "")
	if got := getenvCompat("URL"); got != "" {
		t.Errorf("getenvCompat(URL) = %q with both unset, want empty", got)
	}
}

func TestNewAppReadsTheNodeURLFromTheNewVariableFirst(t *testing.T) {
	t.Setenv("AGENTHALLWAY_URL", "")
	t.Setenv("AGENTHUB_URL", "http://127.0.0.1:9001")
	if _, got := NewApp().current(); got != "http://127.0.0.1:9001" {
		t.Errorf("with only AGENTHUB_URL set the app points at %q", got)
	}
	t.Setenv("AGENTHALLWAY_URL", "http://127.0.0.1:9002")
	if _, got := NewApp().current(); got != "http://127.0.0.1:9002" {
		t.Errorf("with both set the app points at %q, want AGENTHALLWAY_URL's", got)
	}
}

func TestLocateBinaryPrefersTheNewVariable(t *testing.T) {
	dir := t.TempDir()
	current := filepath.Join(t.TempDir(), "current-ah")
	legacy := filepath.Join(t.TempDir(), "legacy-ah")
	executable(t, current)
	executable(t, legacy)
	t.Setenv("AGENTHALLWAY_AH", current)
	t.Setenv("AGENTHUB_AH", legacy)

	found, err := locateBinaryNear(dir, "ah", "AH")
	if err != nil {
		t.Fatal(err)
	}
	if found != current {
		t.Errorf("found %q with both variables set, want AGENTHALLWAY_AH's %q", found, current)
	}
}

func TestLocateBinaryFallsBackToTheOldVariable(t *testing.T) {
	dir := t.TempDir()
	legacy := filepath.Join(t.TempDir(), "legacy-ah")
	executable(t, legacy)
	t.Setenv("AGENTHALLWAY_AH", "")
	t.Setenv("AGENTHUB_AH", legacy)

	found, err := locateBinaryNear(dir, "ah", "AH")
	if err != nil {
		t.Fatal(err)
	}
	if found != legacy {
		t.Errorf("found %q through the older variable, want %q", found, legacy)
	}
}

// The error names the variable the owner should set now, and the one they gave
// when it did not point at anything runnable.
func TestLocateBinaryErrorNamesTheNewVariable(t *testing.T) {
	t.Setenv("AGENTHALLWAY_NODE", "")
	t.Setenv("AGENTHUB_NODE", filepath.Join(t.TempDir(), "not-here"))

	_, err := locateBinaryNear(t.TempDir(), productNodeBinary, "NODE")
	if err == nil {
		t.Fatal("a missing node was found")
	}
	if !strings.Contains(err.Error(), "set AGENTHALLWAY_NODE to its path") {
		t.Errorf("the error does not tell the owner to set AGENTHALLWAY_NODE: %v", err)
	}
	if !strings.Contains(err.Error(), "$AGENTHUB_NODE=") {
		t.Errorf("the error does not say which variable the rejected path came from: %v", err)
	}
}

// The older variable still finds the MCP binary the snippet names.
func TestMCPConfigFindsTheBinaryThroughTheOldVariable(t *testing.T) {
	binary := fakeMCPBinary(t)
	t.Setenv("AGENTHALLWAY_MCP", "")
	t.Setenv("AGENTHUB_MCP", binary)
	watchClipboard(t, nil)

	app := &App{client: newClient(defaultNodeURL), url: defaultNodeURL}
	result, err := app.MCPConfig("claude:x")
	if err != nil {
		t.Fatal(err)
	}
	if result.Command != binary {
		t.Errorf("command = %q, want %q", result.Command, binary)
	}
}
