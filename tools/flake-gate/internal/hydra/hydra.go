// Package hydra looks up a Hydra build matching a violation's EXACT output
// hash, to explain WHY an unserved row is unserved (never to change the
// verdict) - porting plan-gate.sh's hydra_verdict() (lines 150-203).
package hydra

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path"
	"strconv"
	"strings"
	"time"
)

// Class is hydra_verdict()'s hv_class.
type Class string

const (
	FailedUpstream Class = "failed-upstream"
	Pending        Class = "hydra-pending"
	NoJob          Class = "no-hydra-job"
	Inconclusive   Class = "inconclusive" // default: skipped, unreachable, or no match in the last 10
)

// Verdict is hv_class + hv_detail.
type Verdict struct {
	Class  Class
	Detail string
}

// Client is a budget-limited Hydra API client. The budget (MaxLookups) is
// shared across every Verdict call made on one Client - a large held set
// cannot blow up run time on API calls.
type Client struct {
	HTTP       *http.Client
	BaseURL    string
	Jobset     string // "project/jobset", e.g. "nixos/unstable"
	MaxLookups int
	lookups    int
}

func (c *Client) client() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return http.DefaultClient
}

type apiBuild struct {
	ID          int  `json:"id"`
	BuildStatus *int `json:"buildstatus"`
	Finished    int  `json:"finished"`
}

func (b apiBuild) statusStr() string {
	if b.BuildStatus == nil {
		return "-"
	}
	return strconv.Itoa(*b.BuildStatus)
}

// statusName mirrors hydra_status_name().
func statusName(s string) string {
	switch s {
	case "0":
		return "succeeded"
	case "1":
		return "failed"
	case "2":
		return "dependency failed"
	case "3":
		return "aborted"
	case "4":
		return "cancelled"
	case "6":
		return "failed with output"
	case "7":
		return "timed out"
	case "9":
		return "unsupported system"
	case "10":
		return "log limit exceeded"
	case "11":
		return "output limit exceeded"
	case "12":
		return "non-deterministic"
	default:
		return "status " + s
	}
}

// Verdict looks up the Hydra build of pname/system matching out's exact
// store-path hash. Globals in bash (hv_class/hv_detail survive the
// lookup-budget check across calls); here that state is the Client itself.
func (c *Client) Verdict(ctx context.Context, pname, out, system string) Verdict {
	if system == "" {
		system = "x86_64-linux"
	}
	hash := hashOf(out)
	job := "nixpkgs." + pname + "." + system
	if c.lookups >= c.MaxLookups {
		return Verdict{Class: Inconclusive, Detail: fmt.Sprintf(
			"lookup skipped (budget of %d spent); check: just hydra-check %s", c.MaxLookups, pname)}
	}
	c.lookups++

	project, jobsetName := splitJobset(c.Jobset)
	builds, err := c.latestBuilds(ctx, project, jobsetName, job)
	if err != nil {
		return Verdict{Class: Inconclusive, Detail: fmt.Sprintf("Hydra unreachable; check: just hydra-check %s", pname)}
	}
	if len(builds) == 0 {
		return Verdict{Class: NoJob, Detail: fmt.Sprintf(
			"no %s job %s (unfree, not a Hydra job, or the attr differs from the pname)", c.Jobset, job)}
	}
	newest := builds[0]
	for _, b := range builds {
		outs, err := c.buildOutputs(ctx, b.ID)
		if err != nil || !containsHash(outs, hash) {
			continue
		}
		url := fmt.Sprintf("%s/build/%d", c.BaseURL, b.ID)
		switch {
		case b.Finished != 1:
			return Verdict{Class: Pending, Detail: "queued on Hydra, not built yet: " + url}
		case b.statusStr() == "0":
			return Verdict{Class: Pending, Detail: "Hydra built it but no cache serves it yet: " + url}
		case b.statusStr() == "3" || b.statusStr() == "4":
			return Verdict{Class: Pending, Detail: fmt.Sprintf("%s on Hydra, may be retried: %s", statusName(b.statusStr()), url)}
		default:
			detail := fmt.Sprintf("%s on Hydra for this exact output: %s", statusName(b.statusStr()), url)
			if b.ID != newest.ID && newest.Finished == 1 && newest.statusStr() == "0" {
				detail += fmt.Sprintf("; a later build succeeded (%s/build/%d), so it is fixed upstream and waits for the channel", c.BaseURL, newest.ID)
			}
			return Verdict{Class: FailedUpstream, Detail: detail}
		}
	}
	nstatus := "queued"
	if newest.Finished == 1 {
		nstatus = statusName(newest.statusStr())
	}
	return Verdict{Class: Inconclusive, Detail: fmt.Sprintf(
		"none of %s's last 10 builds made this output (newest: %s/build/%d, %s); check: just hydra-check %s",
		job, c.BaseURL, newest.ID, nstatus, pname)}
}

func (c *Client) latestBuilds(ctx context.Context, project, jobsetName, job string) ([]apiBuild, error) {
	u := fmt.Sprintf("%s/api/latestbuilds?nr=10&project=%s&jobset=%s&job=%s", c.BaseURL, project, jobsetName, job)
	var builds []apiBuild
	if err := c.getJSON(ctx, u, &builds); err != nil {
		return nil, err
	}
	return builds, nil
}

type buildDetail struct {
	BuildOutputs map[string]struct {
		Path string `json:"path"`
	} `json:"buildoutputs"`
}

func (c *Client) buildOutputs(ctx context.Context, id int) ([]string, error) {
	u := fmt.Sprintf("%s/build/%d", c.BaseURL, id)
	var d buildDetail
	if err := c.getJSON(ctx, u, &d); err != nil {
		return nil, err
	}
	out := make([]string, 0, len(d.BuildOutputs))
	for _, o := range d.BuildOutputs {
		out = append(out, o.Path)
	}
	return out, nil
}

func (c *Client) getJSON(ctx context.Context, url string, v interface{}) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("hydra: %s: HTTP %d", url, resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, v)
}

// splitJobset mirrors `${JOBSET%%/*}` / `${JOBSET#*/}`.
func splitJobset(jobset string) (project, name string) {
	if idx := strings.Index(jobset, "/"); idx >= 0 {
		return jobset[:idx], jobset[idx+1:]
	}
	return jobset, ""
}

// containsHash mirrors `grep -q "/$hash-" <<<"$outs"`.
func containsHash(outs []string, hash string) bool {
	needle := "/" + hash + "-"
	for _, o := range outs {
		if strings.Contains(o, needle) {
			return true
		}
	}
	return false
}

func hashOf(out string) string {
	base := path.Base(out)
	if idx := strings.Index(base, "-"); idx >= 0 {
		return base[:idx]
	}
	return base
}
