// Package gate orchestrates plan-gate.sh's decision: parse the dry-run
// plan, classify every BUILD derivation, probe the survivors, and apply
// policy (BLOCK / config-artifact / kmod / trivial / i686 / baseline) to
// whatever is left unserved. Run is a pure function of already-captured
// nix output, so it is table-driven-testable without a nix daemon.
package gate

import (
	"context"
	"fmt"
	"path"
	"sort"
	"strings"

	"github.com/phycoforce/den-nix/tools/flake-gate/internal/baseline"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/classify"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/hydra"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/nixplan"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/policy"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/probe"
)

// Verdict is plan-gate.sh's 0/1/2 exit-code contract.
type Verdict = nixplan.Verdict

const (
	Pass        = nixplan.Pass
	Violation   = nixplan.Violation
	CannotJudge = nixplan.CannotJudge
)

// ViolationRow is one row that failed policy, or couldn't be judged at all
// (Kind "unprobeable").
type ViolationRow struct {
	Pname       string
	Drv         string
	Out         string
	System      string
	Kind        string // "blocked" | "new" | "unprobeable"
	Hint        string // set when Kind == "blocked"
	HydraClass  string // set when Kind is "blocked" or "new"
	HydraDetail string
}

// Counts mirrors the summary line's tallies, kept structured for --json.
type Counts struct {
	Fetched         int
	Build           int
	LocalPolicy     int
	FOD             int
	Served          int
	ConfigArtifacts int
	Trivial         int
	I686Tolerated   int
	Tolerated       int
	Violations      int
}

// Result is everything a caller needs to print plan-gate.sh's stdout/
// stderr, set its exit code, and fill --json.
type Result struct {
	Verdict     Verdict
	Reason      string // headline cannot-judge/violation reason, "" on a clean pass
	Summary     string // the one ">> plan-gate: ..." line (empty on early exits)
	Stderr      []string
	Violations  []ViolationRow
	Health      []probe.Health
	Counts      Counts
	I686OverCap bool
	Trivial     []string
	I686Names   []string
	Tolerated   []string
	// MeasuredUnserved is every non-i686, non-block, non-trivial unserved
	// pname (plan-gate.sh's unserved_pnames) - the --write-baseline input,
	// always populated so a caller can write a baseline regardless of mode.
	MeasuredUnserved []string
}

// Input bundles everything bash's plan-gate.sh reads from its environment,
// nix, and disk.
type Input struct {
	PlanText           string
	NixRC              int
	DerivationShowDocs [][]byte
	// LoadDerivations, when set, replaces DerivationShowDocs and runs only once the
	// plan passed the cheap guards (the max-builds cap must fail fast offline).
	LoadDerivations func(drvs []string) ([][]byte, error)
	Baseline        baseline.Baseline
	Policy          policy.Compiled // env overrides already applied
	NixpkgsAgeDays  *int            // optional, only for the empty-plan message
	WriteBaseline   bool
}

