#!/usr/bin/env bash
# TAPPaaS Module: mediamanager -- shared helpers (sourced by install.sh, update.sh,
# delete.sh and test.sh)
#
# Authentik tiles: one link-only application per published app, in the group
# "Media". Seerr is shown to the group users, the admin UIs to ADMIN_GROUP only
# (an application with no binding is shown to everyone). The tiles are
# cosmetic: the gate is oauth2-proxy on the VM. identity:identity's own
# "mediamanager" app is hidden (blank://blank, as the platform does for
# <module>-gate): it would duplicate the qBittorrent tile.

ADMIN_GROUP="mediamanager-admins"
TILE_APPS="qbittorrent sonarr radarr lidarr prowlarr bazarr seerr"
declare -A TILE_NAME=([qbittorrent]=qBittorrent [sonarr]=Sonarr [radarr]=Radarr [lidarr]=Lidarr
                      [prowlarr]=Prowlarr [bazarr]=Bazarr [seerr]=Seerr)
declare -A TILE_DESC=([qbittorrent]="Downloads" [sonarr]="Series" [radarr]="Films" [lidarr]="Music"
                      [prowlarr]="Indexers" [bazarr]="Subtitles" [seerr]="Request films and series")
TILE_ICONS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/icons"

# mm_published <name> -- the name exists and has a public record (the verdict
# identity:identity and network:proxy use; no resolver counts as published).
mm_published() {
    local rc=0
    [[ -n "$1" ]] || return 1
    command -v network-manager >/dev/null 2>&1 || return 0
    network-manager split-horizon-target "$1" >/dev/null 2>&1 || rc=$?
    [[ ${rc} -ne 3 ]]
}

# ak_init: read the API credentials; the token goes to curl in a 0600 file,
# never on its command line. The caller's EXIT trap is kept.
ak_init() {
    local creds="${HOME}/.authentik-credentials.txt" token prev
    [[ -r "${creds}" ]] || return 1
    AK_URL="$(grep '^url=' "${creds}" | cut -d= -f2-)"
    token="$(grep '^token=' "${creds}" | cut -d= -f2-)"
    [[ -n "${AK_URL}" && -n "${token}" ]] || return 1
    AK_HDR="$(mktemp)"
    chmod 600 "${AK_HDR}"
    printf 'Authorization: Bearer %s\n' "${token}" > "${AK_HDR}"
    prev="$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")"
    # shellcheck disable=SC2064
    trap "rm -f '${AK_HDR}'; ${prev}" EXIT
}

# ak METHOD PATH [JSON] -- one Authentik API call; fails on any HTTP error.
ak() {
    local data=()
    [[ -n "${3:-}" ]] && data=(-H 'Content-Type: application/json' --data "$3")
    curl -sSf --max-time 30 -X "$1" -H @"${AK_HDR}" "${data[@]}" "${AK_URL}/api/v3$2"
}

# ak_app <slug> -- the application as JSON; nothing if it does not exist (404);
# fails on any other answer. (The list endpoint ignores ?slug=, so it cannot be
# used to look one up.)
ak_app() {
    local out code
    out="$(curl -sS --max-time 30 -H @"${AK_HDR}" -w '\n%{http_code}' "${AK_URL}/api/v3/core/applications/$1/")" || return 1
    code="${out##*$'\n'}"
    case "${code}" in
        200) printf '%s' "${out%$'\n'*}" ;;
        404) ;;
        *)   return 1 ;;
    esac
}

# group_pk <name> -- the pk of exactly that group, or nothing.
group_pk() {
    ak GET "/core/groups/?name=$1" | jq -r --arg n "$1" '[.results[] | select(.name == $n)][0].pk // empty'
}

# tiles_bind <app pk> <group pk> -- exactly one binding on that app: that group.
# Bindings are filtered here as well: Authentik ignores an empty target filter
# and would return every binding on the site.
tiles_bind() {
    local pk="$1" group="$2" b
    [[ -n "${pk}" && -n "${group}" ]] || return 1
    for b in $(ak GET "/policies/bindings/?target=${pk}" \
               | jq -r --arg t "${pk}" --arg g "${group}" '.results[] | select(.target == $t and .group != $g) | .pk'); do
        ak DELETE "/policies/bindings/${b}/" >/dev/null
    done
    ak GET "/policies/bindings/?target=${pk}" \
        | jq -e --arg t "${pk}" --arg g "${group}" '.results | any(.target == $t and .group == $g)' >/dev/null \
        || ak POST "/policies/bindings/" "$(jq -cn --arg t "${pk}" --arg g "${group}" \
            '{target: $t, group: $g, order: 0, enabled: true, negate: false, timeout: 30}')" >/dev/null
}

