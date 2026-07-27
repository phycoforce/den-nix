set positional-arguments

nix_flags := "--accept-flake-config"
host := "temperantia"
installed_flake := "/etc/nixos/den-desktop#temperantia"
toplevel := ".#nixosConfigurations." + host + ".config.system.build.toplevel"
upstream_ref := "nixos-unstable"

# Packages that must never have to be compiled locally. Everything here is
# meant to arrive prebuilt from a substituter, so one of these turning up in a
# build plan means no cache can serve it -- upstream is broken at that lock
# revision. It is not an invitation to compile for an hour.
#
# This matters because nixos-unstable is NOT gated on these building:
# nixos/release-combined.nix advances the channel once the `tested` aggregate
# passes and every other job has merely *finished* ("they may fail"). niri is
# not in `tested`; it failed on Hydra 2026-07-26 and the channel bumped anyway.
watched := "niri xwayland-satellite quickshell mesa nvidia-x11 linux-cachyos sddm ghostty"

default:
    @just --list

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

# Shared implementation of the buildless gate. `nix build --dry-run` exits 0
# even when a package cannot be built, but its plan names every derivation no
# substituter can serve -- so scan the plan instead of trusting the exit code.
#
# The store-hash anchor keeps `linux-cachyos` from matching the always-local
# `initrd-linux-cachyos-*`, and the `-<pkg>-<digit>` / `-<pkg>.drv` tail keeps
# `sddm` from matching the always-local `sddm.conf`.
[private]
scan label *args:
    #!/usr/bin/env bash
    set -euo pipefail
    label="$1"; shift
    plan="$(mktemp "${TMPDIR:-/tmp}/nix-plan.XXXXXX")"
    trap 'rm -f "$plan"' EXIT
    if ! nix build {{toplevel}} --dry-run {{nix_flags}} "$@" >"$plan" 2>&1; then
      cat "$plan" >&2
      echo "!! $label: evaluation failed (see above)." >&2
      exit 1
    fi
    hits=()
    for pkg in {{watched}}; do
      if grep -qE "/nix/store/[a-z0-9]{32}-${pkg}(-[0-9]|[.]drv)" "$plan"; then
        hits+=("$pkg")
      fi
    done
    if [ "${#hits[@]}" -gt 0 ]; then
      echo >&2
      echo "!! $label FAILED: no substituter can serve: ${hits[*]}" >&2
      echo "!! Upstream is broken at this revision -- do not switch to it." >&2
      echo "!! Confirm with: just hydra-check ${hits[0]}" >&2
      exit 1
    fi
    echo ">> $label OK: nothing watched needs a local build."

[doc("Buildless gate on the current lock; runs before every switch")]
preflight: (scan "preflight")
    @just lock-status

# Answers "is it safe to update yet / has upstream healed" without writing the
# lock. Run it before `just update-verified`, and while holding a pin to see
# when the hold can be dropped.
[doc("Buildless gate on a candidate revision, without touching flake.lock")]
check-tip ref=upstream_ref: (scan ("check-tip " + ref) "--override-input" "nixpkgs" ("github:NixOS/nixpkgs/" + ref) "--no-write-lock-file")

[doc("Where nixpkgs is locked, how old it is, and whether upstream has moved")]
lock-status:
    #!/usr/bin/env bash
    set -euo pipefail
    node="$(jq -r '.nodes.root.inputs.nixpkgs' flake.lock)"
    rev="$(jq -r --arg n "$node" '.nodes[$n].locked.rev' flake.lock)"
    mod="$(jq -r --arg n "$node" '.nodes[$n].locked.lastModified' flake.lock)"
    ref="$(jq -r --arg n "$node" '.nodes[$n].original.ref // "{{upstream_ref}}"' flake.lock)"
    age=$(( ( $(date +%s) - mod ) / 86400 ))
    printf '   nixpkgs %s (%s, %sd old, tracking %s)\n' \
      "${rev:0:12}" "$(date -d "@$mod" +%F)" "$age" "$ref"
    tip="$(git ls-remote https://github.com/NixOS/nixpkgs "$ref" 2>/dev/null | cut -f1)"
    if [ -n "$tip" ] && [ "$tip" != "$rev" ]; then
      printf '   held off %s tip %s -- probe it with: just check-tip\n' \
        "$ref" "${tip:0:12}"
    fi
    if [ "$age" -ge 21 ]; then
      printf '   !! %sd old; CI flake-checker (fail-mode) trips at 30d.\n' "$age" >&2
    fi

# `just update-verified` does everything; `just update-verified nixpkgs` does
# one input. Replaces the update-then-discover-then-hand-revert loop: a lock
# that does not build never survives the command that created it.
[doc("Update inputs, prove they build, restore the old lock if they do not")]
update-verified *inputs:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f flake.lock || { echo "update-verified: no flake.lock in $PWD" >&2; exit 1; }
    prev="$(mktemp "${TMPDIR:-/tmp}/flake.lock.prev.XXXXXX")"
    cp -p flake.lock "$prev"
    nix flake update "$@" {{nix_flags}}
    if cmp -s flake.lock "$prev"; then
      echo ">> flake.lock unchanged; nothing to verify."
      rm -f "$prev"
      exit 0
    fi
    if {{just_executable()}} preflight \
      && nix build {{toplevel}} {{nix_flags}} --print-build-logs --keep-going --no-link; then
      echo ">> lock verified: {{host}} builds."
      rm -f "$prev"
      exit 0
    fi
    rejected="$prev.rejected"
    cp -p flake.lock "$rejected"
    cp -p "$prev" flake.lock
    echo >&2
    echo "!! FAILED -- flake.lock restored to its previous revision." >&2
    echo "!! rejected lock kept at: $rejected" >&2
    echo "!! inputs it moved:" >&2
    {{just_executable()}} lock-diff "$prev" "$rejected" >&2 || true
    echo "!! attribute it with: just bisect-lock" >&2
    exit 1

