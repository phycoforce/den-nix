#!/usr/bin/env bash
# plan-gate: decide whether a lock is safe to build/switch WITHOUT compiling.
#
# nixos-unstable is NOT gated on this host's leaf packages (release-combined
# advances once the `tested` aggregate passes and every other job has merely
# *finished*), so the channel regularly ships something no cache serves. This
# gate answers "would anything expensive compile locally" with facts.
#
# Method:
#   1. Section-parse `nix build --dry-run --log-format raw` stderr. The BUILD
#      section is only a candidate set: local-by-policy derivations land there
#      even when caches serve them, and a path can appear in BOTH sections.
#   2. Drop local-by-policy and fixed-output derivations (facts from
#      `nix derivation show`); a FOD is a download, not a compile.
#   3. Probe every remaining output against every substituter (narinfo); a
#      path any substituter serves is never a violation.
#   4. What survives is an unserved local build: BLOCK pnames always fail,
#      trivial builders (a compiler-less stdenv running an inline
#      buildCommand with no source, or repacking a .nupkg) are dropped as
#      cheap by construction, i686 rows are
#      policy-tolerated up to PLAN_GATE_MAX_I686 (Hydra never builds this
#      host's full 32-bit set; only third-party caches serve it incidentally,
#      at revs of their choosing), baseline pnames are tolerated, anything
#      else is a violation.
#
# Knobs:
#   --cold                 plan against a throwaway empty store so the gate
#                          sees what a fresh CI runner sees, not the delta
#                          against this warm store (~2.5 GiB of temp disk).
#   --write-baseline       re-measure the expected-local set; run it --cold or
#                          the warm store hides most of the set.
#   PLAN_GATE_STORE=<path> use this store instead of the default.
#
# Exit codes: 0 = safe (or nothing to prove), 1 = violations / eval failure /
# unparsable plan, 2 = cannot judge (a substituter down or answering 5xx, a
# network error mid-plan, rate-limited, or the plan looks like an offline
# bootstrap-from-source explosion). Every exit 2 lists per-substituter health.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPLEVEL="${TOPLEVEL:-.#nixosConfigurations.temperantia.config.system.build.toplevel}"
BASELINE="${PLAN_GATE_BASELINE:-$SCRIPT_DIR/plan-gate-baseline.txt}"
# Calibrated against a COLD plan (~600 candidates); the offline signature this
# guards against is thousands of builds plus bootstrap seeds.
MAX_BUILDS="${PLAN_GATE_MAX_BUILDS:-2000}"
# The usual unserved 32-bit leaf set (nvidia EGL stack + stragglers) is ~10;
# the runtime closure holds ~460 i686 packages, so past this cap the plan is
# an i686 mass rebuild no cache will absorb - hold, don't tolerate. Under the
# cap, non-BLOCK i686 builds compile at switch by design (bounded, listed).
MAX_I686="${PLAN_GATE_MAX_I686:-25}"
# Hydra verdicts explain WHY an unserved row is unserved; they never change the
# exit code. Jobs are guessed as nixpkgs.<pname>.<system>, so "no job" is not
# proof that Hydra never builds the package.
HYDRA="${PLAN_GATE_HYDRA:-https://hydra.nixos.org}"
HYDRA_JOBSET="${PLAN_GATE_HYDRA_JOBSET:-nixos/unstable}"
MAX_HYDRA_LOOKUPS="${PLAN_GATE_MAX_HYDRA_LOOKUPS:-10}"

# Must mirror the flake's nixConfig + the default cache; an unreachable cache
# makes "no one serves X" unknowable, so the gate exits 2 instead of guessing.
SUBSTITUTERS=(
  "https://cache.nixos.org"
  "https://attic.xuyh0120.win/lantian"
  "https://nix-community.cachix.org"
  "https://phycoforce.cachix.org"
)
# This repo's own CI cache: excluded while measuring the baseline (it only
# proves what a PAST run pushed), authoritative everywhere else.
OWN_CACHE="https://phycoforce.cachix.org"

