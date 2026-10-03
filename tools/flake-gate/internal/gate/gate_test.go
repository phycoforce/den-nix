package gate

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/phycoforce/den-nix/tools/flake-gate/internal/baseline"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/hydra"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/policy"
	"github.com/phycoforce/den-nix/tools/flake-gate/internal/probe"
)

// realConfigArtifactRegex/realKmodClosureRegex/realBlock are plan-gate.sh's
// exact patterns, transcribed for a realistic test policy.
const (
	realConfigArtifactRegex = `^(unit-.+[.](service|timer|socket|target|mount|automount|slice|path|scope)|initrd-|system-path$|home-manager-path$|home-manager-files$|home-manager-generation$|nixos-system-|etc$|etc-|graphics-drivers$|system-generators$|user-generators$|X-Restart-Triggers|options[.]json$|home-configuration-reference-manpage$|.+[.]conf$|sddm-wrapped$|security-wrapper($|-)|pam[.]d$|hm-modules-messages$|jack-libs$)`
	realKmodClosureRegex    = `^linux-.+-modules(-shrunk)?$`
)

var realBlock = []policy.BlockEntry{
	{Prefix: "linux-cachyos", Hint: "attic.xuyh0120.win/lantian"},
	{Prefix: "nvidia-x11", Hint: "attic.xuyh0120.win/lantian or phycoforce.cachix.org"},
	{Prefix: "mesa", Hint: "cache.nixos.org"},
	{Prefix: "niri", Hint: "cache.nixos.org (Hydra, not in 'tested'; probe: just hydra-check niri)"},
}

func testPolicy(t *testing.T, substituters []string, maxBuilds, maxI686 int) policy.Compiled {
	t.Helper()
	if substituters == nil {
		// A harmless placeholder for tests that never reach the probe
		// stage (early cannot-judge/violation returns) - policy.Compile
		// requires a non-empty list.
		substituters = []string{"http://127.0.0.1:1"}
	}
	p := policy.Policy{
		Toplevel: ".#x", Baseline: "baseline.txt", Substituters: substituters, OwnCache: "https://own.example",
		MaxBuilds: maxBuilds, MaxI686: maxI686,
		Hydra:               policy.HydraConfig{URL: "http://127.0.0.1:1", Jobset: "nixos/unstable", MaxLookups: 10},
		ConfigArtifactRegex: realConfigArtifactRegex, KmodClosureRegex: realKmodClosureRegex, Block: realBlock,
	}
	c, err := p.Compile()
	if err != nil {
		t.Fatalf("policy.Compile: %v", err)
	}
	return c
}

// stubHydraClient points at a closed port: every Verdict call fails fast
// with "connection refused" (Inconclusive/"Hydra unreachable"), so tests
// that don't care about hydra content stay quick and deterministic.
func stubHydraClient() *hydra.Client {
	return &hydra.Client{BaseURL: "http://127.0.0.1:1", Jobset: "nixos/unstable", MaxLookups: 10}
}

func noopProbeClient() *probe.Client {
	return &probe.Client{HealthTimeout: time.Second, ProbeTimeout: time.Second}
}

func hash32(seed string) string {
	var clean []byte
	for _, c := range strings.ToLower(seed) {
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') {
			clean = append(clean, byte(c))
		}
	}
	if len(clean) == 0 {
		clean = []byte("x")
	}
	out := make([]byte, 0, 32)
	for len(out) < 32 {
		out = append(out, clean...)
	}
	return string(out[:32])
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

func buildPlan(names ...string) string {
	var b strings.Builder
	if len(names) == 1 {
		b.WriteString("this derivation will be built:\n")
	} else {
		b.WriteString("these " + itoa(len(names)) + " derivations will be built:\n")
	}
	for i, n := range names {
		b.WriteString("  /nix/store/" + hash32("p"+itoa(i)+n) + "-" + n + "\n")
	}
	return b.String()
}

