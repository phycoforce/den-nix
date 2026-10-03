// Command flake-gate is the shadow Go port of scripts/plan-gate.sh.
// Subcommand style: "flake-gate gate ...".
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"time"

	"github.com/phycoforce/den-nix/tools/flake-gate/internal/baseline"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/gate"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/hydra"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/lockfile"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/nixexec"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/nixplan"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/policy"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/probe"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "flake-gate: expected a subcommand (gate)")
		return 1
	}
	switch args[0] {
	case "gate":
		return runGate(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "flake-gate: unknown subcommand %q (want: gate)\n", args[0])
		return 1
	}
}

// gateArgs is runGate's parsed flags, split out so parseGateArgs (the
// "--" passthrough logic in particular) is unit-testable without a nix
// daemon.
type gateArgs struct {
	Cold          bool
	WriteBaseline bool
	PolicyPath    string
	Repo          string
	JSONPath      string
	Extra         []string // "--" passthrough, e.g. just check-tip's --override-input
}

func parseGateArgs(args []string, errOut io.Writer) (gateArgs, error) {
	fset := flag.NewFlagSet("gate", flag.ContinueOnError)
	fset.SetOutput(errOut)
	var a gateArgs
	fset.BoolVar(&a.Cold, "cold", false, "plan against a throwaway store, like a fresh CI runner")
	fset.BoolVar(&a.WriteBaseline, "write-baseline", false, "re-measure the expected-local baseline")
	fset.StringVar(&a.PolicyPath, "policy", "", "policy JSON path (default: $FLAKE_GATE_POLICY)")
	fset.StringVar(&a.Repo, "repo", ".", "repository root (flake ref, baseline path, flake.lock are relative to this)")
	fset.StringVar(&a.JSONPath, "json", "", "write a machine-readable result to this file")
	if err := fset.Parse(args); err != nil {
		return gateArgs{}, err
	}
	a.Extra = fset.Args()
	return a, nil
}

func runGate(args []string) int {
	a, err := parseGateArgs(args, os.Stderr)
	if err != nil {
		return 1
	}

	pol, err := loadPolicy(a.PolicyPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "flake-gate:", err)
		if a.JSONPath != "" {
			_ = writeJSONResult(a.JSONPath, 1, gate.Result{Verdict: gate.Violation, Reason: err.Error()})
		}
		return 1
	}

	// No whole-run deadline: an expired one would mark every unprobed candidate
	// unserved. Every HTTP call carries its own timeout, as in plan-gate.sh.
	code, result := executeGate(context.Background(), executeOptions{
		Repo: a.Repo, Cold: a.Cold, WriteBaseline: a.WriteBaseline, Policy: pol, ExtraArgs: a.Extra,
	})

	if a.JSONPath != "" {
		if err := writeJSONResult(a.JSONPath, code, result); err != nil {
			fmt.Fprintln(os.Stderr, "flake-gate: writing --json output:", err)
		}
	}
	return code
}

func loadPolicy(flagPath string) (policy.Compiled, error) {
	path, err := policy.ResolvePath(flagPath, os.Getenv)
	if err != nil {
		return policy.Compiled{}, err
	}
	pol, err := policy.Load(path)
	if err != nil {
		return policy.Compiled{}, err
	}
	return policy.ApplyEnv(pol, os.Getenv)
}

type executeOptions struct {
	Repo          string
	Cold          bool
	WriteBaseline bool
	Policy        policy.Compiled
	ExtraArgs     []string
}

