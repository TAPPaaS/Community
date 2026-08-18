# Podman — container host with a web console

Primary audience: TAPPaaS operator who wants a plain place to run OCI containers.

A **Debian 13 (trixie) VM with [Podman](https://podman.io) installed** — the daemonless,
rootless-capable container engine (a drop-in for `docker`). On top of the engine it adds the
**Cockpit web console** with the **`cockpit-podman`** plugin, so containers, images and pods
can be managed from a browser instead of only the CLI. Cockpit's console has a **login
screen**, so per the module brief it is published internally as `https://podman.<domain>` via
`network:proxy`.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Podman container engine (rootless + CLI) | on the VM | `ssh tappaas@<vm-ip>` then `podman …` |
| Cockpit web console (login + Podman page) | `mgmt` zone | `https://podman.<domain>` (internal) |
| Direct console | LAN reachable from `mgmt` | `https://<vm-ip>:9090` |
| `podman-compose` for compose files | on the VM | `podman-compose up -d` |

## What is not included

- **No pre-loaded containers.** This is a clean host — you bring the images/compose files.
- **No internet exposure.** The friendly name is reachable only from the `mgmt` zone; it is
  not published to the internet (no inbound NAT/port-forward).
- **No Docker daemon / Kubernetes.** Podman is daemonless; there is no `dockerd` and no k8s
  control plane here (Podman can generate/play Kubernetes YAML, but that is out of scope).
- **No default web login.** The console authenticates against Linux (PAM) accounts on the VM;
  the cloud-init `tappaas` user has no password until you set one — see [INSTALL.md](./INSTALL.md).

## Access (internal only)

`network:proxy` publishes **`https://podman.<domain>`** (split-horizon DNS → Caddy → the VM's
`:9090`, HTTPS upstream), with an access-list permitting only the **`mgmt`** zone — **not
reachable from the internet**. Cockpit rides WebSockets, so the route is created with
`proxyUpstreamHttp1: true` (Caddy talks HTTP/1.1 to the upstream); the direct
`https://<vm-ip>:9090` always works too.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | Creates the Debian 13 VM from the cloud image |
| `templates:debian` | OS prep (apt update/upgrade + qemu-guest-agent) |
| `backup:vm` | Scheduled VM backup to PBS |
| `network:proxy` | Internal-only reverse proxy for `podman.<domain>` |

## Placement

The module sets no explicit `zone0`, so the VM is placed in the **default environment's zone**;
install it with `--environment <env>` to put it in a specific environment and its associated
zone instead (see [INSTALL.md](./INSTALL.md#placement--zone)).

## Sizing

2 vCPU / **2 GB** RAM / 20 GB disk — enough for the engine, Cockpit and a handful of light
containers. Bump memory/disk to match whatever you actually run on it (container images and
volumes land on the VM disk, thin-provisioned on ZFS).

For installation steps see [INSTALL.md](./INSTALL.md).
