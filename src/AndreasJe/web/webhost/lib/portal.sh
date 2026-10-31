#!/usr/bin/env bash
#
# lib/portal.sh — the mothership's side of the site portal, run by
# `webhost-manager portal sync` (a user timer, every minute). The portal in the
# webhost container only writes requests; this validates them, creates and
# deletes sites through the manager, and gives the portal what it shows: its
# settings, the gate's key and the list of sites.
# Source from webhost-manager (needs its declaration helpers).
#
# shellcheck disable=SC2148

readonly PORTAL_GROUPS='["webhost","installer"]'
readonly PORTAL_ADMIN_GROUPS='["installer"]'
readonly PORTAL_SITE_LIMIT=10
readonly PORTAL_MAX_UPLOAD_MB=100

# portal_domain — the portal's public name: the webhost instance's proxyDomain.
portal_domain() {
    local cfg="${WEBHOST_CONFIG_DIR}/${INSTANCE}.json" d base
    d="$(jq -r '.proxyDomain // .config["network:proxy"].proxyDomain // empty' "${cfg}")"
    if [[ -z "${d}" ]]; then
        base="$(jq -r '.tappaas.domain // empty' "${WEBHOST_CONFIG_DIR}/configuration.json")"
        d="$(jq -r '.vmname' "${cfg}").${base}"
    fi
    printf '%s\n' "${d}"
}

# portal_gate_key — the gate's provider (client id, secret, application slug)
# from Authentik, found by the portal's external host, as the console does.
portal_gate_key() {
    local cred="${HOME}/.authentik-credentials.txt" url token host pk
    [[ -r "${cred}" ]] || { warn "portal: no ${cred}; the portal cannot verify logins"; return 1; }
    url="$(sed -n 's/^url=//p' "${cred}" | sed 's#/*$##')"
    token="$(sed -n 's/^token=//p' "${cred}")"
    host="https://$(portal_domain)"
    pk="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${token}" "${url}/api/v3/providers/proxy/?page_size=500" \
        | jq -r --arg h "${host}" '.results[] | select((.external_host | rtrimstr("/") | ascii_downcase) == $h) | .pk' | head -1)" || return 1
    [[ -n "${pk}" ]] || { warn "portal: no Authentik gate for ${host} yet (identity:accessControl)"; return 1; }
    curl -fsS --max-time 15 -H "Authorization: Bearer ${token}" "${url}/api/v3/providers/oauth2/${pk}/" \
        | jq -c '{client_id, secret: .client_secret, slug: .assigned_application_slug}
                 | select(.client_id and .secret and .slug)'
}

# portal_settings — what the portal shows and enforces.
portal_settings() {
    local fw base tj
    fw="$(jq -r '.dmz.ip // empty' "${WEBHOST_CONFIG_DIR}/zones.json" | sed 's#\.[0-9]*/.*#.1#')"
    base="$(jq -r '.tappaas.domain // empty' "${WEBHOST_CONFIG_DIR}/configuration.json")"
    for tj in "${WEBHOST_ROOT}"/templates/*/template.json "${CUSTOM_TEMPLATE_DIR}"/*/template.json; do
        [[ -f "${tj}" ]] || continue; jq -c '{name: .template, runtime, summary, group, label, guide: (.guide // []), database: (.database // "none"), app: (.app // null)}' "${tj}"
    done | jq -sc --arg fw "${fw}" --arg base "${base}" --argjson g "${PORTAL_GROUPS}" --argjson a "${PORTAL_ADMIN_GROUPS}" \
        --argjson lim "${PORTAL_SITE_LIMIT}" --argjson mb "${PORTAL_MAX_UPLOAD_MB}" \
        '{listen: "0.0.0.0:8080", firewall: $fw, base_domain: $base, groups: $g, admin_groups: $a,
          site_limit: $lim, max_upload_mb: $mb, templates: .}'
}

