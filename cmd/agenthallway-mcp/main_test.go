package main

import "testing"

// The stdio server reads the node's address from AGENTHALLWAY_URL, and from the
// older AGENTHUB_URL for a configuration written before the rename.
func TestTheNodeURLComesFromTheNewVariableFirst(t *testing.T) {
	cases := []struct {
		name, current, legacy, want string
	}{
		{"neither", "", "", "http://127.0.0.1:7462"},
		{"only the older name", "", "http://127.0.0.1:9001", "http://127.0.0.1:9001"},
		{"only the new name", "http://127.0.0.1:9002", "", "http://127.0.0.1:9002"},
		{"both", "http://127.0.0.1:9002", "http://127.0.0.1:9001", "http://127.0.0.1:9002"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("AGENTHALLWAY_URL", tc.current)
			t.Setenv("AGENTHUB_URL", tc.legacy)
			if got := defaultNodeURL(); got != tc.want {
				t.Errorf("defaultNodeURL() = %q, want %q", got, tc.want)
			}
		})
	}
}
