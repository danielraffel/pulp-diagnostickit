#!/bin/bash
# Controls for check_version_bump.sh, in a throwaway repository: each planted
# defect must fail the check and each repaired state must pass, so a check
# that silently passes everything cannot go unnoticed.
set -euo pipefail

check="$(cd "$(dirname "$0")" && pwd)/check_version_bump.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

git init -q -b main
git config user.email "test@example.invalid"
git config user.name "test"
git config commit.gpgsign false
git config tag.gpgsign false
mkdir -p Sources Tests
echo 1.0.0 > VERSION
echo 'print("a")' > Sources/App.swift
echo 'test' > Tests/T.swift
git add VERSION Sources Tests && git commit -qm base
git tag v1.0.0

failures=0
expect() { # expect <pass|fail> <name> -- <args...>
    local want="$1" name="$2"; shift 3
    if "$check" "$@" >"$work/out" 2>&1; then got=pass; else got=fail; fi
    if [[ "$got" == "$want" ]]; then
        echo "PASS $name"
    else
        echo "FAIL $name (expected $want, got $got)"; sed 's/^/     /' "$work/out"
        failures=$((failures + 1))
    fi
}

expect pass "released tree with no change accepted" --
git checkout -qb feature
echo 'print("b")' > Sources/App.swift
git commit -qam "change source, no bump"
expect fail "source change after a release without a bump rejected" --
expect fail "source change on a branch without a bump rejected" -- --base main

echo 1.0.1 > VERSION && git commit -qam bump
expect pass "source change with a bump accepted" --
expect pass "bumped branch accepted against its base" -- --base main

git checkout -q main && git checkout -qb tests-only
echo 'more' >> Tests/T.swift && git commit -qam "tests only"
expect pass "change outside the app's paths needs no bump" -- --base main

git checkout -q main && git checkout -qb downgrade
echo 'print("c")' > Sources/App.swift && echo 0.9.9 > VERSION && git commit -qam down
expect fail "a lower VERSION is not a bump" -- --base main

echo 'one.two' > VERSION && git commit -qam bad
expect fail "malformed VERSION rejected" --

exit $((failures > 0))
