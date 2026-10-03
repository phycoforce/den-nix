#!/usr/bin/env bash
# flake-update: bump inputs so that a lock that fails the gate never survives,
# and a broken input holds back ONLY itself.
#
# Shape: batch-first (the cheap path on a healthy day), per-input bisect only
# when the batch fails, then one grouped retry of the held set - coupled
# inputs (e.g. den + flake-file) would otherwise deadlock individually.
#
# Modes:
#   flake-update.sh [inputs...]            local: plan-gate + write-flake regen
#   flake-update.sh --ci [inputs...]       CI: + flake check, fmt-check, lint;
#                                          emits GITHUB_OUTPUT + summary files
#   flake-update.sh --build [inputs...]    local + one real toplevel build,
#                                          which catches what the gate cannot:
#                                          buildEnv collisions, initrd
#                                          assembly, FOD hash drift
#
# Exit: 0 = done (possibly with holds; holds are reported, not fatal),
#       1 = nothing could be verified / eval broke, 2 = cannot judge (network).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE=local
DO_BUILD=0
while [ "${1:-}" != "" ] && [[ "${1:-}" == --* ]]; do
  case "$1" in
    --ci) MODE=ci ;;
    --build) DO_BUILD=1 ;;
    *) echo "flake-update: unknown flag $1" >&2; exit 1 ;;
  esac
  shift
done

TOPLEVEL="${TOPLEVEL:-.#nixosConfigurations.temperantia.config.system.build.toplevel}"
NIX_FLAGS=(--accept-flake-config)

# CI wires GITHUB_TOKEN into nix; locally borrow gh's token. Unauthenticated
# GitHub API is 60 req/hr/IP, and `nix flake update` on hitting the limit
# keeps the CACHED rev and exits 0 - a no-op that reads as "already current".
if [ "$MODE" = "local" ] && command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
  export NIX_CONFIG="access-tokens = github.com=$(gh auth token)
${NIX_CONFIG:-}"
fi

