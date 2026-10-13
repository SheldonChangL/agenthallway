package product

import "testing"

func TestGetenvPrefersTheNewName(t *testing.T) {
	t.Setenv("AGENTHALLWAY_URL", "http://new")
	t.Setenv("AGENTHUB_URL", "http://old")
	if got := Getenv("URL"); got != "http://new" {
		t.Errorf("Getenv(URL) = %q, want the value of AGENTHALLWAY_URL", got)
	}
}

func TestGetenvFallsBackToTheOldName(t *testing.T) {
	t.Setenv("AGENTHALLWAY_URL", "")
	t.Setenv("AGENTHUB_URL", "http://old")
	if got := Getenv("URL"); got != "http://old" {
		t.Errorf("Getenv(URL) = %q, want the value of AGENTHUB_URL", got)
	}
}

func TestGetenvTreatsEmptyAsUnset(t *testing.T) {
	t.Setenv("AGENTHALLWAY_URL", "")
	t.Setenv("AGENTHUB_URL", "")
	if got := Getenv("URL"); got != "" {
		t.Errorf("Getenv(URL) = %q with both unset, want empty", got)
	}
}

func TestTheConstantsSpellTheNamesTheyAreFor(t *testing.T) {
	if EnvPrefix+"URL" != "AGENTHALLWAY_URL" || LegacyEnvPrefix+"URL" != "AGENTHUB_URL" {
		t.Errorf("environment prefixes %q and %q", EnvPrefix, LegacyEnvPrefix)
	}
	if NodeBinary != Slug+"-node" || MCPBinary != Slug+"-mcp" || DesktopBinary != Slug+"-desktop" {
		t.Errorf("binary names %q %q %q do not follow the slug %q", NodeBinary, MCPBinary, DesktopBinary, Slug)
	}
	if LegacyNodeBinary != LegacySlug+"-node" || LegacyMCPBinary != LegacySlug+"-mcp" {
		t.Errorf("legacy binary names %q %q do not follow the slug %q", LegacyNodeBinary, LegacyMCPBinary, LegacySlug)
	}
}
