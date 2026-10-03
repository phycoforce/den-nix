package policy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// realConfigArtifactRegex and realKmodClosureRegex are plan-gate.sh's exact
// CONFIG_ARTIFACT_RE / KMOD_CLOSURE_RE, transcribed for tests that need a
// realistic Compiled policy.
const (
	realConfigArtifactRegex = `^(unit-.+[.](service|timer|socket|target|mount|automount|slice|path|scope)|initrd-|system-path$|home-manager-path$|home-manager-files$|home-manager-generation$|nixos-system-|etc$|etc-|graphics-drivers$|system-generators$|user-generators$|X-Restart-Triggers|options[.]json$|home-configuration-reference-manpage$|.+[.]conf$|sddm-wrapped$|security-wrapper($|-)|pam[.]d$|hm-modules-messages$|jack-libs$)`
	realKmodClosureRegex    = `^linux-.+-modules(-shrunk)?$`
)

var realBlock = []BlockEntry{
	{Prefix: "linux-cachyos", Hint: "attic.xuyh0120.win/lantian"},
	{Prefix: "nvidia-x11", Hint: "attic.xuyh0120.win/lantian or phycoforce.cachix.org"},
	{Prefix: "mesa", Hint: "cache.nixos.org"},
	{Prefix: "niri", Hint: "cache.nixos.org"},
}

func mustCompile(t *testing.T) Compiled {
	t.Helper()
	p := Policy{
		Toplevel: ".#x", Substituters: []string{"https://cache.nixos.org"},
		ConfigArtifactRegex: realConfigArtifactRegex, KmodClosureRegex: realKmodClosureRegex, Block: realBlock,
	}.defaulted()
	c, err := p.Compile()
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	return c
}