// Run executes the gate against already-captured nix output.
func Run(ctx context.Context, probeClient *probe.Client, hydraClient *hydra.Client, in Input) Result {
	maxBuilds := in.Policy.MaxBuilds
	maxI686 := in.Policy.MaxI686

	// Probed once, before any verdict - plan-gate.sh:240-253.
	health := probeClient.CheckHealth(ctx, in.Policy.Substituters)
	var unreachable []probe.Health
	for _, h := range health {
		if !h.Up {
			unreachable = append(unreachable, h)
		}
	}

	net := nixplan.CheckDegradedNetwork(in.PlanText, in.NixRC)
	if in.NixRC != 0 {
		if net.CannotJudge {
			return cannotJudge(net.Reason, net.Evidence, health)
		}
		cause := nixplan.ClassifyEvalFailure(in.PlanText)
		stderr := append(splitLines(in.PlanText), "!! plan-gate: evaluation failed (see above).")
		return Result{
			Verdict: Violation,
			Reason:  "evaluation failed: " + cause.Class,
			Stderr:  append(stderr, cause.Lines()...),
			Health:  health,
		}
	}
	if net.CannotJudge {
		return cannotJudge(net.Reason, net.Evidence, health)
	}

	plan := nixplan.Parse(in.PlanText)

	if plan.HeaderCount == 0 {
		// Both lines are plain `echo` in bash (plan-gate.sh:318-319), not
		// >&2 - they belong on stdout (Summary), never Stderr.
		detail := "   (this is NOT substituter health"
		if in.NixpkgsAgeDays != nil {
			detail += fmt.Sprintf("; lock is %dd old - probe a candidate with: just check-tip)", *in.NixpkgsAgeDays)
		} else {
			detail += ")"
		}
		msg := ">> plan-gate: plan is empty - closure already realized locally; nothing to prove."
		return Result{Verdict: Pass, Summary: msg + "\n" + detail, Health: health}
	}

	hasUnknown := plan.UnknownCount > 0
	if plan.BuildCount == 0 && plan.FetchCount == 0 && !hasUnknown {
		lines := []string{"!! plan-gate: plan headers present but no records were recognized - refusing to pass an unparsed plan."}
		lines = append(lines, planExcerpt(in.PlanText, 15)...)
		return Result{Verdict: Violation, Reason: "plan headers present but no records were recognized", Stderr: lines, Health: health}
	}
	if hasUnknown {
		lines := []string{"!! plan-gate: nix does not know how to build these paths (no deriver, no substituter) - and --dry-run still exits 0 on this:"}
		for _, p := range plan.UnknownPaths() {
			lines = append(lines, "   "+p)
		}
		return Result{Verdict: Violation, Reason: "nix does not know how to build these paths", Stderr: lines, Health: health}
	}

	buildDrvs := plan.BuildDrvs()
	bootstrap := false
	for _, r := range plan.Records {
		if r.Section == nixplan.Build && (strings.Contains(r.StorePath, "stage0-posix") || strings.Contains(r.StorePath, "bootstrap-tools")) {
			bootstrap = true
			break
		}
	}
	if len(buildDrvs) > maxBuilds || bootstrap {
		return cannotJudge(fmt.Sprintf(
			"%d derivations to build (cap %d) or bootstrap seeds present - what 'no substituter reachable' looks like, not what 'upstream broke' looks like",
			len(buildDrvs), maxBuilds), nil, health)
	}

	docs := in.DerivationShowDocs
	if in.LoadDerivations != nil {
		// plan-gate.sh dies here with xargs' status, which blames the input; a
		// failed show is infrastructure, so this deliberately says cannot judge.
		loaded, err := in.LoadDerivations(buildDrvs)
		if err != nil {
			return cannotJudge("nix derivation show failed: "+err.Error(), nil, health)
		}
		docs = loaded
	}
	derivs, err := classify.Parse(docs...)
	if err != nil {
		return cannotJudge("nix derivation show output did not decode: "+err.Error(), nil, health)
	}
	rows := classify.Classify(derivs)
	if len(rows) != len(buildDrvs) {
		return cannotJudge(fmt.Sprintf(
			"classified %d of %d build derivations - nix derivation show schema drift? Cannot judge an unexamined plan.",
			len(rows), len(buildDrvs)), nil, health)
	}

	var localCount, fodCount int
	var unprobeable []classify.Row
	var toProbe []probe.Candidate
	trivialSet := map[string]bool{}
	for _, r := range rows {
		switch r.Kind {
		case classify.Local:
			localCount++
		case classify.FOD:
			fodCount++
		case classify.Check:
			if r.Out == "" {
				unprobeable = append(unprobeable, r)
			} else {
				toProbe = append(toProbe, probe.Candidate{Drv: r.Drv, Out: r.Out, System: r.System})
			}
		}
		if r.Trivial {
			trivialSet[r.Drv] = true
		}
	}

	violations := 0
	var stderrLines []string
	var unprobeableViolations []ViolationRow
	if len(unprobeable) > 0 {
		stderrLines = append(stderrLines, "!! plan-gate: build derivations with no computable output path - cannot probe, refusing to pass:")
		for _, r := range unprobeable {
			stderrLines = append(stderrLines, "   "+r.Drv)
			unprobeableViolations = append(unprobeableViolations, ViolationRow{Drv: r.Drv, Kind: "unprobeable"})
		}
		violations += len(unprobeable)
	}

	results := probeClient.Probe(ctx, toProbe, in.Policy.Substituters)
	if len(results) != len(toProbe) {
		return cannotJudge(fmt.Sprintf(
			"probed %d of %d candidates - the probe itself failed; cannot judge.",
			len(results), len(toProbe)), nil, health)
	}

	servedCount := 0
	var unserved []probe.Result
	for _, r := range results {
		if r.Served {
			servedCount++
		} else {
			unserved = append(unserved, r)
		}
	}
	sort.Slice(unserved, func(i, j int) bool { return unserved[i].Drv < unserved[j].Drv })

	configArtifacts := 0
	var toleratedNames, trivialNames, i686Names, measuredUnserved []string
	var pendingViolations []ViolationRow
	for _, u := range unserved {
		base := strings.TrimSuffix(path.Base(u.Drv), ".drv")
		fullname := stripHashPrefix(base)
		if in.Policy.KmodClosureRE.MatchString(fullname) {
			configArtifacts++
			continue
		}
		pname := policy.PnameOf(base)
		if in.Policy.ConfigArtifactRE.MatchString(pname) {
			configArtifacts++
			continue
		}
		if hint := policy.MatchBlock(in.Policy.Block, pname); hint != "" {
			violations++
			pendingViolations = append(pendingViolations, ViolationRow{Pname: pname, Drv: u.Drv, Out: u.Out, System: u.System, Kind: "blocked", Hint: hint})
			continue
		}
		if trivialSet[u.Drv] {
			trivialNames = append(trivialNames, pname)
			continue
		}
		if u.System == "i686-linux" {
			i686Names = append(i686Names, pname)
			continue
		}
		measuredUnserved = append(measuredUnserved, pname)
		if in.WriteBaseline {
			continue // measurement only - neither tolerated nor a violation
		}
		if in.Baseline != nil && in.Baseline.Tolerates(pname) {
			toleratedNames = append(toleratedNames, pname)
			continue
		}
		violations++
		pendingViolations = append(pendingViolations, ViolationRow{Pname: pname, Drv: u.Drv, Out: u.Out, System: u.System, Kind: "new"})
	}

	// Deterministic order (sort by pname, then drv): bash's xargs -P8 probe
	// order is nondeterministic, so this is the one deliberate divergence
	// from byte-for-byte parity - it also decides which 10 rows spend the
	// Hydra lookup budget.
	sort.Slice(pendingViolations, func(i, j int) bool {
		if pendingViolations[i].Pname != pendingViolations[j].Pname {
			return pendingViolations[i].Pname < pendingViolations[j].Pname
		}
		return pendingViolations[i].Drv < pendingViolations[j].Drv
	})
	baselineBase := path.Base(in.Policy.Baseline)
	for i := range pendingViolations {
		v := &pendingViolations[i]
		verdict := hydraClient.Verdict(ctx, v.Pname, v.Out, v.System)
		v.HydraClass, v.HydraDetail = string(verdict.Class), verdict.Detail
		if v.Kind == "blocked" {
			stderrLines = append(stderrLines, blockedLines(*v)...)
		} else {
			stderrLines = append(stderrLines, newViolationLines(*v, baselineBase)...)
			stderrLines = append(stderrLines, nextHint(verdict.Class, in.Policy.Hydra.Jobset))
		}
	}
	allViolations := append(unprobeableViolations, pendingViolations...)
	sort.Slice(allViolations, func(i, j int) bool {
		if allViolations[i].Pname != allViolations[j].Pname {
			return allViolations[i].Pname < allViolations[j].Pname
		}
		return allViolations[i].Drv < allViolations[j].Drv
	})

	// The cap counts RAW unserved i686 rows (bash: ${#i686_tolerated[@]},
	// appended once per row, never deduped); only the printed/JSON list is
	// deduped+sorted. Skipped entirely in --write-baseline mode.
	i686Unique := policy.SortedPnames(i686Names)
	i686OverCap := !in.WriteBaseline && len(i686Names) > maxI686
	if i686OverCap {
		stderrLines = append(stderrLines, fmt.Sprintf(
			"!! plan-gate: %d unserved 32-bit builds (cap %d) - an i686 mass rebuild no cache will absorb, not the usual leaf set. Holding.",
			len(i686Names), maxI686))
	}

	// --write-baseline refuses to measure during an outage: everything a
	// dead cache would have served would otherwise probe unserved and, via
	// merge semantics, stay tolerated forever.
	if in.WriteBaseline && len(unreachable) > 0 {
		lines := append([]string{}, stderrLines...)
		return appendCannotJudge(Result{Stderr: lines, Health: health, MeasuredUnserved: policy.SortedPnames(measuredUnserved)},
			"not writing a baseline measured while substituters were unreachable", nil, health)
	}

	trivialUnique := policy.SortedPnames(trivialNames)
	toleratedUnique := policy.SortedPnames(toleratedNames)
	summary := formatSummary(plan.FetchCount, plan.Download, len(buildDrvs), localCount, fodCount,
		servedCount, configArtifacts, trivialNames, i686Names, toleratedNames, violations)

	if len(unreachable) > 0 {
		if violations > 0 || len(i686Unique) > 0 {
			// bash prints the summary line UNCONDITIONALLY before this
			// check (plan-gate.sh:580-603) - it still exits 2, but stdout
			// already has the counts by the time it does.
			res := appendCannotJudge(Result{Stderr: stderrLines, Health: health}, "violations/i686-tolerated above may be phantoms of the unreachable cache", nil, health)
			res.Summary = summary
			return res
		}
		stderrLines = append(stderrLines, "?? plan-gate: passing with substituters down - no unserved row depended on them:")
		for _, h := range health {
			stderrLines = append(stderrLines, healthLine(h))
		}
	}

	verdict := Pass
	reason := ""
	if violations > 0 || i686OverCap {
		verdict = Violation
		reason = fmt.Sprintf("%d violation(s)", violations)
		if i686OverCap {
			reason = strings.TrimSpace(reason + " i686 cap exceeded")
		}
	}
	return Result{
		Verdict:     verdict,
		Reason:      reason,
		Summary:     summary,
		Stderr:      stderrLines,
		Violations:  allViolations,
		Health:      health,
		I686OverCap: i686OverCap,
		Trivial:     trivialUnique,
		I686Names:   i686Unique,
		Tolerated:   toleratedUnique,
		Counts: Counts{
			Fetched: plan.FetchCount, Build: len(buildDrvs), LocalPolicy: localCount, FOD: fodCount,
			Served: servedCount, ConfigArtifacts: configArtifacts, Trivial: len(trivialNames),
			I686Tolerated: len(i686Names), Tolerated: len(toleratedNames), Violations: violations,
		},
		MeasuredUnserved: policy.SortedPnames(measuredUnserved),
	}
}

