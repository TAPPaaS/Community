# MikroTik switches — install

## 1. On each switch (RouterOS 7, once)

```routeros
/interface bridge set bridge vlan-filtering=yes          # the bridge the ports are on
/user group add name=tappaas policy=read,write,api,test
/user add name=tappaas group=tappaas password=<a long password>
/ip service set api address=<mothership address>/32       # or api-ssl with a certificate
```

Keep the switch's own management address on a port or VLAN TAPPaaS does not manage.

## 2. The module

```bash
module-manager module add mikrotik
```

module-manager builds `mikrotik-controller` (Ansible and `community.routeros`, from the
release's nixpkgs), links it into `~/bin` and records it in `config/control-plane.json`.

## 3. Each switch

```bash
/home/tappaas/Community/src/larsrossen/network/mikrotik/setup-credentials.sh crs-a --ip 10.0.0.5
# prompts for the RouterOS user and password, checks the login, stores
# ~/.mikrotik-credentials/crs-a.txt (chmod 600) and adds crs-a to switch-manager
switch-manager interrogate
switch-manager add-port crs-a sfp-sfpplus1 --type node --target tappaas1 --target-port enp1s0
switch-manager reconcile            # preview
switch-manager reconcile --apply
```

## 4. An MLAG pair (optional)

Set the peer link once on both switches in RouterOS (`/interface bridge mlag set
bridge=bridge peer-port=<port>`, the same `system-id` on both). Then declare the pair and
an aggregate across it:

```bash
switch-manager mlag-pair set crs-a crs-b --peer-port sfp-sfpplus16
switch-manager lag set crs-a node1 --ports crs-a:sfp-sfpplus1,crs-b:sfp-sfpplus1 --apply
```

## Verification

```bash
module-manager module test mikrotik
```
