#!/usr/bin/env bash
# plan-gate: decide whether a lock is safe to build/switch WITHOUT compiling.
#
# Why this exists: nixos-unstable is NOT gated on this host's leaf packages.
# nixos/release-combined.nix advances the channel once the `tested` aggregate
# passes and every other job has merely *finished* ("they may fail"). niri is
# not in `tested`; it failed on Hydra 2026-07-26 and the channel bumped anyway,
# healed 2026-07-28. This gate answers "would anything expensive compile
# locally at this lock" with facts, not name lists.
#
# Method (each stage is load-bearing; see the header of each section):
#   1. `nix build --dry-run --log-format raw` and section-parse its stderr.
#      The BUILD section is NOT "nothing can serve this": derivations with
#      preferLocalBuild/allowSubstitutes=false (writeText, buildEnv, wrappers)
#      land there even when caches serve them, and nix can print the same path
#      in BOTH sections. So section membership is only the candidate set.
#   2. Drop local-by-policy derivations (facts from `nix derivation show`).
#   3. Probe every remaining output against every substituter (narinfo).
#      A path any substituter serves is never a violation.
#   4. What survives is an unserved local build: BLOCK-listed pnames fail
#      always (expensive; never tolerate), baseline pnames are tolerated
#      (measured expected-local set, see --write-baseline), anything else is
#      a violation - the "some OTHER program has a problem" case, made loud.
#
# Exit codes: 0 = safe (or nothing to prove), 1 = violations / eval failure /
# unparsable plan, 2 = cannot judge (substituters unreachable, rate-limited,
# or the plan looks like an offline bootstrap-from-source explosion).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPLEVEL="${TOPLEVEL:-.#nixosConfigurations.temperantia.config.system.build.toplevel}"
BASELINE="${PLAN_GATE_BASELINE:-$SCRIPT_DIR/plan-gate-baseline.txt}"
MAX_BUILDS="${PLAN_GATE_MAX_BUILDS:-500}"

# Must mirror the flake's nixConfig + the default cache. Checked cheaply up
# front; an unreachable cache makes "no one serves X" unknowable, so the gate
# refuses to guess (exit 2) instead of crying "upstream is broken".
SUBSTITUTERS=(
  "https://cache.nixos.org"
  "https://cache.xinux.uz"
  "https://attic.xuyh0120.win/lantian"
  "https://noctalia.cachix.org"
  "https://nix-community.cachix.org"
  "https://phycoforce.cachix.org"
)

# Per-configuration artifacts: generated from THIS config, so no public cache
# can ever serve them, and their build cost is trivial (file writes and
# symlink farms). Matching pnames are dropped without consulting the baseline,
# so adding a systemd unit or renaming the host never trips the gate. Keep the
# patterns structural - a real package must never match.
CONFIG_ARTIFACT_RE='^(unit-.+[.](service|timer|socket|target|mount|automount|slice|path|scope)|initrd-|system-path$|home-manager-path$|home-manager-files$|home-manager-generation$|nixos-system-|etc$|etc-|graphics-drivers$|system-generators$|user-generators$|X-Restart-Triggers|options[.]json$|home-configuration-reference-manpage$|.+[.]conf$|sddm-wrapped$)'

# Never tolerated, even if baselined: an unserved match here means an
# hours-long compile (kernel/graphics/toolchain) or a wedged boot. The hint
# names the substituter that OWNS the package so the failure is actionable.
BLOCK_PATTERNS=(
  "linux-cachyos|attic.xuyh0120.win/lantian (bump nix-cachyos-kernel only when its release branch is cached; probe: curl -sI <attic>/<hash>.narinfo)"
  "nvidia|attic.xuyh0120.win/lantian or phycoforce.cachix.org (unfree: cache.nixos.org never carries it)"
  "mesa|cache.nixos.org (Hydra; probe: just hydra-check mesa)"
  "niri|cache.nixos.org (Hydra, not in 'tested'; probe: just hydra-check niri)"
  "quickshell|cache.nixos.org (probe: just hydra-check quickshell)"
  "xwayland-satellite|cache.nixos.org (probe: just hydra-check xwayland-satellite)"
  "ghostty|cache.nixos.org (probe: just hydra-check ghostty)"
  "sddm-unwrapped|cache.nixos.org (probe: just hydra-check kdePackages.sddm)"
  "webkitgtk|cache.nixos.org (multi-hour build)"
  "qtwebengine|cache.nixos.org (multi-hour build)"
  "electron|cache.nixos.org (multi-hour build)"
  "chromium|cache.nixos.org (multi-hour build)"
  "thunderbird-unwrapped|cache.nixos.org (multi-hour build)"
  "firefox-unwrapped|cache.nixos.org (multi-hour build)"
  "llvm|cache.nixos.org (toolchain; a rebuild here means the tip is mid-rebuild - hold)"
  "rustc|cache.nixos.org (toolchain; hold)"
  "gcc|cache.nixos.org (toolchain; hold)"
)