func cannotJudge(reason string, evidence []string, health []probe.Health) Result {
	return appendCannotJudge(Result{}, reason, evidence, health)
}

// appendCannotJudge appends the cannot-judge block to any stderr lines
// already gathered (used by the write-baseline-during-outage and
// phantom-violation paths, which must keep what was already printed).
func appendCannotJudge(base Result, reason string, evidence []string, health []probe.Health) Result {
	lines := append(base.Stderr, fmt.Sprintf("?? plan-gate: %s - cannot judge this plan.", reason))
	if len(evidence) > 0 {
		lines = append(lines, "   nix reported:")
		for _, e := range evidence {
			lines = append(lines, "     "+e)
		}
	}
	lines = append(lines, "   substituters (probed now):")
	for _, h := range health {
		lines = append(lines, healthLine(h))
	}
	lines = append(lines, "   nothing was judged; re-run once every substituter answers (probe: curl -sI <substituter>/nix-cache-info).")
	base.Verdict, base.Reason, base.Stderr, base.Health = CannotJudge, reason, lines, health
	return base
}

// planExcerpt mirrors `sed -n '1,Np' "$plan"`.
func planExcerpt(planText string, n int) []string {
	lines := splitLines(planText)
	if len(lines) > n {
		lines = lines[:n]
	}
	return lines
}

