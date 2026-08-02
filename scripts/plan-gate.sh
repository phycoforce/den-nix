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
#   2. Drop local-by-policy derivations and fixed-output derivations (facts
#      from `nix derivation show`, schema v4: policy flags live in plain env
#      OR the top-level structuredAttrs object; a FOD carries an output hash
#      and no output path - it is a download, not a compile).
#   3. Probe every remaining output against every substituter (narinfo).
#      A path any substituter serves is never a violation.
#   4. What survives is an unserved local build: BLOCK-listed pnames fail
#      always (expensive; never tolerate), baseline pnames are tolerated
#      (measured expected-local set, see --write-baseline), anything else is
#      a violation - the "some OTHER program has a problem" case, made loud.
#
# Modes and knobs:
#   --cold                 plan against a throwaway empty store, so the gate
#                          sees what a fresh CI runner sees instead of the
#                          delta against this machine's warm store (~2.5 GiB
#                          of temp disk while it runs; cleaned on exit).
#   --write-baseline       re-measure the expected-local set. Measurement
#                          excludes the repo's OWN cache: it serves whatever a
#                          past run pushed, but a candidate lock re-keys those
#                          paths, so "own cache serves it today" proves
#                          nothing about tomorrow. Run it --cold or the warm
#                          store hides most of the set. Results MERGE into the
#                          existing baseline (an incremental cache means any
#                          single measurement only sees a delta).
#   PLAN_GATE_STORE=<path> use this store instead of the default (what --cold
#                          sets, pointed at a temp dir).
#
# Exit codes: 0 = safe (or nothing to prove), 1 = violations / eval failure /
# unparsable plan, 2 = cannot judge (substituters unreachable, rate-limited,
# or the plan looks like an offline bootstrap-from-source explosion).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPLEVEL="${TOPLEVEL:-.#nixosConfigurations.temperantia.config.system.build.toplevel}"
BASELINE="${PLAN_GATE_BASELINE:-$SCRIPT_DIR/plan-gate-baseline.txt}"
# Cap calibrated against a COLD plan (~600 candidate derivations, nearly all
# config artifacts), not a warm delta; the offline signature this guards
# against is thousands of builds plus bootstrap seeds.
MAX_BUILDS="${PLAN_GATE_MAX_BUILDS:-2000}"

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
# The cache this repo's own CI pushes to - excluded while measuring the
# baseline (see --write-baseline above), authoritative everywhere else.
OWN_CACHE="https://phycoforce.cachix.org"

# Per-configuration artifacts: generated from THIS config, so no public cache
# can ever serve them, and their build cost is trivial (file writes, symlink
# farms, tiny wrapper compiles). Matching pnames are dropped without
# consulting the baseline, so adding a systemd unit or renaming the host never
# trips the gate. Keep the patterns structural - a real package must never
# match.
CONFIG_ARTIFACT_RE='^(unit-.+[.](service|timer|socket|target|mount|automount|slice|path|scope)|initrd-|system-path$|home-manager-path$|home-manager-files$|home-manager-generation$|nixos-system-|etc$|etc-|graphics-drivers$|system-generators$|user-generators$|X-Restart-Triggers|options[.]json$|home-configuration-reference-manpage$|.+[.]conf$|sddm-wrapped$|security-wrapper($|-)|pam[.]d$|hm-modules-messages$|jack-libs$)'

# Kernel-module closures, matched on the FULL store name because the version
# strip in pname_of collapses them onto the kernel's own pname and the BLOCK
# list would fire. aggregateModules / makeModulesClosure assemble THIS host's
# module list with root-nixpkgs tooling: no cache can serve them, every root
# nixpkgs bump re-keys them, and the copy is cheap. The kernel itself carries
# no such suffix and stays BLOCK-guarded.
KMOD_CLOSURE_RE='^linux-.+-modules(-shrunk)?$'

