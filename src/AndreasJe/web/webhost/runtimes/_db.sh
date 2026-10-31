#!/usr/bin/env bash
#
# runtimes/_db.sh — a site's own database, on loopback, for templates that
# name one: mariadb, postgresql or mongodb (Percona Server for MongoDB,
# version and key pinned in snapshots/). Credentials are generated in the
# guest once, into /etc/secrets/site.env (DB_* and DATABASE_URL).
#
# shellcheck disable=SC2148

# db_setup <node> <vmid> <database> <dbname>
db_setup() {
    local node="$1" vmid="$2" db="$3" name="$4"
    case "${db}" in
        ""|none) return 0 ;;
        mariadb)
            pct_exec_script "${node}" "${vmid}" <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
dpkg -s mariadb-server >/dev/null 2>&1 || apt-get install -y -qq mariadb-server
install -d /etc/mysql/mariadb.conf.d
printf '[mysqld]\nbind-address = 127.0.0.1\n' > /etc/mysql/mariadb.conf.d/60-webhost-loopback.cnf
systemctl enable --now mariadb >/dev/null 2>&1
GUEST
            ;;
        postgresql)
            pct_exec_script "${node}" "${vmid}" <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
dpkg -s postgresql >/dev/null 2>&1 || apt-get install -y -qq postgresql
systemctl enable --now postgresql >/dev/null 2>&1
GUEST
            ;;
        mongodb) db_mongodb_install "${node}" "${vmid}" ;;
        *) die "unknown database '${db}'" ;;
    esac
    pct_exec_script "${node}" "${vmid}" "${db}" "${name}" <<'GUEST'
set -euo pipefail
DB="$1"; NAME="$2"; SEC=/etc/secrets/site.env
install -d -m 0700 /etc/secrets
touch "${SEC}"; chmod 0600 "${SEC}"
grep -q '^DB_HOST=' "${SEC}" || printf 'DB_HOST=127.0.0.1\n' >> "${SEC}"
grep -q '^DB_PASSWORD=' "${SEC}" && { echo "database credentials present, not regenerating"; exit 0; }
PASS="$(openssl rand -hex 24)"
case "${DB}" in
    mariadb)
        mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${NAME}'@'localhost' IDENTIFIED BY '${PASS}';
CREATE USER IF NOT EXISTS '${NAME}'@'127.0.0.1' IDENTIFIED BY '${PASS}';
GRANT ALL PRIVILEGES ON \`${NAME}\`.* TO '${NAME}'@'localhost';
GRANT ALL PRIVILEGES ON \`${NAME}\`.* TO '${NAME}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
        URL="mysql://${NAME}:${PASS}@127.0.0.1:3306/${NAME}" ;;
    postgresql)
        runuser -u postgres -- psql -q -v ON_ERROR_STOP=1 \
            -c "DO \$\$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${NAME}') THEN CREATE ROLE \"${NAME}\" LOGIN; END IF; END\$\$;" \
            -c "ALTER ROLE \"${NAME}\" PASSWORD '${PASS}';"
        runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname = '${NAME}'" | grep -q 1 \
            || runuser -u postgres -- createdb -O "${NAME}" "${NAME}"
        URL="postgres://${NAME}:${PASS}@127.0.0.1:5432/${NAME}" ;;
    mongodb)
        ADMIN_PASS="$(openssl rand -hex 24)"
        mongosh --quiet --eval "
            db.getSiblingDB('admin').createUser({user: 'root', pwd: '${ADMIN_PASS}', roles: ['root']});
            db.getSiblingDB('${NAME}').createUser({user: '${NAME}', pwd: '${PASS}', roles: [{role: 'readWrite', db: '${NAME}'}]});" >/dev/null
        printf 'MONGO_ROOT_PASSWORD=%s\n' "${ADMIN_PASS}" >> "${SEC}"
        sed -i 's/^#\?security:.*/security:\n  authorization: enabled/' /etc/mongod.conf
        grep -q 'authorization: enabled' /etc/mongod.conf || printf 'security:\n  authorization: enabled\n' >> /etc/mongod.conf
        systemctl restart mongod
        URL="mongodb://${NAME}:${PASS}@127.0.0.1:27017/${NAME}?authSource=${NAME}" ;;
esac
printf 'DB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\nDATABASE_URL=%s\n' "${NAME}" "${NAME}" "${PASS}" "${URL}" >> "${SEC}"
GUEST
}

# db_mongodb_install <node> <vmid> — Percona Server for MongoDB at the pinned
# version, through the webhost cache, bound to loopback.
db_mongodb_install() {
    local node="$1" vmid="$2"
    local repos
    repos="$(grep -v '^#' "${WEBHOST_ROOT}/snapshots/percona.pin")"
    # shellcheck disable=SC1090
    local REPO TELEMETRY_REPO SUITE KEY VERSION TELEMETRY_VERSION; eval "${repos}"
    read -r VERSION _ <<<"$(pin node percona)"
    read -r TELEMETRY_VERSION _ <<<"$(pin node percona-telemetry)"
    pct_push "${node}" "${vmid}" "${WEBHOST_ROOT}/snapshots/keys/${KEY}" /etc/apt/keyrings/tappaas-percona.gpg
    pct_exec_script "${node}" "${vmid}" "${REPO}" "${TELEMETRY_REPO}" "${SUITE}" "${VERSION}" "${TELEMETRY_VERSION}" <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive PERCONA_TELEMETRY_DISABLE=1
printf 'Types: deb\nURIs: %s %s\nSuites: %s\nComponents: main\nSigned-By: /etc/apt/keyrings/tappaas-percona.gpg\n' "$1" "$2" "$3" \
    > /etc/apt/sources.list.d/tappaas-percona.sources
printf 'Package: percona-server-mongodb*\nPin: version %s\nPin-Priority: 1001\n\nPackage: percona-telemetry-agent\nPin: version %s\nPin-Priority: 1001\n' "$4" "$5" \
    > /etc/apt/preferences.d/tappaas-percona
apt-get update -qq
apt-get install -y -qq percona-server-mongodb
systemctl disable --now percona-telemetry-agent >/dev/null 2>&1 || true
systemctl mask percona-telemetry-agent >/dev/null 2>&1 || true
sed -i 's/^\(\s*bindIp:\).*/\1 127.0.0.1/' /etc/mongod.conf
systemctl enable --now mongod >/dev/null 2>&1
for _ in $(seq 1 30); do mongosh --quiet --eval 'db.runCommand({ping: 1}).ok' 2>/dev/null | grep -q 1 && break; sleep 2; done
GUEST
}

# db_check <node> <vmid> <database> — the site's own credentials open its database.
db_check() {
    case "$3" in ""|none) return 0 ;; esac
    pct_exec_script "$1" "$2" "$3" <<'GUEST'
set -euo pipefail
# shellcheck disable=SC1091
. /etc/secrets/site.env
case "$1" in
    mariadb)    mysql -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" -e 'SELECT 1' >/dev/null ;;
    postgresql) PGPASSWORD="${DB_PASSWORD}" psql -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -tAc 'SELECT 1' | grep -q 1 ;;
    mongodb)    mongosh --quiet "${DATABASE_URL}" --eval 'db.runCommand({ping: 1}).ok' | grep -q 1 ;;
esac
GUEST
}
