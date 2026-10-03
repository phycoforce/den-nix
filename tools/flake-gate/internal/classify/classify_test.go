package classify

import (
	"os"
	"testing"
)

func mustClassifyOne(t *testing.T, doc string) Row {
	t.Helper()
	derivs, err := Parse([]byte(doc))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	rows := Classify(derivs)
	if len(rows) != 1 {
		t.Fatalf("got %d rows, want 1: %+v", len(rows), rows)
	}
	return rows[0]
}

func TestClassify_PlainEnvPreferLocalBuild(t *testing.T) {
	doc := `{"derivations":{"h1-foo.drv":{
		"env":{"preferLocalBuild":"1","stdenv":"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-stdenv-linux"},
		"system":"x86_64-linux",
		"outputs":{"out":{"path":"h1-foo"}}
	}}}`
	if r := mustClassifyOne(t, doc); r.Kind != Local {
		t.Fatalf("Kind = %q, want local (plain env preferLocalBuild=1)", r.Kind)
	}
}

func TestClassify_PlainEnvAllowSubstitutesFalse(t *testing.T) {
	// nix's plain-env convention: a false boolean renders as "".
	doc := `{"derivations":{"h1-foo.drv":{
		"env":{"allowSubstitutes":"","stdenv":"x"},
		"system":"x86_64-linux",
		"outputs":{"out":{"path":"h1-foo"}}
	}}}`
	if r := mustClassifyOne(t, doc); r.Kind != Local {
		t.Fatalf("Kind = %q, want local (allowSubstitutes=\"\" means false)", r.Kind)
	}
}

func TestClassify_StructuredAttrsOnlyPreferLocalBuild(t *testing.T) {
	// The 2026-08-02 blind spot (d2bae36): nixpkgs defaults many packages
	// to structuredAttrs, where every plain .env key is absent. A
	// classifier reading only env.preferLocalBuild never fires here.
	doc := `{"derivations":{"h1-foo.drv":{
		"env":{"__structuredAttrs":""},
		"structuredAttrs":{"preferLocalBuild":true,"stdenv":"x"},
		"system":"x86_64-linux",
		"outputs":{"out":{"path":"h1-foo"}}
	}}}`
	if r := mustClassifyOne(t, doc); r.Kind != Local {
		t.Fatalf("Kind = %q, want local (structuredAttrs.preferLocalBuild=true, no plain-env equivalent)", r.Kind)
	}
}

func TestClassify_StructuredAttrsAllowSubstitutesFalse(t *testing.T) {
	doc := `{"derivations":{"h1-foo.drv":{
		"structuredAttrs":{"allowSubstitutes":false},
		"system":"x86_64-linux",
		"outputs":{"out":{"path":"h1-foo"}}
	}}}`
	if r := mustClassifyOne(t, doc); r.Kind != Local {
		t.Fatalf("Kind = %q, want local (structuredAttrs.allowSubstitutes=false)", r.Kind)
	}
}

func TestClassify_FOD_NoOutputPath(t *testing.T) {
	// Schema v4's FOD shape: {hash,method}, no "path" at all. Out must be
	// forced to "" so it can never reach the probe stage.
	doc := `{"derivations":{"h1-src.drv":{
		"env":{},
		"system":"x86_64-linux",
		"outputs":{"out":{"hash":"deadbeef","method":"flat"}}
	}}}`
	r := mustClassifyOne(t, doc)
	if r.Kind != FOD {
		t.Fatalf("Kind = %q, want fod", r.Kind)
	}
	if r.Out != "" {
		t.Fatalf("Out = %q, want \"\" (a FOD row must never carry a probeable output path)", r.Out)
	}
}

func TestClassify_CheckRow(t *testing.T) {
	doc := `{"derivations":{"h1-ordinary.drv":{
		"env":{"name":"ordinary"},
		"system":"x86_64-linux",
		"outputs":{"out":{"path":"h1-ordinary"}}
	}}}`
	r := mustClassifyOne(t, doc)
	if r.Kind != Check {
		t.Fatalf("Kind = %q, want check", r.Kind)
	}
	if r.Out != "h1-ordinary" {
		t.Fatalf("Out = %q", r.Out)
	}
}

func TestClassify_TrivialInlineBuildCommandNoSrc(t *testing.T) {
	doc := `{"derivations":{"h1-etc.drv":{
		"env":{"stdenv":"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-stdenv-linux-no-cc","buildCommand":"mkdir -p $out","src":"","srcs":""},
		"system":"x86_64-linux",
		"outputs":{"out":{"path":"h1-etc"}}
	}}}`
	if r := mustClassifyOne(t, doc); !r.Trivial {
		t.Fatalf("expected Trivial=true for an inline buildCommand with no source under a compiler-less stdenv")
	}
}