// drvJSON builds a minimal schema-v4 `nix derivation show` document, keyed
// by basename (no leading /nix/store/, matching nix's own schema-v4 keys).
func drvJSON(basename, extraEnv, extraStructured, system, outPath string) string {
	env := "{}"
	if extraEnv != "" {
		env = extraEnv
	}
	if system == "" {
		system = "x86_64-linux"
	}
	outputs := `{"out":{"path":"` + outPath + `"}}`
	if outPath == "" {
		outputs = `{"out":{"hash":"deadbeef","method":"flat"}}`
	}
	structured := ""
	if extraStructured != "" {
		structured = `,"structuredAttrs":` + extraStructured
	}
	return `{"derivations":{"` + basename + `":{"env":` + env + `,"system":"` + system + `"` + structured + `,"outputs":` + outputs + `}}}`
}

func allUpServer(t *testing.T, narinfoStatus int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "nix-cache-info") {
			w.WriteHeader(200)
			return
		}
		w.WriteHeader(narinfoStatus)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func downServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(502)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// firstKey extracts the "<hash>-<name>" schema-v4 key from a plan built by
// buildPlan with exactly one BUILD record.
func firstKey(plan string) string {
	for _, line := range strings.Split(plan, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "/nix/store/") {
			return strings.TrimPrefix(line, "/nix/store/")
		}
	}
	return ""
}

func TestRun_EmptyPlanPasses(t *testing.T) {
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: "warning: Git tree is dirty\n", NixRC: 0, Policy: testPolicy(t, nil, 2000, 25),
	})
	if res.Verdict != Pass {
		t.Fatalf("Verdict = %d, want Pass", res.Verdict)
	}
	if !strings.Contains(res.Summary, "plan is empty") {
		t.Fatalf("Summary = %q", res.Summary)
	}
}

func TestRun_EmptyPlanBothLinesGoToStdoutNotStderr(t *testing.T) {
	age := 5
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: "warning: dirty\n", NixRC: 0, Policy: testPolicy(t, nil, 2000, 25), NixpkgsAgeDays: &age,
	})
	if len(res.Stderr) != 0 {
		t.Fatalf("Stderr = %v, want empty (both lines belong on stdout)", res.Stderr)
	}
	want := ">> plan-gate: plan is empty - closure already realized locally; nothing to prove.\n" +
		"   (this is NOT substituter health; lock is 5d old - probe a candidate with: just check-tip)"
	if res.Summary != want {
		t.Fatalf("Summary:\n got:  %q\n want: %q", res.Summary, want)
	}
}

func TestRun_NetworkErrorIsCannotJudge(t *testing.T) {
	plan := "error: unable to download 'https://cache.xinux.uz/x.narinfo': HTTP error 502\n"
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{PlanText: plan, NixRC: 1, Policy: testPolicy(t, nil, 2000, 25)})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge", res.Verdict)
	}
}

func TestRun_DaemonCrashIsCannotJudge(t *testing.T) {
	plan := "error: Nix daemon disconnected unexpectedly (maybe it crashed?)\n"
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{PlanText: plan, NixRC: 1, Policy: testPolicy(t, nil, 2000, 25)})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge", res.Verdict)
	}
}

func TestRun_GenericEvalFailureIsViolation(t *testing.T) {
	plan := "error: attribute 'doesNotExist' missing\n"
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{PlanText: plan, NixRC: 1, Policy: testPolicy(t, nil, 2000, 25)})
	if res.Verdict != Violation {
		t.Fatalf("Verdict = %d, want Violation", res.Verdict)
	}
}

func TestRun_EvalFailureStderrHasNoSpuriousBlankLine(t *testing.T) {
	// bash's `cat "$plan"` dumps the plan verbatim, no extra blank line
	// before the next echo'd line - a naive Fprintln on the whole
	// (newline-terminated) blob as one element would add one.
	plan := "error: foo\nerror: bar\n"
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{PlanText: plan, NixRC: 1, Policy: testPolicy(t, nil, 2000, 25)})
	want := []string{"error: foo", "error: bar", "!! plan-gate: evaluation failed (see above)."}
	if !equalStrings(res.Stderr, want) {
		t.Fatalf("Stderr = %#v, want %#v", res.Stderr, want)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestRun_CacheInfoDownOnZeroExitIsCannotJudge(t *testing.T) {
	plan := "warning: unable to download 'https://dead.example/nix-cache-info': timeout\n" + buildPlan("foo")
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{PlanText: plan, NixRC: 0, Policy: testPolicy(t, nil, 2000, 25)})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge", res.Verdict)
	}
}