[doc("Deprecated spelling, kept so muscle memory cannot bypass the gate")]
update-lock: update-verified

[doc("Update one input, verified")]
update-input input: (update-verified input)

# Writes the rev into flake.lock's `locked` field and leaves `original`
# tracking the branch, so nothing is declared in tracked source, the generated
# flake.nix is untouched, and the next plain `nix flake update` clears the hold
# on its own. There is no pin left behind to forget -- and `just lock-status`,
# which every preflight runs, reports the hold until it is gone.
[doc("Hold nixpkgs at a known-good revision without editing flake.nix")]
pin-nixpkgs rev:
    nix flake update nixpkgs --override-input nixpkgs github:NixOS/nixpkgs/{{rev}} {{nix_flags}}
    @just lock-status

[doc("Drop the hold: take what the tracked branch points at now, verified")]
unpin-nixpkgs: (update-verified "nixpkgs")

[doc("Which inputs moved between two locks; defaults to HEAD vs the worktree")]
lock-diff old="" new="":
    #!/usr/bin/env bash
    set -euo pipefail
    revs() {
      jq -r '
        (.nodes.root.inputs | to_entries | map({key: .value, value: .key}) | from_entries) as $alias
        | .nodes | to_entries[] | select(.value.locked)
        | "\($alias[.key] // ("~" + .key)) \(.value.locked.rev // .value.locked.narHash)"
      ' "$1" | sort
    }
    old="{{old}}"
    new="{{new}}"
    scratch=""
    if [ -z "$old" ]; then
      scratch="$(mktemp "${TMPDIR:-/tmp}/flake.lock.head.XXXXXX")"
      git show HEAD:flake.lock > "$scratch"
      old="$scratch"
    fi
    [ -n "$new" ] || new=flake.lock
    diff -u <(revs "$old") <(revs "$new") || true
    [ -z "$scratch" ] || rm -f "$scratch"

# Bumps a single input at a time and preflights after each: bumps that pass are
# kept, bumps that fail are rolled back and named. Ends holding the newest
# combination that still passes -- exactly the "hold nixpkgs, take everything
# else" lock you want during an upstream breakage. Pass names to narrow it.
[doc("Attribute a broken update to one input")]
bisect-lock *inputs:
    #!/usr/bin/env bash
    set -euo pipefail
    good="$(mktemp "${TMPDIR:-/tmp}/flake.lock.good.XXXXXX")"
    cp -p flake.lock "$good"
    trap 'cp -p "$good" flake.lock; rm -f "$good"' EXIT
    if [ "$#" -eq 0 ]; then
      mapfile -t all < <(jq -r '.nodes.root.inputs | keys[]' flake.lock)
      set -- "${all[@]}"
    fi
    broken=()
    for input in "$@"; do
      cp -p "$good" flake.lock
      # `nix flake update <unknown>` only warns, so check the name ourselves.
      if ! jq -e --arg i "$input" '.nodes.root.inputs | has($i)' flake.lock >/dev/null; then
        printf '  %-22s SKIP  (not a root input)\n' "$input"
        continue
      fi
      if ! nix flake update "$input" {{nix_flags}} >/dev/null 2>&1; then
        printf '  %-22s SKIP  (fetch failed)\n' "$input"
        continue
      fi
      if cmp -s flake.lock "$good"; then
        printf '  %-22s -     (already current)\n' "$input"
        continue
      fi
      printf '  %-22s ' "$input"
      if {{just_executable()}} scan "bisect" >/dev/null 2>&1; then
        echo "OK"
        cp -p flake.lock "$good"
      else
        echo "BROKEN"
        broken+=("$input")
      fi
    done
    cp -p "$good" flake.lock
    echo
    if [ "${#broken[@]}" -eq 0 ]; then
      echo ">> every input bumped cleanly."
    else
      echo "!! culprits: ${broken[*]}"
      echo "!! flake.lock now holds the newest combination that passes preflight."
    fi

# Distinguishes "Hydra is merely behind, wait a day" from "failed, this needs
# an upstream fix and the hold stays".
[doc("What Hydra did with a package on the unstable channel")]
hydra-check +args:
    nix {{nix_flags}} run nixpkgs#hydra-check -- {{args}} --channel unstable

switch: preflight
    nix {{nix_flags}} run .#{{host}} -- switch

[doc("Stage the next generation for boot; use for kernel / NVIDIA changes")]
boot: preflight
    nix {{nix_flags}} run .#{{host}} -- boot

switch-installed: preflight
    sudo nixos-rebuild switch --flake {{installed_flake}} {{nix_flags}}