# Requested inputs must be real root inputs: `nix flake update <unknown>` only
# warns, and a dispatch-supplied name must not smuggle flags.
mapfile -t ALL_INPUTS < <(jq -r '.nodes.root.inputs | keys[]' flake.lock)
TARGETS=()
if [ "$#" -gt 0 ]; then
  for req in "$@"; do
    [[ "$req" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "flake-update: invalid input name: $req" >&2; exit 1; }
    if printf '%s\n' "${ALL_INPUTS[@]}" | grep -qxF "$req"; then
      TARGETS+=("$req")
    else
      echo "flake-update: '$req' is not a root input - skipping." >&2
    fi
  done
  [ "${#TARGETS[@]}" -gt 0 ] || { echo "flake-update: no valid inputs requested." >&2; exit 1; }
else
  TARGETS=("${ALL_INPUTS[@]}")
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/flake-update.XXXXXX")"
snapshot="$workdir/flake.lock.start"
good="$workdir/flake.lock.good"
cp -p flake.lock "$snapshot"
cp -p flake.lock "$good"
trap 'rm -rf "$workdir"' EXIT

declare -A RESULT REASON NEWREV

rev_of() { # rev_of <root-input> <lockfile>
  jq -r --arg i "$1" '.nodes[.nodes.root.inputs[$i]].locked.rev
    // .nodes[.nodes.root.inputs[$i]].locked.narHash // "?"' "$2"
}

bump() { # bump <lockfile-out-of-band-log> <inputs...>; fails on rate-limit lies
  local log="$1"; shift
  nix flake update "$@" "${NIX_FLAGS[@]}" 2>&1 | tee "$log" >&2 || return 1
  if grep -qE 'API rate limit exceeded|using cached version' "$log"; then
    echo "!! flake-update: GitHub API rate-limited mid-update; the lock was NOT fully re-resolved." >&2
    echo "!! authenticate (gh auth login) or wait for the limit reset - do not trust 'already current'." >&2
    return 2
  fi
}

gate_reason() { # gate_reason <plan-gate-stderr>: one classified line for hold()
  local err="$1" kind class pnames reasons=() joined
  if grep -q '^!! plan-gate: evaluation failed' "$err"; then
    echo "eval failed"
    return
  fi
  # Grouped by plan-gate's per-row Hydra verdict: whether a hold self-heals is
  # what the reader of a commit body or annotation needs first.
  for kind in blocked new; do
    for class in failed-upstream hydra-pending no-hydra-job inconclusive; do
      pnames="$(awk -v k="$kind" -v c="$class" '
        /^!! VIOLATION: / { p = $3; vk = (/ would compile locally/ ? "blocked" : "new"); next }
        /^   hydra: / && p != "" { if (vk == k && $2 == c) print p; p = "" }
      ' "$err" | sort -u | tr '\n' ' ')"
      pnames="${pnames% }"
      [ -n "$pnames" ] || continue
      case "$kind/$class" in
        blocked/failed-upstream) reasons+=("blocked, failed upstream on Hydra: $pnames - self-heals once nixos-unstable ships a fix") ;;
        blocked/hydra-pending) reasons+=("blocked, Hydra pending: $pnames - self-heals once Hydra finishes") ;;
        blocked/*) reasons+=("blocked: $pnames - see the BLOCK hint in the run log") ;;
        new/failed-upstream) reasons+=("failed upstream on Hydra: $pnames - self-heals once nixos-unstable ships a fix, never re-baseline") ;;
        new/hydra-pending) reasons+=("Hydra pending: $pnames - self-heals once Hydra finishes, never re-baseline") ;;
        new/no-hydra-job) reasons+=("baseline-stale: $pnames - no Hydra job, never self-heals, re-baseline if cheap") ;;
        new/inconclusive) reasons+=("unserved: $pnames - Hydra inconclusive, run just hydra-check before re-baselining") ;;
      esac
    done
  done
  if grep -q '32-bit builds (cap' "$err"; then reasons+=("i686 over cap"); fi
  if [ "${#reasons[@]}" -eq 0 ]; then
    echo "gate failed (see run log)"
    return
  fi
  joined="$(printf '%s; ' "${reasons[@]}")"
  echo "${joined%; }"
}

# cannot_judge <lock-to-restore> <why> [plan-gate-stderr]: an exit 2 that says
# why - a bare "exit code 2" in CI reads like a broken input, not an outage.
cannot_judge() {
  local lock="$1" why="$2" err="${3:-}" down=""
  cp -p "$lock" flake.lock
  if [ -n "$err" ] && [ -f "$err" ]; then
    [ -n "$why" ] || why="$(sed -nE 's/^\?\? plan-gate: (.*) - cannot judge this plan\.$/\1/p' "$err" | head -1)"
    [ -n "$why" ] || why="$(sed -nE 's/^\?\? (plan-gate: )?//p' "$err" | head -1)"
    down="$(sed -nE 's/^ +DOWN +//p' "$err" | paste -sd ',' - | sed 's/,/, /g')"
  fi
  why="${why:-plan-gate could not judge}${down:+ (down: $down)}"
  echo "?? flake-update: cannot judge - $why. No input was blamed or committed; re-run once it recovers." >&2
  if [ "$MODE" = "ci" ]; then
    echo "::error title=flake-update cannot judge::$why. No input was blamed or committed; re-run once it recovers."
    {
      echo "## flake-update: cannot judge"
      echo
      echo "$why. No input was blamed or committed; re-run once it recovers."
      if [ -n "$err" ] && [ -s "$err" ]; then
        echo
        echo '```'
        tail -n 40 "$err"
        echo '```'
      fi
    } >"${RUNNER_TEMP:-$workdir}/flake-update-summary.md"
  fi
  exit 2
}

gate() { # gate <label>; uses the CURRENT worktree lock
  local label="$1" rc=0
  echo ">> gate [$label]: plan-gate"
  # stderr rides through a file so a hold gets a classified reason instead of
  # "see log above" in a commit body that has no log; replayed right after.
  "$SCRIPT_DIR/plan-gate.sh" 2>"$workdir/gate.err" || rc=$?
  cat "$workdir/gate.err" >&2
  if [ "$rc" -ne 0 ]; then
    gate_reason "$workdir/gate.err" >"$workdir/gate-reason"
    return "$rc"
  fi
  # flake.nix is generated and a bump can change its codegen: regenerate now so
  # the change rides in the same commit and check-generated stays green.
  echo ">> gate [$label]: write-flake regeneration"
  nix run .#write-flake "${NIX_FLAGS[@]}" >/dev/null \
    || { echo "write-flake regeneration failed" >"$workdir/gate-reason"; return 1; }
  if [ "$MODE" = "ci" ]; then
    # This lock lands on main via a GITHUB_TOKEN push, which cannot trigger
    # ci.yml - so every gate ci.yml would run must run HERE or nowhere.
    echo ">> gate [$label]: nix flake check"
    nix flake check "${NIX_FLAGS[@]}" || { echo "flake check failed" >"$workdir/gate-reason"; return 1; }
    echo ">> gate [$label]: fmt-check"
    git ls-files -z '*.nix' | xargs -0 nix "${NIX_FLAGS[@]}" fmt -- --check \
      || { echo "fmt-check failed" >"$workdir/gate-reason"; return 1; }
    echo ">> gate [$label]: lint (pre-commit checks)"
    nix build .#checks.x86_64-linux.pre-commit "${NIX_FLAGS[@]}" \
      || { echo "lint failed" >"$workdir/gate-reason"; return 1; }
  fi
}

hold() { # hold <reason> <inputs...>; restore the last good lock
  local why="$1"; shift
  for i in "$@"; do RESULT[$i]=held; REASON[$i]="$why"; done
  cp -p "$good" flake.lock
  git checkout --quiet flake.nix 2>/dev/null || true
  nix run .#write-flake "${NIX_FLAGS[@]}" >/dev/null 2>&1 || true
}

# --- batch first ------------------------------------------------------------
echo ">> flake-update: batch attempt (${#TARGETS[@]} inputs)"
rc=0; bump "$workdir/bump.log" "${TARGETS[@]}" || rc=$?
[ "$rc" -eq 2 ] && cannot_judge "$snapshot" "GitHub API rate-limited while resolving inputs"
[ "$rc" -ne 0 ] && { cp -p "$snapshot" flake.lock; echo "!! flake-update: batch bump failed to resolve." >&2; exit 1; }

MOVED=()
for i in "${TARGETS[@]}"; do
  if [ "$(rev_of "$i" flake.lock)" != "$(rev_of "$i" "$snapshot")" ]; then
    MOVED+=("$i")
  else
    RESULT[$i]=current
  fi
done

if [ "${#MOVED[@]}" -eq 0 ]; then
  echo ">> flake-update: every requested input is already at its tip; nothing to verify."
else
  rc=0; gate "batch" || rc=$?
  if [ "$rc" -eq 2 ]; then cannot_judge "$snapshot" "" "$workdir/gate.err"; fi
  if [ "$rc" -eq 0 ]; then
    for i in "${MOVED[@]}"; do RESULT[$i]=kept; NEWREV[$i]="$(rev_of "$i" flake.lock)"; done
    cp -p flake.lock "$good"
  else
    # --- bisect: only the inputs that actually moved -----------------------
    echo ">> flake-update: batch gate failed - bisecting ${#MOVED[@]} moved inputs"
    cp -p "$snapshot" flake.lock
    for i in "${MOVED[@]}"; do
      cp -p "$good" flake.lock
      rc=0; bump "$workdir/bump-$i.log" "$i" || rc=$?
      if [ "$rc" -ne 0 ]; then hold "fetch/rate-limit while re-resolving" "$i"; [ "$rc" -eq 2 ] && cannot_judge "$good" "GitHub API rate-limited while re-resolving $i"; continue; fi
      if cmp -s flake.lock "$good"; then RESULT[$i]=current; continue; fi
      rc=0; gate "$i" || rc=$?
      if [ "$rc" -eq 2 ]; then cannot_judge "$good" "" "$workdir/gate.err"; fi
      if [ "$rc" -eq 0 ]; then
        RESULT[$i]=kept; NEWREV[$i]="$(rev_of "$i" flake.lock)"; cp -p flake.lock "$good"
      else
        hold "$(cat "$workdir/gate-reason" 2>/dev/null || echo "gate failed (see run log)")" "$i"
      fi
    done
    # --- grouped retry of the held set: coupled inputs pass together -------
    HELD=(); for i in "${MOVED[@]}"; do [ "${RESULT[$i]:-}" = held ] && HELD+=("$i"); done
    if [ "${#HELD[@]}" -ge 2 ]; then
      echo ">> flake-update: retrying held set as a group: ${HELD[*]}"
      cp -p "$good" flake.lock
      if bump "$workdir/bump-held.log" "${HELD[@]}" && gate "held-group"; then
        for i in "${HELD[@]}"; do RESULT[$i]=kept; NEWREV[$i]="$(rev_of "$i" flake.lock)"; REASON[$i]=""; done
        cp -p flake.lock "$good"
      else
        cp -p "$good" flake.lock
        git checkout --quiet flake.nix 2>/dev/null || true
        nix run .#write-flake "${NIX_FLAGS[@]}" >/dev/null 2>&1 || true
      fi
    fi
  fi
fi

# --- report -----------------------------------------------------------------
changed=false
cmp -s flake.lock "$snapshot" || changed=true
summary="$workdir/summary.tsv"
{
  for i in "${TARGETS[@]}"; do
    case "${RESULT[$i]:-current}" in
      kept)    printf 'kept\t%s\t%s\n'    "$i" "${NEWREV[$i]:0:12}" ;;
      held)    printf 'held\t%s\t%s\n'    "$i" "${REASON[$i]:-}" ;;
      current) printf 'current\t%s\t-\n'  "$i" ;;
    esac
  done
} >"$summary"

echo
echo ">> flake-update result (lock $([ "$changed" = true ] && echo changed || echo unchanged)):"
if command -v column >/dev/null 2>&1; then
  column -t -s$'\t' "$summary" | sed 's/^/   /'
else
  sed 's/^/   /' "$summary"
fi
if grep -q '^kept' "$summary"; then
  echo
  echo ">> gated: everything non-trivial in the new lock is substitutable."
  echo ">> NOT built locally - tolerated derivations (see plan-gate output) compile at switch time."
fi

if [ "$DO_BUILD" -eq 1 ] && [ "$changed" = true ]; then
  echo ">> flake-update: real build (requested with --build)"
  nix build "$TOPLEVEL" "${NIX_FLAGS[@]}" --print-build-logs --keep-going --no-link
fi

if [ "$MODE" = "ci" ]; then
  {
    echo "## flake-update"
    echo
    echo '| input | result | detail |'
    echo '| --- | --- | --- |'
    awk -F'\t' '{printf "| %s | %s | %s |\n", $2, $1, $3}' "$summary"
    if [ "$changed" = true ]; then
      echo
      echo '### lock diff'
      echo '```'
      "$SCRIPT_DIR/lock-diff.sh" "$snapshot" flake.lock || true
      echo '```'
    fi
  } >"${RUNNER_TEMP:-$workdir}/flake-update-summary.md"
  {
    echo "chore(lock): scheduled input update"
    echo
    awk -F'\t' '$1=="kept" {printf "kept: %s -> %s\n", $2, $3}' "$summary"
    awk -F'\t' '$1=="held" {printf "held: %s (%s)\n", $2, $3}' "$summary"
  } >"${RUNNER_TEMP:-$workdir}/commit-message.txt"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "changed=$changed" >>"$GITHUB_OUTPUT"
    # A hold-everything day lands no commit, so the workflow must surface the
    # classified reasons itself or they never leave this run's log.
    echo "held=$(grep -c '^held' "$summary" || true)" >>"$GITHUB_OUTPUT"
  fi
fi
