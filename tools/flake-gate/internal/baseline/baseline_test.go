package baseline

import (
	"os"
	"testing"
)

func TestLoad_StripsCommentsAndBlankLines(t *testing.T) {
	text := "# a comment\n\nfoo\nbar\n  \n# another\nbaz\n"
	b := Load(text)
	for _, want := range []string{"foo", "bar", "baz"} {
		if !b.Tolerates(want) {
			t.Errorf("expected baseline to tolerate %q", want)
		}
	}
	if len(b) != 3 {
		t.Errorf("len(baseline) = %d, want 3 (comments/blanks must not count)", len(b))
	}
}

func TestLoad_RealFixture(t *testing.T) {
	data, err := os.ReadFile("../../testdata/real-baseline.txt")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	if b := Load(string(data)); len(b) == 0 {
		t.Fatalf("expected a non-empty real baseline")
	}
}

func notBlocked(string) bool { return false }

func TestMerge_UnionIsSortedAndDeduped(t *testing.T) {
	kept, added := Merge("foo\nbar\n", []string{"bar", "baz"}, notBlocked)
	wantKept := []string{"bar", "baz", "foo"}
	if !equal(kept, wantKept) {
		t.Fatalf("kept = %v, want %v", kept, wantKept)
	}
	if !equal(added, []string{"baz"}) {
		t.Fatalf("added = %v, want [baz]", added)
	}
}

func TestMerge_BlockRuleAddedLaterPrunesAnOldEntry(t *testing.T) {
	// plan-gate.sh's skip filter runs on the UNION (old+new): a BLOCK rule
	// added after the fact silently prunes a pname already in the file.
	isBlocked := func(p string) bool { return p == "now-blocked" }
	kept, added := Merge("now-blocked\nkept-fine\n", nil, isBlocked)
	if equalContains(kept, "now-blocked") {
		t.Fatalf("kept = %v, must not contain a pname that newly matches BLOCK", kept)
	}
	if !equalContains(kept, "kept-fine") {
		t.Fatalf("kept = %v, must still contain the unaffected entry", kept)
	}
	if len(added) != 0 {
		t.Fatalf("added = %v, want empty (nothing new was measured)", added)
	}
}

func TestMerge_NeverWritesABlockedMeasuredPname(t *testing.T) {
	isBlocked := func(p string) bool { return p == "niri" }
	kept, added := Merge("", []string{"niri", "ordinary-pkg"}, isBlocked)
	if equalContains(kept, "niri") {
		t.Fatalf("kept = %v, must never write a pname matching BLOCK", kept)
	}
	if !equalContains(added, "ordinary-pkg") {
		t.Fatalf("added = %v, want ordinary-pkg", added)
	}
}

func TestMerge_AddedIsRelativeToOldRawFile(t *testing.T) {
	// comm -13's "added" set is old-file-as-written vs new-file-post-filter
	// - re-measuring the SAME set twice must report nothing new.
	kept1, added1 := Merge("", []string{"foo", "bar"}, notBlocked)
	if len(added1) != 2 {
		t.Fatalf("first measurement: added = %v, want 2 new entries", added1)
	}
	existing := Render(nil, kept1)
	_, added2 := Merge(existing, []string{"foo", "bar"}, notBlocked)
	if len(added2) != 0 {
		t.Fatalf("second identical measurement: added = %v, want none (nothing new)", added2)
	}
}

func TestHeader_ExactText(t *testing.T) {
	h := Header("2026-10-03", "abc123def456")
	if len(h) != 11 {
		t.Fatalf("got %d header lines, want 11 (plan-gate.sh's exact comment block)", len(h))
	}
	if h[0] != "# Measured expected-local set: pnames no PUBLIC substituter serves at a" {
		t.Fatalf("h[0] = %q", h[0])
	}
	last := h[len(h)-1]
	if last != "# Last measured 2026-10-03 against abc123def456." {
		t.Fatalf("h[last] = %q", last)
	}
}

func TestRender_HeaderThenOnePnamePerLine(t *testing.T) {
	text := Render([]string{"# h1", "# h2"}, []string{"bar", "foo"})
	want := "# h1\n# h2\nbar\nfoo\n"
	if text != want {
		t.Fatalf("got %q, want %q", text, want)
	}
}

func equal(a, b []string) bool {
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

func equalContains(ss []string, v string) bool {
	for _, s := range ss {
		if s == v {
			return true
		}
	}
	return false
}
