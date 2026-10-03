// Package nixexec is the one place that shells out to `nix` (never a
// pinned build - the daemon protocol must match the host, so callers must
// resolve "nix" from PATH).
package nixexec

import (
	"bytes"
	"context"
	"os/exec"
)

// DryRunOptions mirrors the exact argv shape plan-gate.sh builds:
// <toplevel> --dry-run --accept-flake-config --log-format raw
// --no-write-lock-file [--store X] [--option accept-flake-config false
// --option substituters "<space-joined>"] [extra args], stdin=/dev/null.
type DryRunOptions struct {
	Dir      string
	Toplevel string
	// Store, if set, is passed as --store (--cold's throwaway store, or
	// $PLAN_GATE_STORE).
	Store string
	// SubstitutersOverride, if non-empty, is --write-baseline's
	// "--option accept-flake-config false --option substituters ...":
	// nixConfig/nix.conf append AFTER a CLI override, so only a plain
	// assignment to the base setting actually excludes a cache.
	SubstitutersOverride []string
	// ExtraArgs is "--" passthrough (e.g. just check-tip's
	// --override-input).
	ExtraArgs []string
}

// DryRunPlan runs the dry-run build and returns its stderr (the plan text),
// nix's exit code, and a Go error only for a failure to even start nix.
// Stdin is left nil, which Go connects to the null device - load-bearing in
// --write-baseline mode, where nix would otherwise prompt y/N on a tty for
// nixConfig settings and a stray newline could re-admit an excluded cache.
func DryRunPlan(ctx context.Context, opts DryRunOptions) (stderr string, exitCode int, err error) {
	args := []string{
		"build", opts.Toplevel, "--dry-run", "--accept-flake-config",
		"--log-format", "raw", "--no-write-lock-file",
	}
	if opts.Store != "" {
		args = append(args, "--store", opts.Store)
	}
	if len(opts.SubstitutersOverride) > 0 {
		args = append(args, "--option", "accept-flake-config", "false",
			"--option", "substituters", joinSpace(opts.SubstitutersOverride))
	}
	args = append(args, opts.ExtraArgs...)

	cmd := exec.CommandContext(ctx, "nix", args...)
	cmd.Dir = opts.Dir
	var errBuf bytes.Buffer
	cmd.Stderr = &errBuf
	runErr := cmd.Run()
	if runErr == nil {
		return errBuf.String(), 0, nil
	}
	if exitErr, ok := runErr.(*exec.ExitError); ok {
		return errBuf.String(), exitErr.ExitCode(), nil
	}
	return errBuf.String(), -1, runErr
}

// DerivationShow runs `nix derivation show` over a batch of drv paths,
// returning its raw JSON stdout per invocation (xargs splits a large
// build-drvs list across several; classify.Parse merges them like `jq -rs`).
func DerivationShow(ctx context.Context, dir, store string, drvPaths []string, batchSize int) ([][]byte, error) {
	if len(drvPaths) == 0 {
		return nil, nil
	}
	if batchSize <= 0 {
		batchSize = len(drvPaths)
	}
	var docs [][]byte
	for i := 0; i < len(drvPaths); i += batchSize {
		end := min(i+batchSize, len(drvPaths))
		args := []string{"derivation", "show"}
		if store != "" {
			args = append(args, "--store", store)
		}
		args = append(args, drvPaths[i:end]...)
		cmd := exec.CommandContext(ctx, "nix", args...)
		cmd.Dir = dir
		out, err := cmd.Output()
		if err != nil {
			return nil, err
		}
		docs = append(docs, out)
	}
	return docs, nil
}

func joinSpace(ss []string) string {
	out := ""
	for i, s := range ss {
		if i > 0 {
			out += " "
		}
		out += s
	}
	return out
}
