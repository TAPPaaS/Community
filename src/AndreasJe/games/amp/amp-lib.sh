#!/usr/bin/env bash
# TAPPaaS Module: amp — helpers shared by install.sh, update.sh and test.sh.
# Expects amp() (ssh to the VM) to be defined by the caller.

# The management instance as "<name><TAB><ip><TAB><port>", or nothing. Parses
# 'ampinstmgr status' the way getamp.sh does: a '│'-delimited table of
# name │ friendly name │ module │ IP │ port │ up, with OSC-8 links and colours.
amp_ads_instance() {
    amp "sudo su -l amp -c 'ampinstmgr status' 2>/dev/null" \
        | sed -e 's/\x1b]8;;[^\x07]*\x07//g' -e 's/\x1b\[[0-9;]*m//g' \
        | awk -F '│' 'NF >= 5 && $3 ~ /(^|[^A-Za-z])ADS([^A-Za-z]|$)/ {
              for (i = 1; i <= 5; i++) gsub(/[[:space:]]/, "", $i); print $1 "\t" $4 "\t" $5; exit }'
}

# The amp user's instance directory for <name>.
amp_instance_dir() {
    echo "$(amp "getent passwd amp | cut -d: -f6")/.ampdata/instances/$1"
}

# Value of setting <key> (e.g. ADSModule.Network.UseDockerHostNetwork), or nothing.
# The files drop the first segment: ADSModule.* is in ADSModule.kvp, Core.* in AMPConfig.conf.
amp_kvp() {
    local file
    case "$2" in Core.*) file=AMPConfig.conf ;; *) file="${2%%.*}.kvp" ;; esac
    amp "sudo grep -hs '^${2#*.}=' '$(amp_instance_dir "$1")/${file}' | head -1 | cut -d= -f2-"
}

# Wait until the panel answers HTTP on <port> (AMP reports "running" before it listens).
amp_wait_panel() {
    amp "for i in \$(seq 60); do curl -s -o /dev/null --max-time 2 http://127.0.0.1:$1/ && exit 0; sleep 2; done; exit 1"
}