func TestRun_UnknownSectionIsViolation(t *testing.T) {
	plan := "don't know how to build these paths:\n  /nix/store/" + hash32("u") + "-foo\n"
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{PlanText: plan, NixRC: 0, Policy: testPolicy(t, nil, 2000, 25)})
	if res.Verdict != Violation {
		t.Fatalf("Verdict = %d, want Violation", res.Verdict)
	}
}

func TestRun_HeadersPresentButUnparsedIsViolation(t *testing.T) {
	plan := "this derivation will be built:\nsomething that is not a store path\n"
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{PlanText: plan, NixRC: 0, Policy: testPolicy(t, nil, 2000, 25)})
	if res.Verdict != Violation {
		t.Fatalf("Verdict = %d, want Violation", res.Verdict)
	}
	want := []string{
		"!! plan-gate: plan headers present but no records were recognized - refusing to pass an unparsed plan.",
		"this derivation will be built:", "something that is not a store path",
	}
	if !equalStrings(res.Stderr, want) {
		t.Fatalf("Stderr = %#v, want %#v (no spurious trailing blank line from the plan's own final newline)", res.Stderr, want)
	}
}

func TestRun_BootstrapSeedsAreCannotJudge(t *testing.T) {
	plan := buildPlan("stage0-posix-bootstrap-tools")
	docs := []byte(drvJSON(firstKey(plan), "", "", "", "x-out"))
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs}, Policy: testPolicy(t, nil, 2000, 25),
	})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge (bootstrap seeds present)", res.Verdict)
	}
}

func TestRun_MaxBuildsExceededIsCannotJudge(t *testing.T) {
	names := make([]string, 5)
	for i := range names {
		names[i] = "pkg" + itoa(i)
	}
	plan := buildPlan(names...)
	loaded := false
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, Policy: testPolicy(t, nil, 2, 25),
		LoadDerivations: func([]string) ([][]byte, error) { loaded = true; return nil, nil },
	})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge (build count %d > cap 2)", res.Verdict, len(names))
	}
	if loaded {
		t.Fatal("derivations were loaded past the max-builds cap; the cap must fail fast")
	}
}

func TestRun_DerivationLoadFailureIsCannotJudge(t *testing.T) {
	plan := buildPlan("pkg")
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, Policy: testPolicy(t, nil, 2000, 25),
		LoadDerivations: func([]string) ([][]byte, error) { return nil, errors.New("daemon gone") },
	})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge for a failed nix derivation show", res.Verdict)
	}
}

func TestRun_ClassifyMismatchIsCannotJudge(t *testing.T) {
	plan := buildPlan("foo", "bar")
	key := firstKey(buildPlan("foo"))
	docs := []byte(drvJSON(key, "", "", "", "x-out"))
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs}, Policy: testPolicy(t, nil, 2000, 25),
	})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge (classified count must equal candidate count)", res.Verdict)
	}
}

func TestRun_BlockedViolation(t *testing.T) {
	plan := buildPlan("niri-25.08")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, `{"name":"niri-25.08"}`, "", "", hash32("out")+"-niri-25.08"))
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25),
	})
	if res.Verdict != Violation {
		t.Fatalf("Verdict = %d, want Violation", res.Verdict)
	}
	if len(res.Violations) != 1 || res.Violations[0].Kind != "blocked" {
		t.Fatalf("Violations = %+v, want one blocked violation", res.Violations)
	}
	if !strings.Contains(res.Violations[0].Hint, "hydra-check niri") {
		t.Fatalf("Hint = %q, missing expected BLOCK hint", res.Violations[0].Hint)
	}
	if !strings.Contains(res.Violations[0].HydraDetail, "Hydra unreachable") {
		t.Fatalf("HydraDetail = %q, want a hydra verdict to have run for a BLOCK violation", res.Violations[0].HydraDetail)
	}
	foundNext := false
	for _, l := range res.Stderr {
		if strings.HasPrefix(l, "   next:") {
			foundNext = true
		}
	}
	if foundNext {
		t.Fatalf("a \"next:\" hint must only follow a NEW violation, never a BLOCK one: %v", res.Stderr)
	}
}