# Per-configuration artifacts: no cache can ever serve them and they cost
# nothing to build, so they are dropped without consulting the baseline. Keep
# the patterns structural - a real package must never match.
CONFIG_ARTIFACT_RE='^(unit-.+[.](service|timer|socket|target|mount|automount|slice|path|scope)|initrd-|system-path$|home-manager-path$|home-manager-files$|home-manager-generation$|nixos-system-|etc$|etc-|graphics-drivers$|system-generators$|user-generators$|X-Restart-Triggers|options[.]json$|home-configuration-reference-manpage$|.+[.]conf$|sddm-wrapped$|security-wrapper($|-)|pam[.]d$|hm-modules-messages$|jack-libs$)'

# Kernel-module closures: host-specific (no cache can serve them, cheap to
# assemble), matched on the FULL store name because pname_of's version strip
# would collapse them onto the kernel's pname and fire the BLOCK list. The
# kernel itself carries no such suffix and stays BLOCK-guarded.
KMOD_CLOSURE_RE='^linux-.+-modules(-shrunk)?$'

# Never tolerated, even if baselined: an unserved match means an hours-long
# compile or a wedged boot. The hint names the substituter that OWNS it.
BLOCK_PATTERNS=(
  "linux-cachyos|attic.xuyh0120.win/lantian (bump nix-cachyos-kernel only when its release branch is cached; probe: curl -sI <attic>/<hash>.narinfo)"
  # Deliberately NOT a bare "nvidia" prefix: nvidia-open and
  # nvidia-persistenced are never publicly cached for this kernel (cheap, so
  # baseline-tolerated); a bare prefix would hold every kernel bump forever.
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
  "clang|cache.nixos.org (toolchain; hold - also guards the i686 twin, which llvm/gcc prefixes miss)"
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

# cannot_judge <headline> [nix-evidence-file]: exit 2 naming the cache that is
# down, so a red run says why and no input is blamed for an outage.
cannot_judge() {
  echo "?? plan-gate: $1 - cannot judge this plan." >&2
  if [ -n "${2:-}" ] && [ -s "$2" ]; then
    echo "   nix reported:" >&2
    sed 's/^[[:space:]]*/     /' "$2" >&2
  fi
  echo "   substituters (probed now):" >&2
  printf '%s\n' "${health[@]}" >&2
  echo "   nothing was judged; re-run once every substituter answers (probe: curl -sI <substituter>/nix-cache-info)." >&2
  exit 2
}

hydra_status_name() {
  case "$1" in
    0) echo "succeeded" ;;
    1) echo "failed" ;;
    2) echo "dependency failed" ;;
    3) echo "aborted" ;;
    4) echo "cancelled" ;;
    6) echo "failed with output" ;;
    7) echo "timed out" ;;
    9) echo "unsupported system" ;;
    10) echo "log limit exceeded" ;;
    11) echo "output limit exceeded" ;;
    12) echo "non-deterministic" ;;
    *) echo "status $1" ;;
  esac
}

