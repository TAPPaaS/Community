#!/usr/bin/env bash
#
# runtimes/_common.sh — host-side steps shared by every runtime: base
# packages, the site-agent, Caddy config with the security floor.
# Source after lib/common.sh and lib/csp.sh.
#
# shellcheck disable=SC2148

RUNTIMES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNTIMES_DIR

# guest_base <node> <vmid> <runtime> — the runtime's packages from the
# snapshot webhost:packages set up. Upgrades arrive with the next promoted
# snapshot, so unattended-upgrades is removed.
guest_base() {
    local node="$1" vmid="$2" pkgs
    pkgs="$(grep -v '^#' "${WEBHOST_ROOT}/snapshots/$3.packages" | tr '\n' ' ')"
    pct_exec_script "${node}" "${vmid}" "${pkgs}" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
read -ra PKGS <<<"$1"
apt-get update -qq
# Caddy comes from trixie-backports: trixie's 2.6 lacks client_ip matching.
apt-get install -y -qq -t trixie-backports caddy
apt-get install -y -qq "${PKGS[@]}"
# No SSH server in a site: access is pct exec on the node (ground rule 4).
apt-get purge -y -qq openssh-server unattended-upgrades >/dev/null 2>&1 || true
install -d -m 0755 /srv/site/releases /srv/site/data /var/log/caddy
install -d -m 0700 /etc/secrets
EOF
}

# install_egress <node> <vmid> <site> <template.json> — outbound filter.
install_egress() {
    local node="$1" vmid="$2" site="$3" tj="$4" conf f
    printf -v conf 'WEBHOST=%q\nLOGGING=%q\nSELF=%q\nALLOW=%q\n' "${WEBHOST_HOST}" logging.mgmt.internal \
        "$(decl_get "${site}" .public.domain)" "$(jq -r '(.egress // []) | join(" ")' "${tj}")"
    pct_exec_script "${node}" "${vmid}" "${conf}" <<'EOF'
printf '%s' "$1" > /etc/site-egress.conf
EOF
    pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/site-egress.sh" /usr/local/sbin/site-egress 0755
    for f in tappaas-site-egress.service tappaas-site-egress.timer; do
        pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/${f}" "/etc/systemd/system/${f}"
    done
    pct_exec_script "${node}" "${vmid}" <<'EOF'
set -euo pipefail
systemctl daemon-reload
systemctl enable tappaas-site-egress.service >/dev/null 2>&1
systemctl enable --now tappaas-site-egress.timer >/dev/null
systemctl start tappaas-site-egress.service
EOF
}

# install_site_agent <node> <vmid> <site> <mirror-url|""> <ref> <subdir> [extra-conf]
install_site_agent() {
    local node="$1" vmid="$2" site="$3" repo="$4" ref="$5" subdir="$6" conf dirs owner
    dirs="$(jq -r '(.options.dataDirs // []) | join(" ")' "$(decl_path "${site}")" 2>/dev/null || true)"
    case "$(jq -r '.runtime // empty' "$(decl_path "${site}")" 2>/dev/null)" in
        php) owner=www-data ;; node|python) owner=site ;; *) owner="" ;;
    esac
    printf -v conf 'SITE=%q\nREPO=%q\nREF=%q\nSUBDIR=%q\nKEEP=3\nDATA_DIRS=%q\nDATA_OWNER=%q\n%s' \
        "${site}" "${repo}" "${ref}" "${subdir}" "${dirs}" "${owner}" "${7:-}"
    pct_exec_script "${node}" "${vmid}" "${conf}" <<'EOF'
set -euo pipefail
printf '%s' "$1" > /etc/site-agent.conf
chmod 0644 /etc/site-agent.conf
EOF
    pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/site-agent.sh" /usr/local/sbin/site-agent 0755
    pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/tappaas-site-agent.service" /etc/systemd/system/tappaas-site-agent.service
    pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/tappaas-site-agent.timer" /etc/systemd/system/tappaas-site-agent.timer
    pct_exec_script "${node}" "${vmid}" <<'EOF'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now tappaas-site-agent.timer
EOF
}

