// Package baseline loads, tolerates, and (--write-baseline) re-measures
// plan-gate's expected-local pname set: packages no public substituter
// serves at a healthy lock, which the gate tolerates rather than holds.
package baseline

import (
	"bufio"
	"sort"
	"strings"
)

// Baseline is the measured expected-local pname set, comments/blanks
// stripped.
type Baseline map[string]struct{}

// Load parses a baseline file's text, dropping comment and blank lines.
func Load(text string) Baseline {
	b := Baseline{}
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		b[line] = struct{}{}
	}
	return b
}

func (b Baseline) Tolerates(pname string) bool {
	_, ok := b[pname]
	return ok
}

// Header is plan-gate.sh's exact baseline-file comment block.
func Header(measuredDate, rev string) []string {
	return []string{
		"# Measured expected-local set: pnames no PUBLIC substituter serves at a",
		"# healthy lock - unfree repacks, FHS envs, repo-owned flake packages,",
		"# per-config builds. The gate tolerates these; they compile at switch",
		"# time, so review the cost of every newly added entry (the writer",
		"# prints them). Regenerate with: just gate-baseline",
		"# (cold store, own cache excluded: the own cache only proves what a",
		"# PAST run pushed, not what a candidate lock will need). Re-measuring",
		"# MERGES with existing entries - an incremental cache means one",
		"# measurement only ever sees a delta; prune by hand when a package",
		"# leaves the config. BLOCK-pattern matches are never written.",
		"# Last measured " + measuredDate + " against " + rev + ".",
	}
}

// Merge unions the existing baseline with newly measured pnames, drops any
// pname matching isBlocked (applied to the union, so a BLOCK rule added
// after the fact prunes an old entry too), and returns the new sorted pname
// list plus the ones added relative to the existing file - plan-gate.sh's
// `sort -u` merge and `comm -13` added-set (lines 546-578).
func Merge(existingText string, measured []string, isBlocked func(string) bool) (kept, added []string) {
	old := Load(existingText)
	union := map[string]struct{}{}
	for p := range old {
		union[p] = struct{}{}
	}
	for _, p := range measured {
		union[p] = struct{}{}
	}
	all := make([]string, 0, len(union))
	for p := range union {
		all = append(all, p)
	}
	sort.Strings(all)
	for _, p := range all {
		if !isBlocked(p) {
			kept = append(kept, p)
		}
	}
	for _, p := range kept {
		if _, ok := old[p]; !ok {
			added = append(added, p)
		}
	}
	return kept, added
}

// Render assembles the full baseline file text: header comment block, then
// one pname per line.
func Render(header, pnames []string) string {
	var b strings.Builder
	for _, h := range header {
		b.WriteString(h)
		b.WriteString("\n")
	}
	for _, p := range pnames {
		b.WriteString(p)
		b.WriteString("\n")
	}
	return b.String()
}
