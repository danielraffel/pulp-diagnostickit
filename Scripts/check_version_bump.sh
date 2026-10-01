#!/bin/bash
# "No changes without versioning": fail when the app's source changed but
# VERSION did not move.
#
#   Scripts/check_version_bump.sh [--base <ref>]
#
# Two rules, both over the paths that change what the app does (APP_PATHS):
#
#   1. Released means frozen. If tag v<VERSION> exists, those paths must be
#      byte-identical to the tag. A change after a release needs a new
#      VERSION, so two different builds never claim the same kit version.
#   2. With --base (a pull request's base, or origin/main), a branch that
#      changes those paths since its merge-base must raise VERSION above the
#      base's VERSION (a base without a VERSION file counts as 0.0.0).
#
# Exit 0 when consistent, 1 when a bump is missing, 2 on a usage error.
set -euo pipefail

APP_PATHS=(Sources Resources Scripts/build_app.sh Package.swift DiagnosticKit.entitlements JUCE/CMakeLists.txt JUCE/Source)

base=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --base) base="${2:?--base needs a ref}"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

root="$(git rev-parse --show-toplevel)"
cd "$root"

semver_re='^[0-9]+\.[0-9]+\.[0-9]+$'
version="$(tr -d '[:space:]' < VERSION 2>/dev/null || true)"
[[ "$version" =~ $semver_re ]] || { echo "FAIL VERSION must hold MAJOR.MINOR.PATCH, found '${version}'"; exit 1; }

# 0 when $1 > $2 (both MAJOR.MINOR.PATCH).
version_gt() {
    local IFS=.
    local -a a=($1) b=($2)
    for i in 0 1 2; do
        ((10#${a[i]} > 10#${b[i]})) && return 0
        ((10#${a[i]} < 10#${b[i]})) && return 1
    done
    return 1
}

failed=0
if git rev-parse -q --verify "refs/tags/v$version^{commit}" >/dev/null; then
    changed="$(git diff --name-only "v$version" HEAD -- "${APP_PATHS[@]}")"
    if [[ -n "$changed" ]]; then
        echo "FAIL v$version is already released, and the app's source changed since:"
        printf '       %s\n' $changed
        echo "     raise VERSION (patch for fixes, minor for new behaviour, major for breaking config)"
        failed=1
    fi
fi

if [[ -n "$base" ]]; then
    merge_base="$(git merge-base "$base" HEAD)" || { echo "cannot find a merge-base with $base" >&2; exit 2; }
    changed="$(git diff --name-only "$merge_base" HEAD -- "${APP_PATHS[@]}")"
    base_version="$(git show "$merge_base:VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$base_version" =~ $semver_re ]] || base_version=0.0.0
    if [[ -n "$changed" ]] && ! version_gt "$version" "$base_version"; then
        echo "FAIL the app's source changed since $base, but VERSION is $version (base has $base_version):"
        printf '       %s\n' $changed
        failed=1
    fi
fi

if ((failed)); then exit 1; fi
echo "PASS DiagnosticKit $version${base:+ (checked against $base)}"
