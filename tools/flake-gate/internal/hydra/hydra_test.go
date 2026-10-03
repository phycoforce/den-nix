package hydra

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// build is a canned /api/latestbuilds row plus the /build/<id> detail
// (keyed by id) the test server serves.
type build struct {
	ID          int
	BuildStatus *int
	Finished    int
	OutputHash  string // "" = no outputs / never matches
}

func ptr(n int) *int { return &n }

func newServer(t *testing.T, builds []build, latestbuildsStatus int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/latestbuilds"):
			if latestbuildsStatus != 0 {
				w.WriteHeader(latestbuildsStatus)
				return
			}
			type row struct {
				ID          int  `json:"id"`
				BuildStatus *int `json:"buildstatus"`
				Finished    int  `json:"finished"`
			}
			var out []row
			for _, b := range builds {
				out = append(out, row{ID: b.ID, BuildStatus: b.BuildStatus, Finished: b.Finished})
			}
			json.NewEncoder(w).Encode(out)
		case strings.HasPrefix(r.URL.Path, "/build/"):
			var id int
			fmt.Sscanf(strings.TrimPrefix(r.URL.Path, "/build/"), "%d", &id)
			for _, b := range builds {
				if b.ID == id {
					resp := map[string]any{}
					if b.OutputHash != "" {
						resp["buildoutputs"] = map[string]any{"out": map[string]string{"path": "/nix/store/" + b.OutputHash + "-pkg"}}
					} else {
						resp["buildoutputs"] = map[string]any{}
					}
					json.NewEncoder(w).Encode(resp)
					return
				}
			}
			w.WriteHeader(404)
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

const candidateOut = "cafef00dcafef00dcafef00dcafef00d-pkg"
const candidateHash = "cafef00dcafef00dcafef00dcafef00d"

func TestVerdict_NoHydraJob(t *testing.T) {
	srv := newServer(t, nil, 0)
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
	v := c.Verdict(context.Background(), "some-pkg", candidateOut, "x86_64-linux")
	if v.Class != NoJob {
		t.Fatalf("Class = %q, want no-hydra-job: %+v", v.Class, v)
	}
	if !strings.Contains(v.Detail, "nixpkgs.some-pkg.x86_64-linux") {
		t.Fatalf("Detail = %q, missing job name", v.Detail)
	}
}

func TestVerdict_Unreachable(t *testing.T) {
	srv := newServer(t, nil, 500)
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
	v := c.Verdict(context.Background(), "some-pkg", candidateOut, "x86_64-linux")
	if v.Class != Inconclusive || !strings.Contains(v.Detail, "Hydra unreachable") {
		t.Fatalf("got %+v, want inconclusive/unreachable", v)
	}
}

func TestVerdict_FailedUpstream_ExactHashMatch(t *testing.T) {
	srv := newServer(t, []build{{ID: 1, BuildStatus: ptr(1), Finished: 1, OutputHash: candidateHash}}, 0)
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
	v := c.Verdict(context.Background(), "some-pkg", candidateOut, "x86_64-linux")
	if v.Class != FailedUpstream {
		t.Fatalf("Class = %q, want failed-upstream: %+v", v.Class, v)
	}
	if !strings.Contains(v.Detail, "failed on Hydra for this exact output") || !strings.Contains(v.Detail, "/build/1") {
		t.Fatalf("Detail = %q", v.Detail)
	}
}

func TestVerdict_FailedUpstream_LaterBuildSucceeded(t *testing.T) {
	// "Hydra green != cached": the newest build (id 2) succeeded under a
	// DIFFERENT output hash than the one this lock's candidate needs - the
	// older, failed build (id 1) is the one matching by exact hash.
	builds := []build{
		{ID: 2, BuildStatus: ptr(0), Finished: 1, OutputHash: "feedfacefeedfacefeedfacefeedface"},
		{ID: 1, BuildStatus: ptr(1), Finished: 1, OutputHash: candidateHash},
	}
	srv := newServer(t, builds, 0)
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
	v := c.Verdict(context.Background(), "some-pkg", candidateOut, "x86_64-linux")
	if v.Class != FailedUpstream {
		t.Fatalf("Class = %q, want failed-upstream: %+v", v.Class, v)
	}
	if !strings.Contains(v.Detail, "a later build succeeded (") || !strings.Contains(v.Detail, "/build/2") {
		t.Fatalf("Detail = %q, missing the later-build-succeeded suffix", v.Detail)
	}
}

func TestVerdict_Pending_NotFinished(t *testing.T) {
	srv := newServer(t, []build{{ID: 1, Finished: 0, OutputHash: candidateHash}}, 0)
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
	v := c.Verdict(context.Background(), "some-pkg", candidateOut, "x86_64-linux")
	if v.Class != Pending || !strings.Contains(v.Detail, "queued on Hydra, not built yet") {
		t.Fatalf("got %+v", v)
	}
}

func TestVerdict_Pending_SucceededButNotCached(t *testing.T) {
	srv := newServer(t, []build{{ID: 1, BuildStatus: ptr(0), Finished: 1, OutputHash: candidateHash}}, 0)
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
	v := c.Verdict(context.Background(), "some-pkg", candidateOut, "x86_64-linux")
	if v.Class != Pending || !strings.Contains(v.Detail, "no cache serves it yet") {
		t.Fatalf("got %+v", v)
	}
}

func TestVerdict_Pending_AbortedOrCancelled(t *testing.T) {
	for _, status := range []int{3, 4} {
		srv := newServer(t, []build{{ID: 1, BuildStatus: ptr(status), Finished: 1, OutputHash: candidateHash}}, 0)
		c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
		v := c.Verdict(context.Background(), "some-pkg", candidateOut, "x86_64-linux")
		if v.Class != Pending || !strings.Contains(v.Detail, "may be retried") {
			t.Fatalf("status %d: got %+v", status, v)
		}
	}
}

func TestVerdict_Inconclusive_NoMatchInLast10(t *testing.T) {
	srv := newServer(t, []build{{ID: 1, BuildStatus: ptr(0), Finished: 1, OutputHash: "00000000000000000000000000000000"}}, 0)
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
	v := c.Verdict(context.Background(), "some-pkg", candidateOut, "x86_64-linux")
	if v.Class != Inconclusive || !strings.Contains(v.Detail, "last 10 builds made this output") {
		t.Fatalf("got %+v", v)
	}
}

func TestVerdict_BudgetExhausted(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		json.NewEncoder(w).Encode([]any{})
	}))
	defer srv.Close()
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 1}
	v1 := c.Verdict(context.Background(), "pkg-a", candidateOut, "x86_64-linux")
	if v1.Class != NoJob {
		t.Fatalf("first lookup should spend the budget normally, got %+v", v1)
	}
	v2 := c.Verdict(context.Background(), "pkg-b", candidateOut, "x86_64-linux")
	if v2.Class != Inconclusive || !strings.Contains(v2.Detail, "budget of 1 spent") {
		t.Fatalf("second lookup should be budget-skipped, got %+v", v2)
	}
	if calls != 1 {
		t.Fatalf("got %d HTTP calls, want exactly 1 (the skipped lookup must not touch the network)", calls)
	}
}

