#!/usr/bin/env bash
# Build mikrotik-controller's runtime (default.nix, against the nixpkgs tappaas-cicd's
# flake.lock pins), GC-root it, and link the entry point into ~/bin (idempotent:
# nix does nothing when the inputs are unchanged).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
gcroots="${TAPPAAS_GCROOTS:-${HOME}/.tappaas-gcroots}"
flake="${TAPPAAS_CICD_FLAKE:-/home/tappaas/TAPPaaS/src/foundation/tappaas-cicd}"
mkdir -p "${bin}" "${gcroots}"
nix --extra-experimental-features 'nix-command flakes' build --impure \
    --out-link "${gcroots}/mikrotik-controller-env" --expr "
      import ${here}/default.nix {
        pkgs = (builtins.getFlake \"${flake}\").inputs.nixpkgs.legacyPackages.x86_64-linux;
      }" >/dev/null
chmod +x "${here}/mikrotik-controller"
ln -sfn "${here}/mikrotik-controller" "${bin}/mikrotik-controller"
echo "  linked ${bin}/mikrotik-controller (runtime: $(readlink -f "${gcroots}/mikrotik-controller-env"))"