func TestRun_NewUnservedNotInBaselineIsViolation(t *testing.T) {
	plan := buildPlan("some-random-pkg-1.0")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, "", "", "", hash32("out2")+"-some-random-pkg-1.0"))
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25),
	})
	if res.Verdict != Violation {
		t.Fatalf("Verdict = %d, want Violation", res.Verdict)
	}
	if res.Violations[0].Kind != "new" || res.Violations[0].Pname != "some-random-pkg" {
		t.Fatalf("Violations[0] = %+v", res.Violations[0])
	}
	joined := strings.Join(res.Stderr, "\n")
	if !strings.Contains(joined, "not in baseline.txt") {
		t.Fatalf("stderr must name the baseline file's actual basename, got: %s", joined)
	}
	if !strings.Contains(joined, "next:") {
		t.Fatalf("a NEW violation must be followed by a \"next:\" hint, got: %s", joined)
	}
}

func TestRun_BaselineTolerated(t *testing.T) {
	plan := buildPlan("xivlauncher-core-1.0")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, "", "", "", hash32("out3")+"-xivlauncher-core-1.0"))
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25), Baseline: baseline.Load("xivlauncher-core\n"),
	})
	if res.Verdict != Pass {
		t.Fatalf("Verdict = %d, want Pass (baselined pname)", res.Verdict)
	}
	if !strings.Contains(res.Summary, "1 tolerated") {
		t.Fatalf("Summary = %q, want it to count the tolerated row", res.Summary)
	}
}

func TestRun_KmodClosureCarveOutAvoidsBlock(t *testing.T) {
	plan := buildPlan("linux-cachyos-6.1.2-modules-shrunk")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, "", "", "", hash32("out4")+"-linux-cachyos-6.1.2-modules-shrunk"))
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25),
	})
	if res.Verdict != Pass {
		t.Fatalf("Verdict = %d, want Pass (kmod closure must be a config-artifact, not BLOCK): stderr=%v", res.Verdict, res.Stderr)
	}
	if !strings.Contains(res.Summary, "1 config-artifacts") {
		t.Fatalf("Summary = %q, want 1 config-artifacts", res.Summary)
	}
}

func TestRun_TrivialBuilderUnservedIsNotAViolation(t *testing.T) {
	plan := buildPlan("some-nupkg-repack")
	key := firstKey(plan)
	env := `{"stdenv":"/nix/store/` + hash32("sd") + `-stdenv-linux-no-cc","src":"` + hash32("sr") + `-Foo.1.2.3.nupkg"}`
	docs := []byte(drvJSON(key, env, "", "", hash32("out5")+"-some-nupkg-repack"))
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25),
	})
	if res.Verdict != Pass {
		t.Fatalf("Verdict = %d, want Pass (trivial nupkg repack, unserved but cheap): stderr=%v", res.Verdict, res.Stderr)
	}
	if !strings.Contains(res.Summary, "1 trivial-builders") {
		t.Fatalf("Summary = %q, want 1 trivial-builders", res.Summary)
	}
}

func TestRun_SummaryCountsRawRowsListsDeduped(t *testing.T) {
	plan := buildPlan("repack-1.0", "repack-2.0")
	var keys []string
	for _, line := range strings.Split(plan, "\n") {
		if l := strings.TrimSpace(line); strings.HasPrefix(l, "/nix/store/") {
			keys = append(keys, strings.TrimPrefix(l, "/nix/store/"))
		}
	}
	env := `{"stdenv":"/nix/store/` + hash32("sd") + `-stdenv-linux-no-cc","src":"` + hash32("sr") + `-Foo.1.2.3.nupkg"}`
	docs := [][]byte{
		[]byte(drvJSON(keys[0], env, "", "", "/nix/store/"+hash32("outa")+"-repack-1.0")),
		[]byte(drvJSON(keys[1], env, "", "", "/nix/store/"+hash32("outb")+"-repack-2.0")),
	}
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: docs,
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25),
	})
	lines := strings.Split(res.Summary, "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], " 2 trivial-builders,") || !strings.HasSuffix(lines[1], "seconds): repack ") {
		t.Fatalf("Summary = %q, want a raw count of 2 over a deduped list", res.Summary)
	}
	if res.Counts.Trivial != 2 {
		t.Fatalf("Counts.Trivial = %d, want 2 (raw rows, like bash)", res.Counts.Trivial)
	}
}

