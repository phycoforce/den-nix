package nixplan

import (
	"os"
	"strings"
	"testing"
)

func TestParse_EmptyPlan(t *testing.T) {
	p := Parse("warning: Git tree is dirty\n")
	if p.HeaderCount != 0 || p.BuildCount != 0 || p.FetchCount != 0 {
		t.Fatalf("got %+v, want all zero", p)
	}
}

func TestParse_SingularBuild(t *testing.T) {
	text := "this derivation will be built:\n  /nix/store/abcdefghijklmnopqrstuvwxyz012345-foo.drv\n"
	p := Parse(text)
	if p.BuildCount != 1 {
		t.Fatalf("BuildCount = %d, want 1", p.BuildCount)
	}
	if p.Records[0].StorePath != "/nix/store/abcdefghijklmnopqrstuvwxyz012345-foo.drv" {
		t.Fatalf("unexpected record: %+v", p.Records[0])
	}
}

func TestParse_PluralBuild(t *testing.T) {
	text := "these 2 derivations will be built:\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-foo.drv\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012346-bar.drv\n"
	if p := Parse(text); p.BuildCount != 2 {
		t.Fatalf("BuildCount = %d, want 2", p.BuildCount)
	}
}

func TestParse_FetchSingularAndPlural(t *testing.T) {
	text := "this path will be fetched (1.23 MiB download, 4.56 MiB unpacked):\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-foo\n"
	p := Parse(text)
	if p.FetchCount != 1 {
		t.Fatalf("FetchCount = %d, want 1", p.FetchCount)
	}
	if p.Download != "(1.23 MiB download, 4.56 MiB unpacked)" {
		t.Fatalf("Download = %q", p.Download)
	}
	text2 := "these 3 paths will be fetched (10 KiB download, 20 KiB unpacked):\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-a\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012346-b\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012347-c\n"
	if p2 := Parse(text2); p2.FetchCount != 3 {
		t.Fatalf("FetchCount = %d, want 3", p2.FetchCount)
	}
}

func TestParse_CopySection(t *testing.T) {
	text := "these 2 paths will be copied (3.00 GiB download, 9.00 GiB unpacked):\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-a\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012346-b\n"
	p := Parse(text)
	if len(p.Records) != 2 || p.Records[0].Section != Copy {
		t.Fatalf("expected 2 COPY records, got %+v", p.Records)
	}
}

func TestParse_UnknownSection(t *testing.T) {
	text := "don't know how to build these paths (may be on an unsupported system):\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-a\n"
	p := Parse(text)
	if p.UnknownCount != 1 {
		t.Fatalf("UnknownCount = %d, want 1", p.UnknownCount)
	}
	if got := p.UnknownPaths(); len(got) != 1 || got[0] != "/nix/store/abcdefghijklmnopqrstuvwxyz012345-a" {
		t.Fatalf("UnknownPaths() = %v", got)
	}
}

func TestParse_UnknownApostropheVariant(t *testing.T) {
	// bash's awk pattern uses "don.t" (a wildcard, not a literal
	// apostrophe) so either glyph matches - mirrored on purpose.
	text := "don’t know how to build these paths:\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-a\n"
	if p := Parse(text); p.UnknownCount != 1 {
		t.Fatalf("UnknownCount = %d, want 1 (apostrophe-tolerant match)", p.UnknownCount)
	}
}

func TestParse_WarningsInterleaved(t *testing.T) {
	text := "these 2 derivations will be built:\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-a.drv\n" +
		"warning: some unrelated warning\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012346-b.drv\n" +
		"this path will be fetched (1 KiB download, 1 KiB unpacked):\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012347-c\n"
	p := Parse(text)
	if p.BuildCount != 1 {
		t.Fatalf("BuildCount = %d, want 1 (warning should close the BUILD section)", p.BuildCount)
	}
	if p.FetchCount != 1 {
		t.Fatalf("FetchCount = %d, want 1", p.FetchCount)
	}
}

func TestPlan_BuildDrvs_SortedDeduped(t *testing.T) {
	text := "these 3 derivations will be built:\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012347-c.drv\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-a.drv\n" +
		"  /nix/store/abcdefghijklmnopqrstuvwxyz012345-a.drv\n"
	got := Parse(text).BuildDrvs()
	want := []string{
		"/nix/store/abcdefghijklmnopqrstuvwxyz012345-a.drv",
		"/nix/store/abcdefghijklmnopqrstuvwxyz012347-c.drv",
	}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("BuildDrvs() = %v, want %v", got, want)
	}
}