# Never tolerated, even if baselined: an unserved match here means an
# hours-long compile (kernel/graphics/toolchain) or a wedged boot. The hint
# names the substituter that OWNS the package so the failure is actionable.
BLOCK_PATTERNS=(
  "linux-cachyos|attic.xuyh0120.win/lantian (bump nix-cachyos-kernel only when its release branch is cached; probe: curl -sI <attic>/<hash>.narinfo)"
  # Deliberately NOT a bare "nvidia" prefix: nvidia-open (the v4-kernel module,
  # ~1-2 min compile) and nvidia-persistenced are never publicly cached for
  # this kernel - upstream builds nvidia only against generic kernels - so a
  # bare prefix would hold every nix-cachyos-kernel bump forever. Those two are
  # baseline-tolerated; the big userspace bundle stays guarded.
  "nvidia-x11|attic.xuyh0120.win/lantian or phycoforce.cachix.org (unfree: cache.nixos.org never carries it)"
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
COLD=0
while [ "${1:-}" != "" ] && [[ "${1:-}" == --* ]] && [ "${1:-}" != "--" ]; do
  case "$1" in
    --write-baseline) WRITE_BASELINE=1 ;;
    --cold) COLD=1 ;;
    *) echo "plan-gate: unknown flag $1" >&2; exit 1 ;;
  esac
  shift
done
[ "${1:-}" = "--" ] && shift

workdir="$(mktemp -d "${TMPDIR:-/tmp}/plan-gate.XXXXXX")"
# Store paths under a --cold store are read-only; make them deletable first.
# The final || true is load-bearing: a failing EXIT trap REPLACES the script's
# exit status, and turning an exit 2 (cannot judge) into a generic 1 would
# make flake-update blame one input for a network problem.
trap 'chmod -R u+w "$workdir" 2>/dev/null || true; rm -rf "$workdir" || true' EXIT
plan="$workdir/plan.txt"

[ "$COLD" -eq 1 ] && PLAN_GATE_STORE="${PLAN_GATE_STORE:-$workdir/store}"
STORE_ARGS=()
[ -n "${PLAN_GATE_STORE:-}" ] && STORE_ARGS=(--store "$PLAN_GATE_STORE")

SUB_ARGS=()
if [ "$WRITE_BASELINE" -eq 1 ]; then
  filtered=()
  for sub in "${SUBSTITUTERS[@]}"; do
    [ "$sub" = "$OWN_CACHE" ] || filtered+=("$sub")
  done
  SUBSTITUTERS=("${filtered[@]}")
  # Applies to nix's own planning too, so own-cache-only paths land in the
  # BUILD section and flow through the same classifier as everything else.
  # accept-flake-config must be refused here: the flake's nixConfig appends
  # extra-substituters (own cache included) AFTER any CLI override, as does
  # /etc/nix/nix.conf - a plain assignment to the base setting, processed
  # last, is the only spelling that actually excludes a cache. (Verified
  # against nix 2.34.8: with this pair, own-cache-only paths move from the
  # fetched section to the built section.)
  SUB_ARGS=(--option accept-flake-config false --option substituters "${SUBSTITUTERS[*]}")
fi

# nix must see the flake's substituters or every path looks unservable and the
# gate becomes a permanent false alarm (the failure mode this rewrite buries).
# stdin comes from /dev/null: with accept-flake-config refused (baseline mode)
# nix on a tty PROMPTS y/N per nixConfig setting, the prompt lands invisibly
# in $plan, and answering y would re-admit the own cache mid-measurement.
if ! nix build "$TOPLEVEL" --dry-run --accept-flake-config --log-format raw \
    --no-write-lock-file "${STORE_ARGS[@]}" "${SUB_ARGS[@]}" "$@" \
    </dev/null >/dev/null 2>"$plan"; then
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
# Classify every BUILD derivation with facts from `nix derivation show`
# (schema v4). Three verdicts:
#   fod   - fixed-output derivation: an output hash and NO output path in the
#           schema. It is a pinned download (source tarball, nupkg, crate),
#           not a compile; cost = bandwidth. Also the reason the output path
#           falls back to "" below - a FOD row must never reach the probe
#           stage, where an empty field would corrupt the pipeline.
#   local - preferLocalBuild / allowSubstitutes=false: builds locally by
#           DESIGN and is cheap. The flags live in plain env OR the top-level
#           structuredAttrs object (v4 exposes it; the old env.__json spelling
#           is kept for older nix).
#   check - a real candidate; probe substituters for it.
# A zero-build plan (everything fetchable) makes the grep below match nothing;
# that is the BEST outcome, not an error - hence the guard.
# ---------------------------------------------------------------------------
grep '^BUILD ' "$workdir/records" | cut -d' ' -f2 | sort -u >"$workdir/build-drvs" || true
if [ -s "$workdir/build-drvs" ]; then
  xargs -a "$workdir/build-drvs" nix derivation show "${STORE_ARGS[@]}" >"$workdir/drvs.json"
