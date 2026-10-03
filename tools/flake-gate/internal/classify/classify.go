// Package classify decodes `nix derivation show` schema v4 and sorts every
// BUILD-section derivation into fod / local-by-policy / check, plus a
// trivial-builder flag, porting plan-gate.sh's jq pipeline (lines ~355-390).
package classify

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// Kind mirrors the 3rd column plan-gate.sh's jq emits.
type Kind string

const (
	FOD   Kind = "fod"
	Local Kind = "local"
	Check Kind = "check"
)

// Row is one classified BUILD derivation.
type Row struct {
	Drv     string // schema-v4 key, "<hash>-<name>.drv" (store-relative)
	Out     string // output path ("" for a FOD - must never reach the probe)
	Kind    Kind
	System  string
	Trivial bool
}

// Derivation mirrors enough of schema v4 to replicate the jq classifier.
// Env values are plain strings in v4; structuredAttrs carries real JSON
// types, decoded loosely via interface{}.
type Derivation struct {
	Env             map[string]string      `json:"env"`
	StructuredAttrs map[string]interface{} `json:"structuredAttrs"`
	System          string                 `json:"system"`
	Outputs         map[string]Output      `json:"outputs"`
}

type Output struct {
	Path   string  `json:"path"`
	Hash   *string `json:"hash"` // presence, not value, marks a FOD (jq has("hash"))
	Method string  `json:"method"`
}

type showDoc struct {
	Derivations map[string]Derivation `json:"derivations"`
}

// stdenvNoCC matches plan-gate.sh's trivial-builder stdenv test: a store
// path ending "-stdenv-<word>-no-cc".
var stdenvNoCC = regexp.MustCompile(`^/nix/store/[0-9a-z]{32}-stdenv-[a-z0-9]+-no-cc$`)

// Parse decodes one or more `nix derivation show` documents (xargs may
// split a large build-drvs list across invocations; jq -rs slurps and
// merges them - callers pass each invocation's raw output here).
func Parse(jsonDocs ...[]byte) (map[string]Derivation, error) {
	merged := map[string]Derivation{}
	for i, doc := range jsonDocs {
		if len(strings.TrimSpace(string(doc))) == 0 {
			continue
		}
		var d showDoc
		if err := json.Unmarshal(doc, &d); err != nil {
			return nil, fmt.Errorf("decoding derivation-show doc %d: %w", i, err)
		}
		for k, v := range d.Derivations {
			merged[k] = v
		}
	}
	return merged, nil
}

// Classify turns decoded derivations into Rows, sorted by Drv so output
// order is deterministic (jq's to_entries has no guaranteed order).
func Classify(derivs map[string]Derivation) []Row {
	rows := make([]Row, 0, len(derivs))
	for drv, d := range derivs {
		rows = append(rows, classifyOne(drv, d))
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Drv < rows[j].Drv })
	return rows
}

func classifyOne(drv string, d Derivation) Row {
	out, fod := resolveOutput(d.Outputs)
	row := Row{Drv: drv, Out: out, System: d.System}
	switch {
	case fod:
		row.Kind = FOD
		row.Out = "" // plan-gate.sh:338-340 - a FOD row must never reach the probe
	case isLocalPolicy(d):
		row.Kind = Local
	default:
		row.Kind = Check
	}
	row.Trivial = isTrivial(d)
	return row
}

// resolveOutput mirrors:
//
//	(.outputs.out.path // (.outputs | to_entries[0].value.path)) // ""
//
// fod is true when any output carries a "hash" key (v4's FOD shape has
// {hash,method} and no path).
func resolveOutput(outputs map[string]Output) (path string, fod bool) {
	for _, o := range outputs {
		if o.Hash != nil {
			fod = true
		}
	}
	if o, ok := outputs["out"]; ok && o.Path != "" {
		return o.Path, fod
	}
	// jq's to_entries[0] has no stable order either; take the lowest key
	// deterministically.
	keys := make([]string, 0, len(outputs))
	for k := range outputs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if outputs[k].Path != "" {
			return outputs[k].Path, fod
		}
	}
	return "", fod
}

// isLocalPolicy mirrors the jq $e/$s preferLocalBuild/allowSubstitutes
// disjunction, including the legacy env.__json fallback for pre-v4 nix.
func isLocalPolicy(d Derivation) bool {
	e, s := d.Env, d.StructuredAttrs
	if e["preferLocalBuild"] == "1" {
		return true
	}
	if v, ok := e["allowSubstitutes"]; ok && v == "" {
		return true
	}
	if b, ok := s["preferLocalBuild"].(bool); ok && b {
		return true
	}
	if b, ok := s["allowSubstitutes"].(bool); ok && !b {
		return true
	}
	if raw, ok := e["__json"]; ok && raw != "" {
		var legacy struct {
			PreferLocalBuild *bool `json:"preferLocalBuild"`
			AllowSubstitutes *bool `json:"allowSubstitutes"`
		}
		if json.Unmarshal([]byte(raw), &legacy) == nil {
			if legacy.PreferLocalBuild != nil && *legacy.PreferLocalBuild {
				return true
			}
			if legacy.AllowSubstitutes != nil && !*legacy.AllowSubstitutes {
				return true
			}
		}
	}
	return false
}

// isTrivial mirrors the two cheap-by-construction shapes: an inline
// buildCommand with no source under a compiler-less stdenv, or a fetchNupkg
// repack (src ends in ".nupkg", no buildCommand - phases are used instead).
// BLOCK is checked BEFORE this in the policy stage, deliberately.
func isTrivial(d Derivation) bool {
	e, s := d.Env, d.StructuredAttrs
	stdenv := firstString(e["stdenv"], anyToString(s["stdenv"]))
	if !stdenvNoCC.MatchString(stdenv) {
		return false
	}
	src := firstString(e["src"], anyToString(s["src"]))
	if strings.HasSuffix(src, ".nupkg") {
		return true
	}
	_, eHasBuildCmd := e["buildCommand"]
	_, sHasBuildCmd := s["buildCommand"]
	srcs := firstString(e["srcs"], anyToString(s["srcs"]))
	return (eHasBuildCmd || sHasBuildCmd) && src == "" && srcs == "" && len(d.Outputs) == 1
}

// firstString mirrors jq's `$e.x // $s.x // ""` fallback order.
func firstString(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func anyToString(v interface{}) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}