# portal_sites — every declared site, as the portal lists it.
portal_sites() {
    local s state cfg out="[]"
    for s in $(declared_sites); do
        cfg="${WEBHOST_CONFIG_DIR}/${s}.json"
        state="$(site_entry "${s}" | jq -r '.state // "active"')"
        if [[ "${state}" == active ]]; then
            if [[ ! -f "${cfg}" ]]; then state=pending
            elif [[ "$(jq -r '.suspended // false' "${cfg}")" == true ]]; then state=suspended
            else state=live; fi
        fi
        out="$(jq --argjson e "$(site_entry "${s}")" --arg st "${state}" \
            '. + [{name: $e.name, owner: ($e.owner // null), template: $e.template, runtime: $e.runtime,
                   domain: $e.public.domain, public: (($e.public.zones // []) | index("internet") != null),
                   source: ($e.source // {}), state: $st}]' <<<"${out}")"
    done
    printf '%s\n' "${out}"
}

# req_set <id> <status> [message] — record a request's progress for the portal.
req_set() {
    webhost_sh "$1" "$2" "${3:-}" <<'EOF'
f="/srv/webhost/portal/requests/$1.json"
[[ -f "${f}" ]] || exit 0
jq --arg s "$2" --arg m "$3" --arg t "$(date -u +%FT%TZ)" '.status = $s | .message = $m | .updated = $t' "${f}" > "${f}.new" \
    && chmod 0664 "${f}.new" && chown --reference="${f}" "${f}.new" && mv "${f}.new" "${f}"
EOF
}

# log_clean <file> — the last lines of a log, fit for a site owner: no colour
# codes, values after secret-sounding names hidden.
log_clean() {
    [[ -f "$1" ]] || return 0
    tail -n 150 "$1" | sed -E 's/\x1b\[[0-9;]*m//g; s/((pass(word)?|secret|token|api[_-]?key|private[_-]?key)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[^[:space:],"'"'"']+/\1[hidden]/Ig'
}

# log_error <file> <fallback> — the log's last error line, else the fallback.
log_error() {
    local e
    e="$(log_clean "$1" | grep -E '\[Error\]' | tail -n 1 | sed -E 's/^.*\[Error\][[:space:]]*//')"
    printf '%s' "${e:-$2}"
}

# portal_log <id> <file> — the request's log, for the portal to show.
portal_log() {
    local tmp
    tmp="$(mktemp)"
    log_clean "$2" >"${tmp}"
    pct_push "${WEBHOST_NODE}" "${WEBHOST_VMID}" "${tmp}" "/srv/webhost/portal/logs/$1.log" 0644 || true
    rm -f "${tmp}"
}

# portal_reject <id> <site> <message> — and forget anything it uploaded.
portal_reject() {
    req_set "$1" rejected "$3"
    webhost_sh "$2" "$1" <<'EOF'
[[ "$1" =~ ^[a-z][a-z0-9-]{0,30}$ ]] && rm -rf "/srv/webhost/portal/uploads/$1"
rm -f "/srv/webhost/portal/tokens/$2"
EOF
}

# portal_take_token <id> <site> — the token the portal saved with request <id>
# moves to the mothership's store; the portal keeps no copy.
portal_take_token() {
    webhost_sh "$1" <<'EOF' | token_set "$2"
f="/srv/webhost/portal/tokens/$1"; cat "${f}" 2>/dev/null; rm -f "${f}"
EOF
}

portal_token() {
    local id="$1" req="$2" site user owner
    site="$(jq -r .site <<<"${req}")"; user="$(jq -r .user <<<"${req}")"
    owner="$(site_entry "${site}" | jq -r '.owner // empty')"
    if [[ -z "$(site_entry "${site}")" ]] || { [[ "${owner}" != "${user}" ]] && ! jq -e '.groups | index("installer")' <<<"${req}" >/dev/null; }; then
        webhost_sh "${id}" <<<'rm -f "/srv/webhost/portal/tokens/$1"'
        req_set "${id}" rejected "${site} is not yours."; return
    fi
    if ! portal_take_token "${id}" "${site}"; then req_set "${id}" rejected "The token is not valid."; return; fi
    mirrors_sync "${site}"
    if [[ -f "${WEBHOST_TOKENS}/${site}" ]]; then req_set "${id}" "done" "The access token is saved; the next fetch uses it."
    else req_set "${id}" "done" "The access token is removed."; fi
}

portal_create() {
    local id="$1" req="$2" site user tpl tj rt domain entry n tmp insp rules msg line v log pid
    site="$(jq -r .site <<<"${req}")"; user="$(jq -r .user <<<"${req}")"
    tpl="$(jq -r .template <<<"${req}")"; domain="$(jq -r .domain <<<"${req}")"
    req_set "${id}" checking "Checking the request."

    validate_site_name "${site}" 2>/dev/null || { portal_reject "${id}" "${site}" "Invalid site name."; return; }
    [[ "${site}" != canary-* && -z "$(site_entry "${site}")" && ! -f "${WEBHOST_CONFIG_DIR}/${site}.json" ]] \
        || { portal_reject "${id}" "${site}" "A site named ${site} exists."; return; }
    [[ "${user}" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || { portal_reject "${id}" "${site}" "Unknown user."; return; }
    tj="${WEBHOST_ROOT}/templates/${tpl}/template.json"
    [[ -f "${tj}" ]] || tj="${CUSTOM_TEMPLATE_DIR}/${tpl}/template.json"
    [[ "${tpl}" =~ ^[a-z][a-z0-9-]*$ && -f "${tj}" ]] || { portal_reject "${id}" "${site}" "Unknown template ${tpl}."; return; }
    rt="$(jq -r .runtime "${tj}")"
    if jq -e --arg d "${domain}" '[.sites[] | .public.domain] | index($d)' "${HM_DECL}" >/dev/null; then
        portal_reject "${id}" "${site}" "${domain} is used by another site."; return
    fi
    if ! jq -e '.groups | index("installer")' <<<"${req}" >/dev/null; then
        n="$(jq --arg u "${user}" '[.sites[] | select(.owner == $u)] | length' "${HM_DECL}")"
        (( n < PORTAL_SITE_LIMIT )) || { portal_reject "${id}" "${site}" "The limit of ${PORTAL_SITE_LIMIT} sites is reached."; return; }
    fi
    entry="$(jq -c --arg n "${site}" --arg u "${user}" --arg t "${tpl}" --arg rt "${rt}" --arg d "${domain}" \
        '{name: $n, owner: $u, template: $t, runtime: $rt, public: ({domain: $d} + (if .public then {zones: ["internet"]} else {} end))}
         + (if .source.repo then {source: {repo: .source.repo, ref: (.source.ref // "main")}}
            elif .source.upload then {source: {upload: true}} else {} end)' <<<"${req}")"
    tmp="$(mktemp)"
    jq --argjson e "${entry}" '.sites += [$e]' "${HM_DECL}" >"${tmp}"
    if ! line="$(hm_write "${tmp}" 2>&1)"; then
        rm -f "${tmp}"; portal_reject "${id}" "${site}" "The request does not validate: ${line//$'\n'/; }"; return
    fi
    rm -f "${tmp}"
    install -d -m 0755 "$(dirname "$(decl_path "${site}")")"
    website_decl "${site}" >"$(decl_path "${site}")"
    if jq -e '.token' <<<"${req}" >/dev/null; then
        portal_take_token "${id}" "${site}" || { set_entry_remove "${site}"; portal_reject "${id}" "${site}" "The access token is not valid."; return; }
    fi

    if jq -e '.source' <<<"${entry}" >/dev/null; then
        req_set "${id}" inspecting "Fetching and inspecting the content."
        mirrors_sync "${site}"
        insp="$(inspection_of "${site}")"
        if [[ "$(jq -r '.verdict // empty' <<<"${insp}")" != pass ]]; then
            rules="$(jq -r '[.findings[]? | select(.level == "block") | "\(.rule) (\(.file))"] | join(", ")' <<<"${insp}")"
            set_entry_remove "${site}"
            if [[ -n "${rules}" ]]; then msg="The inspection blocked the content: ${rules}."; else msg="No content could be fetched from the source."; fi
            portal_reject "${id}" "${site}" "${msg}"
            return
        fi
    fi
    req_set "${id}" creating "Creating the site; this takes two to three minutes."
    log="/home/tappaas/logs/webhost-${site}-create.log"
    rm -f "${log}"
    (while sleep 10; do portal_log "${id}" "${log}"; done) &
    pid=$!
    line="$(reconcile_site "${site}" 1)"
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    portal_log "${id}" "${log}"
    case "${line}" in
        *": created") req_set "${id}" live "Your site is live." ;;
        *)  # no container came of it: forget the site, so the name is free again
            v="$(jq -r '.vmid // empty' "${WEBHOST_CONFIG_DIR}/${site}.json" 2>/dev/null || true)"
            if [[ -z "${v}" ]] || ! resolve_lxc_node "${v}" >/dev/null 2>&1; then
                set_entry_remove "${site}"
                rm -f "${WEBHOST_CONFIG_DIR}/${site}.json" "${WEBHOST_CONFIG_DIR}/${site}.json.orig"
            fi
            req_set "${id}" failed "$(log_error "${log}" "${line#*: }")" ;;
    esac
}

# set_entry_remove <site> — forget a site that never got a container.
set_entry_remove() {
    local tmp
    tmp="$(mktemp)"
    jq --arg n "$1" '.sites |= map(select(.name != $n))' "${HM_DECL}" >"${tmp}" && install -m 0644 "${tmp}" "${HM_DECL}"
    rm -f "${tmp}"
    rm -rf "${WEBHOST_DECL_DIR:?}/$1"
    rm -f "${WEBHOST_TOKENS:?}/$1"
    mirrors_sync
}

portal_delete() {
    local id="$1" req="$2" site user owner
    site="$(jq -r .site <<<"${req}")"; user="$(jq -r .user <<<"${req}")"
    owner="$(site_entry "${site}" | jq -r '.owner // empty')"
    if [[ -z "$(site_entry "${site}")" ]]; then req_set "${id}" rejected "No site ${site}."; return; fi
    if [[ "${owner}" != "${user}" ]] && ! jq -e '.groups | index("installer")' <<<"${req}" >/dev/null; then
        req_set "${id}" rejected "${site} is not yours."; return
    fi
    req_set "${id}" deleting "Deleting ${site}."
    if (cmd_site_delete "${site}") >/dev/null 2>&1; then req_set "${id}" "done" "${site} is deleted. Its backups are kept: restore it under Deleted sites."
    else req_set "${id}" failed "Deleting ${site} failed; an administrator has been told."; fi
}

# portal_backups [force] — each site's restore points and the deleted sites
# that can come back, for the portal; refreshed every 30 minutes or on demand.
portal_backups() {
    local age s v out='{"sites": {}, "deleted": []}' rec tmp
    if [[ -z "${1:-}" ]]; then
        age="$(webhost_sh <<<'f=/srv/webhost/portal/backups.json; [[ -s $f ]] && echo $(( ($(date +%s) - $(stat -c %Y $f)) / 60 )) || echo 9999')"
        [[ "${age}" -ge 30 ]] || return 0
    fi
    for s in $(declared_sites); do
        v="$(jq -r '.vmid // empty' "${WEBHOST_CONFIG_DIR}/${s}.json" 2>/dev/null || true)"
        [[ -n "${v}" ]] || continue
        out="$(jq --arg s "${s}" --argjson b "$(site_backups "${v}" | jq -c '.[:10]')" '.sites[$s] = $b' <<<"${out}")"
    done
    for rec in "${WEBHOST_DELETED}"/*.json; do
        [[ -f "${rec}" ]] || continue
        out="$(jq --slurpfile r "${rec}" --argjson b "$(site_backups "$(jq -r .vmid "${rec}")" | jq -c '.[:10]')" \
            '.deleted += [$r[0] | {name: .entry.name, owner: (.entry.owner // null), template: .entry.template,
                                   domain: .entry.public.domain, deleted, backups: $b}]' <<<"${out}")"
    done
    tmp="$(mktemp)"
    printf '%s\n' "${out}" >"${tmp}"
    pct_push "${WEBHOST_NODE}" "${WEBHOST_VMID}" "${tmp}" /srv/webhost/portal/backups.json 0644 || true
    rm -f "${tmp}"
}

portal_restore() {
    local id="$1" req="$2" site user owner backup log pid out
    site="$(jq -r .site <<<"${req}")"; user="$(jq -r .user <<<"${req}")"; backup="$(jq -r '.backup // empty' <<<"${req}")"
    owner="$(site_entry "${site}" | jq -r '.owner // empty')"
    [[ -n "${owner}" ]] || owner="$(jq -r '.entry.owner // empty' "${WEBHOST_DELETED}/${site}.json" 2>/dev/null || true)"
    if ! validate_site_name "${site}" 2>/dev/null || { [[ -z "$(site_entry "${site}")" ]] && [[ ! -f "${WEBHOST_DELETED}/${site}.json" ]]; }; then
        req_set "${id}" rejected "No site ${site} to restore."; return
    fi
    if [[ "${owner}" != "${user}" ]] && ! jq -e '.groups | index("installer")' <<<"${req}" >/dev/null; then
        req_set "${id}" rejected "${site} is not yours."; return
    fi
    if [[ -n "${backup}" && ! "${backup}" =~ ^[A-Za-z0-9_.-]+:backup/ct/[0-9]+/[0-9TZ:-]+$ ]]; then
        req_set "${id}" rejected "Unknown backup."; return
    fi
    req_set "${id}" restoring "Restoring ${site}; this takes a few minutes. Changes made after the backup are lost."
    log="/home/tappaas/logs/webhost-${site}-restore.log"
    (while sleep 10; do portal_log "${id}" "${log}"; done) &
    pid=$!
    # shellcheck disable=SC2034  # read by cmd_site_restore
    if out="$( (OPT_BACKUP="${backup}"; cmd_site_restore "${site}") 2>&1)"; then
        req_set "${id}" live "${site} is restored ($(tail -n 1 <<<"${out}" | sed -E 's/.*\((.*)\)$/\1/'))."
    else
        req_set "${id}" failed "$(tail -n 1 <<<"${out}" | sed -E 's/\x1b\[[0-9;]*m//g; s/^.*\[Error\][[:space:]]*//')"
    fi
    kill "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    portal_log "${id}" "${log}"
}

portal_sync() {
    exec 8>"${XDG_RUNTIME_DIR:-/tmp}/webhost-portal-sync.lock"
    flock -n 8 || return 0
    local key settings reqs id req kind

    settings="$(portal_settings)"
    key=""
    if [[ "$(webhost_sh <<<'f=/etc/webhost/portal-gate.json; [[ -s $f ]] && echo $(( ($(date +%s) - $(stat -c %Y $f)) / 60 )) || echo 9999')" -ge 60 ]]; then
        key="$(portal_gate_key)" || key=""
    fi
    webhost_sh "${settings}" "${key}" "$(portal_sites)" <<'EOF'
set -euo pipefail
install -d -m 0755 /etc/webhost
printf '%s\n' "$1" > /etc/webhost/portal.json.new && mv /etc/webhost/portal.json.new /etc/webhost/portal.json
if [[ -n "$2" ]]; then
    install -m 0640 -g webhost-portal /dev/null /etc/webhost/portal-gate.json.new
    printf '%s\n' "$2" > /etc/webhost/portal-gate.json.new && mv /etc/webhost/portal-gate.json.new /etc/webhost/portal-gate.json
fi
printf '%s\n' "$3" > /srv/webhost/portal/sites.json.new && chmod 0644 /srv/webhost/portal/sites.json.new \
    && mv /srv/webhost/portal/sites.json.new /srv/webhost/portal/sites.json
EOF

    reqs="$(webhost_sh <<'EOF'
for f in /srv/webhost/portal/requests/*.json; do
    [[ -f "${f}" ]] && jq -c 'select(.status == "new")' "${f}" 2>/dev/null
done
exit 0
EOF
)"
    while read -r req; do
        [[ -n "${req}" ]] || continue
        id="$(jq -r .id <<<"${req}")"
        [[ "${id}" =~ ^[0-9TZ]+-[0-9a-f]{6}$ ]] || continue
        kind="$(jq -r .kind <<<"${req}")"
        case "${kind}" in
            create) portal_create "${id}" "${req}" ;;
            delete) portal_delete "${id}" "${req}" ;;
            token)  portal_token "${id}" "${req}" ;;
            restore) portal_restore "${id}" "${req}" ;;
            *) req_set "${id}" rejected "Unknown request." ;;
        esac
    done <<<"${reqs}"

    if [[ -n "${reqs}" ]]; then portal_backups force; else portal_backups; fi
    [[ -z "${reqs}" ]] || webhost_sh "$(portal_sites)" <<'EOF'
printf '%s\n' "$1" > /srv/webhost/portal/sites.json.new && chmod 0644 /srv/webhost/portal/sites.json.new \
    && mv /srv/webhost/portal/sites.json.new /srv/webhost/portal/sites.json
EOF
}