WRITE_BASELINE=0
if [ "${1:-}" = "--write-baseline" ]; then
  WRITE_BASELINE=1
  shift
fi
[ "${1:-}" = "--" ] && shift

workdir="$(mktemp -d "${TMPDIR:-/tmp}/plan-gate.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
plan="$workdir/plan.txt"

# nix must see the flake's substituters or every path looks unservable and the
# gate becomes a permanent false alarm (the failure mode this rewrite buries).
if ! nix build "$TOPLEVEL" --dry-run --accept-flake-config --log-format raw \
    --no-write-lock-file "$@" >/dev/null 2>"$plan"; then
  cat "$plan" >&2
  echo "!! plan-gate: evaluation failed (see above)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Degraded-network detection, BEFORE interpreting the plan: with a substituter
# down, nix cannot tell "absent" from "unqueryable" and quietly reclassifies
# fetches as builds ("offline --dry-run" lists 8000+ bootstrap derivations,
# exit 0). Never convert that into "upstream is broken".
# ---------------------------------------------------------------------------
if grep -qE "unable to download '.*nix-cache-info'|API rate limit exceeded" "$plan"; then
  grep -E "unable to download|API rate limit" "$plan" | sort -u | head -5 >&2
  echo "?? plan-gate: a substituter or the GitHub API was unreachable - cannot judge this plan." >&2
  exit 2
fi
unreachable=()
for sub in "${SUBSTITUTERS[@]}"; do
  code="$(curl -m 5 -s -o /dev/null -w '%{http_code}' "$sub/nix-cache-info" || true)"
  [ "$code" = "200" ] || unreachable+=("$sub")
done