// splitLines mirrors how `cat`/`sed` print a text blob line-by-line: no
// synthetic trailing blank line from the file's own final newline, and no
// line at all for empty input.
func splitLines(text string) []string {
	trimmed := strings.TrimRight(text, "\n")
	if trimmed == "" {
		return nil
	}
	return strings.Split(trimmed, "\n")
}

func healthLine(h probe.Health) string {
	if h.Up {
		return fmt.Sprintf("     up    %s", h.Sub)
	}
	return fmt.Sprintf("     DOWN  %s (%s)", h.Sub, h.Code)
}

// stripHashPrefix mirrors `fullname="${fullname#*-}"` on a "<hash>-<name>"
// basename.
func stripHashPrefix(base string) string {
	if idx := strings.IndexByte(base, '-'); idx >= 0 {
		return base[idx+1:]
	}
	return base
}

func blockedLines(v ViolationRow) []string {
	sysSuffix := ""
	if v.System != "" {
		sysSuffix = ", " + v.System
	}
	return []string{
		fmt.Sprintf("!! VIOLATION: %s would compile locally (%s%s)", v.Pname, v.Drv, sysSuffix),
		"   expected from: " + v.Hint,
		"   output: " + v.Out,
		fmt.Sprintf("   hydra: %s - %s", v.HydraClass, v.HydraDetail),
	}
}