// executeGate wires nix/HTTP I/O around gate.Run and prints plan-gate.sh's
// stdout/stderr shape. It always returns a Result (even a synthesized
// cannot-judge one for an infrastructure failure), since --json is written
// from whatever this returns.
func executeGate(ctx context.Context, opts executeOptions) (int, gate.Result) {
	// --cold: a throwaway, read-only-after-build store under a temp
	// workdir. Cleanup must never change the exit code (plan-gate.sh's
	// EXIT-trap lesson: a failing trap replaces the real exit status) - so
	// it runs in a defer, after the return value below is already fixed,
	// and never panics past this function.
	store := os.Getenv("PLAN_GATE_STORE")
	if opts.Cold {
		workdir, err := os.MkdirTemp("", "flake-gate.*")
		if err != nil {
			return 2, gate.Result{Verdict: gate.CannotJudge, Reason: "failed to create a throwaway store workdir: " + err.Error()}
		}
		defer cleanupCold(workdir)
		if store == "" {
			store = filepath.Join(workdir, "store")
		}
	}

	substituters := opts.Policy.Substituters
	var subOverride []string
	if opts.WriteBaseline {
		// Own cache excluded: it only proves what a past run pushed, not
		// what a candidate lock will need.
		for _, s := range substituters {
			if s != opts.Policy.OwnCache {
				subOverride = append(subOverride, s)
			}
		}
		substituters = subOverride
	}

	stderrText, rc, err := nixexec.DryRunPlan(ctx, nixexec.DryRunOptions{
		Dir: opts.Repo, Toplevel: opts.Policy.Toplevel, Store: store,
		SubstitutersOverride: subOverride, ExtraArgs: opts.ExtraArgs,
	})
	if err != nil {
		res := gate.Result{Verdict: gate.CannotJudge, Reason: "failed to run nix build --dry-run: " + err.Error()}
		fmt.Fprintln(os.Stderr, "flake-gate:", res.Reason)
		return 2, res
	}

	plan := nixplan.Parse(stderrText)

	baselinePath := opts.Policy.Baseline
	if !filepath.IsAbs(baselinePath) {
		baselinePath = filepath.Join(opts.Repo, baselinePath)
	}
	baselineText := ""
	if b, err := os.ReadFile(baselinePath); err == nil {
		baselineText = string(b)
	}

	lockPath := filepath.Join(opts.Repo, "flake.lock")
	var agePtr *int
	if age, ok := lockfile.RootNixpkgsAgeDays(lockPath); ok {
		agePtr = &age
	}

	pol := opts.Policy
	pol.Substituters = substituters // probes and health honor the own-cache exclusion too
	in := gate.Input{
		PlanText: stderrText, NixRC: rc,
		LoadDerivations: func(drvs []string) ([][]byte, error) {
			return nixexec.DerivationShow(ctx, opts.Repo, store, drvs, 300)
		},
		Baseline: baseline.Load(baselineText), Policy: pol,
		NixpkgsAgeDays: agePtr, WriteBaseline: opts.WriteBaseline,
	}
	result := gate.Run(ctx, &probe.Client{}, &hydra.Client{
		BaseURL: opts.Policy.Hydra.URL, Jobset: opts.Policy.Hydra.Jobset, MaxLookups: opts.Policy.Hydra.MaxLookups,
	}, in)

	for _, l := range result.Stderr {
		fmt.Fprintln(os.Stderr, l)
	}

	// --write-baseline's "written"/"newly tolerated" lines print BEFORE the
	// normal summary - Result.Summary is only set once gate.Run reaches
	// that final point (never on an early cannot-judge/violation return),
	// so that's exactly the signal for "there is something to write".
	// An empty plan measured nothing; plan-gate.sh exits before its writer.
	if opts.WriteBaseline && result.Summary != "" && plan.HeaderCount > 0 {
		rev, _ := lockfile.RootNixpkgsRev12(lockPath)
		if err := writeBaselineFile(baselinePath, baselineText, result.MeasuredUnserved, opts.Policy.Block, rev); err != nil {
			fmt.Fprintln(os.Stderr, "flake-gate: writing baseline:", err)
		}
	}
	if result.Summary != "" {
		fmt.Println(result.Summary)
	}
	return int(result.Verdict), result
}

// cleanupCold mirrors plan-gate.sh's EXIT trap: chmod -R u+w (a --cold
// store is read-only after use) then remove the workdir, swallowing every
// error - it must never panic or otherwise affect the exit code already
// returned by executeGate.
func cleanupCold(workdir string) {
	defer func() { _ = recover() }()
	_ = filepath.WalkDir(workdir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil //nolint:nilerr // best-effort cleanup, never propagates
		}
		info, err := d.Info()
		if err == nil {
			_ = os.Chmod(p, info.Mode()|0o200)
		}
		return nil
	})
	_ = os.RemoveAll(workdir)
}

