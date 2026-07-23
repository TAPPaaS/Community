#!/usr/bin/env bash
#
# media-watcher.sh — watches hosting/media/ for changes and runs
# update-module.sh for whichever site changed, once things go quiet.
#
# Why this exists: nothing inside a site's LXC watches this host's
# filesystem, so dropping files into hosting/media/<template>/<sitename>/
# does nothing on its own — update-module.sh has to actually run to push
# them into the container. This watches for changes and triggers that
# automatically, instead of waiting for the platform's hourly schedule or a
# manual run.
#
# Debouncing: does NOT fire per file-event. A bulk transfer (rsync of many
# files) fires a burst of events — triggering update-module.sh per-event
# would mean dozens of overlapping installs racing each other. Instead this
# waits for MEDIA_WATCHER_QUIET_SECONDS of no further activity in a site's
# folder before running its update.
#
# This is a GAP detector, not a cap on total transfer time: `modify` events
# fire continuously as rsync writes each file's bytes, so the quiet timer
# keeps resetting for as long as data keeps arriving, however long that
# takes. The only real risk is a network stall longer than the quiet
# window — worst case that causes one early, redundant update (harmless:
# rsync/update-module.sh are both safe to re-run, so it just gets corrected
# on the next quiet period). Raise MEDIA_WATCHER_QUIET_SECONDS if your
# connection is slow enough that this happens often.
#
# Waiting out the FULL quiet period after every transfer, even one that's
# obviously finished, is real added latency (QUIET_SECONDS, always). If you
# know your own transfer just finished, you can skip that wait entirely:
# touch a ".sync-now" file inside the site's own media folder as the last
# step of your own transfer command (e.g. `rsync -av ./photos/
# media/static/<site>/ && touch media/static/<site>/.sync-now`) and this
# triggers the update on the very next check (within POLL_SECONDS), no
# quiet-period wait at all. The quiet-period path still exists as the
# fallback for whenever you don't (or can't) do that.
#
# Runs as a long-lived process — see media-watcher.service. Not something
# TAPPaaS's own module lifecycle manages, since it isn't per-site.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR
readonly MEDIA_ROOT="${SCRIPT_DIR}/media"
readonly QUIET_SECONDS="${MEDIA_WATCHER_QUIET_SECONDS:-30}"
readonly POLL_SECONDS=5
readonly UPDATE_MODULE="${MEDIA_WATCHER_UPDATE_MODULE:-/home/tappaas/bin/update-module.sh}"
readonly SYNC_NOW_MARKER=".sync-now"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

command -v inotifywait &>/dev/null || {
    log "FATAL: inotifywait not found. On this NixOS host: nix profile install nixpkgs#inotify-tools"
    exit 1
}

mkdir -p "${MEDIA_ROOT}"

STATE_DIR="$(mktemp -d)"
readonly STATE_DIR
CHANGES_FILE="${STATE_DIR}/changes"
readonly CHANGES_FILE
touch "${CHANGES_FILE}"

INOTIFY_PID=""
cleanup() {
    [[ -n "${INOTIFY_PID}" ]] && kill "${INOTIFY_PID}" 2>/dev/null || true
    rm -rf "${STATE_DIR}"
}
trap cleanup EXIT

# Background pipeline: append "<epoch> <template>/<sitename>" for every
# filesystem event under MEDIA_ROOT, forever. If inotifywait itself dies,
# this pipeline exits, the kill -0 check below notices within POLL_SECONDS,
# and the whole script exits — systemd (Restart=always) starts it fresh.
(
    inotifywait -m -r -e modify,create,delete,move,close_write \
        --format '%w%f' "${MEDIA_ROOT}" |
    while IFS= read -r changed_path; do
        rel="${changed_path#"${MEDIA_ROOT}"/}"
        site_key="$(cut -d/ -f1,2 <<< "${rel}")"
        [[ "${site_key}" == */* ]] || continue
        printf '%s %s\n' "$(date +%s)" "${site_key}" >> "${CHANGES_FILE}"
    done
) &
INOTIFY_PID=$!

log "Watching ${MEDIA_ROOT} (quiet period: ${QUIET_SECONDS}s, PID ${INOTIFY_PID})"

declare -A last_change=()
declare -A last_synced=()

while true; do
    sleep "${POLL_SECONDS}"

    kill -0 "${INOTIFY_PID}" 2>/dev/null || {
        log "inotifywait watcher died — exiting so the service manager restarts us"
        exit 1
    }

    if [[ -s "${CHANGES_FILE}" ]]; then
        while read -r epoch site_key; do
            [[ -z "${site_key}" ]] && continue
            if [[ -z "${last_change[${site_key}]:-}" || "${epoch}" -gt "${last_change[${site_key}]}" ]]; then
                last_change["${site_key}"]="${epoch}"
            fi
        done < "${CHANGES_FILE}"
        : > "${CHANGES_FILE}"
    fi

    now="$(date +%s)"
    for site_key in "${!last_change[@]}"; do
        last="${last_change[${site_key}]}"
        synced="${last_synced[${site_key}]:-0}"
        [[ "${synced}" -ge "${last}" ]] && continue

        sitename="${site_key#*/}"
        marker="${MEDIA_ROOT}/${site_key}/${SYNC_NOW_MARKER}"
        if [[ -f "${marker}" ]]; then
            # Explicit "I'm done" signal — skip the quiet-period wait
            # entirely. Remove it BEFORE syncing so it never gets copied
            # into the site itself.
            rm -f "${marker}"
            log "Sync-now marker found for ${site_key} — triggering immediately"
        elif (( now - last < QUIET_SECONDS )); then
            continue
        else
            log "Quiet for ${QUIET_SECONDS}s on ${site_key} — running update-module.sh ${sitename}"
        fi

        if "${UPDATE_MODULE}" "${sitename}"; then
            last_synced["${site_key}"]="${last}"
        else
            log "WARN: update-module.sh ${sitename} failed — will retry next check"
        fi
    done
done
