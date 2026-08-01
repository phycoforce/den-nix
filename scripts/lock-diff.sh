#!/usr/bin/env bash
# lock-diff: which ROOT inputs moved between two locks, keyed on the root
# alias (never the node name: the node literally called "nixpkgs" in this lock
# is nix-cachyos-kernel's own pin, the system's nixpkgs is the node the root
# alias resolves to). Transitive nodes are prefixed "~".
set -euo pipefail

old="${1:-}"
new="${2:-flake.lock}"

revs() {
  jq -r '
    (.nodes.root.inputs | to_entries | map({key: .value, value: .key}) | from_entries) as $alias
    | .nodes | to_entries[] | select(.value.locked)
    | "\($alias[.key] // ("~" + .key)) \(.value.locked.rev // .value.locked.narHash)"
  ' "$1" | sort
}

scratch=""
if [ -z "$old" ]; then
  scratch="$(mktemp "${TMPDIR:-/tmp}/flake.lock.head.XXXXXX")"
  git show HEAD:flake.lock >"$scratch"
  old="$scratch"
fi
diff -u <(revs "$old") <(revs "$new") || true
[ -z "$scratch" ] || rm -f "$scratch"
