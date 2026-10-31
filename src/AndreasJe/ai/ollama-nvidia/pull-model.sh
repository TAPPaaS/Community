#!/usr/bin/env bash
# pull-model.sh — TAPPaaS ollama-nvidia model puller + smoke test
#
# Replaces vllm-amd's download-model.sh + scripts/install-model.sh: Ollama has
# no HF-safetensors download step and no compose-file --model flag to patch —
# `ollama pull <tag>` is self-sufficient, so there's one script instead of two.
#
# Run FROM tappaas-cicd (resolves the LXC's live node via pvesh, same pattern
# as test.sh/update.sh).
#
# Usage:
#   ./pull-model.sh smoke  [module]  — qwen2.5:3b   (~2GB, fits any supported card)
#   ./pull-model.sh prod   [module]  — qwen2.5:14b  (~9GB Q4, fully GPU-resident
#                                       at 12GB+ VRAM, hybrid-offloads on 8GB)
#   ./pull-model.sh large  [module]  — llama3.1:70b (~40GB Q4 — exercises the
#                                       hybrid GPU+CPU layer offload; needs
#                                       ~48GB free system RAM below 48GB VRAM)
#   ./pull-model.sh <ollama-library-tag> [module]  — any tag from ollama.com/library

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -z "${1:-}" ] && { echo "Usage: $0 {smoke|prod|large|<tag>} [module]"; exit 1; }
ARG="$1"
VMNAME="${2:-ollama-nvidia}"
CONFIG_FILE="${SCRIPT_DIR}/${VMNAME}.json"
[[ -f "$CONFIG_FILE" ]] || { echo "ERROR: ${CONFIG_FILE} not found — run from the module directory"; exit 1; }
VMID="${TAPPAAS_VMID_OVERRIDE:-$(jq -r '.vmid' "$CONFIG_FILE")}"

case "$ARG" in
    smoke) TAG="qwen2.5:3b" ;;
    prod)  TAG="qwen2.5:14b" ;;
    large) TAG="llama3.1:70b" ;;
    help|--help|-h)
        echo "Usage: $0 {smoke|prod|large|<tag>} [module]"
        echo ""
        echo "  smoke  — qwen2.5:3b   (~2GB, fits any supported card — quick validation)"
        echo "  prod   — qwen2.5:14b  (~9GB Q4, fully GPU-resident at 12GB+ VRAM,"
        echo "           hybrid-offloads on 8GB cards)"
        echo "  large  — llama3.1:70b (~40GB Q4, hybrid GPU+CPU offload — needs"
        echo "           ~48GB free system RAM below 48GB VRAM)"
        echo "  <tag>  — any tag from https://ollama.com/library"
        exit 0
        ;;
    *) TAG="$ARG" ;;
esac

_PRIMARY="tappaas1.mgmt.internal"
LXC_NODE="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${_PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --argjson id "${VMID}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
[[ -n "${LXC_NODE:-}" ]] || { echo "ERROR: cannot resolve the node hosting LXC ${VMID}"; exit 1; }
pct() { ssh -n -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${LXC_NODE}.mgmt.internal" pct "$@"; }

echo ""
echo "=== Pulling ${TAG} into ollama-nvidia (VMID: ${VMID}) ==="
echo ""
# ollama pull streams progress to stdout; give it plenty of time for large tags.
pct exec "${VMID}" -- docker exec ollama ollama pull "${TAG}"

echo ""
echo "=== Smoke test: ${TAG} ==="
# First load of a large hybrid-offload model streams tens of GB from disk
# into RAM/VRAM before the first token — give it 10 minutes, not 60s.
RESPONSE=$(pct exec "${VMID}" -- curl -s --connect-timeout 30 --max-time 600 \
    -X POST "http://127.0.0.1:11434/v1/chat/completions" \
    -H "Content-Type:application/json" \
    -d "'{\"model\":\"${TAG}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in exactly 3 words.\"}],\"max_tokens\":20}'" \
    2>/dev/null || true)

if echo "$RESPONSE" | jq -e '.choices[0].message.content' > /dev/null 2>&1; then
    echo "OK — response: $(echo "$RESPONSE" | jq -r '.choices[0].message.content')"
else
    echo "WARNING: smoke test did not return a valid completion."
    echo "  Raw response: ${RESPONSE}"
    echo "  (For 'large' tags this can simply mean the CPU-offloaded layers"
    echo "   are still loading — retry the curl by hand after a minute.)"
fi

# ── Register the model with LiteLLM ─────────────────────────────────────────
#
# Pulling is only half the job. LiteLLM is a router, not a model host: it holds
# no weights, just a routing entry saying "model X lives at this backend". A
# model that exists in Ollama but has no LiteLLM entry is invisible to every
# consumer, because OpenWebUI and the dev fleet reach models ONLY through
# LiteLLM (OpenWebUI's direct Ollama connection is deliberately disabled — it
# bypasses LiteLLM's tool-stripping, and models like phi4 and gemma3 return
# 400 "does not support tools" when a tools array reaches Ollama natively).
#
# Doing it here keeps the two halves together, so a pulled model is usable
# rather than merely present. Idempotent and non-fatal: a model already
# registered is left alone, and a LiteLLM that cannot be reached is reported
# rather than failing the pull that already succeeded.
LITELLM_HOST="${LITELLM_HOST:-litellm.srvWork.internal}"
OLLAMA_HOST="${OLLAMA_HOST:-ollama-nvidia.srvWork.internal}"
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

echo ""
echo "=== Registering ${TAG} with LiteLLM (${LITELLM_HOST}) ==="

# The master key lives only on the LiteLLM VM, so the whole call runs there.
if ! ssh ${SSH_OPTS} "tappaas@${LITELLM_HOST}" "bash -s" <<REMOTE
set -uo pipefail
MK="\$(sudo grep -m1 '^LITELLM_MASTER_KEY=' /etc/secrets/litellm.env 2>/dev/null | cut -d= -f2- | tr -d '\r\n\"')"
[ -n "\$MK" ] || { echo "  no master key on \$(hostname) — skipped"; exit 1; }

EXISTING="\$(curl -fsS --max-time 20 -H "Authorization: Bearer \$MK" \
              http://127.0.0.1:4000/model/info 2>/dev/null \
            | jq -r --arg m "${TAG}" '[.data[]? | select(.model_name == \$m)] | length' 2>/dev/null)"
if [ "\${EXISTING:-0}" != "0" ]; then
    echo "  '${TAG}' already registered — nothing to do"
    exit 0
fi

if curl -fsS --max-time 30 -X POST http://127.0.0.1:4000/model/new \
     -H "Authorization: Bearer \$MK" -H 'Content-Type: application/json' \
     -d "\$(jq -nc --arg m '${TAG}' --arg b 'http://${OLLAMA_HOST}:11434' \
           '{model_name:\$m, litellm_params:{model:("ollama/"+\$m), api_base:\$b, litellm_credential_name:"ollama"}}')" \
     >/dev/null
then
    echo "  registered '${TAG}' -> http://${OLLAMA_HOST}:11434"
else
    echo "  could not register '${TAG}' with LiteLLM" >&2
    exit 1
fi
REMOTE
then
    echo ""
    echo "WARNING: ${TAG} is pulled but NOT registered with LiteLLM, so it will"
    echo "  not appear in OpenWebUI. Register it by hand with POST /model/new,"
    echo "  or re-run this script once ${LITELLM_HOST} is reachable."
fi
