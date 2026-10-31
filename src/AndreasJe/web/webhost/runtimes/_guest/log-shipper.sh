#!/usr/bin/env bash
#
# log-shipper — runs inside a website container (systemd timer). Sends new
# journal lines to the site's Loki push receiver, the same way core's Alloy
# pipeline does for NixOS guests (core lib/log-shipping.sh): secret-handling
# units dropped, secret values scrubbed, labels host/zone/unit/severity/job.
# The cursor advances only after Loki accepted the batch.
#
# Config: /etc/log-shipper.conf (HOST, ZONE, URL, DROP). Secret:
# /etc/secrets/tappaas-logging-push.

set -euo pipefail

CONF=/etc/log-shipper.conf
SECRET=/etc/secrets/tappaas-logging-push
STATE=/var/lib/log-shipper
BATCH=2000

[[ -f "${CONF}" && -s "${SECRET}" ]] || exit 0
# shellcheck source=/dev/null
. "${CONF}"

mkdir -p "${STATE}"
exec 9>"${STATE}/lock"
flock -n 9 || exit 0

CURSOR="$(cat "${STATE}/cursor" 2>/dev/null || true)"
if [[ -n "${CURSOR}" ]]; then
    FROM=(--after-cursor="${CURSOR}")
else
    FROM=(--since=-5min)
fi

while :; do
    LINES="$(journalctl -o json --no-pager "${FROM[@]}" | head -n "${BATCH}" || true)"
    [[ -n "${LINES}" ]] || exit 0

    BODY="$(jq -cs --arg host "${HOST}" --arg zone "${ZONE}" --arg drop "^(${DROP})$" '
      def kw: ["emerg","alert","crit","err","warning","notice","info","debug"][(. // "6") | tonumber];
      def msg: if type == "array" then implode elif type == "string" then . else tostring end;
      def scrub:
        gsub("(?<p>(?i:\\b(?:token|secret|password|passwd|api[_-]?key))\\s*[:=]\\s*)\\S+"; "\(.p)***REDACTED***")
        | gsub("(?<p>-u\\s+[\"'"'"']?)[^\"'"'"' ]+:[^\"'"'"' ]+"; "\(.p)***REDACTED***")
        | gsub("(?<p>Authorization:\\s+(?:Basic|Bearer)\\s+)\\S+"; "\(.p)***REDACTED***");
      map(select((._SYSTEMD_UNIT // "") | test($drop) | not))
      | map({unit: (._SYSTEMD_UNIT // ""), severity: (.PRIORITY | kw),
             ts: (.__REALTIME_TIMESTAMP + "000"), line: (.MESSAGE | msg | scrub)})
      | group_by([.unit, .severity])
      | {streams: map({
          stream: ({host: $host, job: "systemd-journal", severity: .[0].severity}
                   + (if $zone == "" then {} else {zone: $zone} end)
                   + (if .[0].unit == "" then {} else {unit: .[0].unit} end)),
          values: map([.ts, .line])})}' <<<"${LINES}")"
    NEXT="$(tail -n 1 <<<"${LINES}" | jq -r '.__CURSOR')"

    if [[ "$(jq '.streams | length' <<<"${BODY}")" -gt 0 ]]; then
        CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -u "${HOST}:$(cat "${SECRET}")" \
            -H 'Content-Type: application/json' --data-binary @- "${URL}" <<<"${BODY}" || true)"
        case "${CODE}" in
            2??) ;;
            401|429|000|5??) echo "push failed (http ${CODE}); retrying next run" >&2; exit 1 ;;
            *) echo "push refused (http ${CODE}); batch skipped" >&2 ;;
        esac
    fi
    printf '%s' "${NEXT}" > "${STATE}/cursor"
    FROM=(--after-cursor="${NEXT}")
    [[ "$(wc -l <<<"${LINES}")" -ge "${BATCH}" ]] || exit 0
done
