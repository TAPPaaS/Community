#!/usr/bin/env python3
"""mikrotik-controller — MikroTik RouterOS switches for switch-manager (switch/1, ADR-035).

A device-architecture controller: one RouterOS switch (CRS3xx/CRS5xx, RouterOS 7,
bridge VLAN filtering) per management address. Reads and writes go over the
RouterOS API through Ansible's community.routeros collection (ADR-035 D10); this
file maps what RouterOS answers onto switch/1 and plans an apply itself, so only
the ports TAPPaaS manages are touched and `apply --check` is that plan.

Verbs (switch/1): describe, supports, check-access, interrogate, apply, mlag-status.
JSON on stdout only; reasons on stderr. Exit 0 done, 1 the switch refused or could
not be reached, 2 bad usage, 3 not this controller's.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
CONTRACT = os.path.join(HERE, "contract.json")
PLAYBOOKS = os.path.join(HERE, "playbooks")
CRED_DIR = os.path.expanduser(os.environ.get("MIKROTIK_CREDENTIALS_DIR", "/home/tappaas/.mikrotik-credentials"))
CONFIG_DIR = os.environ.get("CONFIG_DIR", "/home/tappaas/config")

ACCESS_FRAMES = "admit-only-untagged-and-priority-tagged"
TRUNK_FRAMES = "admit-all"
BOND_DEFAULTS = {"mode": "802.3ad", "lacp-rate": "1sec", "transmit-hash-policy": "layer-2-and-3"}
READ_PATHS = ["interface ethernet", "interface bonding", "interface bridge", "interface bridge port",
              "interface bridge vlan", "interface bridge mlag", "system resource", "system identity",
              "system routerboard"]


class Refused(Exception):
    """The switch refused, or could not be reached (exit 1)."""


def warn(msg):
    print(f"mikrotik-controller: {msg}", file=sys.stderr)


# ── Values as RouterOS answers them ──────────────────────────────────
# librouteros types what it can (true/false, numbers); a raw answer is strings.

def truthy(v):
    return v is True or str(v).lower() in ("true", "yes")


def natkey(s):
    return [int(p) if p.isdigit() else p for p in re.findall(r"\d+|\D+", str(s))]


def split_list(v):
    """ "ether1,bond1" -> ["ether1", "bond1"]; empty -> []."""
    if v is None or v == "":
        return []
    if isinstance(v, list):
        return [str(x) for x in v]
    return [x for x in str(v).split(",") if x]


def vlan_ids(v):
    """ "200,310-312" -> [200, 310, 311, 312]."""
    out = []
    for part in split_list(v):
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return out


def join_list(items):
    return ",".join(sorted(set(items), key=natkey))


# ── Credentials and the Ansible runs ─────────────────────────────────

def credentials(switch, path=None):
    """The switch's credentials file: username=, password=, and optionally tls=,
    port=, validate_certs=, force_no_cert= (key=value lines, # comments)."""
    f = path or os.path.join(CRED_DIR, f"{switch}.txt")
    if not os.path.isfile(f):
        raise Refused(f"no credentials for {switch}: {f} (run the mikrotik module's setup-credentials.sh {switch} --ip <address>)")
    c = {}
    with open(f, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                c[k.strip()] = v.strip()
    if not c.get("username") or not c.get("password"):
        raise Refused(f"{f}: username= and password= are both needed (a RouterOS user in a group with the api policy)")
    return c


def connection(ip, cred):
    conn = {"hostname": ip, "username": cred["username"], "password": cred["password"],
            "tls": truthy(cred.get("tls", "false")),
            "validate_certs": truthy(cred.get("validate_certs", "false")),
            "force_no_cert": truthy(cred.get("force_no_cert", "false")),
            "timeout": int(cred.get("timeout", "15"))}
    if cred.get("port"):
        conn["port"] = int(cred["port"])
    return conn


def ansible_bin(name):
    d = os.environ.get("MIKROTIK_ANSIBLE_BIN") or os.path.dirname(sys.executable)
    return os.path.join(d, name)


def run_playbook(playbook, ip, cred, extra, check=False, debug=False):
    """Run one playbook against the switch; return what it wrote to its result file.
    The password goes in a 0600 vars file, never on a command line."""
    with tempfile.TemporaryDirectory(prefix="mikrotik-") as tmp:
        vars_file = os.path.join(tmp, "vars.json")
        out_file = os.path.join(tmp, "result.json")
        data = {"conn": connection(ip, cred), "out_file": out_file,
                "ansible_python_interpreter": sys.executable, **extra}
        fd = os.open(vars_file, os.O_WRONLY | os.O_CREAT, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh)
        env = dict(os.environ, ANSIBLE_LOCAL_TEMP=os.path.join(tmp, "ansible"), ANSIBLE_NOCOLOR="1",
                   ANSIBLE_RETRY_FILES_ENABLED="0", ANSIBLE_DEPRECATION_WARNINGS="0",
                   ANSIBLE_LOCALHOST_WARNING="0", ANSIBLE_INVENTORY_UNPARSED_WARNING="0",
                   ANSIBLE_HOME=os.path.join(tmp, "home"))
        cmd = [ansible_bin("ansible-playbook"), "-i", "localhost,", "-e", f"@{vars_file}",
               os.path.join(PLAYBOOKS, playbook)]
        if check:
            cmd += ["--check", "--diff"]
        p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if debug:
            print(p.stdout, file=sys.stderr)
        if p.returncode != 0:
            raise Refused(f"{ip}: {playbook} failed — {ansible_reason(p.stdout)}")
        if not os.path.exists(out_file):
            return {}
        with open(out_file, encoding="utf-8") as fh:
            return json.load(fh)


def ansible_reason(out):
    """The useful line of a failed run: the last module msg, else the last error line."""
    msgs = re.findall(r'"msg":\s*"((?:[^"\\]|\\.)*)"', out)
    if msgs:
        return msgs[-1].encode("utf-8").decode("unicode_escape")[:300]
    lines = [l for l in out.splitlines() if "FAILED" in l or "ERROR" in l or "fatal" in l]
    if lines:
        return lines[-1][:300]
    return (out.strip().splitlines() or ["no output"])[-1][:300]


def monitor(ip, cred, path, **args):
    """A RouterOS monitor (`… monitor once`), read through librouteros — the
    library community.routeros itself uses: the collection's `api` module runs
    the command but drops its answer. Reads only."""
    import ssl
    import librouteros
    conn = connection(ip, cred)
    kw = {"host": ip, "username": conn["username"], "password": conn["password"], "timeout": conn["timeout"]}
    if conn.get("port"):
        kw["port"] = conn["port"]
    if conn["tls"]:
        ctx = ssl.create_default_context()
        if not conn["validate_certs"]:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        if conn["force_no_cert"]:
            ctx.set_ciphers("ADH:@SECLEVEL=0")
        kw["ssl_wrapper"] = ctx.wrap_socket
        kw.setdefault("port", 8729)
    try:
        api = librouteros.connect(**kw)
        try:
            return list(api.path(*path.split())("monitor", once=True, **args))
        finally:
            api.close()
    except Exception as e:  # noqa: BLE001 — the reason is what the caller reports
        raise Refused(f"{ip}: {path} monitor failed — {e}")


def read_raw(ip, cred, debug=False):
    r = run_playbook("read.yml", ip, cred, {"paths": READ_PATHS}, debug=debug)
    return {p: (r.get(p) if isinstance(r.get(p), list) else []) for p in READ_PATHS}


# ── RouterOS -> switch/1 ─────────────────────────────────────────────

def static(entries):
    return [e for e in entries if not truthy(e.get("dynamic", False))]


def model(raw, bridge):
    """What the managers need from a read: interfaces, bonds, bridge ports and the
    static VLAN entries of <bridge>."""
    eth = {e["name"]: e for e in raw["interface ethernet"] if e.get("name")}
    bonds = {b["name"]: b for b in raw["interface bonding"] if b.get("name")}
    ports = {p["interface"]: p for p in raw["interface bridge port"] if p.get("bridge") == bridge and p.get("interface")}
    vlans = [v for v in static(raw["interface bridge vlan"]) if v.get("bridge") == bridge]
    slave_of = {s: b for b, bo in bonds.items() for s in split_list(bo.get("slaves"))}
    br = next((b for b in raw["interface bridge"] if b.get("name") == bridge), None)
    # The MLAG peer link (a port or a bond of ports) is the operator's: it carries
    # every VLAN between the two switches and is never TAPPaaS's to program.
    peer = mlag_peer(raw, bridge, br)
    peer_ifaces = set()
    if peer:
        peer_ifaces = {peer} | set(split_list(bonds.get(peer, {}).get("slaves")))
    return {"eth": eth, "bonds": bonds, "ports": ports, "vlans": vlans, "slave_of": slave_of, "bridge": br,
            "peer": peer, "peer_ifaces": peer_ifaces}


def mlag_peer(raw, bridge, br=None):
    """The bridge's MLAG peer port, wherever this RouterOS keeps it: up to 7.2x in
    its own menu (`/interface bridge mlag`, `peer-port`), from 7.23 on the bridge
    itself (`mlag-peer-port`). None when MLAG is not set up."""
    if br is None:
        br = next((b for b in raw.get("interface bridge", []) if b.get("name") == bridge), None) or {}
    p = br.get("mlag-peer-port")
    if p not in (None, "", "none"):
        return p
    old = next((x for x in raw.get("interface bridge mlag", []) if x.get("bridge") == bridge and x.get("peer-port")), None)
    return old.get("peer-port") if old else None


def native_of(pvid, bridge_pvid=1):
    """TAPPaaS's nativeVlan 0 is the bridge's own (untagged) VLAN, PVID 1 by default."""
    pvid = int(pvid if pvid not in (None, "") else 1)
    return 0 if pvid == int(bridge_pvid or 1) else pvid


def interrogate(raw, name, ip, bridge="bridge"):
    m = model(raw, bridge)
    if m["bridge"] is None:
        raise Refused(f"{name}: no bridge '{bridge}' on the switch (--bridge NAME, or set it up with vlan-filtering=yes)")
    if not truthy(m["bridge"].get("vlan-filtering", False)):
        warn(f"{name}: bridge '{bridge}' has vlan-filtering off — the VLANs below are configured but not enforced")
    bpvid = m["bridge"].get("pvid", 1)
    res = (raw["system resource"] or [{}])[0]
    rb = (raw["system routerboard"] or [{}])[0]
    ident = (raw["system identity"] or [{}])[0]
    out_ports = {}
    for ifname in sorted(m["eth"], key=natkey):
        e = m["eth"][ifname]
        bond = m["slave_of"].get(ifname)
        target = bond or ifname
        bp = m["ports"].get(target)
        p = {"link": "up" if truthy(e.get("running")) else "down",
             "disabled": truthy(e.get("disabled")), "source": "discovered", "lagMembers": []}
        if bond:
            members = sorted(split_list(m["bonds"][bond].get("slaves")), key=natkey)
            p["bond"] = bond
            if members and members[0] == ifname:
                p["lagMembers"] = members
            mlag = m["bonds"][bond].get("mlag-id")
            if mlag not in (None, ""):
                p["liveMlagId"] = int(mlag)
        if ifname in m["peer_ifaces"]:
            # The MLAG peer link: reported disabled so the manager neither parks
            # nor warns about it, and refused if anything asks to program it.
            p.update({"mode": "trunk", "nativeVlan": 0, "disabled": True, "peerLink": True,
                      "taggedVlans": sorted({v for vl in m["vlans"] if target in split_list(vl.get("tagged")) for v in vlan_ids(vl.get("vlan-ids"))})})
            out_ports[ifname] = p
            continue
        if bp is None:
            # Not on the bridge (a routed or management port): reported disabled,
            # so the manager neither parks nor programs it.
            p.update({"mode": "access", "nativeVlan": 0, "taggedVlans": [], "disabled": True, "bridged": False})
            out_ports[ifname] = p
            continue
        tagged = sorted({v for vl in m["vlans"] if target in split_list(vl.get("tagged")) for v in vlan_ids(vl.get("vlan-ids"))})
        p["nativeVlan"] = native_of(bp.get("pvid"), bpvid)
        p["mode"] = "trunk" if tagged else "access"
        p["taggedVlans"] = tagged
        if truthy(bp.get("disabled")):
            p["disabled"] = True
        out_ports[ifname] = p
    sw = {"vendor": "mikrotik", "model": rb.get("model") or res.get("board-name") or "",
          "managementIp": ip, "firmware": str(res.get("version", "")), "identity": ident.get("name", ""),
          "bridge": bridge, "ports": out_ports}
    if m["peer"]:
        br = m["bridge"] or {}
        # What MikroTik requires alike on both peers (or the pair floods its own
        # MLAG bonds): the heartbeat on, the same STP priority. Reported so the
        # manager can compare the two (mlag-pair list, the mlag-pairs gate).
        sw["mlag"] = {"peerPort": m["peer"], "bridge": bridge,
                      "heartbeat": str(br.get("mlag-heartbeat", "")) if "mlag-heartbeat" in br else None,
                      "priority": br.get("mlag-priority"), "stpPriority": br.get("priority")}
    return {"switches": {name: sw}, "aps": {}}


# ── apply: desired ports -> RouterOS operations ──────────────────────

def managed(ports):
    """The ports TAPPaaS manages (annotated or parked, as on UniFi), lead or alone:
    a member that follows its lead is set through it."""
    out = {k: v for k, v in ports.items() if v.get("type") is not None or v.get("parked") is True}
    followers = {str(x) for v in out.values() for x in (v.get("lagMembers") or [])[1:]}
    followers |= {k for k, v in out.items() if v.get("lagLead") is not None}
    return {k: v for k, v in out.items() if k not in followers}, followers


def plan(raw, desired_ports, bridge="bridge", mlag_ids=None):
    """The operations that bring the managed ports to desired, in the order they
    must run, and what changes ({port, from, to}). Ports the desired file does not
    manage are not touched; neither are VLAN memberships of other interfaces."""
    m = model(raw, bridge)
    if m["bridge"] is None:
        raise Refused(f"no bridge '{bridge}' on the switch")
    bpvid = int(m["bridge"].get("pvid", 1) or 1)
    leads, followers = managed(desired_ports)
    ops, changed, lags = [], [], []
    errors = []

    # Which interface carries each managed lead's VLANs: the bond when it leads a
    # LAG, else the port itself.
    target, new_bonds, apart = {}, [], []
    for port, d in sorted(leads.items(), key=lambda kv: natkey(kv[0])):
        members = [str(x) for x in (d.get("lagMembers") or [])]
        cur_bond = m["slave_of"].get(port)
        hit = ({port} | set(members)) & m["peer_ifaces"]
        if hit:
            errors.append(f"{', '.join(sorted(hit, key=natkey))} is the MLAG peer link ({m['peer']}) — the operator's, never programmed by TAPPaaS")
            continue
        # An aggregate: two or more members here, or one when its other member
        # is on the MLAG peer (an mlag-id names it).
        if len(members) > 1 or (members and port in (mlag_ids or {})):
            gone = [x for x in members if x not in m["eth"]]
            if gone:
                errors.append(f"LAG of {port}: no interface {', '.join(gone)} on the switch")
                continue
            existing = next((b for b, bo in m["bonds"].items()
                             if sorted(split_list(bo.get("slaves")), key=natkey) == sorted(members, key=natkey)), None)
            name = existing or cur_bond or f"bond-{port}"
            target[port] = name
            want_mlag = (mlag_ids or {}).get(port)
            if existing is None:
                new_bonds.append({"name": name, "members": sorted(members, key=natkey), "update": name in m["bonds"],
                                  "mlag": want_mlag})
                lags.append({"port": port, "bond": name, "members": sorted(members, key=natkey), "action": "form"})
            elif want_mlag is not None and str(m["bonds"][name].get("mlag-id", "")) != str(want_mlag):
                ops.append({"op": "update", "path": "interface bonding", "args": f".id={m['bonds'][name]['.id']} mlag-id={want_mlag}"})
                lags.append({"port": port, "bond": name, "members": sorted(members, key=natkey), "action": "mlag-id"})
        else:
            target[port] = port
            if cur_bond:
                apart.append(cur_bond)
                lags.append({"port": port, "bond": cur_bond, "members": sorted(split_list(m["bonds"][cur_bond].get("slaves")), key=natkey), "action": "take apart"})
        if target[port] == port and port not in m["ports"] and not cur_bond:
            if port in m["eth"]:
                errors.append(f"{port} is not a port of bridge '{bridge}' — not touched (add it to the bridge by hand if TAPPaaS should manage it)")
            else:
                errors.append(f"{port}: no such interface on the switch")
    if errors:
        raise Refused("; ".join(errors))

    # Every interface whose VLAN membership is TAPPaaS's: the managed ports, their
    # LAG members, the bonds carrying them and the bonds being taken apart.
    mine = set(leads) | followers | set(target.values()) | set(apart)
    for b in apart:
        mine |= set(split_list(m["bonds"][b].get("slaves")))

    # 1. Aggregates taken apart: off the bridge, gone; their members come back.
    for b in apart:
        if b in m["ports"]:
            ops.append({"op": "remove", "path": "interface bridge port", "id": m["ports"][b][".id"]})
        ops.append({"op": "remove", "path": "interface bonding", "id": m["bonds"][b][".id"]})
    # 2. Aggregates formed: members off the bridge (RouterOS will not enslave a
    #    bridge port), then the bond.
    for nb in new_bonds:
        for s in nb["members"]:
            if s in m["ports"]:
                ops.append({"op": "remove", "path": "interface bridge port", "id": m["ports"][s][".id"]})
        args = {**BOND_DEFAULTS, "slaves": ",".join(nb["members"])}
        if nb["mlag"] is not None:
            args["mlag-id"] = str(nb["mlag"])
        if nb["update"]:
            ops.append({"op": "update", "path": "interface bonding", "args": f".id={m['bonds'][nb['name']]['.id']} slaves={args['slaves']}"})
        else:
            ops.append({"op": "add", "path": "interface bonding", "args": " ".join([f"name={nb['name']}"] + [f"{k}={v}" for k, v in args.items()])})

    # 3. Bridge ports: PVID and frame types, added where the interface is new to it.
    def want_port(d):
        nv = int(d.get("nativeVlan") or 0)
        return (nv if nv > 0 else bpvid), (ACCESS_FRAMES if d.get("mode") == "access" else TRUNK_FRAMES)

    added_ports = {nb["name"] for nb in new_bonds if nb["name"] not in m["ports"]}
    for b in apart:
        for s in split_list(m["bonds"][b].get("slaves")):
            added_ports.add(s)
    for port, d in sorted(leads.items(), key=lambda kv: natkey(kv[0])):
        t = target[port]
        pvid, frames = want_port(d)
        bp = None if t in added_ports else m["ports"].get(t)
        if bp is None:
            ops.append({"op": "add", "path": "interface bridge port", "args": f"bridge={bridge} interface={t} pvid={pvid} frame-types={frames}"})
        elif int(bp.get("pvid", 1) or 1) != pvid or (bp.get("frame-types") or TRUNK_FRAMES) != frames:
            ops.append({"op": "update", "path": "interface bridge port", "args": f".id={bp['.id']} pvid={pvid} frame-types={frames}"})
    # Members of a LAG taken apart that no managed lead names: back on the bridge as they were.
    for b in apart:
        for s in split_list(m["bonds"][b].get("slaves")):
            if s not in target.values():
                old = m["ports"].get(b, {})
                ops.append({"op": "add", "path": "interface bridge port",
                            "args": f"bridge={bridge} interface={s} pvid={old.get('pvid', bpvid)} frame-types={old.get('frame-types', TRUNK_FRAMES)}"})

    # 4. VLAN entries: for each VLAN, the tagged list's managed part is rewritten
    #    and the rest kept; a shared entry whose VLANs now differ is split.
    want = {}  # vlan -> set of interfaces that must tag it
    for port, d in leads.items():
        if d.get("mode") == "trunk":
            for v in d.get("taggedVlans") or []:
                want.setdefault(int(v), set()).add(target[port])
    # Across an MLAG pair the peer link carries every VLAN an MLAG port uses,
    # untagged ones too (a port's PVID: 1 for TAPPaaS's native 0, the site's
    # mgmt): tagged on the peer link, so a frame that enters on one switch can
    # leave through the other. The PVID entries are the peer link's alone.
    peer_pvids = set()
    if m["peer"]:
        for port, d in leads.items():
            nv = int(d.get("nativeVlan") or 0)
            peer_pvids.add(nv if nv > 0 else bpvid)
    seen = set()
    for vl in m["vlans"]:
        ids = vlan_ids(vl.get("vlan-ids"))
        seen |= set(ids)
        keep = [x for x in split_list(vl.get("tagged")) if x not in mine]
        untag = [x for x in split_list(vl.get("untagged")) if x not in mine]
        # Across an MLAG pair every VLAN a managed interface carries is on the
        # peer link too, or the two halves of an aggregate cannot meet.
        peer = [m["peer"]] if m["peer"] else []
        new_by_id = {v: join_list(keep + sorted(want.get(v, set())) + (peer if (want.get(v) or v in peer_pvids) else [])) for v in ids}
        old_tag, old_untag = join_list(split_list(vl.get("tagged"))), join_list(split_list(vl.get("untagged")))
        if len(set(new_by_id.values())) <= 1:
            nt = next(iter(new_by_id.values()), "")
            if nt != old_tag or join_list(untag) != old_untag:
                ops.append({"op": "update", "path": "interface bridge vlan",
                            "args": f".id={vl['.id']} tagged={nt} untagged={join_list(untag)}"})
        else:
            ops.append({"op": "remove", "path": "interface bridge vlan", "id": vl[".id"]})
            for v in ids:
                ops.append({"op": "add", "path": "interface bridge vlan",
                            "args": f"bridge={bridge} vlan-ids={v} tagged={new_by_id[v]}" + (f" untagged={join_list(untag)}" if untag else "")})
    for v in sorted((set(want) | peer_pvids) - seen):
        ops.append({"op": "add", "path": "interface bridge vlan",
                    "args": f"bridge={bridge} vlan-ids={v} tagged={join_list(sorted(want.get(v, set())) + ([m['peer']] if m['peer'] else []))}"})

    # What changes, per managed port, in switch/1 terms.
    cur = interrogate(raw, "_", "", bridge)["switches"]["_"]["ports"]
    for port, d in sorted(leads.items(), key=lambda kv: natkey(kv[0])):
        c = cur.get(port, {})
        frm = {"mode": c.get("mode"), "nativeVlan": c.get("nativeVlan"), "taggedVlans": c.get("taggedVlans", []), "lagMembers": c.get("lagMembers", [])}
        to = {"mode": d.get("mode"), "nativeVlan": int(d.get("nativeVlan") or 0),
              "taggedVlans": sorted(int(v) for v in (d.get("taggedVlans") or [])) if d.get("mode") == "trunk" else [],
              "lagMembers": sorted([str(x) for x in (d.get("lagMembers") or [])], key=natkey)}
        if frm != to:
            changed.append({"port": port, "from": frm, "to": to})
    return ops, changed, lags


def fix_empty(ops):
    """RouterOS takes an empty list as `tagged=""`; the API string form needs it spelled."""
    for o in ops:
        if "args" in o:
            o["args"] = re.sub(r"(\b(?:tagged|untagged))=(?=\s|$)", r'\1=""', o["args"])
    return ops


def bonds_settled(raw, lags, bridge, active=None):
    """Each bond formed is running with its members — and, where its monitor was
    read (`active`: bond -> active ports), every member is active in LACP; the
    reason when not."""
    m = model(raw, bridge)
    active = active or {}
    wrong = []
    for l in lags:
        if l["action"] == "take apart":
            if l["bond"] in m["bonds"]:
                wrong.append(f"{l['bond']} still exists")
            continue
        b = m["bonds"].get(l["bond"])
        if b is None:
            wrong.append(f"{l['bond']} was not created")
        elif sorted(split_list(b.get("slaves")), key=natkey) != l["members"]:
            wrong.append(f"{l['bond']} has {b.get('slaves')}, not {','.join(l['members'])}")
        elif not truthy(b.get("running")):
            wrong.append(f"{l['bond']} is not running — is the LACP partner (the node's bond) up?")
        elif l["bond"] in active and sorted(active[l["bond"]], key=natkey) != l["members"]:
            idle = sorted(set(l["members"]) - set(active[l["bond"]]), key=natkey)
            wrong.append(f"{l['bond']}: {', '.join(idle)} not active in LACP yet")
    return wrong


# ── verbs ────────────────────────────────────────────────────────────

def contract():
    with open(CONTRACT, encoding="utf-8") as fh:
        return json.load(fh)


def out(obj):
    print(json.dumps(obj, sort_keys=True))


def cmd_describe(a):
    c = contract()
    c["implementation"] = os.path.realpath(__file__)
    c["credentials"] = os.path.join(CRED_DIR, "<switch>.txt")
    out(c)
    return 0


def need(a, *names):
    missing = [n for n in names if not getattr(a, n.replace("-", "_"))]
    if missing:
        warn(f"{a.verb} needs " + ", ".join("--" + n for n in missing))
        sys.exit(2)


def cmd_check_access(a):
    need(a, "ip")
    sw = a.switch or a.ip
    cred = credentials(sw, a.credentials)
    raw = read_raw(a.ip, cred, a.debug)
    res = (raw["system resource"] or [{}])[0]
    out({"ok": True, "apiVersion": str(res.get("version", "")), "user": cred["username"],
         "model": res.get("board-name", ""), "identity": (raw["system identity"] or [{}])[0].get("name", "")})
    return 0


def cmd_interrogate(a):
    if a.controller:
        warn("a MikroTik switch is its own controller (arch device): interrogate --switch NAME --ip ADDRESS")
        return 3
    need(a, "switch", "ip")
    raw = read_raw(a.ip, credentials(a.switch, a.credentials), a.debug)
    out(interrogate(raw, a.switch, a.ip, a.bridge))
    return 0


def desired_for(a):
    f = a.desired or os.path.join(CONFIG_DIR, "switch-configuration-desired.json")
    try:
        with open(f, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError) as e:
        raise Refused(f"desired config not readable: {f} ({e})")
    sw = (d.get("switches") or {}).get(a.switch)
    if sw is None:
        raise Refused(f"{a.switch}: not in {f}")
    return sw


def cmd_apply(a):
    need(a, "switch")
    sw = desired_for(a)
    ip = a.ip or sw.get("managementIp")
    if not ip:
        raise Refused(f"{a.switch}: no managementIp in desired, and no --ip")
    cred = credentials(a.switch, a.credentials)
    raw = read_raw(ip, cred, a.debug)
    ops, changed, lags = plan(raw, sw.get("ports") or {}, a.bridge, mlag_ids_for(a.switch, sw))
    ops = fix_empty(ops)
    result = {"switch": a.switch, "changed": changed, "unchanged": len(managed(sw.get("ports") or {})[0]) - len(changed),
              "lags": lags, "operations": ops, "check": bool(a.check)}
    if a.check or not ops:
        out(result)
        return 0
    run_playbook("apply.yml", ip, cred, {"ops": ops}, debug=a.debug)
    if lags:
        deadline = time.time() + a.timeout
        while True:
            active = {}
            for l in lags:
                if l["action"] != "take apart":
                    try:
                        mon = (monitor(ip, cred, "interface bonding", numbers=l["bond"]) or [{}])[0]
                        active[l["bond"]] = split_list(mon.get("active-ports"))
                    except Refused:
                        pass   # not formed yet: the read below says so
            wrong = bonds_settled(read_raw(ip, cred, a.debug), lags, a.bridge, active)
            if not wrong:
                break
            if time.time() >= deadline:
                out({**result, "settled": False, "reason": "; ".join(wrong)})
                warn(f"{a.switch}: the aggregate did not settle within {a.timeout}s: {'; '.join(wrong)}")
                return 1
            time.sleep(5)
    after = interrogate(read_raw(ip, cred, a.debug), a.switch, ip, a.bridge)["switches"][a.switch]["ports"]
    wrong = [c["port"] for c in changed if {k: after.get(c["port"], {}).get(k) for k in ("mode", "nativeVlan", "taggedVlans")}
             != {k: c["to"][k] for k in ("mode", "nativeVlan", "taggedVlans")}]
    if wrong:
        out({**result, "settled": False, "reason": f"ports {', '.join(wrong)} do not read back as desired"})
        warn(f"{a.switch}: ports {', '.join(wrong)} do not read back as desired after the apply")
        return 1
    out({**result, "settled": True})
    return 0


def mlag_ids_for(switch, sw):
    """mlag-id per lead port, where switch-manager names one in desired (an MLAG-pair LAG)."""
    return {k: int(v["mlagId"]) for k, v in (sw.get("ports") or {}).items() if v.get("mlagId") not in (None, "")}


def cmd_mlag_status(a):
    need(a, "switch", "ip")
    cred = credentials(a.switch, a.credentials)
    raw = read_raw(a.ip, cred, a.debug)
    m = model(raw, a.bridge)
    if not m["peer"]:
        out({"switch": a.switch, "configured": False, "peerPort": None, "ids": []})
        return 0
    br = m["bridge"] or {}
    if br.get("mlag-peer-port") not in (None, "", "none"):
        # 7.23 on: the bridge's own monitor carries the MLAG state.
        mon = (monitor(a.ip, cred, "interface bridge", numbers=a.bridge) or [{}])[0]
        state = {"status": mon.get("mlag-state", ""), "active-role": mon.get("mlag-active-role", ""),
                 "system-id": mon.get("mlag-system-id", "")}
    else:
        state = (monitor(a.ip, cred, "interface bridge mlag") or [{}])[0]
    peer = m["eth"].get(m["peer"]) or m["bonds"].get(m["peer"]) or {}
    ids = sorted({int(b["mlag-id"]) for b in m["bonds"].values() if b.get("mlag-id") not in (None, "")})
    out({"switch": a.switch, "configured": True, "peerPort": m["peer"],
         "peerLink": "up" if truthy(peer.get("running")) else "down",
         "state": state.get("status", ""), "role": state.get("active-role", ""), "systemId": state.get("system-id", ""),
         "ids": ids, "monitor": state})
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="mikrotik-controller", description=__doc__.split("\n")[0])
    p.add_argument("verb", nargs="?", choices=["describe", "supports", "check-access", "interrogate", "apply", "mlag-status"])
    p.add_argument("arg", nargs="?")
    p.add_argument("--ip"); p.add_argument("--switch"); p.add_argument("--controller")
    p.add_argument("--desired"); p.add_argument("--changes-json")
    p.add_argument("--check", action="store_true")
    p.add_argument("--credentials"); p.add_argument("--session")
    p.add_argument("--config-dir"); p.add_argument("--bridge", default=os.environ.get("MIKROTIK_BRIDGE", "bridge"))
    p.add_argument("--timeout", type=int, default=int(os.environ.get("MIKROTIK_LAG_WAIT", "90")))
    p.add_argument("--debug", action="store_true")
    p.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    a = p.parse_args(argv)
    if a.config_dir:
        global CONFIG_DIR
        CONFIG_DIR = a.config_dir
    if a.verb is None:
        p.print_help()
        return 0
    try:
        if a.verb == "supports":
            return 0 if a.arg == "mikrotik" else 3
        return {"describe": cmd_describe, "check-access": cmd_check_access, "interrogate": cmd_interrogate,
                "apply": cmd_apply, "mlag-status": cmd_mlag_status}[a.verb](a)
    except Refused as e:
        warn(str(e))
        if a.verb in ("interrogate",):
            out({})
        return 1


if __name__ == "__main__":
    sys.exit(main())
