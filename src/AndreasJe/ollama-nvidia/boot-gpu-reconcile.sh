#!/usr/bin/env bash
#
# TAPPaaS ollama-nvidia — boot-time GPU passthrough reconcile
#
# WHY THIS EXISTS
# ---------------
# nvidia_uvm's device major is allocated dynamically when the kernel module
# loads. It is NOT stable: a driver rebuild (DKMS on kernel update) or a host
# reboot can move it — this host has already drifted 508 -> 510. The LXC's
# passthrough conf, however, is written once at install time. When the major
# moves, the container starts perfectly happily with cgroup rules pointing at a
# major that no longer exists, so:
#
#   - nvidia-smi still works (it only needs /dev/nvidia0, major 195, which is
#     statically registered and never drifts), and
#   - CUDA fails, because it needs /dev/nvidia-uvm on the drifted major.
#
# That asymmetry is what makes this bug expensive: every obvious check looks
# healthy while inference has silently fallen back to CPU.
#
# This is the single implementation of that reconcile. It runs two ways, and
# both must produce the same conf: patch-host-gpu.sh calls it directly (its
# Step 6) for an operator-driven run, and installs it as
# ollama-gpu-reconcile.service (its Step 7) ordered before pve-guests, which
# closes the previously unbounded window between "driver rebuilt" and
# "someone notices inference got slow".
#
# Step 6 used to carry a second, sentinel-block implementation of the same
# thing. Do not reintroduce one: the two formats strip and duplicate each
# other's lines. See the NOTE ON THE APPROACH below.
#
# This script deliberately does ONLY the conf reconcile. It does not install or
# upgrade drivers: boot is the wrong moment to attempt a DKMS build, and a
# failure here must never block the host's guests from starting.
#
# Installed as ollama-gpu-reconcile.service by patch-host-gpu.sh.
set -uo pipefail

MODULE="${1:-ollama-nvidia}"
TAPPAAS_DIR="/root/tappaas"
MODULE_JSON="${TAPPAAS_DIR}/${MODULE}.json"

log() { echo "[ollama-gpu-reconcile] $*"; }

# Exit codes. 0 = reconciled or already correct. 3 = SKIPPED: nothing was
# written because a precondition was missing (no vmid, no conf, required
# device absent). Anything else = a real error.
#
# Skips exit non-zero on purpose so that patch-host-gpu.sh's Step 6 can show
# an operator a ❌ instead of a false ✅ — a skipped reconcile that looks
# successful is the same "everything looks healthy" failure this script exists
# to prevent. The systemd unit lists 3 in SuccessExitStatus, so at boot a skip
# is still not a red unit and can never block the host's guests.
EXIT_SKIP=3

VMID="$(jq -r '.vmid // empty' "${MODULE_JSON}" 2>/dev/null)"
if [ -z "${VMID}" ]; then
    log "no vmid in ${MODULE_JSON} — nothing to reconcile"
    exit "${EXIT_SKIP}"
fi
CONF="/etc/pve/lxc/${VMID}.conf"
if [ ! -f "${CONF}" ]; then
    log "conf ${CONF} absent — nothing to reconcile"
    exit "${EXIT_SKIP}"
fi

# The uvm devices are created by nvidia-modprobe on first CUDA use, so they may
# legitimately not exist yet this early in boot. Load the modules so the majors
# are allocated now; if that fails there is no GPU to pass through and the
# correct behaviour is to leave the conf untouched rather than write a block
# with missing entries.
if [ ! -c /dev/nvidia-uvm ]; then
    modprobe nvidia_uvm 2>/dev/null || true
    nvidia-modprobe -u -c=0 2>/dev/null || true
fi

# Build the desired device lines from live state.
#
# NOTE ON THE APPROACH: an earlier version delimited these with BEGIN/END
# sentinel comments and replaced the block between them. That does not work
# here — Proxmox normalises /etc/pve/lxc/<id>.conf on write, hoisting comments
# to the top and regrouping the lxc.* keys at the bottom. The sentinels get
# separated from the lines they were meant to bracket, so the next run finds an
# empty block, appends a fresh copy, and the conf accumulates a duplicate set
# of device lines on every single boot. Reconcile by LINE instead: the result
# is identical whatever order Proxmox chooses to write things in.
DESIRED=""
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
    [ -c "$dev" ] || continue
    LIVE_MAJ="$(printf '%d' "0x$(stat -c '%t' "$dev")")"
    LIVE_MIN="$(printf '%d' "0x$(stat -c '%T' "$dev")")"
    DESIRED="${DESIRED}lxc.cgroup2.devices.allow: c ${LIVE_MAJ}:${LIVE_MIN} rwm
