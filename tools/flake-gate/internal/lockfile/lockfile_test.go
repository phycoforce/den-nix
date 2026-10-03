package lockfile

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writeLock writes a flake.lock where a node literally named "nixpkgs" is a
// DECOY (e.g. nix-cachyos-kernel's own pin) - root's real nixpkgs is a
// different node, reached only through root.inputs.nixpkgs. Any resolver
// that looks up l.Nodes["nixpkgs"] directly would silently use the decoy.
func writeLock(t *testing.T, lastModified int64, rev string) string {
	t.Helper()
	data := `{
  "nodes": {
    "root": {"inputs": {"nixpkgs": "nixpkgs_2"}},
    "nixpkgs": {"locked": {"lastModified": 1, "rev": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}},
    "nixpkgs_2": {"locked": {"lastModified": ` + itoa(lastModified) + `, "rev": "` + rev + `"}}
  }
}`
	p := filepath.Join(t.TempDir(), "flake.lock")
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		t.Fatalf("writing fixture: %v", err)
	}
	return p
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}

func TestRootNixpkgsAgeDays_ResolvesAliasNotLiteralName(t *testing.T) {
	fiveDaysAgo := time.Now().Add(-5 * 24 * time.Hour).Unix()
	p := writeLock(t, fiveDaysAgo, "cafecafecafecafecafecafecafecafecafecafe")
	age, ok := RootNixpkgsAgeDays(p)
	if !ok {
		t.Fatalf("expected ok=true")
	}
	if age != 5 {
		t.Fatalf("age = %d, want 5 (must resolve root.inputs.nixpkgs -> nixpkgs_2, never the decoy node literally named \"nixpkgs\")", age)
	}
}

func TestRootNixpkgsRev12_ResolvesAliasNotLiteralName(t *testing.T) {
	p := writeLock(t, time.Now().Unix(), "cafecafecafecafecafecafecafecafecafecafe")
	rev, err := RootNixpkgsRev12(p)
	if err != nil {
		t.Fatalf("RootNixpkgsRev12: %v", err)
	}
	if rev != "cafecafecafe" {
		t.Fatalf("rev = %q, want %q (12-char prefix of the ALIASED node's rev, not the decoy's)", rev, "cafecafecafe")
	}
}

func TestRootNixpkgsAgeDays_MissingFileIsBestEffort(t *testing.T) {
	_, ok := RootNixpkgsAgeDays(filepath.Join(t.TempDir(), "nope.lock"))
	if ok {
		t.Fatalf("expected ok=false for a missing flake.lock, never an error/panic")
	}
}

func TestRootNixpkgsAgeDays_MalformedLockIsBestEffort(t *testing.T) {
	p := filepath.Join(t.TempDir(), "flake.lock")
	os.WriteFile(p, []byte("{not json"), 0o644)
	if _, ok := RootNixpkgsAgeDays(p); ok {
		t.Fatalf("expected ok=false for malformed JSON")
	}
}