func TestRun_I686UnderCapIsTolerated(t *testing.T) {
	plan := buildPlan("some-i686-leaf")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, "", "", "i686-linux", hash32("out6")+"-some-i686-leaf"))
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25),
	})
	if res.Verdict != Pass {
		t.Fatalf("Verdict = %d, want Pass (1 i686 leaf is under the cap): stderr=%v", res.Verdict, res.Stderr)
	}
	if !strings.Contains(res.Summary, "1 i686-tolerated") {
		t.Fatalf("Summary = %q", res.Summary)
	}
}

func i686Plan(t *testing.T, n int) (string, [][]byte) {
	t.Helper()
	names := make([]string, n)
	for i := range names {
		names[i] = "i686-leaf-" + itoa(i)
	}
	plan := buildPlan(names...)
	var rows []string
	for i, name := range names {
		full := hash32("p"+itoa(i)+name) + "-" + name
		rows = append(rows, `"`+full+`":{"env":{},"system":"i686-linux","outputs":{"out":{"path":"`+hash32("o"+itoa(i))+`-`+name+`"}}}`)
	}
	return plan, [][]byte{[]byte(`{"derivations":{` + strings.Join(rows, ",") + `}}`)}
}

func TestRun_I686OverCapIsViolation(t *testing.T) {
	plan, docs := i686Plan(t, 3)
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: docs,
		Policy: testPolicy(t, []string{srv.URL}, 2000, 2),
	})
	if res.Verdict != Violation || !res.I686OverCap {
		t.Fatalf("Verdict = %d I686OverCap=%v, want Violation+true (3 i686 leaves > cap 2): stderr=%v", res.Verdict, res.I686OverCap, res.Stderr)
	}
}

func TestRun_I686CapSkippedInWriteBaselineMode(t *testing.T) {
	plan, docs := i686Plan(t, 3)
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: docs,
		Policy: testPolicy(t, []string{srv.URL}, 2000, 2), WriteBaseline: true,
	})
	if res.Verdict != Pass || res.I686OverCap {
		t.Fatalf("Verdict = %d I686OverCap=%v, want Pass+false (the i686 cap is skipped entirely in --write-baseline mode): stderr=%v", res.Verdict, res.I686OverCap, res.Stderr)
	}
}

func TestRun_UnreachableSubstituterWithNoFalloutPasses(t *testing.T) {
	plan := buildPlan("ordinary-pkg")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, `{"preferLocalBuild":"1"}`, "", "", "x-out"))
	down := downServer(t)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{down.URL}, 2000, 25),
	})
	if res.Verdict != Pass {
		t.Fatalf("Verdict = %d, want Pass (local-by-policy row, substituter down but irrelevant): stderr=%v", res.Verdict, res.Stderr)
	}
	found := false
	for _, l := range res.Stderr {
		if strings.Contains(l, "passing with substituters down") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected the \"passing with substituters down\" warning, got stderr=%v", res.Stderr)
	}
}

func TestRun_UnreachableSubstituterWithViolationIsCannotJudge(t *testing.T) {
	plan := buildPlan("niri-25.08")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, "", "", "", hash32("out7")+"-niri-25.08"))
	down := downServer(t)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{down.URL}, 2000, 25),
	})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge (a violation when a substituter was down must be treated as a possible phantom): stderr=%v", res.Verdict, res.Stderr)
	}
	// plan-gate.sh prints the summary line UNCONDITIONALLY before this
	// check (lines 580-603) - stdout must still carry the counts even
	// though the run exits 2.
	if !strings.Contains(res.Summary, "1 violations") {
		t.Fatalf("Summary = %q, want the normal counts line even on this cannot-judge exit", res.Summary)
	}
}

func TestRun_WriteBaselineMode_MeasuresWithoutTolerateOrViolation(t *testing.T) {
	plan := buildPlan("freshly-unserved-pkg-1.0")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, "", "", "", hash32("outwb")+"-freshly-unserved-pkg-1.0"))
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25), WriteBaseline: true,
	})
	if res.Verdict != Pass {
		t.Fatalf("Verdict = %d, want Pass (write-baseline mode: ordinary unserved rows are measurement only): stderr=%v", res.Verdict, res.Stderr)
	}
	if len(res.Tolerated) != 0 || res.Counts.Violations != 0 {
		t.Fatalf("got Tolerated=%v Violations=%d, want neither tolerated nor violated", res.Tolerated, res.Counts.Violations)
	}
	if !containsString(res.MeasuredUnserved, "freshly-unserved-pkg") {
		t.Fatalf("MeasuredUnserved = %v, want freshly-unserved-pkg", res.MeasuredUnserved)
	}
}

