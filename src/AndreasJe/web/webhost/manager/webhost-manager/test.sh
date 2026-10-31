#!/usr/bin/env bash
# manager/webhost-manager/test.sh — offline self-test: the release declaration
# passes the schema, a broken one does not, and --help --json lists every verb.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
root="$(cd "${here}/../.." && pwd)"
fail=0
ok() { printf '  PASS: %s\n' "$1"; }
no() { printf '  FAIL: %s\n' "$1"; fail=1; }
v() { jq -r --slurpfile s "${here}/schema.json" -f "${root}/lib/declaration.jq" "$@"; }

[[ -z "$(v "${root}/webhost-manager.json")" ]] && ok "release declaration is valid" || no "release declaration is valid"
bad="$(jq '.sites = [{name: "Bad", template: "static", runtime: "static", public: {domain: "x"}}]' "${root}/webhost-manager.json" | v)"
grep -q 'sites\[0\].name' <<<"${bad}" && grep -q 'sites\[0\].public.domain' <<<"${bad}" \
    && ok "invalid site refused, naming its paths" || no "invalid site refused, naming its paths"
for verb in "site add" "site list" "site modify" "site quarantine" "reconcile" "snapshots build"; do
    jq -e --arg v "${verb}" 'any(.verbs[]; .verb == $v)' "${here}/help.json" >/dev/null \
        && ok "--help --json lists '${verb}'" || no "--help --json lists '${verb}'"
done
exit "${fail}"
