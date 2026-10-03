// Package policy holds the repo-specific rules plan-gate.sh hardcoded
// (BLOCK list, config-artifact/kmod carve-outs, caps) as data loaded from a
// JSON file the Nix side renders - this package never hardcodes a repo
// fact itself.
package policy

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// HydraConfig is the Hydra API endpoint and lookup-budget policy.
type HydraConfig struct {
	URL        string `json:"url"`
	Jobset     string `json:"jobset"`
	MaxLookups int    `json:"maxLookups"`
}

// BlockEntry is one never-tolerated pname prefix, with a hint naming the
// substituter expected to own it. Order matters: first-prefix-match wins.
type BlockEntry struct {
	Prefix string `json:"prefix"`
	Hint   string `json:"hint"`
}

// Policy is the JSON schema the Nix side renders (modules/flake-gate.nix).
type Policy struct {
	Toplevel            string       `json:"toplevel"`
	Baseline            string       `json:"baseline"`
	Substituters        []string     `json:"substituters"`
	OwnCache            string       `json:"ownCache"`
	MaxBuilds           int          `json:"maxBuilds"`
	MaxI686             int          `json:"maxI686"`
	Hydra               HydraConfig  `json:"hydra"`
	ConfigArtifactRegex string       `json:"configArtifactRegex"`
	KmodClosureRegex    string       `json:"kmodClosureRegex"`
	Block               []BlockEntry `json:"block"`
}

// Compiled is a Policy with its regexes pre-compiled once at load time.
type Compiled struct {
	Policy
	ConfigArtifactRE *regexp.Regexp
	KmodClosureRE    *regexp.Regexp
}

// Defaults mirror plan-gate.sh's `${VAR:-default}` fallbacks, applied to
// any field the JSON left at its zero value.
func (p Policy) defaulted() Policy {
	if p.MaxBuilds == 0 {
		p.MaxBuilds = 2000
	}
	if p.MaxI686 == 0 {
		p.MaxI686 = 25
	}
	if p.Hydra.URL == "" {
		p.Hydra.URL = "https://hydra.nixos.org"
	}
	if p.Hydra.Jobset == "" {
		p.Hydra.Jobset = "nixos/unstable"
	}
	if p.Hydra.MaxLookups == 0 {
		p.Hydra.MaxLookups = 10
	}
	if p.Baseline == "" {
		p.Baseline = "scripts/plan-gate-baseline.txt"
	}
	return p
}

// ResolvePath picks the policy file: --policy flag, else
// $FLAKE_GATE_POLICY (set by the Nix wrapper's makeWrapper --set-default).
func ResolvePath(flagVal string, getenv func(string) string) (string, error) {
	if flagVal != "" {
		return flagVal, nil
	}
	if v := getenv("FLAKE_GATE_POLICY"); v != "" {
		return v, nil
	}
	return "", fmt.Errorf("no policy file given: pass --policy FILE or set FLAKE_GATE_POLICY")
}

// Load reads and validates a policy JSON file, applying defaults for
// omitted fields.
func Load(path string) (Compiled, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Compiled{}, fmt.Errorf("reading policy %s: %w", path, err)
	}
	var p Policy
	if err := json.Unmarshal(data, &p); err != nil {
		return Compiled{}, fmt.Errorf("parsing policy %s: %w", path, err)
	}
	p = p.defaulted()
	return p.Compile()
}