func TestCheckDegradedNetwork_HTTP5xx(t *testing.T) {
	plan := "error: unable to download 'https://cache.xinux.uz/abc.narinfo': HTTP error 502\n" +
		"error: unable to download 'https://cache.xinux.uz/def.narinfo': HTTP error 502\n"
	r := CheckDegradedNetwork(plan, 1)
	if !r.CannotJudge {
		t.Fatalf("expected CannotJudge for a 502 on a non-zero nix exit, got %+v", r)
	}
	if !strings.Contains(strings.Join(r.Evidence, "\n"), "cache.xinux.uz answered HTTP 502 (x2)") {
		t.Fatalf("evidence missing collapsed per-host count: %v", r.Evidence)
	}
}

func TestCheckDegradedNetwork_ErrorNotOnFirstLine(t *testing.T) {
	// Real nix stderr leads with warnings; the 2026-10-03 502 storm did.
	plan := "warning: Git tree '/repo' is dirty\n" +
		"error (ignored): unable to download 'https://cache.xinux.uz/abc.narinfo': HTTP error 502\n" +
		"       error: unable to download 'https://cache.xinux.uz/def.narinfo': HTTP error 502\n"
	if r := CheckDegradedNetwork(plan, 1); !r.CannotJudge {
		t.Fatalf("a 5xx after other lines must still be cannot-judge, got %+v", r)
	}
	daemon := "warning: Git tree '/repo' is dirty\nerror: Nix daemon disconnected unexpectedly (maybe it crashed?)\n"
	if r := CheckDegradedNetwork(daemon, 1); !r.CannotJudge || !r.DaemonDied {
		t.Fatalf("a daemon crash after other lines must still be cannot-judge, got %+v", r)
	}
}

func TestCheckDegradedNetwork_408And429(t *testing.T) {
	for _, code := range []string{"408", "429"} {
		plan := "error: unable to download 'https://example.org/x.narinfo': HTTP error " + code + "\n"
		if r := CheckDegradedNetwork(plan, 1); !r.CannotJudge {
			t.Fatalf("code %s: expected CannotJudge, got %+v", code, r)
		}
	}
}

func TestCheckDegradedNetwork_GenericTransportError(t *testing.T) {
	plan := "error: unable to download 'https://example.org/x.narinfo': Couldn't connect to server (7)\n"
	if r := CheckDegradedNetwork(plan, 1); !r.CannotJudge {
		t.Fatalf("expected CannotJudge for a generic curl-style transport error, got %+v", r)
	}
}

func TestCheckDegradedNetwork_RateLimit(t *testing.T) {
	plan := "error: API rate limit exceeded for installation ID 12345.\n"
	if r := CheckDegradedNetwork(plan, 1); !r.CannotJudge {
		t.Fatalf("expected CannotJudge for GitHub rate-limit text, got %+v", r)
	}
}

func TestCheckDegradedNetwork_DaemonDisconnected(t *testing.T) {
	plan := "error: Nix daemon disconnected unexpectedly (maybe it crashed?)\n"
	r := CheckDegradedNetwork(plan, 1)
	if !r.CannotJudge || !r.DaemonDied {
		t.Fatalf("expected CannotJudge+DaemonDied for a daemon crash, got %+v", r)
	}
}

func TestCheckDegradedNetwork_GenericEvalFailureIsNotNetwork(t *testing.T) {
	plan := "error: attribute 'doesNotExist' missing\n"
	if r := CheckDegradedNetwork(plan, 1); r.CannotJudge {
		t.Fatalf("a plain eval error must NOT be reclassified as cannot-judge, got %+v", r)
	}
}

func TestCheckDegradedNetwork_CacheInfoDownWithZeroExit(t *testing.T) {
	// nix can exit 0 yet still have failed to reach nix-cache-info - the
	// case that silently reclassifies fetches as builds, not a hard error.
	plan := "warning: unable to download 'https://dead.example/nix-cache-info': timeout\n" +
		"this derivation will be built:\n  /nix/store/abcdefghijklmnopqrstuvwxyz012345-a.drv\n"
	if r := CheckDegradedNetwork(plan, 0); !r.CannotJudge {
		t.Fatalf("expected CannotJudge when nix-cache-info was unreachable even on exit 0, got %+v", r)
	}
}

func TestParse_RealCapturedPlan(t *testing.T) {
	data, err := os.ReadFile("../../testdata/real-plan.txt")
	if err != nil {
		t.Fatalf("reading fixture: %v", err)
	}
	p := Parse(string(data))
	if p.BuildCount != 10 || p.FetchCount != 0 || p.UnknownCount != 0 {
		t.Fatalf("real-plan.txt: got build=%d fetch=%d unknown=%d, want 10/0/0", p.BuildCount, p.FetchCount, p.UnknownCount)
	}
	if len(p.BuildDrvs()) != 10 {
		t.Fatalf("real-plan.txt: BuildDrvs() = %d, want 10", len(p.BuildDrvs()))
	}
}
