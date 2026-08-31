set positional-arguments

nix_flags := "--accept-flake-config"
host := "temperantia"
installed_flake := "/etc/nixos/den-desktop#temperantia"
toplevel := ".#nixosConfigurations." + host + ".config.system.build.toplevel"
upstream_ref := "nixos-unstable"

# The gate lives in scripts/plan-gate.sh (shared with
# .github/workflows/flake-update.yml): it judges a lock by substituter narinfo
# probes, never by hand-maintained package lists, and exits 2 rather than
# blaming upstream when the network is degraded.

default:
    @just --list

# ---------------------------------------------------------------------------
# formatting / repo checks
# ---------------------------------------------------------------------------

fmt:
    git ls-files -z '*.nix' | xargs -0 nix {{nix_flags}} fmt --

fmt-check:
    git ls-files -z '*.nix' | xargs -0 nix {{nix_flags}} fmt -- --check

write-flake:
    nix {{nix_flags}} run .#write-flake

write-inputs:
    nix {{nix_flags}} run .#write-inputs

check-generated:
    nix {{nix_flags}} run .#write-flake
    git diff --exit-code flake.nix

flake-check:
    nix flake check {{nix_flags}}

lint:
    nix build .#checks.x86_64-linux.pre-commit -L {{nix_flags}}

build-dry:
    nix build {{toplevel}} --dry-run {{nix_flags}}

build:
    nix build {{toplevel}} {{nix_flags}}

validate: fmt-check lint check-generated flake-check preflight

# ---------------------------------------------------------------------------
# the gate
# ---------------------------------------------------------------------------

[doc("Judge the current lock: would anything unserved compile locally?")]
preflight:
    ./scripts/plan-gate.sh
    @just lock-age

# The warm gate proves nothing on an up-to-date machine (empty plan); this
# plans against a throwaway store, as a fresh CI runner would (~2.5 GiB temp).
[doc("Judge the current lock as CI's cold store sees it")]
preflight-cold:
    ./scripts/plan-gate.sh --cold

[doc("Judge a candidate nixpkgs rev without touching flake.lock")]
check-tip ref=upstream_ref:
    ./scripts/plan-gate.sh -- --override-input nixpkgs github:NixOS/nixpkgs/{{ref}}

# MERGES into scripts/plan-gate-baseline.txt (prune by hand). Cold and sans
# the repo's own cache: a warm store hides what is already realized and the
# own cache only proves what a past run pushed - either shrinks the
# measurement to a misleading delta.
[doc("Re-measure the tolerated expected-local set for the gate (cold, sans own cache)")]
gate-baseline *args:
    ./scripts/plan-gate.sh --write-baseline --cold "$@"

# ---------------------------------------------------------------------------
# updating
# ---------------------------------------------------------------------------

[doc("Fast-forward to origin/main (the CI updater lands proven locks there)")]
sync:
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch origin main 2>/dev/null || { echo "?? sync: could not reach origin - working with the local tree."; exit 0; }
    counts="$(git rev-list --left-right --count origin/main...HEAD)"
    behind="${counts%%$'\t'*}"; ahead="${counts##*$'\t'}"
    if [ "$behind" = "0" ]; then
      echo ">> sync: up to date with origin/main${ahead:+ (local ahead by $ahead)}."
    elif [ "$ahead" != "0" ]; then
      echo "!! sync: local and origin/main have DIVERGED ($behind behind, $ahead ahead) - reconcile by hand." >&2
      exit 1
    elif ! git diff --quiet flake.lock 2>/dev/null; then
      echo "!! sync: local flake.lock has uncommitted changes - not fast-forwarding over them." >&2
      exit 1
    else
      git merge --ff-only origin/main
      echo ">> sync: adopted origin/main ($behind commits) - if the updater landed a lock, it is already built and cached."
    fi

