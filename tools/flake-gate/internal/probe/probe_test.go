package probe

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func narinfoServer(t *testing.T, status int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestCheckHealth_UpAndDown(t *testing.T) {
	up := narinfoServer(t, 200)
	down := narinfoServer(t, 502)
	c := &Client{HealthTimeout: time.Second}
	health := c.CheckHealth(context.Background(), []string{up.URL, down.URL})
	if len(health) != 2 {
		t.Fatalf("got %d health results, want 2", len(health))
	}
	if !health[0].Up || health[0].Code != "200" {
		t.Fatalf("health[0] = %+v, want Up=true Code=200", health[0])
	}
	if health[1].Up || health[1].Code != "HTTP 502" {
		t.Fatalf("health[1] = %+v, want Up=false Code=\"HTTP 502\" (plan-gate.sh's `code=\"HTTP $code\"` convention)", health[1])
	}
}

func TestCheckHealth_Unreachable(t *testing.T) {
	c := &Client{HealthTimeout: 500 * time.Millisecond}
	health := c.CheckHealth(context.Background(), []string{"http://127.0.0.1:1"})
	if health[0].Up {
		t.Fatalf("expected an unreachable port to be Up=false")
	}
	if health[0].Code != "no response" {
		t.Fatalf("Code = %q, want %q (curl's \"000\" convention)", health[0].Code, "no response")
	}
}

func TestCheckHealth_PreservesOrder(t *testing.T) {
	a, b, c := narinfoServer(t, 200), narinfoServer(t, 200), narinfoServer(t, 200)
	cl := &Client{HealthTimeout: time.Second}
	health := cl.CheckHealth(context.Background(), []string{a.URL, b.URL, c.URL})
	if health[0].Sub != a.URL || health[1].Sub != b.URL || health[2].Sub != c.URL {
		t.Fatalf("health order must match the substituter list order (BLOCK hints name a specific, stable owner): %+v", health)
	}
}

func TestProbe_FirstInOrderWinsEvenIfSlower(t *testing.T) {
	// sub1 answers 200 but is SLOW; sub2 answers 200 FAST. List order must
	// still decide the winner, never a race - the determinism plan-gate.sh
	// relies on for its BLOCK-hint probe commands.
	slowSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(50 * time.Millisecond)
		w.WriteHeader(200)
	}))
	defer slowSrv.Close()
	fastSrv := narinfoServer(t, 200)

	c := &Client{ProbeTimeout: 2 * time.Second}
	results := c.Probe(context.Background(), []Candidate{
		{Drv: "h1-foo.drv", Out: "abcdef0123456789-foo", System: "x86_64-linux"},
	}, []string{slowSrv.URL, fastSrv.URL})
	if !results[0].Served || results[0].Sub != slowSrv.URL {
		t.Fatalf("expected the FIRST substituter in list order to win even though slower, got %+v", results[0])
	}
}

func TestProbe_UnservedWhenAllDown(t *testing.T) {
	down1, down2 := narinfoServer(t, 404), narinfoServer(t, 500)
	c := &Client{ProbeTimeout: time.Second}
	results := c.Probe(context.Background(), []Candidate{
		{Drv: "h1-foo.drv", Out: "abcdef0123456789-foo", System: "x86_64-linux"},
	}, []string{down1.URL, down2.URL})
	if results[0].Served {
		t.Fatalf("expected UNSERVED when every substituter answers non-200, got %+v", results[0])
	}
}

func TestProbe_SecondSubstituterServesWhenFirstMisses(t *testing.T) {
	miss, hit := narinfoServer(t, 404), narinfoServer(t, 200)
	c := &Client{ProbeTimeout: time.Second}
	results := c.Probe(context.Background(), []Candidate{
		{Drv: "h1-foo.drv", Out: "abcdef0123456789-foo", System: "x86_64-linux"},
	}, []string{miss.URL, hit.URL})
	if !results[0].Served || results[0].Sub != hit.URL {
		t.Fatalf("got %+v, want served by the 2nd substituter", results[0])
	}
}

func TestProbe_ReturnsExactlyOneResultPerCandidate(t *testing.T) {
	// Mirrors plan-gate.sh's probed_count==to_probe_count reconciliation
	// guard: a shortfall must never silently read as "everything served".
	srv := narinfoServer(t, 404)
	n := 50
	cands := make([]Candidate, n)
	for i := range cands {
		cands[i] = Candidate{Drv: "h-pkg.drv", Out: "abcdef0123456789-pkg", System: "x86_64-linux"}
	}
	c := &Client{ProbeTimeout: time.Second, Concurrency: 8}
	if results := c.Probe(context.Background(), cands, []string{srv.URL}); len(results) != n {
		t.Fatalf("got %d results, want %d", len(results), n)
	}
}

func TestProbe_HashExtraction(t *testing.T) {
	var gotPath atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath.Store(r.URL.Path)
		w.WriteHeader(200)
	}))
	defer srv.Close()
	c := &Client{ProbeTimeout: time.Second}
	c.Probe(context.Background(), []Candidate{
		{Drv: "h1-foo.drv", Out: "abcdef0123456789abcdef0123456789-foo-1.2.3", System: "x86_64-linux"},
	}, []string{srv.URL})
	want := "/abcdef0123456789abcdef0123456789.narinfo"
	if got := gotPath.Load().(string); got != want {
		t.Fatalf("probed path = %q, want %q (hash is everything before the first '-' in the output's basename)", got, want)
	}
}

func TestProbe_ConcurrencyBound(t *testing.T) {
	var inFlight, maxSeen int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&inFlight, 1)
		for {
			m := atomic.LoadInt32(&maxSeen)
			if n <= m || atomic.CompareAndSwapInt32(&maxSeen, m, n) {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
		atomic.AddInt32(&inFlight, -1)
		w.WriteHeader(404)
	}))
	defer srv.Close()
	cands := make([]Candidate, 40)
	for i := range cands {
		cands[i] = Candidate{Drv: "h-pkg.drv", Out: "abcdef0123456789-pkg", System: "x86_64-linux"}
	}
	c := &Client{ProbeTimeout: time.Second, Concurrency: 4}
	c.Probe(context.Background(), cands, []string{srv.URL})
	if atomic.LoadInt32(&maxSeen) > 4 {
		t.Fatalf("max concurrent probes = %d, want <= 4 (Concurrency bound, mirrors xargs -P8)", maxSeen)
	}
}
