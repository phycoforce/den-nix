// Package nixplan parses the stderr of `nix build --dry-run --log-format
// raw` (the only usable signal nix gives for "what would this lock build or
// fetch" - internal-json yields an empty plan) and detects substituter/
// daemon degradation that must gate interpretation of that text.
package nixplan

import (
	"bufio"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Section is which dry-run section a store-path record belongs to.
type Section string

const (
	Build   Section = "BUILD"
	Fetch   Section = "FETCH"
	Copy    Section = "COPY"
	Unknown Section = "UNKNOWN"
)

// Record is one store-path line inside a section.
type Record struct {
	Section   Section
	StorePath string
}

var (
	// Singular/plural header variants, nix 2.34.8 wording. "don.t" mirrors
	// the bash awk pattern's wildcard so either apostrophe glyph matches.
	reBuildHdr   = regexp.MustCompile(`^(these [0-9]+ derivations|this derivation) will be built:$`)
	reFetchHdr   = regexp.MustCompile(`^(these [0-9]+ paths|this path) will be fetched \(`)
	reCopyHdr    = regexp.MustCompile(`^(these [0-9]+ paths|this path) will be copied \(`)
	reUnknownHdr = regexp.MustCompile(`^don.t know how to build these paths`)
	reRecord     = regexp.MustCompile(`^  /nix/store/[0-9a-z]{32}-`)
	reDownload   = regexp.MustCompile(`\([0-9.]+ [KMGT]iB download, [0-9.]+ [KMGT]iB unpacked\)`)

	// NetErrorRe mirrors plan-gate.sh's NET_ERROR_RE: a transport failure,
	// not a judgment about this lock - checked only when nix exited non-zero.
	NetErrorRe = regexp.MustCompile(`^[[:space:]]*error: unable to download '[^']+': (HTTP error (5[0-9]{2}|408|429)|[A-Z][^(]*\([0-9]+\))|API rate limit exceeded`)

	re5xxEvidence   = regexp.MustCompile(`unable to download '(https?://[^/']+)[^']*': HTTP error ([0-9]{3})`)
	reDaemonDied    = regexp.MustCompile(`Nix daemon disconnected unexpectedly`)
	reCacheInfoDown = regexp.MustCompile(`unable to download '.*nix-cache-info'|API rate limit exceeded`)
)

// Plan is the parsed result of one dry-run.
type Plan struct {
	Records      []Record
	BuildCount   int
	FetchCount   int
	UnknownCount int
	HeaderCount  int // any header line present; 0 means "empty plan"
	Download     string
}

// Parse section-splits the plan (plan-gate.sh's awk, lines ~295-310): any
// line that is not a recognized header or record closes the current
// section, so interleaved warnings never corrupt the split.
func Parse(planText string) Plan {
	var p Plan
	sec := Section("")
	sc := bufio.NewScanner(strings.NewReader(planText))
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case reBuildHdr.MatchString(line):
			sec, p.HeaderCount = Build, p.HeaderCount+1
			continue
		case reFetchHdr.MatchString(line):
			sec, p.HeaderCount = Fetch, p.HeaderCount+1
			continue
		case reCopyHdr.MatchString(line):
			sec, p.HeaderCount = Copy, p.HeaderCount+1
			continue
		case reUnknownHdr.MatchString(line):
			sec, p.HeaderCount = Unknown, p.HeaderCount+1
			continue
		}
		if sec != "" && reRecord.MatchString(line) {
			fields := strings.Fields(line)
			p.Records = append(p.Records, Record{Section: sec, StorePath: fields[0]})
			switch sec {
			case Build:
				p.BuildCount++
			case Fetch:
				p.FetchCount++
			case Unknown:
				p.UnknownCount++
			}
			continue
		}
		sec = ""
	}
	if m := reDownload.FindString(planText); m != "" {
		p.Download = m
	}
	return p
}

