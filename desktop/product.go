package main

import "os"

// The names this product goes by, copied from internal/product/product.go.
//
// This module cannot import the root module (it is what keeps Wails' CGo
// requirement away from a cross-compiled agenthallway-node), so the constants
// are spelled here a second time and product_test.go reads the original and
// fails when the two drift.
const (
	productName          = "Agent Hallway"
	productSlug          = "agenthallway"
	productNodeBinary    = "agenthallway-node"
	productMCPBinary     = "agenthallway-mcp"
	productDesktopBinary = "agenthallway-desktop"

	// What the product was called through v0.1.x.
	productLegacySlug       = "agenthub"
	productLegacyNodeBinary = "agenthub-node"
	productLegacyMCPBinary  = "agenthub-mcp"

	productEnvPrefix       = "AGENTHALLWAY_"
	productLegacyEnvPrefix = "AGENTHUB_"
)

// lookupEnvCompat returns AGENTHALLWAY_<name>, or AGENTHUB_<name> when the
// first is unset or empty, together with the name of the variable the value
// came from. An empty variable counts as unset. Both results are empty when
// neither is set.
func lookupEnvCompat(name string) (value, variable string) {
	if value := os.Getenv(productEnvPrefix + name); value != "" {
		return value, productEnvPrefix + name
	}
	if value := os.Getenv(productLegacyEnvPrefix + name); value != "" {
		return value, productLegacyEnvPrefix + name
	}
	return "", ""
}

// getenvCompat is internal/product.Getenv.
func getenvCompat(name string) string {
	value, _ := lookupEnvCompat(name)
	return value
}