# Syncs first: a lock the CI updater already proved and cached beats
# re-proving one locally. Bisects per-input only on failure, so a broken input
# holds back ONLY itself. Gate-only - tolerated derivations compile at switch.
[doc("Update inputs; a lock that fails the gate never survives")]
update *inputs:
    @just sync
    ./scripts/flake-update.sh "$@"

[doc("update + one real toplevel build (catches collisions/initrd/FOD drift)")]
update-build *inputs:
    @just sync
    ./scripts/flake-update.sh --build "$@"

# A stub, not an alias: aliasing would hide that the semantics changed.
# Delete once fingers have adjusted.
[doc("Renamed - fails loudly; use update / update-build")]
update-verified *inputs:
    @echo "renamed: 'just update' = gate only (no local build); 'just update-build' = old behaviour." >&2
    @exit 2

[doc("Hold nixpkgs at a known-good revision; release with: just update nixpkgs")]
pin-nixpkgs rev:
    nix flake update nixpkgs --override-input nixpkgs github:NixOS/nixpkgs/{{rev}} {{nix_flags}}
    @just lock-age

[doc("Kick the CI updater (fire-and-forget); follow with: just ci")]
update-remote *inputs:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gh >/dev/null || { echo "gh not installed - dispatch flake-update.yml from the Actions tab instead." >&2; exit 1; }
    if [ "$#" -gt 0 ]; then
      gh workflow run flake-update.yml --ref main -f only="$*"
    else
      gh workflow run flake-update.yml --ref main
    fi
    echo ">> dispatched; it updates, builds, pushes to cachix and lands on main. Watch: just ci"

# ---------------------------------------------------------------------------
# information
# ---------------------------------------------------------------------------

[doc("Which inputs moved between two locks; defaults to HEAD vs the worktree")]
lock-diff old="" new="flake.lock":
    ./scripts/lock-diff.sh "$1" "$2"

[private]
lock-age:
    #!/usr/bin/env bash
    set -euo pipefail
    node="$(jq -r '.nodes.root.inputs.nixpkgs' flake.lock)"
    rev="$(jq -r --arg n "$node" '.nodes[$n].locked.rev' flake.lock)"
    mod="$(jq -r --arg n "$node" '.nodes[$n].locked.lastModified' flake.lock)"
    age=$(( ( $(date +%s) - mod ) / 86400 ))
    printf '   nixpkgs %s (%s, %sd old, tracking {{upstream_ref}})\n' "${rev:0:12}" "$(date -d "@$mod" +%F)"  "$age"
    if [ "$age" -ge 21 ]; then
      printf '   !! %sd old; CI flake-checker (fail-mode) trips at 30d. Probe upstream: just check-tip\n' "$age" >&2
    fi

