// Package lockfile reads flake.lock just enough to resolve the root
// nixpkgs input - never by looking up a node literally named "nixpkgs",
// which can be a different input's OWN pin after flake.lock's dedup (e.g.
// nix-cachyos-kernel's).
package lockfile

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

type node struct {
	Inputs map[string]json.RawMessage `json:"inputs"`
	Locked struct {
		LastModified int64  `json:"lastModified"`
		Rev          string `json:"rev"`
	} `json:"locked"`
}

type lock struct {
	Nodes map[string]node `json:"nodes"`
}

func load(path string) (lock, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return lock{}, err
	}
	var l lock
	if err := json.Unmarshal(data, &l); err != nil {
		return lock{}, err
	}
	return l, nil
}

// rootNixpkgs resolves root.inputs.nixpkgs to the node it actually names.
// Root's own inputs are always direct node-name strings (never a
// follows-chain array), so a string assertion is enough here.
func rootNixpkgs(l lock) (node, error) {
	root, ok := l.Nodes["root"]
	if !ok {
		return node{}, fmt.Errorf("flake.lock has no \"root\" node")
	}
	raw, ok := root.Inputs["nixpkgs"]
	if !ok {
		return node{}, fmt.Errorf("root has no \"nixpkgs\" input")
	}
	var name string
	if err := json.Unmarshal(raw, &name); err != nil {
		return node{}, fmt.Errorf("root.inputs.nixpkgs is not a plain node name: %w", err)
	}
	target, ok := l.Nodes[name]
	if !ok {
		return node{}, fmt.Errorf("flake.lock node %q (root's nixpkgs) not found", name)
	}
	return target, nil
}

// RootNixpkgsAgeDays is best-effort only (plan-gate.sh's empty-plan age
// clause, lines 315-317): a missing/unexpected flake.lock just omits the
// message, it never fails the gate.
func RootNixpkgsAgeDays(lockPath string) (int, bool) {
	l, err := load(lockPath)
	if err != nil {
		return 0, false
	}
	n, err := rootNixpkgs(l)
	if err != nil || n.Locked.LastModified == 0 {
		return 0, false
	}
	days := int((time.Now().Unix() - n.Locked.LastModified) / 86400)
	return days, true
}

// RootNixpkgsRev12 returns the root nixpkgs's rev, truncated to 12 chars,
// for the baseline file's "Last measured ... against <rev>" header.
func RootNixpkgsRev12(lockPath string) (string, error) {
	l, err := load(lockPath)
	if err != nil {
		return "", err
	}
	n, err := rootNixpkgs(l)
	if err != nil {
		return "", err
	}
	rev := n.Locked.Rev
	if len(rev) > 12 {
		rev = rev[:12]
	}
	return rev, nil
}
