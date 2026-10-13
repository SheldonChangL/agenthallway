// Package product holds the names this product goes by.
//
// The product was called AgentHub before it was called Agent Hallway, and a
// machine that was set up under the old name keeps reading what it set up. The
// Legacy* constants are the old names, kept in one place so that what still
// recognises them can be found and removed together.
//
// desktop/product.go carries the same constants, because the desktop app is its
// own Go module and cannot import this one. A test there reads this file and
// fails when the two drift.
package product

import "os"

const (
	// Name is what a person reads; Slug is what a file name, a service name or
	// a directory carries.
	Name = "Agent Hallway"
	Slug = "agenthallway"

	NodeBinary    = "agenthallway-node"
	MCPBinary     = "agenthallway-mcp"
	DesktopBinary = "agenthallway-desktop"

	// What the product was called through v0.1.x.
	LegacySlug       = "agenthub"
	LegacyNodeBinary = "agenthub-node"
	LegacyMCPBinary  = "agenthub-mcp"

	// EnvPrefix starts the name of every environment variable this product
	// reads or sets for its own use.
	EnvPrefix       = "AGENTHALLWAY_"
	LegacyEnvPrefix = "AGENTHUB_"
)

// Getenv returns the value of AGENTHALLWAY_<name>, or of AGENTHUB_<name> when
// the first is unset or empty. An empty variable counts as unset, as it does
// for every other setting here, so that `AGENTHALLWAY_URL=` in a shell
// profile does not silently shadow a value the older name still carries.
//
// Nothing is printed when only the older name is set: the standard error of
// `ah --json` and of the stdio MCP server has to stay quiet.
func Getenv(name string) string {
	if value := os.Getenv(EnvPrefix + name); value != "" {
		return value
	}
	return os.Getenv(LegacyEnvPrefix + name)
}