func TestVerdict_JobsetSplitAndSystemDefault(t *testing.T) {
	var gotQuery url.Values
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/latestbuilds") {
			gotQuery = r.URL.Query()
		}
		json.NewEncoder(w).Encode([]any{})
	}))
	defer srv.Close()
	c := &Client{BaseURL: srv.URL, Jobset: "nixos/unstable", MaxLookups: 10}
	c.Verdict(context.Background(), "some-pkg", candidateOut, "") // system left blank
	if gotQuery.Get("project") != "nixos" || gotQuery.Get("jobset") != "unstable" {
		t.Fatalf("got project=%q jobset=%q, want nixos/unstable split", gotQuery.Get("project"), gotQuery.Get("jobset"))
	}
	if gotQuery.Get("job") != "nixpkgs.some-pkg.x86_64-linux" {
		t.Fatalf("job = %q, want system to default to x86_64-linux", gotQuery.Get("job"))
	}
}

func TestStatusName(t *testing.T) {
	cases := map[string]string{
		"0": "succeeded", "1": "failed", "2": "dependency failed", "3": "aborted",
		"4": "cancelled", "6": "failed with output", "7": "timed out",
		"9": "unsupported system", "10": "log limit exceeded", "11": "output limit exceeded",
		"12": "non-deterministic", "42": "status 42",
	}
	for in, want := range cases {
		if got := statusName(in); got != want {
			t.Errorf("statusName(%q) = %q, want %q", in, got, want)
		}
	}
}