func TestClassify_TrivialNupkgRepack(t *testing.T) {
	// a9bc00c's carve-out: a fetchNupkg repack has phases, not
	// buildCommand, so it's detected by src ending in ".nupkg" instead.
	doc := `{"derivations":{"h1-SomePkg.1.2.3.nupkg.drv":{
		"env":{"stdenv":"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-stdenv-linux-no-cc","src":"h2-SomePkg.1.2.3.nupkg"},
		"system":"x86_64-linux",
		"outputs":{"out":{"path":"h1-out"}}
	}}}`
	if r := mustClassifyOne(t, doc); !r.Trivial {
		t.Fatalf("expected Trivial=true for a .nupkg repack")
	}
}

func TestClassify_NotTrivialWithRealSource(t *testing.T) {
	// BLOCK-precedence depends on this NOT firing for llvm-src-shaped
	// derivations with a real source under a compiler-less stdenv.
	doc := `{"derivations":{"h1-llvm-src.drv":{
		"env":{"stdenv":"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-stdenv-linux-no-cc","buildCommand":"cp -r $src $out","src":"h2-llvm-source"},
		"system":"x86_64-linux",
		"outputs":{"out":{"path":"h1-out"}}
	}}}`
	if r := mustClassifyOne(t, doc); r.Trivial {
		t.Fatalf("expected Trivial=false when src is non-empty and it's not a .nupkg - this is exactly the shape BLOCK must still catch")
	}
}

func TestClassify_I686System(t *testing.T) {
	doc := `{"derivations":{"h1-foo.drv":{
		"env":{"name":"foo"},
		"system":"i686-linux",
		"outputs":{"out":{"path":"h1-foo"}}
	}}}`
	r := mustClassifyOne(t, doc)
	if r.System != "i686-linux" || r.Kind != Check {
		t.Fatalf("got System=%q Kind=%q, want i686-linux/check", r.System, r.Kind)
	}
}

func TestClassify_MultiDocMerge(t *testing.T) {
	// xargs may split a large build-drvs list across several `nix
	// derivation show` invocations; Parse must merge them like `jq -rs`.
	doc1 := `{"derivations":{"h1-a.drv":{"env":{},"system":"x86_64-linux","outputs":{"out":{"path":"h1-a"}}}}}`
	doc2 := `{"derivations":{"h2-b.drv":{"env":{},"system":"x86_64-linux","outputs":{"out":{"path":"h2-b"}}}}}`
	derivs, err := Parse([]byte(doc1), []byte(doc2))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if rows := Classify(derivs); len(rows) != 2 {
		t.Fatalf("got %d rows, want 2", len(rows))
	}
}

func TestClassify_RealDerivationShowFixture(t *testing.T) {
	data, err := os.ReadFile("../../testdata/real-drvs.json")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	derivs, err := Parse(data)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	rows := Classify(derivs)
	if len(rows) != 10 {
		t.Fatalf("got %d rows, want 10 (real home-manager-bump plan)", len(rows))
	}
	var local, check int
	var sawPlainEnvLocal, sawStructuredAttrsLocal bool
	for _, r := range rows {
		switch r.Kind {
		case Local:
			local++
		case Check:
			check++
		case FOD:
			t.Fatalf("unexpected fod row in this fixture: %+v", r)
		}
		if r.Drv == "1dy2qi5xbr705f9ij4l91y8pvz8gqg30-home-manager-generation.drv" && r.Kind == Local {
			sawPlainEnvLocal = true
		}
		if r.Drv == "xvh1xh3hz4b9pbw6xj8ljb91q5jmvafq-home-manager-path.drv" && r.Kind == Local {
			sawStructuredAttrsLocal = true
		}
	}
	// Captured run: 8 local-by-policy (3 plain-env, 5 structuredAttrs-only)
	// + 2 check (later probed unserved and classified as config-artifacts).
	if local != 8 {
		t.Fatalf("local = %d, want 8", local)
	}
	if check != 2 {
		t.Fatalf("check = %d, want 2", check)
	}
	if !sawPlainEnvLocal {
		t.Fatalf("expected home-manager-generation.drv (plain-env preferLocalBuild) classified local")
	}
	if !sawStructuredAttrsLocal {
		t.Fatalf("expected home-manager-path.drv (structuredAttrs-only preferLocalBuild) classified local - the real-world shape of the Aug-02 blind spot")
	}
}