// Compile validates p and pre-compiles its regexes. Exported so tests
// outside this package can build a Compiled from a literal Policy without
// a file on disk.
func (p Policy) Compile() (Compiled, error) {
	if p.Toplevel == "" {
		return Compiled{}, fmt.Errorf("policy: \"toplevel\" is required")
	}
	if len(p.Substituters) == 0 {
		return Compiled{}, fmt.Errorf("policy: \"substituters\" must be non-empty")
	}
	if p.ConfigArtifactRegex == "" || p.KmodClosureRegex == "" {
		return Compiled{}, fmt.Errorf("policy: \"configArtifactRegex\" and \"kmodClosureRegex\" are required")
	}
	car, err := regexp.Compile(p.ConfigArtifactRegex)
	if err != nil {
		return Compiled{}, fmt.Errorf("policy: configArtifactRegex: %w", err)
	}
	kmod, err := regexp.Compile(p.KmodClosureRegex)
	if err != nil {
		return Compiled{}, fmt.Errorf("policy: kmodClosureRegex: %w", err)
	}
	for i, b := range p.Block {
		if b.Prefix == "" {
			return Compiled{}, fmt.Errorf("policy: block[%d] has an empty prefix", i)
		}
	}
	return Compiled{Policy: p, ConfigArtifactRE: car, KmodClosureRE: kmod}, nil
}

// EnvOverrides is every env knob plan-gate.sh read, mapped to the Policy
// field it overrides - kept as names (not consulted here) so main can list
// exactly which vars it read.
var EnvOverrideNames = []string{
	"TOPLEVEL", "PLAN_GATE_BASELINE", "PLAN_GATE_MAX_BUILDS", "PLAN_GATE_MAX_I686",
	"PLAN_GATE_HYDRA", "PLAN_GATE_HYDRA_JOBSET", "PLAN_GATE_MAX_HYDRA_LOOKUPS",
}

// ApplyEnv overrides policy values from env, keeping plan-gate.sh's var
// names. A present-but-unparsable integer var is a hard error (exit 1 via
// the caller), never a silently ignored override.
func ApplyEnv(c Compiled, getenv func(string) string) (Compiled, error) {
	if v := getenv("TOPLEVEL"); v != "" {
		c.Toplevel = v
	}
	if v := getenv("PLAN_GATE_BASELINE"); v != "" {
		c.Baseline = v
	}
	if v := getenv("PLAN_GATE_MAX_BUILDS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return c, fmt.Errorf("PLAN_GATE_MAX_BUILDS: %w", err)
		}
		c.MaxBuilds = n
	}
	if v := getenv("PLAN_GATE_MAX_I686"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return c, fmt.Errorf("PLAN_GATE_MAX_I686: %w", err)
		}
		c.MaxI686 = n
	}
	if v := getenv("PLAN_GATE_HYDRA"); v != "" {
		c.Hydra.URL = v
	}
	if v := getenv("PLAN_GATE_HYDRA_JOBSET"); v != "" {
		c.Hydra.Jobset = v
	}
	if v := getenv("PLAN_GATE_MAX_HYDRA_LOOKUPS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return c, fmt.Errorf("PLAN_GATE_MAX_HYDRA_LOOKUPS: %w", err)
		}
		c.Hydra.MaxLookups = n
	}
	return c, nil
}

var pnameVersionStrip = regexp.MustCompile(`-[0-9].*$`)

// PnameOf infers package identity by stripping a trailing version off a
// derivation's store name: basename, drop the leading hash, drop
// "-<digit>...$" - exactly plan-gate.sh's pname_of(). The caller must run
// KmodClosureRE against the FULL name first (see gate.Run): the version
// strip alone collapses a kmod closure onto the kernel's own pname.
func PnameOf(drvBasenameNoExt string) string {
	rest := drvBasenameNoExt
	if idx := strings.IndexByte(drvBasenameNoExt, '-'); idx >= 0 {
		rest = drvBasenameNoExt[idx+1:]
	}
	return pnameVersionStrip.ReplaceAllString(rest, "")
}

// MatchBlock returns the hint for the first BLOCK prefix pname matches, or
// "" if none match.
func MatchBlock(block []BlockEntry, pname string) string {
	for _, b := range block {
		if strings.HasPrefix(pname, b.Prefix) {
			return b.Hint
		}
	}
	return ""
}

// SortedPnames dedupes and sorts, matching bash's trailing `sort -u` on
// every printed pname list.
func SortedPnames(names []string) []string {
	set := map[string]struct{}{}
	for _, n := range names {
		set[n] = struct{}{}
	}
	out := make([]string, 0, len(set))
	for n := range set {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}
