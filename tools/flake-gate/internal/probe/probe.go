// Package probe replaces plan-gate.sh's xargs -P8 + curl narinfo probing
// with a bounded goroutine pool over net/http.
package probe

import (
	"context"
	"net/http"
	"path"
	"strconv"
	"strings"
	"time"
)

// Candidate is one BUILD row classified "check" with a resolvable output.
type Candidate struct {
	Drv    string
	Out    string
	System string
}

// Result is what probe_one would have echoed: SERVED (with the substituter
// that served it, first match in list order) or UNSERVED.
type Result struct {
	Drv    string
	Served bool
	Sub    string
	Out    string
	System string
}

// Health is one substituter's reachability, probed once before any verdict
// so every cannot-judge path can name the cache that is down.
type Health struct {
	Sub string
	Up  bool
	// Code is "HTTP <status>" or "no response" - curl's "000" convention
	// from plan-gate.sh:250.
	Code string
}

// Client lets tests inject a short-timeout http.Client against httptest
// servers; the zero value uses production defaults.
type Client struct {
	HTTP          *http.Client
	HealthTimeout time.Duration // mirrors curl -m 5
	ProbeTimeout  time.Duration // mirrors curl -m 8
	Concurrency   int           // mirrors xargs -P8
}

func (c *Client) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return http.DefaultClient
}

func (c *Client) healthTimeout() time.Duration {
	if c.HealthTimeout > 0 {
		return c.HealthTimeout
	}
	return 5 * time.Second
}

func (c *Client) probeTimeout() time.Duration {
	if c.ProbeTimeout > 0 {
		return c.ProbeTimeout
	}
	return 8 * time.Second
}

func (c *Client) concurrency() int {
	if c.Concurrency > 0 {
		return c.Concurrency
	}
	return 8
}

// CheckHealth GETs "<sub>/nix-cache-info" for every substituter, in order,
// sequentially - the health dump must stay in substituter-list order.
func (c *Client) CheckHealth(ctx context.Context, subs []string) []Health {
	out := make([]Health, 0, len(subs))
	for _, sub := range subs {
		out = append(out, c.checkOne(ctx, sub))
	}
	return out
}

func (c *Client) checkOne(ctx context.Context, sub string) Health {
	ctx, cancel := context.WithTimeout(ctx, c.healthTimeout())
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, joinURL(sub, "nix-cache-info"), nil)
	if err != nil {
		return Health{Sub: sub, Up: false, Code: "no response"}
	}
	resp, err := c.client().Do(req)
	if err != nil {
		return Health{Sub: sub, Up: false, Code: "no response"}
	}
	defer resp.Body.Close()
	if resp.StatusCode == 200 {
		return Health{Sub: sub, Up: true, Code: "200"}
	}
	return Health{Sub: sub, Up: false, Code: "HTTP " + strconv.Itoa(resp.StatusCode)}
}

// Probe runs the narinfo probe pool: for each candidate, try substituters
// IN ORDER (first 200 wins - a slice, never a map, so the credited cache
// stays deterministic) across a bounded worker pool. Returns exactly
// len(candidates) results.
func (c *Client) Probe(ctx context.Context, candidates []Candidate, subs []string) []Result {
	results := make([]Result, len(candidates))
	sem := make(chan struct{}, c.concurrency())
	done := make(chan struct{})
	for i := range candidates {
		i := i
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; done <- struct{}{} }()
			results[i] = c.probeOne(ctx, candidates[i], subs)
		}()
	}
	for range candidates {
		<-done
	}
	return results
}

func (c *Client) probeOne(ctx context.Context, cand Candidate, subs []string) Result {
	hash := hashOf(cand.Out)
	for _, sub := range subs {
		pctx, cancel := context.WithTimeout(ctx, c.probeTimeout())
		req, err := http.NewRequestWithContext(pctx, http.MethodGet, joinURL(sub, hash+".narinfo"), nil)
		if err != nil {
			cancel()
			continue
		}
		resp, err := c.client().Do(req)
		cancel()
		if err != nil {
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == 200 {
			return Result{Drv: cand.Drv, Served: true, Sub: sub, Out: cand.Out, System: cand.System}
		}
	}
	return Result{Drv: cand.Drv, Served: false, Out: cand.Out, System: cand.System}
}

// hashOf mirrors `basename "$out"; hash="${hash%%-*}"`.
func hashOf(out string) string {
	base := path.Base(out)
	if idx := strings.Index(base, "-"); idx >= 0 {
		return base[:idx]
	}
	return base
}

func joinURL(sub, p string) string {
	return strings.TrimRight(sub, "/") + "/" + p
}