func TestPnameOf(t *testing.T) {
	cases := map[string]string{
		"h1-firefox-unwrapped-130.0.1":       "firefox-unwrapped",
		"h1-niri-25.08":                      "niri",
		"h1-mesa":                            "mesa",
		"h1-unit-home-manager-aaron.service": "unit-home-manager-aaron.service",
	}
	for in, want := range cases {
		if got := PnameOf(in); got != want {
			t.Errorf("PnameOf(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPnameOf_KmodCollapseOntoKernelPname(t *testing.T) {
	// The d2bae36 defect: a kmod closure's full name collapses, under the
	// version strip, onto the kernel's OWN pname - exactly why
	// KmodClosureRE must run on the FULL name before PnameOf ever does.
	c := mustCompile(t)
	full := "h1-linux-cachyos-6.1.2-modules-shrunk"
	got := PnameOf(full)
	if got != "linux-cachyos" {
		t.Fatalf("PnameOf(%q) = %q, want %q (the collapse the carve-out guards against)", full, got, "linux-cachyos")
	}
	if hint := MatchBlock(c.Block, got); hint == "" {
		t.Fatalf("expected the collapsed pname %q to hit BLOCK (that's the bug being guarded against)", got)
	}
	if !c.KmodClosureRE.MatchString(full[len("h1-"):]) {
		t.Fatalf("KmodClosureRE must match the full kmod-closure name so the carve-out fires before the collapse")
	}
}

func TestKmodClosureRE_DoesNotMatchKernelItself(t *testing.T) {
	c := mustCompile(t)
	if c.KmodClosureRE.MatchString("linux-cachyos-6.1.2") {
		t.Fatalf("KmodClosureRE must not match the kernel derivation itself, only its modules closure")
	}
}

func TestMatchBlock(t *testing.T) {
	c := mustCompile(t)
	if hint := MatchBlock(c.Block, "niri"); hint == "" {
		t.Fatalf("expected niri to hit BLOCK")
	}
	if hint := MatchBlock(c.Block, "niri-unstable"); hint == "" {
		t.Fatalf("expected a niri-prefixed pname to still hit BLOCK (prefix match, not exact)")
	}
	if hint := MatchBlock(c.Block, "totally-unrelated-package"); hint != "" {
		t.Fatalf("expected no BLOCK match, got %q", hint)
	}
	// nvidia-x11 is deliberately NOT a bare "nvidia" prefix.
	if hint := MatchBlock(c.Block, "nvidia-persistenced"); hint != "" {
		t.Fatalf("nvidia-persistenced must NOT hit BLOCK: got %q", hint)
	}
	if hint := MatchBlock(c.Block, "nvidia-x11"); hint == "" {
		t.Fatalf("expected nvidia-x11 to hit BLOCK")
	}
}

func TestConfigArtifactRE(t *testing.T) {
	c := mustCompile(t)
	matches := []string{
		"etc", "options.json", "home-configuration-reference-manpage",
		"home-manager-path", "unit-home-manager-aaron.service", "nixos-system-temperantia-26.11",
	}
	for _, m := range matches {
		if !c.ConfigArtifactRE.MatchString(m) {
			t.Errorf("ConfigArtifactRE did not match %q, want match", m)
		}
	}
	nonMatches := []string{"firefox-unwrapped", "niri", "linux-cachyos"}
	for _, m := range nonMatches {
		if c.ConfigArtifactRE.MatchString(m) {
			t.Errorf("ConfigArtifactRE matched %q, want no match (a real package must never match)", m)
		}
	}
}

func TestLoad_MissingFile(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "nope.json")); err == nil {
		t.Fatalf("expected an error for a missing policy file")
	}
}

func TestLoad_InvalidJSON(t *testing.T) {
	p := filepath.Join(t.TempDir(), "policy.json")
	os.WriteFile(p, []byte("{not json"), 0o644)
	if _, err := Load(p); err == nil {
		t.Fatalf("expected an error for invalid JSON")
	}
}

func TestLoad_MissingRequiredField(t *testing.T) {
	p := filepath.Join(t.TempDir(), "policy.json")
	data, _ := json.Marshal(map[string]any{"substituters": []string{"https://cache.nixos.org"}})
	os.WriteFile(p, data, 0o644)
	if _, err := Load(p); err == nil {
		t.Fatalf("expected an error for a policy missing \"toplevel\"/regexes")
	}
}

func TestLoad_AppliesDefaults(t *testing.T) {
	p := filepath.Join(t.TempDir(), "policy.json")
	data, _ := json.Marshal(Policy{
		Toplevel: ".#x", Substituters: []string{"https://cache.nixos.org"},
		ConfigArtifactRegex: realConfigArtifactRegex, KmodClosureRegex: realKmodClosureRegex,
	})
	os.WriteFile(p, data, 0o644)
	c, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.MaxBuilds != 2000 || c.MaxI686 != 25 {
		t.Fatalf("defaults not applied: MaxBuilds=%d MaxI686=%d", c.MaxBuilds, c.MaxI686)
	}
	if c.Hydra.URL != "https://hydra.nixos.org" || c.Hydra.Jobset != "nixos/unstable" || c.Hydra.MaxLookups != 10 {
		t.Fatalf("hydra defaults not applied: %+v", c.Hydra)
	}
	if c.Baseline != "scripts/plan-gate-baseline.txt" {
		t.Fatalf("baseline default not applied: %q", c.Baseline)
	}
}

func TestResolvePath(t *testing.T) {
	env := map[string]string{}
	getenv := func(k string) string { return env[k] }
	if _, err := ResolvePath("", getenv); err == nil {
		t.Fatalf("expected an error when neither --policy nor $FLAKE_GATE_POLICY is set")
	}
	if got, err := ResolvePath("/explicit.json", getenv); err != nil || got != "/explicit.json" {
		t.Fatalf("got %q, %v, want /explicit.json flag to win", got, err)
	}
	env["FLAKE_GATE_POLICY"] = "/from-env.json"
	if got, err := ResolvePath("", getenv); err != nil || got != "/from-env.json" {
		t.Fatalf("got %q, %v, want env fallback", got, err)
	}
}

func TestApplyEnv_OverridesAndRejectsBadInt(t *testing.T) {
	c := mustCompile(t)
	env := map[string]string{"PLAN_GATE_MAX_BUILDS": "5", "TOPLEVEL": ".#overridden"}
	getenv := func(k string) string { return env[k] }
	got, err := ApplyEnv(c, getenv)
	if err != nil {
		t.Fatalf("ApplyEnv: %v", err)
	}
	if got.MaxBuilds != 5 || got.Toplevel != ".#overridden" {
		t.Fatalf("got %+v", got)
	}
	env["PLAN_GATE_MAX_I686"] = "not-a-number"
	if _, err := ApplyEnv(c, getenv); err == nil {
		t.Fatalf("expected an error for an unparsable PLAN_GATE_MAX_I686")
	}
}

func TestLoadBaselineFixture_NeverMatchesBlock(t *testing.T) {
	c := mustCompile(t)
	data, err := os.ReadFile("../../testdata/real-baseline.txt")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	for _, line := range splitLines(string(data)) {
		if line == "" || line[0] == '#' {
			continue
		}
		if hint := MatchBlock(c.Block, line); hint != "" {
			t.Errorf("baseline contains %q, which matches a BLOCK pattern (%s) - the writer must never persist a BLOCK-matching pname", line, hint)
		}
	}
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return out
}

func TestSortedPnames_DedupesAndSorts(t *testing.T) {
	got := SortedPnames([]string{"b", "a", "b", "c", "a"})
	want := []string{"a", "b", "c"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}