func TestRun_WriteBaselineMode_BlockStillViolates(t *testing.T) {
	plan := buildPlan("niri-25.08")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, "", "", "", hash32("outwb2")+"-niri-25.08"))
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25), WriteBaseline: true,
	})
	if res.Verdict != Violation {
		t.Fatalf("Verdict = %d, want Violation (BLOCK fires even in --write-baseline mode): stderr=%v", res.Verdict, res.Stderr)
	}
	if len(res.Violations) != 1 || res.Violations[0].Kind != "blocked" {
		t.Fatalf("Violations = %+v", res.Violations)
	}
}

func TestRun_WriteBaselineMode_RefusesDuringOutage(t *testing.T) {
	plan := buildPlan("ordinary-pkg-1.0")
	key := firstKey(plan)
	docs := []byte(drvJSON(key, "", "", "", hash32("outwb3")+"-ordinary-pkg-1.0"))
	down := downServer(t)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{down.URL}, 2000, 25), WriteBaseline: true,
	})
	if res.Verdict != CannotJudge {
		t.Fatalf("Verdict = %d, want CannotJudge (never write a baseline measured during an outage): stderr=%v", res.Verdict, res.Stderr)
	}
	joined := strings.Join(res.Stderr, "\n")
	if !strings.Contains(joined, "not writing a baseline measured while substituters were unreachable") {
		t.Fatalf("stderr = %s, missing the refusal reason", joined)
	}
}

// hydraSequenceServer records, in call order, the pname each
// /api/latestbuilds lookup was made for (parsed from the "job" query
// param), and returns an empty build list (no-hydra-job) for everything.
func hydraSequenceServer(t *testing.T) (*httptest.Server, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var seq []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		job := r.URL.Query().Get("job") // "nixpkgs.<pname>.<system>"
		mu.Lock()
		seq = append(seq, job)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("[]"))
	}))
	t.Cleanup(srv.Close)
	return srv, func() []string { mu.Lock(); defer mu.Unlock(); return append([]string{}, seq...) }
}

func TestRun_ViolationsAndHydraBudgetAreInDeterministicPnameOrder(t *testing.T) {
	// Three BLOCK/NEW-worthy pnames, deliberately built in reverse-sorted
	// plan order, with a Hydra budget of 2: bash's own xargs -P8 probe
	// order is nondeterministic, so the Go port's one deliberate
	// divergence is a SORTED (pname, drv) order - and that sort also
	// decides which rows spend the lookup budget.
	names := []string{"zzz-pkg-1.0", "mesa-1.0", "aaa-pkg-1.0"} // mesa hits BLOCK
	plan := buildPlan(names...)
	var rows []string
	for i, n := range names {
		full := hash32("p"+itoa(i)+n) + "-" + n
		rows = append(rows, `"`+full+`":{"env":{},"system":"x86_64-linux","outputs":{"out":{"path":"`+hash32("o"+itoa(i)+n)+`-`+n+`"}}}`)
	}
	docs := []byte(`{"derivations":{` + strings.Join(rows, ",") + `}}`)

	hydraSrv, seqFn := hydraSequenceServer(t)
	narinfoSrv := allUpServer(t, 404)
	hc := &hydra.Client{BaseURL: hydraSrv.URL, Jobset: "nixos/unstable", MaxLookups: 2}

	res := Run(context.Background(), noopProbeClient(), hc, Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{narinfoSrv.URL}, 2000, 25),
	})
	if res.Verdict != Violation {
		t.Fatalf("Verdict = %d, want Violation: stderr=%v", res.Verdict, res.Stderr)
	}
	if len(res.Violations) != 3 {
		t.Fatalf("got %d violations, want 3: %+v", len(res.Violations), res.Violations)
	}
	wantPnameOrder := []string{"aaa-pkg", "mesa", "zzz-pkg"}
	for i, v := range res.Violations {
		if v.Pname != wantPnameOrder[i] {
			t.Fatalf("Violations[%d].Pname = %q, want %q (sorted by pname): %+v", i, v.Pname, wantPnameOrder[i], res.Violations)
		}
	}
	// Budget is 2: only the first two in sorted order (aaa-pkg, mesa)
	// actually reach the network; zzz-pkg's lookup must be skipped.
	seq := seqFn()
	if len(seq) != 2 {
		t.Fatalf("got %d Hydra HTTP calls, want exactly 2 (budget): %v", len(seq), seq)
	}
	if !strings.Contains(seq[0], "aaa-pkg") || !strings.Contains(seq[1], "mesa") {
		t.Fatalf("Hydra call order = %v, want aaa-pkg then mesa", seq)
	}
	for _, v := range res.Violations {
		if v.Pname == "zzz-pkg" && !strings.Contains(v.HydraDetail, "budget") {
			t.Fatalf("zzz-pkg's HydraDetail = %q, want a budget-skipped message", v.HydraDetail)
		}
	}
}

