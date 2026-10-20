#!/usr/bin/env bash
# mikrotik-controller's offline tests: the mapping and the apply plan over RouterOS
# fixtures (test_mikrotik.py), the playbooks' syntax, and the contract verbs.
# No switch is called.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_bin="${TAPPAAS_GCROOTS:-${HOME}/.tappaas-gcroots}/mikrotik-controller-env/bin"
py="${MIKROTIK_PYTHON:-${env_bin}/python3}"; [[ -x "${py}" ]] || py="$(command -v python3)"
PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
no() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
if out="$("${py}" "${here}/test_mikrotik.py" 2>&1)"; then
    ok "mapping and plan: $(grep -oE 'Ran [0-9]+ tests' <<<"${out}")"
else
    no "mapping and plan:"; tail -20 <<<"${out}"
fi
if [[ -x "${env_bin}/ansible-playbook" ]]; then
    for pb in "${here}"/playbooks/*.yml; do
        if ANSIBLE_LOCAL_TEMP="$(mktemp -d)" "${env_bin}/ansible-playbook" -i localhost, --syntax-check "${pb}" >/dev/null 2>&1; then
            ok "$(basename "${pb}"): syntax"
        else
            no "$(basename "${pb}"): syntax"
        fi
    done
    if MIKROTIK_PYTHON="${env_bin}/python3" "${env_bin}/python3" -c 'import librouteros' 2>/dev/null; then ok "librouteros is in the runtime"; else no "librouteros is not in the runtime"; fi
    if "${env_bin}/ansible-galaxy" collection list community.routeros 2>/dev/null | grep -q community.routeros; then ok "community.routeros is in the runtime"; else no "community.routeros is not in the runtime"; fi
else
    echo "  - runtime not built (${env_bin}): playbook syntax not checked — install.sh builds it"
fi
d="$(MIKROTIK_PYTHON="${py}" "${here}/mikrotik-controller" describe)" || no "describe"
for want in '.contracts == ["switch/1"]' '.vendors == ["mikrotik"]' '.arch == "device"' '.capabilities | index("mlag")'; do
    if jq -e "${want}" >/dev/null <<<"${d}"; then ok "describe: ${want}"; else no "describe: ${want}"; fi
done
MIKROTIK_PYTHON="${py}" "${here}/mikrotik-controller" supports mikrotik && ok "supports mikrotik" || no "supports mikrotik"
MIKROTIK_PYTHON="${py}" "${here}/mikrotik-controller" supports unifi; [[ $? -eq 3 ]] && ok "supports unifi: no (3)" || no "supports unifi should be 3"
MIKROTIK_PYTHON="${py}" "${here}/mikrotik-controller" interrogate --controller x --ip 1 2>/dev/null; [[ $? -eq 3 ]] && ok "interrogate --controller: not mine (3, arch device)" || no "interrogate --controller should be 3"
MIKROTIK_PYTHON="${py}" "${here}/mikrotik-controller" apply 2>/dev/null; [[ $? -eq 2 ]] && ok "apply without --switch: bad usage (2)" || no "apply without --switch should be 2"
echo "mikrotik-controller: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
