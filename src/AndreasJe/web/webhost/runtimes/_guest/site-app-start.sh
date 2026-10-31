#!/usr/bin/env bash
#
# site-app-start — ExecStart of site-app.service (node and python runtimes).
# Runs the release's start command from /etc/site-app.conf (START), with the
# release's node_modules/.bin first on PATH and its Python vendor/ directory on
# PYTHONPATH.

set -euo pipefail
# shellcheck source=/dev/null
. /etc/site-app.conf
cd /srv/site/current
[[ -d node_modules/.bin ]] && PATH="/srv/site/current/node_modules/.bin:${PATH}"
[[ -d vendor ]] && export PYTHONPATH="/srv/site/current/vendor${PYTHONPATH:+:${PYTHONPATH}}"
export PATH
read -ra CMD <<<"${START}"
exec "${CMD[@]}"