# ---------------------------------------------------------------------------
# Section-aware split. Tested against nix 2.34.8: singular+plural headers,
# variable size units, the read-only-store suffix on the UNKNOWN header, and
# warnings interleaving mid-plan (any non-entry line closes the section).
# --log-format raw above is load-bearing: internal-json would make this see an
# empty plan, and an empty plan is a PASS - the worst possible failure mode.
# ---------------------------------------------------------------------------
awk '
  /^(these [0-9]+ derivations|this derivation) will be built:$/ { sec = "BUILD";   next }
  /^(these [0-9]+ paths|this path) will be fetched \(/          { sec = "FETCH";   next }
  /^(these [0-9]+ paths|this path) will be copied \(/           { sec = "COPY";    next }
  /^don.t know how to build these paths/                        { sec = "UNKNOWN"; next }
  sec != "" && /^  \/nix\/store\/[0-9a-z]{32}-/                 { print sec, $1;   next }
                                                                { sec = "" }
' "$plan" >"$workdir/records"

build_count="$(grep -c '^BUILD ' "$workdir/records" || true)"
fetch_count="$(grep -c '^FETCH ' "$workdir/records" || true)"
download="$(grep -oE '\([0-9.]+ [KMGT]iB download, [0-9.]+ [KMGT]iB unpacked\)' "$plan" | head -1 || true)"

# Warnings (dirty git tree, eval renames) always precede the plan, so "empty"
# means "no section headers", not "zero bytes".
headers="$(grep -cE "^(these [0-9]+ (derivations|paths)|this (derivation|path)) will be (built|fetched|copied)|^don't know how to build" "$plan" || true)"

if [ "$headers" -eq 0 ]; then
  # The normal state of an up-to-date machine - and it proves NOTHING about
  # substituter health: paths already in the local store appear in neither
  # section. Say so instead of printing a bare green light.
  node="$(jq -r '.nodes.root.inputs.nixpkgs' flake.lock)"
  mod="$(jq -r --arg n "$node" '.nodes[$n].locked.lastModified' flake.lock)"
  age=$(( ( $(date +%s) - mod ) / 86400 ))
  echo ">> plan-gate: plan is empty - closure already realized locally; nothing to prove."
  echo "   (this is NOT substituter health; lock is ${age}d old - probe a candidate with: just check-tip)"
  exit 0
fi
if [ "$build_count" -eq 0 ] && [ "$fetch_count" -eq 0 ] && ! grep -q '^UNKNOWN ' "$workdir/records"; then
  echo "!! plan-gate: plan headers present but no records were recognized - refusing to pass an unparsed plan." >&2
  sed -n '1,15p' "$plan" >&2
  exit 1
fi
if grep -q '^UNKNOWN ' "$workdir/records"; then
  echo "!! plan-gate: nix does not know how to build these paths (no deriver, no substituter) - and --dry-run still exits 0 on this:" >&2
  grep '^UNKNOWN ' "$workdir/records" | sed 's/^UNKNOWN /   /' >&2
  exit 1
fi
if [ "$build_count" -gt "$MAX_BUILDS" ] || grep -qE '^BUILD .*(stage0-posix|bootstrap-tools)' "$workdir/records"; then
  echo "?? plan-gate: $build_count derivations to build (cap $MAX_BUILDS) or bootstrap seeds present - this is what 'no substituter reachable' looks like, not what 'upstream broke' looks like. Cannot judge." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Classify every BUILD derivation with facts.
# Stage 1: local-by-policy (preferLocalBuild / allowSubstitutes=false). These
# build locally by DESIGN and are cheap; the flags live either in plain env or
# inside structuredAttrs (__json), which `nix derivation show` does not
# flatten - check both.
# ---------------------------------------------------------------------------
grep '^BUILD ' "$workdir/records" | cut -d' ' -f2 | sort -u >"$workdir/build-drvs"
if [ -s "$workdir/build-drvs" ]; then
  xargs -a "$workdir/build-drvs" nix derivation show >"$workdir/drvs.json"
else
  echo '{}' >"$workdir/drvs.json"
fi

# Schema note (nix 2.34, version 4): top level is {"derivations": {...}},
# keys and output paths are store-RELATIVE ("<hash>-name[.drv]"), and xargs
# may split large sets into several invocations -> slurp and merge.
jq -rs '
  ([.[] | .derivations // {}] | add // {}) | to_entries[] |
  {drv: .key,
   out: (.value.outputs.out.path // (.value.outputs | to_entries[0].value.path)),
   local: ((.value.env.preferLocalBuild? == "1") or (.value.env.allowSubstitutes? == "")
           or ((.value.env.__json? // "{}" | fromjson? // {})
               | (.preferLocalBuild == true or .allowSubstitutes == false)))} |
  [.drv, .out, (if .local then "local" else "check" end)] | @tsv
' "$workdir/drvs.json" >"$workdir/classified"

local_policy_count="$(awk -F'\t' '$3=="local"' "$workdir/classified" | wc -l)"

# Stage 2: narinfo probe for the rest, first 200 wins. ~seconds, parallel.
awk -F'\t' '$3=="check" {print $1 "\t" $2}' "$workdir/classified" >"$workdir/to-probe"
probe_one() {
  local drv="$1" out="$2" hash sub code
  hash="$(basename "$out")"; hash="${hash%%-*}"
  for sub in "${SUBSTITUTERS[@]}"; do
    code="$(curl -m 8 -s -o /dev/null -w '%{http_code}' "$sub/$hash.narinfo" || true)"
    if [ "$code" = "200" ]; then echo -e "SERVED\t$drv\t$sub"; return; fi
  done
  echo -e "UNSERVED\t$drv\t$out"
}
export -f probe_one
export SUBSTITUTERS_STR="${SUBSTITUTERS[*]}"
# re-materialize the array inside the xargs subshell
probe_wrapper() { read -ra SUBSTITUTERS <<<"$SUBSTITUTERS_STR"; probe_one "$@"; }
export -f probe_wrapper
xargs -r -a "$workdir/to-probe" -L1 -P 8 bash -c 'probe_wrapper "$@"' _ >"$workdir/probed" || true
touch "$workdir/probed"

served_count="$(grep -c '^SERVED' "$workdir/probed" || true)"

# Stage 3: unserved -> block / baseline / violation, keyed on pname
# (store name with the trailing -<digit>… version stripped).
pname_of() {
  local base; base="$(basename "$1" .drv)"
  base="${base#*-}"
  sed -E 's/-[0-9].*$//' <<<"$base"
}

violations=0
config_artifacts=0
tolerated=()
unserved_pnames=()
while IFS=$'\t' read -r _ drv out; do
  pname="$(pname_of "$drv")"
  if grep -qE "$CONFIG_ARTIFACT_RE" <<<"$pname"; then
    config_artifacts=$((config_artifacts + 1))
    continue
  fi
  unserved_pnames+=("$pname")
  blocked_hint=""
  for entry in "${BLOCK_PATTERNS[@]}"; do
    pat="${entry%%|*}"
    if [[ "$pname" == "$pat"* ]]; then blocked_hint="${entry#*|}"; break; fi
  done
  if [ -n "$blocked_hint" ]; then
    echo "!! VIOLATION: $pname would compile locally ($(basename "$drv"))" >&2
    echo "   expected from: $blocked_hint" >&2
    echo "   output: $out" >&2
    violations=$((violations + 1))
  elif [ "$WRITE_BASELINE" -eq 0 ] && [ -f "$BASELINE" ] && grep -qxF "$pname" "$BASELINE"; then
    tolerated+=("$pname")
  elif [ "$WRITE_BASELINE" -eq 0 ]; then
    echo "!! VIOLATION: $pname is a NEW unserved local build (not in $(basename "$BASELINE"))" >&2
    echo "   no configured substituter serves it; if this is a cheap wrapper/config artifact," >&2
    echo "   re-measure with: just gate-baseline   otherwise: hold this lock." >&2
    echo "   output: $out" >&2
    violations=$((violations + 1))
  fi
done < <(grep '^UNSERVED' "$workdir/probed" || true)

if [ "$WRITE_BASELINE" -eq 1 ]; then
  {
    echo "# Measured expected-local set: pnames that no substituter serves at a"
    echo "# healthy lock (unfree wrappers, FHS envs, config artifacts). Regenerate"
    echo "# with: just gate-baseline   Entries matching a BLOCK pattern are never"
    echo "# written here. Generated $(date -u +%F) against $(jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.rev[0:12]' flake.lock)."
    printf '%s\n' "${unserved_pnames[@]}" | sort -u | while read -r p; do
      skip=0
      for entry in "${BLOCK_PATTERNS[@]}"; do
        [[ "$p" == "${entry%%|*}"* ]] && { skip=1; break; }
      done
      [ "$skip" -eq 0 ] && echo "$p"
    done
  } >"$BASELINE"
  echo ">> plan-gate: baseline written to $BASELINE ($(grep -cv '^#' "$BASELINE") pnames)."
fi

echo ">> plan-gate: $fetch_count fetched ${download:+$download }| $build_count to build:" \
  "$local_policy_count local-by-policy, $served_count cache-served, $config_artifacts config-artifacts," \
  "${#tolerated[@]} tolerated, $violations violations."
if [ "${#tolerated[@]}" -gt 0 ]; then
  echo "   tolerated (will compile at switch, measured cheap): $(printf '%s ' "${tolerated[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
fi
if [ "${#unreachable[@]}" -gt 0 ]; then
  echo "?? unreachable substituters: ${unreachable[*]}" >&2
  if [ "$violations" -gt 0 ]; then
    echo "?? violations above may be phantoms of the unreachable cache - cannot judge." >&2
    exit 2
  fi
fi
[ "$violations" -eq 0 ] || exit 1
