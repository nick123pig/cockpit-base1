#!/usr/bin/env bash
# skip-preview: predict which cockpit-base1 lines would REBUILD vs SKIP on the
# next CI run, comparing THIS working tree's tooling fingerprint against what
# is published on npm. Standalone - not used by CI, and NOT part of the
# fingerprint (only build.sh/.babelrc.json/package.json/README.md/LICENSE are).
#
# Usage: ./scripts/skip-preview.sh [starting_cockpit_version]
#
# NOTE: this is a conservative lower bound. CI can skip MORE than shown here
# because the stage-manifest can also skip versions that are staged-but-pending
# approval with matching fingerprints.
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGE_NAME=cockpit-base1
START=${1:-311}

tooling-hash() {
    sha256sum build.sh .babelrc.json package.json README.md LICENSE 2>/dev/null | sha256sum | awk '{print $1}'
}
version-prefix() {
    local t=${1:-$VERSION}
    [[ "$t" == *.* ]] && echo "$t" || echo "$t.0"
}
published-latest() { # tag -> highest published <prefix>.<n> (or empty)
    local prefix re
    prefix=$(version-prefix "$1")
    re="${prefix//./\\.}"
    npm view "$PACKAGE_NAME" versions --json 2>/dev/null \
        | jq -r '.[]' | grep "^${re}\.[0-9]\+$" | sort -V | tail -1
}

local_tool=$(tooling-hash)
echo "current working tree tooling: ${local_tool:0:12}"
echo "fetching cockpit release list from api.github.com ..."

tags="$(mktemp)"
page=1
while (( page <= 50 )); do
    if body="$(curl -fsSL "https://api.github.com/repos/cockpit-project/cockpit/releases?per_page=100&page=$page")"; then
        [[ "$(printf '%s' "$body" | jq -r 'length')" == "0" ]] && break
        printf '%s' "$body" | jq -r '.[] | select(.draft != true) | .tag_name' >> "$tags"
        page=$((page + 1))
    else
        break
    fi
done

versions="$(grep -E '^[0-9]+([.][0-9]+)?$' "$tags" | awk -F. -v s="$START" 'NF <= 2 && $1 >= s' | sort -t. -k1,1n -k2,2n)"
rm -f "$tags"

skip=0; rebuild=0
printf '%-8s %-14s %-14s %s\n' TAG PUBLISHED STORED_TOOL VERDICT
for v in $versions; do
    cur=$(published-latest "$v")
    if [[ -z "$cur" ]]; then
        printf '%-8s %-14s %-14s REBUILD (no published build yet)\n' "$v" "-" "-"
        rebuild=$((rebuild + 1))
        continue
    fi
    info=$(npm view "$PACKAGE_NAME@$cur" buildInfo 2>/dev/null || true)
    stored=${info%%-*}
    stored12=${stored:0:12}
    [[ -z "$stored12" ]] && stored12="<none>"
    if [[ -n "$stored" && "$stored" == "$local_tool" ]]; then
        printf '%-8s %-14s %-14s SKIP\n' "$v" "$cur" "$stored12"
        skip=$((skip + 1))
    else
        printf '%-8s %-14s %-14s REBUILD (tooling/inputs changed)\n' "$v" "$cur" "$stored12"
        rebuild=$((rebuild + 1))
    fi
done
echo
echo "RESULT: $skip would be skipped, $rebuild would be rebuilt  (total $(($skip + $rebuild)) lines, conservatively)"