# install_log_shipper <node> <vmid> <site> — journal to Loki while the site
# declares logging:logs and logging is deployed. Core's logging:logs ships
# NixOS guests only; this uses its credential and pinhole for an LXC.
install_log_shipper() {
    local node="$1" vmid="$2" site="$3" cfg="${WEBHOST_CONFIG_DIR}/${3}.json" cred conf zone drop u
    cred="/home/tappaas/.loki-push/${site}"
    if [[ ! -f "${WEBHOST_CONFIG_DIR}/logging.json" || ! -s "${cred}" ]] \
        || ! jq -e '((.dependsOn // []) + (.integratesWith // [])) | index("logging:logs") != null' "${cfg}" >/dev/null 2>&1; then
        pct_exec_script "${node}" "${vmid}" <<'EOF'
systemctl disable --now tappaas-log-shipper.timer tappaas-log-heartbeat.timer >/dev/null 2>&1 || true
rm -f /etc/log-shipper.conf /etc/secrets/tappaas-logging-push
EOF
        return 0
    fi
    zone="$(jq -r '.zone0 // ""' "${cfg}")"
    drop="generate-.*-secrets.*"
    for u in $(jq -r '(.dropUnits // [])[]' "${cfg}"); do
        [[ "${u}" =~ ^[A-Za-z0-9_.*@-]+$ ]] && drop+="|${u}"
    done
    printf -v conf 'HOST=%q\nZONE=%q\nURL=%q\nDROP=%q\n' "${site}" "${zone}" \
        "http://logging.mgmt.internal:3101/loki/api/v1/push" "${drop}"
    pct_exec_script "${node}" "${vmid}" "${conf}" <<'EOF'
set -euo pipefail
command -v jq >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq
printf '%s' "$1" > /etc/log-shipper.conf
install -d -m 0700 /etc/secrets
EOF
    pct_push "${node}" "${vmid}" "${cred}" /etc/secrets/tappaas-logging-push 0600
    local f
    for f in tappaas-log-shipper.service tappaas-log-shipper.timer tappaas-log-heartbeat.service tappaas-log-heartbeat.timer; do
        pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/${f}" "/etc/systemd/system/${f}"
    done
    pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/log-shipper.sh" /usr/local/sbin/log-shipper 0755
    pct_exec_script "${node}" "${vmid}" <<'EOF'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now tappaas-log-shipper.timer tappaas-log-heartbeat.timer >/dev/null
systemctl start tappaas-log-heartbeat.service tappaas-log-shipper.service
EOF
}

# release_now <node> <vmid> — run the agent once; fail if nothing is live.
release_now() {
    pct_exec_script "$1" "$2" <<'EOF'
set -euo pipefail
systemctl start tappaas-site-agent.service
test -L /srv/site/current
EOF
}

# render_caddyfile <runtime> <template.json> <csp> [docroot] [clean-urls] — prints the
# Caddyfile. Security floor (ground rule 7): HSTS, nosniff, referrer-policy,
# CSP, no Server header, admin paths only from internal clients, masked
# access log.
render_caddyfile() {
    local runtime="$1" tj="$2" csp="$3" docroot="${4:-.}" clean="${5:-false}" admin_paths root handler
    admin_paths="$(jq -r '(.adminPaths // []) | join(" ")' "${tj}")"
    case "${runtime}" in
        static) root="/srv/site/current"; handler="file_server" ;;
        php)    root="/srv/site/current/${docroot}"
                [[ "$(jq -r '.app // empty' "${tj}")" == wordpress ]] && root="/srv/site/data/www"
                handler="php_fastcgi unix//run/php/php-fpm-site.sock"
                # Clean URLs: /products runs products.php, as Apache rewrite rules often arrange.
                [[ "${clean}" == true ]] && handler+=" {"$'\n\t\t'"try_files {path} {path}.php {path}/index.php index.php"$'\n\t'"}"
                handler+=$'\n\t'"file_server" ;;
        node|python) root="/srv/site/current"; handler="reverse_proxy 127.0.0.1:3000" ;;
    esac

    cat <<CADDY
{
	auto_https off
	servers {
		trusted_proxies static private_ranges
		client_ip_headers X-Forwarded-For
	}
}

:80 {
	root * ${root}
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		Content-Security-Policy "${csp}"
		-Server
	}

	log {
		output stderr
		format filter {
			wrap json
			request>remote_ip ip_mask 24 56
			request>client_ip ip_mask 24 56
			request>uri regexp \\?.* ""
			request>headers delete
		}
	}

CADDY
    if [[ -n "${admin_paths}" ]]; then
        cat <<CADDY
	@admin_external {
		path ${admin_paths}
		not client_ip private_ranges
	}
	respond @admin_external "Forbidden" 403

CADDY
    fi
    printf '\t%s\n}\n' "${handler}"
}

# push_caddyfile <node> <vmid> <runtime> <template.json> [declaration.json]
push_caddyfile() {
    local node="$1" vmid="$2" runtime="$3" tj="$4" decl="${5:-/dev/null}" csp tmp docroot clean
    csp="$(build_csp "${runtime}" "${tj}" "${decl}")" || return 1
    docroot="$(jq -r '.options.docroot // empty' "${decl}" 2>/dev/null)"
    [[ -n "${docroot}" ]] || docroot="$(jq -r '.defaults.options.docroot // "."' "${tj}")"
    tmp="$(mktemp)"
    clean="$(jq -r '.options.cleanUrls // false' "${decl}" 2>/dev/null || echo false)"
    render_caddyfile "${runtime}" "${tj}" "${csp}" "${docroot}" "${clean}" >"${tmp}"
    pct_push "${node}" "${vmid}" "${tmp}" /etc/caddy/Caddyfile
    rm -f "${tmp}"
    pct_exec_script "${node}" "${vmid}" <<'EOF'
set -euo pipefail
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl enable caddy >/dev/null 2>&1
systemctl reload-or-restart caddy
EOF
}

# resolve_template <site> — prints the path of the site's template.json: a
# built-in one, else a custom preset from templateSources.
resolve_template() {
    local t d
    t="$(decl_get "$1" .template)"
    for d in "${WEBHOST_ROOT}/templates" "${WEBHOST_DECL_DIR}/webhost/templates"; do
        [[ -f "${d}/${t}/template.json" ]] && { printf '%s\n' "${d}/${t}/template.json"; return 0; }
    done
    die "unknown template '${t}'"
}
