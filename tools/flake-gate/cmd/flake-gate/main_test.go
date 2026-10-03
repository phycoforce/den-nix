package main

import (
	"io"
	"testing"

	"github.com/phycoforce/den-nix/tools/flake-gate/internal/gate"
)

func TestParseGateArgs_DashDashPassthrough(t *testing.T) {
	// just check-tip's exact shape: -- --override-input nixpkgs
	// github:NixOS/nixpkgs/<rev>.
	a, err := parseGateArgs([]string{
		"--cold", "--policy", "/p.json", "--repo", "/r",
		"--", "--override-input", "nixpkgs", "github:NixOS/nixpkgs/abc123",
	}, io.Discard)
	if err != nil {
		t.Fatalf("parseGateArgs: %v", err)
	}
	if !a.Cold || a.PolicyPath != "/p.json" || a.Repo != "/r" {
		t.Fatalf("got %+v", a)
	}
	want := []string{"--override-input", "nixpkgs", "github:NixOS/nixpkgs/abc123"}
	if len(a.Extra) != len(want) {
		t.Fatalf("Extra = %v, want %v", a.Extra, want)
	}
	for i := range want {
		if a.Extra[i] != want[i] {
			t.Fatalf("Extra = %v, want %v", a.Extra, want)
		}
	}
}

func TestParseGateArgs_NoExtraArgs(t *testing.T) {
	a, err := parseGateArgs([]string{"--write-baseline"}, io.Discard)
	if err != nil {
		t.Fatalf("parseGateArgs: %v", err)
	}
	if !a.WriteBaseline || len(a.Extra) != 0 {
		t.Fatalf("got %+v", a)
	}
}

func TestParseGateArgs_Defaults(t *testing.T) {
	a, err := parseGateArgs(nil, io.Discard)
	if err != nil {
		t.Fatalf("parseGateArgs: %v", err)
	}
	if a.Repo != "." || a.Cold || a.WriteBaseline || a.PolicyPath != "" || a.JSONPath != "" {
		t.Fatalf("got %+v, want zero-value defaults with Repo=\".\"", a)
	}
}

func TestParseGateArgs_UnknownFlagErrors(t *testing.T) {
	if _, err := parseGateArgs([]string{"--not-a-real-flag"}, io.Discard); err == nil {
		t.Fatalf("expected an error for an unknown flag")
	}
}

func TestVerdictString(t *testing.T) {
	cases := map[gate.Verdict]string{gate.Pass: "pass", gate.Violation: "fail", gate.CannotJudge: "cannot-judge"}
	for code, want := range cases {
		if got := verdictString(code); got != want {
			t.Errorf("verdictString(%d) = %q, want %q", code, got, want)
		}
	}
}
