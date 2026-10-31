#!/usr/bin/env bash
# TAPPaaS Module: ollama-nvidia — Test
#
# Verifies the Ollama NVIDIA module is functioning correctly.
#
# Usage: ./test.sh ollama-nvidia

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMNAME="${1:-ollama-nvidia}"
CONFIG_FILE="${SCRIPT_DIR}/${VMNAME}.json"
VMID="${TAPPAAS_VMID_OVERRIDE:-$(jq -r '.vmid' "$CONFIG_FILE")}"

_PRIMARY="tappaas1.mgmt.internal"
LXC_NODE="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${_PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
[[ -n "${LXC_NODE:-}" ]] || { echo "ERROR: cannot resolve the node hosting LXC ${VMID}"; exit 1; }
pct() { ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${LXC_NODE}.mgmt.internal" pct "$@"; }

PASS=0
FAIL=0
WARN=0

check() {
    local desc="$1"
    local result="$2"
    if [[ "$result" == "0" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

warn() {
    local desc="$1"
    echo "  WARN: $desc"
    WARN=$((WARN + 1))
}

echo ""
echo "=== Testing Ollama NVIDIA Module (VMID: ${VMID}) ==="
echo ""

# Every probed command uses the `RC=0; cmd || RC=$?` capture pattern: a bare
# `cmd; check "$?"` under set -e aborts the whole script on the first failing
# probe, so FAIL counts would never be reported.

# Test 1: Container running
echo "--- LXC Container ---"
RC=0; pct status "${VMID}" 2>/dev/null | grep -q "running" || RC=$?
check "LXC container is running" "$RC"

# Test 2: exec access
RC=0; pct exec "${VMID}" -- echo "ok" > /dev/null 2>&1 || RC=$?
check "Can exec into container" "$RC"

# Test 3: GPU device access
echo ""
echo "--- GPU Access ---"
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm; do
    RC=0; pct exec "${VMID}" -- ls "$dev" > /dev/null 2>&1 || RC=$?
    check "$dev device node present in LXC" "$RC"
done

_node() { ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${LXC_NODE}.mgmt.internal" "$@"; }
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm; do
    HEX_MAJ=$(_node stat -c '%t' "$dev" 2>/dev/null || echo "0")
    HEX_MIN=$(_node stat -c '%T' "$dev" 2>/dev/null || echo "0")
    CGROUP_RC=0
    _node grep -qF "cgroup2.devices.allow: c $((16#${HEX_MAJ})):$((16#${HEX_MIN})) rwm" "/etc/pve/lxc/${VMID}.conf" \
        > /dev/null 2>&1 || CGROUP_RC=$?
    check "$dev cgroup allow matches live major:minor ($((16#${HEX_MAJ})):$((16#${HEX_MIN})))" "$CGROUP_RC"
done

# Test 4: Docker running
echo ""
echo "--- Docker ---"
RC=0; pct exec "${VMID}" -- docker ps > /dev/null 2>&1 || RC=$?
check "Docker daemon running" "$RC"

# Test 5: Ollama container
echo ""
echo "--- Ollama Service ---"
OLLAMA_RUNNING=$(pct exec "${VMID}" -- docker ps --filter name=ollama --format "{{.Status}}" 2>/dev/null || echo "")
if [[ "$OLLAMA_RUNNING" == *"Up"* ]]; then
    check "Ollama container running" "0"

    # Test 5b: GPU compute accessible in container
    NVSMI_RC=0
    pct exec "${VMID}" -- docker exec ollama nvidia-smi > /dev/null 2>&1 || NVSMI_RC=$?
    if [[ "$NVSMI_RC" -eq 0 ]]; then
        check "GPU compute accessible in container (nvidia-smi)" "0"
    else
        check "GPU compute accessible in container (nvidia-smi)" "1"
        echo "  (Check nvidia-container-toolkit config and re-run update.sh ollama-nvidia)"
    fi
else
    check "Ollama container running" "1"
    echo "  (Start with: pct exec ${VMID} -- bash -c 'cd /opt/ollama && docker compose up -d')"
fi

# Test 6: Ollama API responding
echo ""
echo "--- API Health ---"
api() { pct exec "${VMID}" -- curl -s --connect-timeout 5 "$@" 2>/dev/null; }
HTTP_CODE=$(pct exec "${VMID}" -- curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://127.0.0.1:11434/api/tags" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    check "Ollama API responding (127.0.0.1:11434)" "0"

    echo ""
    echo "  Pulled models:"
    api "http://127.0.0.1:11434/api/tags" | jq -r '.models[].name' 2>/dev/null | while read -r model; do
        echo "    - $model"
    done

    # Test 7: Inference test (only if at least one model is pulled)
    echo ""
    echo "--- Inference Test ---"
    MODEL=$(api "http://127.0.0.1:11434/api/tags" | jq -r '.models[0].name' 2>/dev/null || echo "")
    if [[ -n "$MODEL" && "$MODEL" != "null" ]]; then
        RESPONSE=$(pct exec "${VMID}" -- curl -s --connect-timeout 30 --max-time 60 \
            -X POST "http://127.0.0.1:11434/v1/chat/completions" \
            -H "Content-Type:application/json" \
            -d "'{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly 3 words.\"}],\"max_tokens\":20}'" \
            2>/dev/null || true)
        if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
            check "Inference working (model: ${MODEL})" "0"
            ANSWER=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
            echo "  Response: ${ANSWER}"
        else
            check "Inference working" "1"
        fi
    else
        warn "No model pulled yet — skip inference test (run ./pull-model.sh smoke)"
    fi
else
    check "Ollama API responding (HTTP ${HTTP_CODE})" "1"
    if [[ "$OLLAMA_RUNNING" == *"Up"* ]]; then
        echo "  (Container running but API not ready — check logs: pct exec ${VMID} -- docker logs -f ollama)"
    fi
fi

# --- GPU residency / CPU-fallback probe ---
#
# The failure this catches: when a model no longer fits in VRAM — because the
# uvm major drifted and CUDA is gone, or because too many models are pinned —
# Ollama does NOT error. It quietly splits the model across GPU and CPU and
# keeps answering, just far slower. Every check above still passes: the
# container is up, the API returns 200, inference "works". So the only way to
# see it is to measure.
#
# Two independent signals, because each misses a case the other catches:
#   - `ollama ps` PROCESSOR — names the split directly, but only while a model
#     is loaded, and reports nothing about actual speed.
#   - tokens/sec from the generate API — catches a slow GPU path that still
#     reports 100% GPU (e.g. thermal throttling, a wrong CUDA build).
if [[ "$HTTP_CODE" == "200" && -n "${MODEL:-}" && "${MODEL}" != "null" ]]; then
    echo ""
    echo "--- GPU Residency / CPU-Fallback Probe ---"

    # Does this model even fit? A model larger than VRAM is ALWAYS hybrid — that
    # is physics, not a fault, and must not be reported as a failure or the
    # suite goes permanently red and blocks update-module.sh's pre-update gate.
    # Only a model that SHOULD fit and is still split indicates a real problem
    # (a drifted uvm major, a lost CUDA runtime, another model hogging VRAM).
    VRAM_MB=$(pct exec "${VMID}" -- nvidia-smi --query-gpu=memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    PS_OUT=$(pct exec "${VMID}" -- docker exec ollama ollama ps 2>/dev/null || true)
    MODEL_MB=$(echo "$PS_OUT" | awk 'NR==2 {
        for (i=1;i<=NF;i++) if ($i=="GB") { printf "%d", $(i-1)*1024; exit }
        for (i=1;i<=NF;i++) if ($i=="MB") { printf "%d", $(i-1);      exit }
    }')
    FITS=1
    if [[ -n "$VRAM_MB" && -n "$MODEL_MB" ]]; then
        # 0.90 leaves room for the CUDA context and KV cache alongside weights.
        awk -v m="$MODEL_MB" -v v="$VRAM_MB" 'BEGIN{exit !(m > v*0.90)}' && FITS=0
    fi

    if echo "$PS_OUT" | grep -q "CPU"; then
        if [[ "$FITS" -eq 0 ]]; then
            warn "CPU offload EXPECTED: model ~${MODEL_MB}MB exceeds ${VRAM_MB}MB VRAM"
            echo "    Not a fault — this model cannot fit on this GPU. Prefer a"
            echo "    model under ~$((VRAM_MB * 90 / 100))MB for full-GPU speed."
        else
            check "No CPU offload (model fits VRAM but is split)" "1"
        fi
        echo "$PS_OUT" | sed 's/^/    /'
    elif echo "$PS_OUT" | grep -q "100% GPU"; then
        check "Model resident 100% on GPU" "0"
    else
        warn "No model currently loaded — PROCESSOR check inconclusive"
    fi

    # eval_count / eval_duration is Ollama's own generation accounting;
    # eval_duration is nanoseconds and excludes prompt load, so this is
    # generation throughput rather than end-to-end latency.
    GEN=$(pct exec "${VMID}" -- curl -s --connect-timeout 30 --max-time 120 \
        -X POST "http://127.0.0.1:11434/api/generate" \
        -H "Content-Type:application/json" \
        -d "'{\"model\":\"${MODEL}\",\"prompt\":\"Count from 1 to 30.\",\"stream\":false}'" \
        2>/dev/null || true)

    EVAL_N=$(echo "$GEN" | jq -r '.eval_count // empty' 2>/dev/null || echo "")
    EVAL_NS=$(echo "$GEN" | jq -r '.eval_duration // empty' 2>/dev/null || echo "")
    if [[ -n "$EVAL_N" && -n "$EVAL_NS" && "$EVAL_NS" != "0" ]]; then
        TPS=$(awk -v n="$EVAL_N" -v d="$EVAL_NS" 'BEGIN{printf "%.1f", n/(d/1000000000)}')
        # Floor, not a benchmark. A P100 running a small model fully on GPU
        # clears this by a wide margin; hybrid CPU offload lands well under it.
        # Deliberately loose so a bigger model or a busy host does not cry wolf
        # — raise it per-deployment once you know the real numbers.
        FLOOR="${OLLAMA_MIN_TOKENS_PER_SEC:-10}"
        if awk -v t="$TPS" -v f="$FLOOR" 'BEGIN{exit !(t >= f)}'; then
            check "Generation throughput ${TPS} tok/s (floor ${FLOOR})" "0"
        elif [[ "$FITS" -eq 0 ]]; then
            # Same reasoning as the PROCESSOR check above: an oversized model is
            # slow by arithmetic, not by regression. Report it, don't fail on it.
            warn "Throughput ${TPS} tok/s — expected, model exceeds VRAM"
        else
            check "Generation throughput ${TPS} tok/s BELOW floor ${FLOOR}" "1"
            echo "    Model fits VRAM yet is slow — suspect CPU fallback. Check"
            echo "    nvidia-smi inside the LXC, and that /dev/nvidia-uvm's major"
            echo "    matches the LXC conf (see boot-gpu-reconcile.sh)."
        fi
    else
        warn "Could not read eval_count/eval_duration — throughput check skipped"
    fi
fi

# Summary
echo ""
echo "=== Test Summary ==="
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
echo "  WARN: ${WARN}"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo "RESULT: FAIL (${FAIL} tests failed)"
    exit 1
else
    echo "RESULT: PASS"
    exit 0
fi