[doc("One screen: where am I, universe ages, reachability, CI state")]
status:
    #!/usr/bin/env bash
    set -uo pipefail
    lock() { jq -r --arg n "$1" ".nodes[\$n].locked.$2 // \"?\"" flake.lock; }
    age_of() { echo $(( ( $(date +%s) - $1 ) / 86400 )); }
    echo "== where am i =="
    git diff --quiet 2>/dev/null && echo "   worktree: clean" || echo "   worktree: DIRTY"
    if git fetch origin main --quiet 2>/dev/null; then
      counts="$(git rev-list --left-right --count origin/main...HEAD 2>/dev/null || echo '? ?')"
      echo "   origin/main: behind ${counts%%$'\t'*}, ahead ${counts##*$'\t'}"
    else
      echo "   origin/main: unreachable"
    fi
    last_lock="$(git log -1 --format='%h %an %cr' -- flake.lock 2>/dev/null || echo unknown)"
    echo "   last lock commit: $last_lock"
    echo "== universes =="
    root="$(jq -r '.nodes.root.inputs.nixpkgs' flake.lock)"
    printf '   nixpkgs        %s  %s  (%sd)  tracking {{upstream_ref}}\n' \
      "$(lock "$root" rev | cut -c1-12)" "$(date -d @"$(lock "$root" lastModified)" +%F)" "$(age_of "$(lock "$root" lastModified)")"
    tip="$(git ls-remote https://github.com/NixOS/nixpkgs {{upstream_ref}} 2>/dev/null | cut -c1-12 || true)"
    [ -n "$tip" ] && [ "$tip" != "$(lock "$root" rev | cut -c1-12)" ] && echo "   ^ upstream tip $tip - newer; adopt with: just update nixpkgs"
    ck="$(jq -r '.nodes.root.inputs."nix-cachyos-kernel"' flake.lock)"
    ckn="$(jq -r --arg n "$ck" '.nodes[$n].inputs.nixpkgs' flake.lock)"
    printf '   cachyos-kernel %s  %s  (%sd)  inner nixpkgs %s (its own pin - by design)\n' \
      "$(lock "$ck" rev | cut -c1-12)" "$(date -d @"$(lock "$ck" lastModified)" +%F)" "$(age_of "$(lock "$ck" lastModified)")" "$(lock "$ckn" rev | cut -c1-12)"
    echo "== reachability =="
    for sub in https://cache.nixos.org https://cache.xinux.uz https://attic.xuyh0120.win/lantian https://nix-community.cachix.org https://phycoforce.cachix.org; do
      t="$( { time -p curl -m 5 -s -o /dev/null "$sub/nix-cache-info"; } 2>&1 | awk '/^real/ {print $2"s"}' )" \
        && echo "   $sub  ${t:-ok}" || echo "   $sub  UNREACHABLE"
    done
    rl="$(curl -m 5 -s https://api.github.com/rate_limit 2>/dev/null | jq -r '.rate | "\(.remaining)/\(.limit)"' 2>/dev/null || echo unknown)"
    tok="absent"; command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1 && tok="present"
    echo "   github api: $rl remaining, gh token: $tok (absent token = 60/hr cap; updates may silently no-op)"
    echo "== ci =="
    if command -v gh >/dev/null 2>&1; then
      up="$(gh run list --workflow flake-update.yml --limit 1 --json conclusion,createdAt --jq '.[0] | "\(.conclusion // "running") \(.createdAt)"' 2>/dev/null || echo unknown)"
      echo "   flake-update.yml: $up"
      case "$up" in
        *T*) d="$(( ( $(date +%s) - $(date -d "${up#* }" +%s) ) / 86400 ))"
             [ "$d" -ge 3 ] && echo "   !! last updater run ${d}d ago - cron disabled/delayed? recover: gh workflow enable flake-update.yml" ;;
      esac
      echo "   ci.yml (main):   $(gh run list --workflow ci.yml --branch main --limit 1 --json conclusion,createdAt --jq '.[0] | "\(.conclusion // "running") \(.createdAt)"' 2>/dev/null || echo unknown)"
    else
      echo "   gh not installed - CI state unknown"
    fi
    just lock-age || true

[doc("Recent updater + CI runs")]
ci:
    gh run list --workflow flake-update.yml --limit 5
    gh run list --workflow ci.yml --branch main --limit 5

# Answers can be STALE for renamed/aliased attrs (a dead job keeps reporting
# old successes); plan-gate's narinfo probes are authoritative.
[doc("What Hydra did with a package on the unstable channel")]
hydra-check +args:
    nix {{nix_flags}} run nixpkgs#hydra-check -- {{args}} --channel unstable

# ---------------------------------------------------------------------------
# applying
# ---------------------------------------------------------------------------

switch: preflight
    nix {{nix_flags}} run .#{{host}} -- switch

[doc("Stage the next generation for boot; use for kernel / NVIDIA changes")]
boot: preflight
    nix {{nix_flags}} run .#{{host}} -- boot

switch-installed: preflight
    sudo nixos-rebuild switch --flake {{installed_flake}} {{nix_flags}}
