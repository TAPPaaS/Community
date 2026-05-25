# euro-office Installation Guide

## Prerequisites

- `cluster:vm`, `templates:nixos`, `backup:vm`, and `firewall:proxy` must already be installed
- A secrets file must exist at `/home/tappaas/secrets/euro-office.env` containing `TAPPAAS_PASSWORD`

## Installation Steps

### 1. Review Configuration

Open [euro-office.json](./euro-office.json) and verify the settings match your environment:

- `node` — which Proxmox node to deploy on (default: `tappaas1`)
- `storage` — storage pool for the VM disk (default: `tanka1`)
- `vmid` — must be unique in your cluster (default: `312`)
- `proxyDomain` — the public hostname for the Caddy reverse proxy

To override defaults without editing the file, copy it to `/home/tappaas/config/euro-office.json` and edit the copy.

### 2. Create the Secrets File

```bash
cat > /home/tappaas/secrets/euro-office.env <<EOF
TAPPAAS_PASSWORD=<generate a strong password>
EOF
chmod 600 /home/tappaas/secrets/euro-office.env
```

The `JWT_SECRET` is auto-generated inside the VM on first boot — do not add it here.

### 3. Run the Installer

From the tappaas-cicd VM, in the module directory:

```bash
cd /home/tappaas/TAPPaaS/src/apps/euro-office
./install.sh euro-office 312 tappaas1
```

The installer will:
1. Create and configure the VM (cloud-init, NixOS rebuild)
2. Pull and start the DocumentServer container
3. Apply the JWT configuration patch
4. Register with the Caddy reverse proxy

Installation takes approximately 5–10 minutes, most of which is the NixOS rebuild and container image pull.

### 4. Verify the Installation

```bash
./test.sh euro-office 312 tappaas1
```

All 10 tests should pass. The HTTPS test requires a valid Let's Encrypt certificate; allow a few minutes after first install for Caddy to issue it.

### 5. Access the Service

| URL | Purpose |
|-----|---------|
| `https://eu-office.example.com/example/` | Built-in test editor — create and edit documents |
| `https://eu-office.example.com/` | DocumentServer welcome page |

## Common Issues

**"document security token is not correctly formed" error in the editor**
The JWT patch did not apply on first boot. SSH into the VM and run manually:
```bash
sudo podman exec euro-office sh -c '
  jq ".services.CoAuthoring.token.enable.browser = false |
      .services.CoAuthoring.token.enable.request.inbox = false |
      .services.CoAuthoring.token.enable.request.outbox = false" \
    /etc/onlyoffice/documentserver/local.json > /tmp/local.tmp &&
  mv /tmp/local.tmp /etc/onlyoffice/documentserver/local.json
' && sudo podman exec euro-office supervisorctl restart docservice converter
```

**VM gets no IP address after creation**
Check that the Proxmox node's physical switch port trunks VLAN 210 (srv zone). This issue has been seen on tappaas2 where the switch port was not configured for service VLANs.

**HTTPS returns an untrusted certificate**
Wait 2–3 minutes after first install for Let's Encrypt to issue the certificate. Caddy handles renewal automatically.

**Container not starting**
Check secrets file exists inside the VM:
```bash
ssh tappaas@<vm-ip> "sudo cat /etc/secrets/euro-office.env"
```
If missing, the oneshot service did not run. Check: `sudo journalctl -u euro-office-init-secrets`.