func TestRun_NextHintMentionsFailedUpstreamJobsetDash(t *testing.T) {
	plan := buildPlan("some-new-pkg-1.0")
	key := firstKey(plan)
	hash := hash32("outnh")
	docs := []byte(drvJSON(key, "", "", "", hash+"-some-new-pkg-1.0"))
	srv := allUpServer(t, 404)

	status1 := 1
	hydraSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/latestbuilds"):
			w.Write([]byte(`[{"id":1,"buildstatus":` + itoa(status1) + `,"finished":1}]`))
		case strings.HasPrefix(r.URL.Path, "/build/1"):
			w.Write([]byte(`{"buildoutputs":{"out":{"path":"/nix/store/` + hash + `-some-new-pkg-1.0"}}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer hydraSrv.Close()
	hc := &hydra.Client{BaseURL: hydraSrv.URL, Jobset: "nixos/unstable", MaxLookups: 10}

	res := Run(context.Background(), noopProbeClient(), hc, Input{
		PlanText: plan, NixRC: 0, DerivationShowDocs: [][]byte{docs},
		Policy: testPolicy(t, []string{srv.URL}, 2000, 25),
	})
	if res.Verdict != Violation {
		t.Fatalf("Verdict = %d, want Violation: stderr=%v", res.Verdict, res.Stderr)
	}
	joined := strings.Join(res.Stderr, "\n")
	if !strings.Contains(joined, "next: hold - it cannot build here either; self-heals once nixos-unstable ships a fixed eval") {
		t.Fatalf("stderr = %s, missing the failed-upstream next-hint with the jobset dash-joined", joined)
	}
}

func containsString(ss []string, v string) bool {
	for _, s := range ss {
		if s == v {
			return true
		}
	}
	return false
}

func TestRun_RealCapturedPlanMatchesBashVerdict(t *testing.T) {
	// End-to-end parity fixture: a real plan.txt + derivation-show JSON
	// captured from `nix build --dry-run` against a home-manager bump,
	// with substituters faked to reproduce the observed real-world
	// outcome (both check-classified rows were genuinely unserved).
	// plan-gate.sh's own verdict on this exact plan+lock:
	//   >> plan-gate: 0 fetched | 10 to build: 8 local-by-policy,
	//   0 source-fetches, 0 cache-served, 2 config-artifacts,
	//   0 trivial-builders, 0 i686-tolerated, 0 tolerated, 0 violations.
	// exit 0.
	planText, err := os.ReadFile("../../testdata/real-plan.txt")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	drvsJSON, err := os.ReadFile("../../testdata/real-drvs.json")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	baselineText, err := os.ReadFile("../../testdata/real-baseline.txt")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	srv := allUpServer(t, 404)
	res := Run(context.Background(), noopProbeClient(), stubHydraClient(), Input{
		PlanText: string(planText), NixRC: 0, DerivationShowDocs: [][]byte{drvsJSON},
		Baseline: baseline.Load(string(baselineText)), Policy: testPolicy(t, []string{srv.URL}, 2000, 25),
	})
	if res.Verdict != Pass {
		t.Fatalf("Verdict = %d, want Pass; stderr=%v", res.Verdict, res.Stderr)
	}
	want := ">> plan-gate: 0 fetched | 10 to build: 8 local-by-policy, 0 source-fetches, 0 cache-served, 2 config-artifacts, 0 trivial-builders, 0 i686-tolerated, 0 tolerated, 0 violations."
	if res.Summary != want {
		t.Fatalf("Summary mismatch:\n got:  %q\n want: %q", res.Summary, want)
	}
}