// writeBaselineFile merges and writes the baseline file, then prints the
// "written"/"newly tolerated" lines (plain stdout, not stderr, mirroring
// plan-gate.sh's `echo`).
func writeBaselineFile(path, existingText string, measured []string, block []policy.BlockEntry, rev string) error {
	isBlocked := func(p string) bool { return policy.MatchBlock(block, p) != "" }
	kept, added := baseline.Merge(existingText, measured, isBlocked)
	text := baseline.Render(baseline.Header(time.Now().UTC().Format("2006-01-02"), rev), kept)
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		return err
	}
	fmt.Printf(">> plan-gate: baseline written to %s (%d pnames, merged).\n", path, len(kept))
	if len(added) > 0 {
		fmt.Printf("   newly tolerated (REVIEW each - it will compile at switch unheld): %s\n", gate.JoinTrailingSpace(added))
	}
	return nil
}

type jsonResult struct {
	Verdict       string          `json:"verdict"`
	ExitCode      int             `json:"exitCode"`
	Reason        string          `json:"reason"`
	Counts        jsonCounts      `json:"counts"`
	Violations    []jsonViolation `json:"violations"`
	I686OverCap   bool            `json:"i686OverCap"`
	Trivial       []string        `json:"trivial"`
	I686Tolerated []string        `json:"i686Tolerated"`
	Tolerated     []string        `json:"tolerated"`
	Health        []jsonHealth    `json:"health"`
}

type jsonCounts struct {
	Fetched         int `json:"fetched"`
	Build           int `json:"build"`
	LocalPolicy     int `json:"localPolicy"`
	FOD             int `json:"fod"`
	Served          int `json:"served"`
	ConfigArtifacts int `json:"configArtifacts"`
	Trivial         int `json:"trivial"`
	I686Tolerated   int `json:"i686Tolerated"`
	Tolerated       int `json:"tolerated"`
	Violations      int `json:"violations"`
}

type jsonViolation struct {
	Pname       string `json:"pname"`
	Drv         string `json:"drv"`
	Out         string `json:"out"`
	System      string `json:"system"`
	Kind        string `json:"kind"`
	Hint        string `json:"hint"`
	HydraClass  string `json:"hydraClass"`
	HydraDetail string `json:"hydraDetail"`
}

type jsonHealth struct {
	URL    string `json:"url"`
	Up     bool   `json:"up"`
	Status string `json:"status"`
}

func verdictString(v gate.Verdict) string {
	switch v {
	case gate.Pass:
		return "pass"
	case gate.Violation:
		return "fail"
	default:
		return "cannot-judge"
	}
}

func writeJSONResult(path string, exitCode int, result gate.Result) error {
	out := jsonResult{
		Verdict: verdictString(result.Verdict), ExitCode: exitCode, Reason: result.Reason,
		Counts: jsonCounts{
			Fetched: result.Counts.Fetched, Build: result.Counts.Build, LocalPolicy: result.Counts.LocalPolicy,
			FOD: result.Counts.FOD, Served: result.Counts.Served, ConfigArtifacts: result.Counts.ConfigArtifacts,
			Trivial: result.Counts.Trivial, I686Tolerated: result.Counts.I686Tolerated,
			Tolerated: result.Counts.Tolerated, Violations: result.Counts.Violations,
		},
		I686OverCap: result.I686OverCap,
		// Empty slices, never null: a consumer should not have to
		// special-case "no rows" vs "field omitted".
		Violations:    []jsonViolation{},
		Trivial:       nonNil(result.Trivial),
		I686Tolerated: nonNil(result.I686Names),
		Tolerated:     nonNil(result.Tolerated),
		Health:        []jsonHealth{},
	}
	for _, v := range result.Violations {
		out.Violations = append(out.Violations, jsonViolation{
			Pname: v.Pname, Drv: v.Drv, Out: v.Out, System: v.System, Kind: v.Kind,
			Hint: v.Hint, HydraClass: v.HydraClass, HydraDetail: v.HydraDetail,
		})
	}
	for _, h := range result.Health {
		out.Health = append(out.Health, jsonHealth{URL: h.Sub, Up: h.Up, Status: h.Code})
	}
	data, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	return writeFile(path, data)
}

func nonNil(ss []string) []string {
	if ss == nil {
		return []string{}
	}
	return ss
}

func writeFile(path string, data []byte) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(data)
	return err
}