else
  echo '{}' >"$workdir/drvs.json"
fi

# Schema note (nix 2.34, version 4): top level is {"derivations": {...}},
# keys and output paths are store-RELATIVE ("<hash>-name[.drv]"), and xargs
# may split large sets into several invocations -> slurp and merge.
jq -rs '
  ([.[] | .derivations // {}] | add // {}) | to_entries[] |
  {drv: .key,
   out: ((.value.outputs.out.path // (.value.outputs | to_entries[0].value.path)) // ""),
   fod: ([.value.outputs[]? | has("hash")] | any),
   local: ((.value.env.preferLocalBuild? == "1") or (.value.env.allowSubstitutes? == "")
           or (.value.structuredAttrs.preferLocalBuild? == true)
           or (.value.structuredAttrs.allowSubstitutes? == false)
           or ((.value.env.__json? // "{}" | fromjson? // {})
               | (.preferLocalBuild == true or .allowSubstitutes == false)))} |
  [.drv, .out, (if .fod then "fod" elif .local then "local" else "check" end)] | @tsv
' "$workdir/drvs.json" >"$workdir/classified"

# Every BUILD derivation must be accounted for: nix silently reshaped this
# schema once already (env.__json -> structuredAttrs), and a future reshape
# would otherwise classify zero rows and pass a completely unexamined plan.
classified_count="$(wc -l <"$workdir/classified")"
candidate_count="$(wc -l <"$workdir/build-drvs")"
if [ "$classified_count" -ne "$candidate_count" ]; then
  echo "?? plan-gate: classified $classified_count of $candidate_count build derivations - nix derivation show schema drift? Cannot judge an unexamined plan." >&2
  exit 2
fi

local_policy_count="$(awk -F'\t' '$3=="local"' "$workdir/classified" | wc -l)"
fod_count="$(awk -F'\t' '$3=="fod"' "$workdir/classified" | wc -l)"

# A check-stage row without an output path cannot be probed, cannot be judged,
# and WILL build locally at unknown cost (floating content-addressed drv?).
# Loud failure, never a pass - and never fed to the probe, where an empty
# field would shift every subsequent line's meaning.
awk -F'\t' '$3=="check" && $2==""  {print $1}' "$workdir/classified" >"$workdir/unprobeable"
awk -F'\t' '$3=="check" && $2!=""  {print $1 "\t" $2}' "$workdir/classified" >"$workdir/to-probe"

violations=0
if [ -s "$workdir/unprobeable" ]; then
  echo "!! plan-gate: build derivations with no computable output path - cannot probe, refusing to pass:" >&2
  sed 's/^/   /' "$workdir/unprobeable" >&2
  violations="$(wc -l <"$workdir/unprobeable")"
fi

# Stage 2: narinfo probe, first 200 wins. ~seconds, parallel. Lines are passed
# WHOLE (-d '\n') and split inside the wrapper: xargs -L would treat the tab
# in "drv<TAB>out" as a trailing blank and merge adjacent lines.
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
probe_wrapper() {
  read -ra SUBSTITUTERS <<<"$SUBSTITUTERS_STR"
  local drv out
  IFS=$'\t' read -r drv out <<<"$1"
  probe_one "$drv" "$out"
}
export -f probe_wrapper
xargs -r -a "$workdir/to-probe" -d '\n' -n1 -P 8 bash -c 'probe_wrapper "$@"' _ >"$workdir/probed" || true
touch "$workdir/probed"

# probe_one emits exactly one line per candidate, so a shortfall means the
# probe infrastructure itself failed (xargs flag unsupported, children
# killed): the || true above must never turn that into "everything served".
probed_count="$(wc -l <"$workdir/probed")"
to_probe_count="$(wc -l <"$workdir/to-probe")"
if [ "$probed_count" -ne "$to_probe_count" ]; then
  echo "?? plan-gate: probed $probed_count of $to_probe_count candidates - the probe itself failed; cannot judge." >&2
  exit 2
fi

served_count="$(grep -c '^SERVED' "$workdir/probed" || true)"

# Stage 3: unserved -> config-artifact / block / baseline / violation, keyed
# on pname (store name with the trailing -<digit>… version stripped).
pname_of() {
  local base; base="$(basename "$1" .drv)"
  base="${base#*-}"
  sed -E 's/-[0-9].*$//' <<<"$base"
}

config_artifacts=0
tolerated=()
unserved_pnames=()
while IFS=$'\t' read -r _ drv out; do
  fullname="$(basename "$drv" .drv)"
  fullname="${fullname#*-}"
  if grep -qE "$KMOD_CLOSURE_RE" <<<"$fullname"; then
    config_artifacts=$((config_artifacts + 1))
    continue
  fi
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
  # Never merge a measurement taken during an outage: everything the dead
  # cache serves would probe unserved, be written, and - merge semantics -
  # stay tolerated forever.
  if [ "${#unreachable[@]}" -gt 0 ]; then
    echo "?? plan-gate: not writing a baseline measured while substituters were unreachable (${unreachable[*]})." >&2
    exit 2
  fi
  {
    echo "# Measured expected-local set: pnames no PUBLIC substituter serves at a"
    echo "# healthy lock - unfree repacks, FHS envs, repo-owned flake packages,"
    echo "# per-config builds. The gate tolerates these; they compile at switch"
    echo "# time, so review the cost of every newly added entry (the writer"
    echo "# prints them). Regenerate with: just gate-baseline"
    echo "# (cold store, own cache excluded: the own cache only proves what a"
    echo "# PAST run pushed, not what a candidate lock will need). Re-measuring"
    echo "# MERGES with existing entries - an incremental cache means one"
    echo "# measurement only ever sees a delta; prune by hand when a package"
    echo "# leaves the config. BLOCK-pattern matches are never written."
    echo "# Last measured $(date -u +%F) against $(jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.rev[0:12]' flake.lock)."
    {
      if [ -f "$BASELINE" ]; then grep -vE '^#|^[[:space:]]*$' "$BASELINE" || true; fi
      if [ "${#unserved_pnames[@]}" -gt 0 ]; then printf '%s\n' "${unserved_pnames[@]}"; fi
    } | sort -u | while read -r p; do
      skip=0
      for entry in "${BLOCK_PATTERNS[@]}"; do
        [[ "$p" == "${entry%%|*}"* ]] && { skip=1; break; }
      done
      # An if, not '[ ] && echo': a skipped final pname would return 1 from
      # the loop, and errexit would kill the script before the mv below.
      if [ "$skip" -eq 0 ]; then echo "$p"; fi
    done
  } >"$workdir/baseline.new"
  added="$(comm -13 <(grep -vE '^#|^[[:space:]]*$' "$BASELINE" 2>/dev/null | sort -u) \
                    <(grep -v '^#' "$workdir/baseline.new") | tr '\n' ' ')"
  mv "$workdir/baseline.new" "$BASELINE"
  echo ">> plan-gate: baseline written to $BASELINE ($(grep -cv '^#' "$BASELINE") pnames, merged)."
  if [ -n "$added" ]; then
    echo "   newly tolerated (REVIEW each - it will compile at switch unheld): $added"
  fi
fi

echo ">> plan-gate: $fetch_count fetched ${download:+$download }| $build_count to build:" \
  "$local_policy_count local-by-policy, $fod_count source-fetches, $served_count cache-served," \
  "$config_artifacts config-artifacts, ${#tolerated[@]} tolerated, $violations violations."
if [ "${#tolerated[@]}" -gt 0 ]; then
  echo "   tolerated (expected-local; compiles at switch): $(printf '%s ' "${tolerated[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
fi
if [ "${#unreachable[@]}" -gt 0 ]; then
  echo "?? unreachable substituters: ${unreachable[*]}" >&2
  if [ "$violations" -gt 0 ]; then
    echo "?? violations above may be phantoms of the unreachable cache - cannot judge." >&2
    exit 2
  fi
fi
[ "$violations" -eq 0 ] || exit 1