func newViolationLines(v ViolationRow, baselineBase string) []string {
	sysSuffix := ""
	if v.System != "" {
		sysSuffix = "; " + v.System
	}
	return []string{
		fmt.Sprintf("!! VIOLATION: %s is a NEW unserved local build (not in %s%s)", v.Pname, baselineBase, sysSuffix),
		"   no configured substituter serves it.",
		"   output: " + v.Out,
		fmt.Sprintf("   hydra: %s - %s", v.HydraClass, v.HydraDetail),
	}
}

// nextHint is only printed after a NEW violation - the baseline is for
// packages no one ever serves, so an upstream failure or a pending build
// would otherwise be tolerated there forever.
func nextHint(class hydra.Class, jobset string) string {
	switch class {
	case hydra.FailedUpstream:
		jobsetDash := strings.Replace(jobset, "/", "-", 1)
		return fmt.Sprintf("   next: hold - it cannot build here either; self-heals once %s ships a fixed eval. Never re-baseline it.", jobsetDash)
	case hydra.Pending:
		return "   next: hold - self-heals once Hydra finishes and the cache catches up. Never re-baseline it."
	default:
		return "   next: if Hydra never builds it and it is cheap (wrapper, repack, unfree blob), re-measure with: just gate-baseline; otherwise hold."
	}
}

// Counts are RAW row counts (bash: ${#arr[@]}); only the printed lists are deduped.
func formatSummary(fetchCount int, download string, buildCount, localCount, fodCount, servedCount, configArtifacts int,
	trivialNames, i686Names, toleratedNames []string, violations int) string {
	downloadSuffix := ""
	if download != "" {
		downloadSuffix = download + " "
	}
	lines := []string{fmt.Sprintf(
		">> plan-gate: %d fetched %s| %d to build: %d local-by-policy, %d source-fetches, %d cache-served, %d config-artifacts, %d trivial-builders, %d i686-tolerated, %d tolerated, %d violations.",
		fetchCount, downloadSuffix, buildCount, localCount, fodCount, servedCount, configArtifacts,
		len(trivialNames), len(i686Names), len(toleratedNames), violations)}
	if len(trivialNames) > 0 {
		lines = append(lines, "   trivial-builders (inline buildCommand or .nupkg repack, no compiler; builds at switch in seconds): "+JoinTrailingSpace(policy.SortedPnames(trivialNames)))
	}
	if len(i686Names) > 0 {
		lines = append(lines, "   i686-tolerated (32-bit, unserved by policy; compiles at switch): "+JoinTrailingSpace(policy.SortedPnames(i686Names)))
	}
	if len(toleratedNames) > 0 {
		lines = append(lines, "   tolerated (expected-local; compiles at switch): "+JoinTrailingSpace(policy.SortedPnames(toleratedNames)))
	}
	return strings.Join(lines, "\n")
}

// JoinTrailingSpace mirrors `printf '%s ' "${arr[@]}" | tr ' ' '\n' | sort -u
// | tr '\n' ' '`: a space-joined list with a TRAILING space after the last
// name - a deliberately preserved bash quirk, not a bug. Exported: main
// reuses it for --write-baseline's "newly tolerated" line.
func JoinTrailingSpace(names []string) string {
	return strings.Join(names, " ") + " "
}
