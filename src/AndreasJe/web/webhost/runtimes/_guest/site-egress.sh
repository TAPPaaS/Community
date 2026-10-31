#!/usr/bin/env bash
#
# site-egress — runs inside a website container (at boot and every 5 min).
# Outbound traffic is dropped except: DHCP, DNS to the resolvers, the webhost
# container (apt cache, git mirror, artefacts), Loki's push port, the site's
# own public name, and the template's allowed hosts on 80/443. Names are
# re-resolved on every run. Replies to inbound requests are unaffected.
#
# Config: /etc/site-egress.conf (WEBHOST, LOGGING, SELF, ALLOW).

set -euo pipefail

CONF=/etc/site-egress.conf
[[ -f "${CONF}" ]] || exit 0
# shellcheck source=/dev/null
. "${CONF}"

v4() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}'; }
v6() { getent ahostsv6 "$1" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1}'; }
set_of() { sort -u | paste -sd, -; }
rule() { [[ -n "$2" ]] && printf '\t\t%s { %s } %s accept\n' "$1" "$2" "$3"; return 0; }

webhost4="$(v4 "${WEBHOST}" | set_of)"
if [[ -z "${webhost4}" ]]; then
    logger -t tappaas-site -p daemon.err "egress-not-applied reason=resolve host=${WEBHOST}"
    exit 1
fi
dns4="$(awk '$1=="nameserver" && $2 !~ /:/ {print $2}' /etc/resolv.conf | set_of)"
dns6="$(awk '$1=="nameserver" && $2 ~ /:/ {print $2}' /etc/resolv.conf | set_of)"
logging4="$( [[ -n "${LOGGING:-}" ]] && v4 "${LOGGING}" | set_of)"
web4="$(for h in ${SELF:-} ${ALLOW:-}; do v4 "${h}"; done | set_of)"
web6="$(for h in ${SELF:-} ${ALLOW:-}; do v6 "${h}"; done | set_of)"

RULES="$(mktemp)"
trap 'rm -f "${RULES}"' EXIT
{
    printf 'table inet tappaas_egress\ndelete table inet tappaas_egress\n'
    printf 'table inet tappaas_egress {\n\tchain output {\n'
    printf '\t\ttype filter hook output priority filter; policy drop;\n'
    printf '\t\toif "lo" accept\n\t\tct state established,related accept\n'
    printf '\t\tmeta l4proto { icmp, ipv6-icmp } accept\n'
    printf '\t\tudp dport { 67, 547 } accept\n'
    rule "ip daddr" "${dns4}" "meta l4proto { tcp, udp } th dport 53"
    rule "ip6 daddr" "${dns6}" "meta l4proto { tcp, udp } th dport 53"
    rule "ip daddr" "${webhost4}" "tcp dport { 80, 3142 }"
    rule "ip daddr" "${logging4}" "tcp dport 3101"
    rule "ip daddr" "${web4}" "tcp dport { 80, 443 }"
    rule "ip6 daddr" "${web6}" "tcp dport { 80, 443 }"
    printf '\t\tcounter comment "dropped"\n\t}\n}\n'
} >"${RULES}"
nft -f "${RULES}"