// BuildDrvs returns the sorted, de-duplicated BUILD-section paths, mirroring
// `grep '^BUILD ' | cut -d' ' -f2 | sort -u`.
func (p Plan) BuildDrvs() []string {
	set := map[string]struct{}{}
	for _, r := range p.Records {
		if r.Section == Build {
			set[r.StorePath] = struct{}{}
		}
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// UnknownPaths returns UNKNOWN-section paths in plan order (bash never
// dedupes this list - it's printed verbatim, one violation line per row).
func (p Plan) UnknownPaths() []string {
	var out []string
	for _, r := range p.Records {
		if r.Section == Unknown {
			out = append(out, r.StorePath)
		}
	}
	return out
}

// Verdict is plan-gate.sh's 0/1/2 exit-code contract, typed so losing the
// 3rd state is a compile error, not a dropped branch.
type Verdict int

const (
	Pass        Verdict = 0
	Violation   Verdict = 1
	CannotJudge Verdict = 2
)

// NetworkCheckResult is the outcome of the degraded-network/daemon-crash
// scan that must run before any plan is interpreted.
type NetworkCheckResult struct {
	CannotJudge bool
	DaemonDied  bool
	Reason      string
	Evidence    []string
}

// CheckDegradedNetwork ports plan-gate.sh:255-286: a substituter 5xx, a
// generic transport error, a GitHub rate-limit message, or a daemon crash
// mid-plan are infrastructure facts, not a verdict on this lock - checked
// regardless of nix's own exit code, since an outage can make nix report a
// bogus-but-successful plan (fetches reclassified as builds).
func CheckDegradedNetwork(planText string, nixRC int) NetworkCheckResult {
	if nixRC != 0 {
		if anyLine(planText, NetErrorRe) {
			evidence := append(fiveXXEvidence(planText), matchingLines(planText, NetErrorRe)...)
			return NetworkCheckResult{CannotJudge: true, Reason: "nix failed on a network error, not on this lock", Evidence: uniqHead(evidence, 5)}
		}
		if anyLine(planText, reDaemonDied) {
			return NetworkCheckResult{CannotJudge: true, DaemonDied: true, Reason: "the nix daemon died mid-plan - infrastructure, not this lock", Evidence: uniqHead(fiveXXEvidence(planText), 5)}
		}
		return NetworkCheckResult{Reason: "evaluation failed"}
	}
	if anyLine(planText, reCacheInfoDown) {
		return NetworkCheckResult{CannotJudge: true, Reason: "a substituter or the GitHub API was unreachable while nix planned", Evidence: uniqHead(matchingLines(planText, reCacheInfoDown), 5)}
	}
	return NetworkCheckResult{}
}

// fiveXXEvidence collapses repeated 5xx lines per host, mirroring
// `sort | uniq -c` in plan-gate.sh:269-271.
func fiveXXEvidence(planText string) []string {
	counts := map[string]int{}
	var order []string
	for _, line := range strings.Split(planText, "\n") {
		m := re5xxEvidence.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		key := fmt.Sprintf("%s answered HTTP %s", m[1], m[2])
		if _, ok := counts[key]; !ok {
			order = append(order, key)
		}
		counts[key]++
	}
	sort.Strings(order)
	out := make([]string, 0, len(order))
	for _, k := range order {
		out = append(out, fmt.Sprintf("%s (x%d)", k, counts[k]))
	}
	return out
}

// anyLine is grep -q: the patterns are ^-anchored per line and RE2 has no
// implicit multiline mode.
func anyLine(text string, re *regexp.Regexp) bool {
	for _, line := range strings.Split(text, "\n") {
		if re.MatchString(line) {
			return true
		}
	}
	return false
}

func matchingLines(text string, re *regexp.Regexp) []string {
	var out []string
	seen := map[string]bool{}
	for _, line := range strings.Split(text, "\n") {
		if re.MatchString(line) && !seen[line] {
			seen[line] = true
			out = append(out, line)
		}
	}
	sort.Strings(out)
	return out
}

func uniqHead(lines []string, n int) []string {
	if len(lines) > n {
		return lines[:n]
	}
	return lines
}