# tile_icon <slug> <app> -- upload icons/<app>.svg|png once under a content-hashed
# name (a changed icon is a new file) and print that name for meta_icon. Prints
# nothing when there is no icon or the upload fails: icons are cosmetic.
tile_icon() {
    local slug="$1" app="$2" f ext mime name
    for ext in svg png; do [[ -f "${TILE_ICONS}/${app}.${ext}" ]] && { f="${TILE_ICONS}/${app}.${ext}"; break; }; done
    [[ -n "${f:-}" ]] || return 0
    [[ "${ext}" == svg ]] && mime="image/svg+xml" || mime="image/png"
    name="tappaas-app-${slug}-$(sha256sum "${f}" | cut -c1-12).${ext}"
    if ! grep -qxF "${name}" <<<"${TILE_FILES:-}"; then
        curl -sSf --max-time 30 -X POST -H @"${AK_HDR}" -F "file=@${f};filename=${name};type=${mime}" \
            -F "name=${name}" -F "usage=media" "${AK_URL}/api/v3/admin/file/" >/dev/null \
            || { warn "  tile ${TILE_NAME[$app]}: icon upload failed -- shown without icon" >&2; return 0; }
    fi
    printf '%s' "${name}"
}

# tiles_sync <vmname> <public domain> <enabled app>... -- create, correct and
# prune this instance's tiles. Stops at the first failed call.
tiles_sync() {
    local vm="$1" domain="$2"; shift 2
    local suffix="${domain#*.}" users admins group app slug url body cur pk icon
    local want=" qbittorrent $* "
    users="$(group_pk users)" && admins="$(group_pk "${ADMIN_GROUP}")" || return 1
    [[ -n "${users}" && -n "${admins}" ]] \
        || { warn "  Authentik lacks group 'users' or '${ADMIN_GROUP}' -- tiles skipped"; return 1; }
    TILE_FILES="$(ak GET "/admin/file/?usage=media" 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)"

    for app in ${TILE_APPS}; do
        slug="${vm}-${app}"
        cur="$(ak_app "${slug}")" || return 1
        if [[ "${want}" != *" ${app} "* ]]; then
            if [[ -n "${cur}" ]]; then
                ak DELETE "/core/applications/${slug}/" >/dev/null || return 1
                info "  tile ${TILE_NAME[$app]}: removed"
            fi
            continue
        fi
        if [[ "${app}" == qbittorrent ]]; then url="https://${domain}/"; else url="https://${app}.${suffix}/"; fi
        icon="$(tile_icon "${slug}" "${app}")"
        body="$(jq -cn --arg n "${TILE_NAME[$app]}" --arg s "${slug}" --arg u "${url}" \
            --arg d "${TILE_DESC[$app]}" --arg i "${icon}" \
            '{name: $n, slug: $s, meta_launch_url: $u, meta_description: $d, meta_icon: $i, group: "Media", open_in_new_tab: false}')"
        if [[ -z "${cur}" ]]; then
            pk="$(ak POST "/core/applications/" "${body}" | jq -r '.pk // empty')" || return 1
            info "  tile ${TILE_NAME[$app]}: added (${url})"
        else
            pk="$(jq -r '.pk // empty' <<<"${cur}")"
            if [[ "$(jq -c '{name, slug, meta_launch_url, meta_description, meta_icon, group, open_in_new_tab}' <<<"${cur}")" != "${body}" ]]; then
                ak PATCH "/core/applications/${slug}/" "${body}" >/dev/null || return 1
                info "  tile ${TILE_NAME[$app]}: updated"
            fi
        fi
        [[ -n "${pk}" ]] || { warn "  tile ${TILE_NAME[$app]}: no application id -- not binding"; return 1; }
        if [[ "${app}" == seerr ]]; then group="${users}"; else group="${admins}"; fi
        tiles_bind "${pk}" "${group}" || return 1
    done

    cur="$(ak_app "${vm}")" || return 1
    if [[ -n "${cur}" && "$(jq -r .meta_launch_url <<<"${cur}")" != "blank://blank" ]]; then
        ak PATCH "/core/applications/${vm}/" '{"meta_launch_url": "blank://blank"}' >/dev/null \
            && info "  tile ${vm}: hidden (the qBittorrent tile replaces it)"
    fi
}

# tiles_delete <vmname> -- remove every tile of this instance.
tiles_delete() {
    local vm="$1" app slug
    for app in ${TILE_APPS}; do
        slug="${vm}-${app}"
        if [[ -n "$(ak_app "${slug}")" ]]; then
            ak DELETE "/core/applications/${slug}/" >/dev/null && info "  tile ${TILE_NAME[$app]}: removed"
        fi
    done
    return 0
}