# hydra_verdict <pname> <output> <system>: sets hv_class/hv_detail from the
# Hydra build of this EXACT output, matched by hash so a later eval's success
# is never mistaken for this lock's. Classes: failed-upstream, hydra-pending,
# no-hydra-job, inconclusive. Globals, not stdout: the lookup budget must
# survive the call.
hydra_lookups=0
hydra_verdict() {
  local pname="$1" out="$2" sys="${3:-x86_64-linux}" hash job list id status finished outs url
  local newest="" nid nstatus nfinished
  hash="$(basename "$out")"; hash="${hash%%-*}"
  job="nixpkgs.$pname.$sys"
  hv_class=inconclusive
  if [ "$hydra_lookups" -ge "$MAX_HYDRA_LOOKUPS" ]; then
    hv_detail="lookup skipped (budget of $MAX_HYDRA_LOOKUPS spent); check: just hydra-check $pname"
    return 0
  fi
  hydra_lookups=$((hydra_lookups + 1))
  if ! list="$(curl -m 10 -sf -H 'Accept: application/json' \
      "$HYDRA/api/latestbuilds?nr=10&project=${HYDRA_JOBSET%%/*}&jobset=${HYDRA_JOBSET#*/}&job=$job" \
      | jq -r '.[] | "\(.id) \(.buildstatus // "-") \(.finished)"')"; then
    hv_detail="Hydra unreachable; check: just hydra-check $pname"
    return 0
  fi
  if [ -z "$list" ]; then
    hv_class=no-hydra-job
    hv_detail="no $HYDRA_JOBSET job $job (unfree, not a Hydra job, or the attr differs from the pname)"
    return 0
  fi
  while read -r id status finished; do
    [ -n "$newest" ] || newest="$id $status $finished"
    outs="$(curl -m 10 -sf -H 'Accept: application/json' "$HYDRA/build/$id" | jq -r '.buildoutputs[]?.path' || true)"
    grep -q "/$hash-" <<<"$outs" || continue
    url="$HYDRA/build/$id"
    if [ "$finished" != 1 ]; then
      hv_class=hydra-pending; hv_detail="queued on Hydra, not built yet: $url"
    elif [ "$status" = 0 ]; then
      hv_class=hydra-pending; hv_detail="Hydra built it but no cache serves it yet: $url"
    elif [ "$status" = 3 ] || [ "$status" = 4 ]; then
      hv_class=hydra-pending; hv_detail="$(hydra_status_name "$status") on Hydra, may be retried: $url"
    else
      hv_class=failed-upstream
      hv_detail="$(hydra_status_name "$status") on Hydra for this exact output: $url"
      read -r nid nstatus nfinished <<<"$newest"
      if [ "$nid" != "$id" ] && [ "$nfinished" = 1 ] && [ "$nstatus" = 0 ]; then
        hv_detail+="; a later build succeeded ($HYDRA/build/$nid), so it is fixed upstream and waits for the channel"
      fi
    fi
    return 0
  done <<<"$list"
  read -r nid nstatus nfinished <<<"$newest"
  if [ "$nfinished" = 1 ]; then nstatus="$(hydra_status_name "$nstatus")"; else nstatus="queued"; fi
  hv_detail="none of $job's last 10 builds made this output (newest: $HYDRA/build/$nid, $nstatus); check: just hydra-check $pname"
  return 0
}

# eval_cause <plan>: classify nix's ROOT error (the last `error:` line - the
# trace prints outermost-first) so a hold names its cause and whether it
# self-heals. For a nixpkgs check-meta refusal, "via" is the nearest
# pkgs/by-name frame above the root: the package that pulled the refused one in.
eval_cause() {
  local msg="" option="" bynames="" name pname why class detail via="" next b
  { IFS= read -r msg; IFS= read -r option; IFS= read -r bynames; } < <(awk '
    /^[[:space:]]*error:/ { root = NR }
    { l[NR] = $0 }
    index($0, "while evaluating the option `") {
      o = $0; sub(/.*while evaluating the option `/, "", o); sub(/'\''.*/, "", o); opt[NR] = o
    }
    match($0, /\/pkgs\/by-name\/[^\/]+\/[^\/]+\/package\.nix/) {
      n = split(substr($0, RSTART, RLENGTH), p, "/"); byname[NR] = p[n - 1]
    }
    END {
      m = ""; o = ""; names = ""
      if (root) {
        # A bare "error:" or a "...:" header carries its message on the next lines.
        m = l[root]; sub(/^[[:space:]]*error:[[:space:]]*/, "", m); sub(/[[:space:]]+$/, "", m)
        j = root + 1
        for (k = 0; k < 2 && (m == "" || m ~ /:$/); k++) {
          while (j <= NR && l[j] ~ /^[[:space:]]*$/) j++
          if (j > NR) break
          s = l[j++]; sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
          m = (m == "" ? s : m " " s)
        }
        for (i = root - 1; i >= 1; i--) if (i in opt) { o = opt[i]; break }
        for (i = root - 1; i >= 1; i--) if (i in byname) names = names byname[i] " "
      }
      print m; print o; print names
    }' "$1") || true
  msg="$(sed -E 's#/nix/store/[0-9a-z]{32}-source/##g' <<<"$msg")"
  name="$(sed -nE "s/^Refusing to evaluate package '([^']+)' in [^ ]+ because it .*/\1/p" <<<"$msg")"
  if [ -n "$name" ]; then
    why="${msg#* because it }"
    pname="$(sed -E 's/-[0-9].*$//' <<<"$name")"
    for b in $bynames; do
      if [ "$b" != "$pname" ]; then via="$b"; break; fi
    done
    detail="$name $why${via:+, via $via}"
    case "$why" in
      "has an unfree license"*)
        class=unfree
        next="needs a repo change - allowlist \"$pname\" as unfree (Hydra never builds it, so baseline it too), or drop the package that pulls it in. Never self-heals." ;;
      "contains elements not built from source"*)
        class=non-source
        next="needs a repo change - allow \"$pname\" as non-source, or drop the package that pulls it in. Never self-heals." ;;
      "is marked as insecure"*)
        class=insecure
        next="needs a repo change - permit \"$name\" in permittedInsecurePackages, or drop the package that pulls it in; self-heals only once nixpkgs ships a fixed version." ;;
      "is not available on the requested hostPlatform"*)
        class=unsupported-platform
        next="needs a repo change - drop or replace the package that pulls it in. Never self-heals." ;;
      "has problems:"*"- broken"*)
        class=broken
        next="hold - self-heals once nixpkgs fixes it; dropping the package that pulls it in unblocks sooner." ;;
      *)
        class=refused
        next="needs a repo change - follow the remediation nix printed above." ;;
    esac
  else
    class=other
    detail="${msg:-nix printed no error message}"
    next="read the trace above - a removed or renamed nixpkgs attribute or option needs a repo change and never self-heals."
  fi
  echo "   eval: $class - $detail"
  [ -z "$option" ] || echo "   option: $option"
  echo "   next: $next"
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/plan-gate.XXXXXX")"
# --cold store paths are read-only, hence the chmod. The trailing || true is
# load-bearing: a failing EXIT trap REPLACES the exit status, turning a 2
# (cannot judge) into a 1 (blame this input).
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
  # Applies to nix's own planning too, so own-cache-only paths land in BUILD
  # and flow through the same classifier. accept-flake-config must be refused:
  # nixConfig and /etc/nix/nix.conf append extra-substituters AFTER any CLI
  # override, so a plain assignment to the base setting is the only spelling
  # that actually excludes a cache (verified against nix 2.34.8).
  SUB_ARGS=(--option accept-flake-config false --option substituters "${SUBSTITUTERS[*]}")
fi

# nix must see the flake's substituters or every path looks unservable and the
# gate is a permanent false alarm. stdin from /dev/null: in baseline mode
# (accept-flake-config refused) nix on a tty PROMPTS y/N per nixConfig
# setting, invisibly into $plan, and a y would re-admit the own cache.
nix_rc=0
nix build "$TOPLEVEL" --dry-run --accept-flake-config --log-format raw \
  --no-write-lock-file "${STORE_ARGS[@]}" "${SUB_ARGS[@]}" "$@" \
  </dev/null >/dev/null 2>"$plan" || nix_rc=$?

# Probed once, before any verdict: every exit 2 below names the cache that was
# down instead of "something was unreachable".
unreachable=()
health=()
for sub in "${SUBSTITUTERS[@]}"; do
  code="$(curl -m 5 -s -o /dev/null -w '%{http_code}' "$sub/nix-cache-info" || true)"
  if [ "$code" = "200" ]; then
    health+=("     up    $sub")
  else
    unreachable+=("$sub")
    if [ "$code" = "000" ]; then code="no response"; else code="HTTP $code"; fi
    health+=("     DOWN  $sub ($code)")
  fi
done

# ---------------------------------------------------------------------------
# Degraded-network detection, BEFORE interpreting the plan. A failed plan is
# the network, not this lock, when nix died on a transport error or a 5xx/
# 408/429: a warm store skips the nix-cache-info handshake, so a cache that
# answers 502 per narinfo is a HARD nix error, which would otherwise read as
# "evaluation failed" and hold every input. A plan that succeeded with a
# substituter down is no better: nix cannot tell "absent" from "unqueryable"
# and reclassifies fetches as builds (8000+ bootstrap derivations, exit 0).
# A daemon crash is never evidence against the lock either: nix 2.34.8's
# daemon worker aborts in querySubstitutablePathInfos under a 502 storm.
# ---------------------------------------------------------------------------
NET_ERROR_RE="^[[:space:]]*error: unable to download '[^']+': (HTTP error (5[0-9]{2}|408|429)|[A-Z][^(]*\([0-9]+\))|API rate limit exceeded"
if [ "$nix_rc" -ne 0 ]; then
  # 5xx retries collapsed per host, so the evidence names the culprit.
  { grep -oE "unable to download 'https?://[^/']+[^']*': HTTP error 5[0-9]{2}" "$plan" || true; } \
    | sed -E "s|unable to download '(https?://[^/']+)[^']*': HTTP error ([0-9]{3})|\1 answered HTTP \2|" \
    | sort | uniq -c | sed -E 's/^ *([0-9]+) (.*)/\2 (x\1)/' >"$workdir/net-evidence"
  if grep -qE "$NET_ERROR_RE" "$plan"; then
    grep -E "$NET_ERROR_RE" "$plan" | sort -u | head -5 >>"$workdir/net-evidence"
    cannot_judge "nix failed on a network error, not on this lock" "$workdir/net-evidence"
  fi
  if grep -q 'Nix daemon disconnected unexpectedly' "$plan"; then
    cannot_judge "the nix daemon died mid-plan - infrastructure, not this lock" "$workdir/net-evidence"
  fi
  cat "$plan" >&2
  echo "!! plan-gate: evaluation failed (see above)." >&2
  eval_cause "$plan" >&2
  exit 1
fi
if grep -qE "unable to download '.*nix-cache-info'|API rate limit exceeded" "$plan"; then
  grep -E "unable to download '.*nix-cache-info'|API rate limit" "$plan" | sort -u | head -5 >"$workdir/net-evidence"
  cannot_judge "a substituter or the GitHub API was unreachable while nix planned" "$workdir/net-evidence"
fi

# ---------------------------------------------------------------------------
# Section-aware split, tested against nix 2.34.8: singular+plural headers,
# variable size units, the read-only-store suffix on UNKNOWN, and warnings
# interleaving mid-plan (any non-entry line closes the section). --log-format
# raw above is load-bearing: internal-json yields an empty plan, and an empty
# plan is a PASS.
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

# Warnings always precede the plan, so "empty" means "no section headers",
# not "zero bytes".
headers="$(grep -cE "^(these [0-9]+ (derivations|paths)|this (derivation|path)) will be (built|fetched|copied)|^don't know how to build" "$plan" || true)"

if [ "$headers" -eq 0 ]; then
  # Normal for an up-to-date machine, and it proves NOTHING about substituter
  # health: paths already in the local store appear in neither section.
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
  cannot_judge "$build_count derivations to build (cap $MAX_BUILDS) or bootstrap seeds present - what 'no substituter reachable' looks like, not what 'upstream broke' looks like"
fi

# ---------------------------------------------------------------------------
# Classify every BUILD derivation from `nix derivation show` (schema v4):
#   fod   - output hash, no output path: a pinned download, not a compile.
#           Also why `out` falls back to "" below; such a row must never reach
#           the probe, where an empty field would corrupt the pipeline.
#   local - preferLocalBuild / allowSubstitutes=false: cheap by design. Flags
#           live in plain env OR the top-level structuredAttrs object (the
#           env.__json spelling is kept for older nix).
#   check - a real candidate; probe substituters for it.
# A zero-build plan makes the grep below match nothing - the BEST outcome, not
# an error, hence the guard.
# ---------------------------------------------------------------------------
grep '^BUILD ' "$workdir/records" | cut -d' ' -f2 | sort -u >"$workdir/build-drvs" || true
if [ -s "$workdir/build-drvs" ]; then
  xargs -a "$workdir/build-drvs" nix derivation show "${STORE_ARGS[@]}" >"$workdir/drvs.json"
else
  echo '{}' >"$workdir/drvs.json"
fi

# Schema v4 (nix 2.34): top level is {"derivations": {...}}, keys and output
# paths are store-RELATIVE, and xargs may split large sets into several
# invocations -> slurp and merge.
# .system rides along as a 4th column so stage 3 can apply the 32-bit policy;
# .triv as a 5th (stage 3 explains it). Attrs are read from plain env AND
# structuredAttrs - nixpkgs defaults many packages to the latter, where every
# .env key is null and an env-only test silently never fires. The store-path
# anchor on stdenv is load-bearing twice: it keeps bootstrap-stage stdenvs
# from matching (the bootstrap guard above must keep firing) and refuses an
# absent stdenv (stage0 seeds carry buildCommand with no stdenv attr).
# Two trivial shapes share that stdenv test: an inline buildCommand with no
# source, and a fetchNupkg repack (src IS the .nupkg; phases, so no
# buildCommand) - unzip-and-copy in seconds, and nixpkgs rehashes every one
# of them on any dotnet hook bump, so a pname baseline can never track them.
jq -rs '
  ([.[] | .derivations // {}] | add // {}) | to_entries[] |
  (.value.env // {}) as $e | (.value.structuredAttrs // {}) as $s |
  {drv: .key,
   out: ((.value.outputs.out.path // (.value.outputs | to_entries[0].value.path)) // ""),
   sys: (.value.system // ""),
   fod: ([.value.outputs[]? | has("hash")] | any),
   local: (($e.preferLocalBuild? == "1") or ($e.allowSubstitutes? == "")
           or ($s.preferLocalBuild? == true)
           or ($s.allowSubstitutes? == false)
           or (($e.__json? // "{}" | fromjson? // {})
               | (.preferLocalBuild == true or .allowSubstitutes == false))),
   triv: (((($e.stdenv // $s.stdenv // "") | tostring)
           | test("^/nix/store/[0-9a-z]{32}-stdenv-[a-z0-9]+-no-cc$"))
          and (((($e.buildCommand // $s.buildCommand) != null)
                and ((($e.src // $s.src // "") | tostring) == "")
                and ((($e.srcs // $s.srcs // "") | tostring) == "")
                and ((.value.outputs | length) == 1))
               or ((($e.src // $s.src // "") | tostring) | endswith(".nupkg"))))} |
  [.drv, .out, (if .fod then "fod" elif .local then "local" else "check" end),
   .sys, (if .triv then "trivial" else "-" end)] | @tsv
' "$workdir/drvs.json" >"$workdir/classified"

# Every BUILD derivation must be accounted for: nix reshaped this schema once
# already, and a future reshape would classify zero rows and silently pass a
# completely unexamined plan.
classified_count="$(wc -l <"$workdir/classified")"
candidate_count="$(wc -l <"$workdir/build-drvs")"
if [ "$classified_count" -ne "$candidate_count" ]; then
  echo "?? plan-gate: classified $classified_count of $candidate_count build derivations - nix derivation show schema drift? Cannot judge an unexamined plan." >&2
  exit 2
fi

local_policy_count="$(awk -F'\t' '$3=="local"' "$workdir/classified" | wc -l)"
fod_count="$(awk -F'\t' '$3=="fod"' "$workdir/classified" | wc -l)"

# A check row without an output path cannot be probed yet WILL build locally
# at unknown cost: fail loudly, and keep it out of the probe input, where an
# empty field would shift every subsequent field's meaning.
awk -F'\t' '$3=="check" && $2==""  {print $1}' "$workdir/classified" >"$workdir/unprobeable"
awk -F'\t' '$3=="check" && $2!=""  {print $1 "\t" $2 "\t" $4}' "$workdir/classified" >"$workdir/to-probe"
awk -F'\t' '$5=="trivial" {print $1}' "$workdir/classified" >"$workdir/trivial-drvs"

violations=0
if [ -s "$workdir/unprobeable" ]; then
  echo "!! plan-gate: build derivations with no computable output path - cannot probe, refusing to pass:" >&2
  sed 's/^/   /' "$workdir/unprobeable" >&2
  violations="$(wc -l <"$workdir/unprobeable")"
fi

# Stage 2: narinfo probe, first 200 wins. Lines are passed WHOLE (-d '\n') and
# split inside the wrapper: xargs -L would treat the tab in "drv<TAB>out" as a
# trailing blank and merge adjacent lines.
probe_one() {
  local drv="$1" out="$2" sys="$3" hash sub code
  hash="$(basename "$out")"; hash="${hash%%-*}"
  for sub in "${SUBSTITUTERS[@]}"; do
    code="$(curl -m 8 -s -o /dev/null -w '%{http_code}' "$sub/$hash.narinfo" || true)"
    if [ "$code" = "200" ]; then echo -e "SERVED\t$drv\t$sub"; return; fi
  done
  echo -e "UNSERVED\t$drv\t$out\t$sys"
}
export -f probe_one
export SUBSTITUTERS_STR="${SUBSTITUTERS[*]}"
# re-materialize the array inside the xargs subshell
probe_wrapper() {
  read -ra SUBSTITUTERS <<<"$SUBSTITUTERS_STR"
  local drv out sys
  IFS=$'\t' read -r drv out sys <<<"$1"
  probe_one "$drv" "$out" "$sys"
}
export -f probe_wrapper
xargs -r -a "$workdir/to-probe" -d '\n' -n1 -P 8 bash -c 'probe_wrapper "$@"' _ >"$workdir/probed" || true
touch "$workdir/probed"

# probe_one emits exactly one line per candidate, so a shortfall means the
# probe itself failed; the || true above must never read as "everything
# served".
probed_count="$(wc -l <"$workdir/probed")"
to_probe_count="$(wc -l <"$workdir/to-probe")"
if [ "$probed_count" -ne "$to_probe_count" ]; then
  echo "?? plan-gate: probed $probed_count of $to_probe_count candidates - the probe itself failed; cannot judge." >&2
  exit 2
fi

served_count="$(grep -c '^SERVED' "$workdir/probed" || true)"

# Stage 3: unserved -> config-artifact / block / baseline / violation, keyed
# on pname (store name with the trailing -<digit>... version stripped).
pname_of() {
  local base; base="$(basename "$1" .drv)"
  base="${base#*-}"
  sed -E 's/-[0-9].*$//' <<<"$base"
}

config_artifacts=0
tolerated=()
trivial_names=()
i686_tolerated=()
unserved_pnames=()
while IFS=$'\t' read -r _ drv out sys; do
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
  blocked_hint=""
  for entry in "${BLOCK_PATTERNS[@]}"; do
    pat="${entry%%|*}"
    if [[ "$pname" == "$pat"* ]]; then blocked_hint="${entry#*|}"; break; fi
  done
  if [ -n "$blocked_hint" ]; then
    # $sys in the message: an i686 row is indistinguishable from its x86_64
    # twin by name, and hydra-check reports only the x86_64 job.
    echo "!! VIOLATION: $pname would compile locally ($(basename "$drv")${sys:+, $sys})" >&2
    echo "   expected from: $blocked_hint" >&2
    echo "   output: $out" >&2
    hydra_verdict "$pname" "$out" "$sys"
    echo "   hydra: $hv_class - $hv_detail" >&2
    violations=$((violations + 1))
    continue
  fi
  # Trivial builder: an inline shell snippet with no source, or a .nupkg
  # repack, under a compiler-less stdenv - cheap by construction, whatever it
  # is named, and every dependency is its own BUILD row. BLOCK stays FIRST:
  # llvm-src/clang-src/niri-<v>-vendor match this shape yet are the
  # mid-toolchain-rebuild tripwire (deliberately the OPPOSITE order of the
  # regex classes above).
  if grep -qxF "$drv" "$workdir/trivial-drvs"; then
    trivial_names+=("$pname")
    continue
  fi
  # i686 rows stay out of the baseline: a pname key cannot tell an i686
  # derivation from its x86_64 twin, and the policy arm below covers them.
  [ "$sys" = "i686-linux" ] || unserved_pnames+=("$pname")
  if [ "$sys" = "i686-linux" ]; then
    i686_tolerated+=("$pname")
  elif [ "$WRITE_BASELINE" -eq 0 ] && [ -f "$BASELINE" ] && grep -qxF "$pname" "$BASELINE"; then
    tolerated+=("$pname")
  elif [ "$WRITE_BASELINE" -eq 0 ]; then
    echo "!! VIOLATION: $pname is a NEW unserved local build (not in $(basename "$BASELINE")${sys:+; $sys})" >&2
    echo "   no configured substituter serves it." >&2
    echo "   output: $out" >&2
    hydra_verdict "$pname" "$out" "$sys"
    echo "   hydra: $hv_class - $hv_detail" >&2
    # The baseline is for packages no one ever serves; an upstream failure or
    # a pending build would be tolerated there forever.
    case "$hv_class" in
      failed-upstream) echo "   next: hold - it cannot build here either; self-heals once ${HYDRA_JOBSET/\//-} ships a fixed eval. Never re-baseline it." >&2 ;;
      hydra-pending) echo "   next: hold - self-heals once Hydra finishes and the cache catches up. Never re-baseline it." >&2 ;;
      *) echo "   next: if Hydra never builds it and it is cheap (wrapper, repack, unfree blob), re-measure with: just gate-baseline; otherwise hold." >&2 ;;
    esac
    violations=$((violations + 1))
  fi
done < <(grep '^UNSERVED' "$workdir/probed" || true)

# A flag, not a violation: the counter must stay reconcilable with the
# per-row output. Skipped in baseline mode - a measurement holds nothing.
i686_over_cap=0
if [ "$WRITE_BASELINE" -eq 0 ] && [ "${#i686_tolerated[@]}" -gt "$MAX_I686" ]; then
  echo "!! plan-gate: ${#i686_tolerated[@]} unserved 32-bit builds (cap $MAX_I686) - an i686 mass rebuild no cache will absorb, not the usual leaf set. Holding." >&2
  i686_over_cap=1
fi

if [ "$WRITE_BASELINE" -eq 1 ]; then
  # Never merge a measurement taken during an outage: everything the dead
  # cache serves would probe unserved and, merge semantics, stay tolerated
  # forever.
  if [ "${#unreachable[@]}" -gt 0 ]; then
    cannot_judge "not writing a baseline measured while substituters were unreachable"
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
      # An if, not '[ ] && echo': a skipped final pname would return 1 and
      # errexit would kill the script before the mv below.
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
  "$config_artifacts config-artifacts, ${#trivial_names[@]} trivial-builders," \
  "${#i686_tolerated[@]} i686-tolerated, ${#tolerated[@]} tolerated, $violations violations."
if [ "${#trivial_names[@]}" -gt 0 ]; then
  echo "   trivial-builders (inline buildCommand or .nupkg repack, no compiler; builds at switch in seconds): $(printf '%s ' "${trivial_names[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
fi
if [ "${#i686_tolerated[@]}" -gt 0 ]; then
  echo "   i686-tolerated (32-bit, unserved by policy; compiles at switch): $(printf '%s ' "${i686_tolerated[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
fi
if [ "${#tolerated[@]}" -gt 0 ]; then
  echo "   tolerated (expected-local; compiles at switch): $(printf '%s ' "${tolerated[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
fi
if [ "${#unreachable[@]}" -gt 0 ]; then
  # i686-tolerated rows count too: they are tolerated, not flagged, yet only
  # a third-party cache ever serves them - a dead cache makes them phantoms
  # that would otherwise pass silently.
  if [ "$violations" -gt 0 ] || [ "${#i686_tolerated[@]}" -gt 0 ]; then
    cannot_judge "violations/i686-tolerated above may be phantoms of the unreachable cache"
  fi
  echo "?? plan-gate: passing with substituters down - no unserved row depended on them:" >&2
  printf '%s\n' "${health[@]}" >&2
fi
[ "$violations" -eq 0 ] && [ "$i686_over_cap" -eq 0 ] || exit 1