lxc.mount.entry: ${dev} ${dev#/} none bind,optional,create=file
"
done

# Refuse to write a partial set: the purge below drops every nvidia line, so
# writing one would revoke access to a device that IS present — worse than
# leaving yesterday's majors in place, which at least fails in a way an
# operator has seen before.
#
# /dev/nvidia-uvm-tools is deliberately NOT required. Some driver versions
# create it lazily and patch-host-gpu.sh's Step 2 already treats its absence
# as non-fatal; demanding all four here would mean that on those drivers the
# reconcile never runs at all and the stale major survives — the exact
# outcome this script exists to prevent. If it is genuinely absent there is
# no access to revoke by omitting it, and the next run picks it up.
missing=""
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm; do
    [ -c "$dev" ] || missing="${missing} ${dev}"
done
if [ -n "${missing}" ]; then
    log "required device(s) absent:${missing} — leaving conf untouched"
    exit "${EXIT_SKIP}"
fi

# Purging ALL lxc.cgroup2.devices.allow lines is safe for THIS container
# specifically: this module owns its device passthrough outright. See
# ollama-nvidia.meta.json's _comment_nvidia_gpu — the device block is named
# `nvidia_gpu` rather than `gpu` precisely so Create-TAPPaaS-LXC.sh's
# AMD-shaped handler never writes passthrough lines here. So every such line
# in this conf was written by this module, and a blanket purge cannot clobber
# another owner's rule. It also purges a DRIFTED major (e.g. a stale 508) that
# a match-on-current-majors filter would leave behind for ever.
tmp=$(mktemp)
grep -vE '^lxc\.cgroup2\.devices\.allow:|^lxc\.mount\.entry: /dev/nvidia|^# (BEGIN|END) ollama-nvidia GPU passthrough' \
    "$CONF" > "$tmp"
printf '%s' "$DESIRED" >> "$tmp"

# Compare normalised (sorted) device lines so a pure reordering by Proxmox is
# not mistaken for drift — otherwise this would rewrite and reboot the
# container on every boot.
#
# Leftover BEGIN/END sentinels from the retired block-managed version count as
# drift even when the device lines already match: they are what an older
# patch-host-gpu.sh keyed off, so leaving them behind keeps the two conf
# formats alive in the same file. They only disappear on a rewrite, so force
# one when any are still present.
cur_norm="$(grep -E '^lxc\.cgroup2\.devices\.allow:|^lxc\.mount\.entry: /dev/nvidia' "$CONF" | sort)"
new_norm="$(printf '%s' "$DESIRED" | sort)"
stale_marks="$(grep -cE '^# (BEGIN|END) ollama-nvidia GPU passthrough' "$CONF" || true)"
if [ "$cur_norm" = "$new_norm" ] && [ "${stale_marks:-0}" -eq 0 ]; then
    rm -f "$tmp"
    log "LXC ${VMID} passthrough already matches live majors — no change"
    exit 0
fi

cat "$tmp" > "$CONF"
rm -f "$tmp"
log "LXC ${VMID} passthrough re-synced to live majors"

# Record the majors we just applied so the meta reflects reality rather than
# whatever was discovered at install time. Best-effort: a stale meta is a
# reporting problem, not a functional one — the conf above is what matters.
META="${TAPPAAS_DIR}/${MODULE}.meta.json"
if [ -f "${META}" ] && command -v jq >/dev/null 2>&1; then
    UVM_MAJ="$(printf '%d' "0x$(stat -c '%t' /dev/nvidia-uvm)")"
    UVM_MIN="$(printf '%d' "0x$(stat -c '%T' /dev/nvidia-uvm)")"
    # uvm-tools is optional (see the device guard above), so stat it only if
    # it exists — otherwise record null rather than stale values, which is
    # what the meta's own schema uses for "not discovered".
    if [ -c /dev/nvidia-uvm-tools ]; then
        UVMT_MAJ="$(printf '%d' "0x$(stat -c '%t' /dev/nvidia-uvm-tools)")"
        UVMT_MIN="$(printf '%d' "0x$(stat -c '%T' /dev/nvidia-uvm-tools)")"
    else
        UVMT_MAJ=null
        UVMT_MIN=null
    fi
    tmpm=$(mktemp)
    # Write the minors too: leaving them at their install-time value made the
    # meta self-contradictory after a drift, which is the one thing an
    # operator reads to confirm the drift was corrected.
    if jq --argjson a "${UVM_MAJ}"  --argjson b "${UVM_MIN}" \
          --argjson c "${UVMT_MAJ}" --argjson d "${UVMT_MIN}" \
        '.nvidia_gpu.uvm_major = $a | .nvidia_gpu.uvm_minor = $b
         | .nvidia_gpu.uvm_tools_major = $c | .nvidia_gpu.uvm_tools_minor = $d' \
        "${META}" > "${tmpm}" 2>/dev/null; then
        cat "${tmpm}" > "${META}"
        log "meta updated: uvm=${UVM_MAJ}:${UVM_MIN} uvm_tools=${UVMT_MAJ}:${UVMT_MIN}"
    fi
    rm -f "${tmpm}"
fi

# If the container is already running with stale cgroup rules, the conf change
# alone does not reach it. At boot this is normally a no-op (we run before
# pve-guests), so this only fires when an operator runs the script by hand.
if pct status "${VMID}" 2>/dev/null | grep -q running; then
    pct reboot "${VMID}" && log "LXC ${VMID} restarted to apply cgroup change"
fi
exit 0
