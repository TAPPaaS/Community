#!/usr/bin/env python3
"""Offline tests for mikrotik_controller.py: RouterOS answers -> switch/1, and the
apply plan (VLANs, PVIDs, parking, aggregates, shared VLAN entries, refusals)."""

import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import mikrotik_controller as mc  # noqa: E402

with open(os.path.join(HERE, "fixtures", "crs326.json"), encoding="utf-8") as fh:
    RAW = json.load(fh)


def raw():
    return copy.deepcopy(RAW)


def ops_of(ops, op, path):
    return [o for o in ops if o["op"] == op and o["path"] == path]


class Interrogate(unittest.TestCase):
    def setUp(self):
        self.sw = mc.interrogate(raw(), "crs-a", "10.0.0.5")["switches"]["crs-a"]
        self.p = self.sw["ports"]

    def test_switch(self):
        self.assertEqual((self.sw["vendor"], self.sw["model"], self.sw["firmware"], self.sw["managementIp"]),
                         ("mikrotik", "CRS326-24S+2Q+", "7.16.1 (stable)", "10.0.0.5"))

    def test_trunk(self):
        self.assertEqual(self.p["sfp-sfpplus1"]["mode"], "trunk")
        self.assertEqual(self.p["sfp-sfpplus1"]["taggedVlans"], [200, 310, 410])
        self.assertEqual(self.p["sfp-sfpplus1"]["nativeVlan"], 0, "PVID 1 is the bridge's own: native 0")
        self.assertEqual(self.p["sfp-sfpplus1"]["link"], "up")

    def test_access(self):
        self.assertEqual((self.p["sfp-sfpplus2"]["mode"], self.p["sfp-sfpplus2"]["nativeVlan"], self.p["sfp-sfpplus2"]["link"]),
                         ("access", 430, "down"))

    def test_lag(self):
        self.assertEqual(self.p["sfp-sfpplus5"]["lagMembers"], ["sfp-sfpplus5", "sfp-sfpplus6"], "the lowest member leads")
        self.assertEqual(self.p["sfp-sfpplus6"]["lagMembers"], [])
        self.assertEqual(self.p["sfp-sfpplus6"]["taggedVlans"], [200, 310], "a member reads the bond's VLANs")
        self.assertEqual(self.p["sfp-sfpplus5"]["bond"], "bond1")

    def test_not_bridged(self):
        self.assertTrue(self.p["ether1"]["disabled"], "a routed port is reported disabled, so it is never parked")
        self.assertFalse(self.p["ether1"]["bridged"])

    def test_disabled(self):
        self.assertTrue(self.p["sfp-sfpplus10"]["disabled"])

    def test_natural_order(self):
        self.assertEqual(list(self.p)[-1], "sfp-sfpplus10")

    def test_dynamic_ignored(self):
        self.assertNotIn(1, self.p["sfp-sfpplus3"]["taggedVlans"])

    def test_no_bridge(self):
        with self.assertRaises(mc.Refused):
            mc.interrogate(raw(), "crs-a", "10.0.0.5", bridge="nope")


class Plan(unittest.TestCase):
    def test_trunk_adds_vlan(self):
        ops, changed, _ = mc.plan(raw(), {"sfp-sfpplus1": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310, 410, 610]}})
        self.assertEqual(ops, [{"op": "add", "path": "interface bridge vlan", "args": "bridge=bridge vlan-ids=610 tagged=sfp-sfpplus1"}])
        self.assertEqual(changed[0]["to"]["taggedVlans"], [200, 310, 410, 610])

    def test_in_sync(self):
        ops, changed, _ = mc.plan(raw(), {"sfp-sfpplus1": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310, 410]}})
        self.assertEqual((ops, changed), ([], []))

    def test_unmanaged_untouched(self):
        ops, _, _ = mc.plan(raw(), {"sfp-sfpplus1": {"mode": "trunk", "taggedVlans": []}, "sfp-sfpplus2": {"source": "discovered", "mode": "access"}})
        self.assertEqual(ops, [], "ports with no type and not parked are not TAPPaaS's")

    def test_shared_entry_split(self):
        ops, _, _ = mc.plan(raw(), {"sfp-sfpplus3": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200]}})
        self.assertIn({"op": "remove", "path": "interface bridge vlan", "id": "*50"}, ops)
        adds = [o["args"] for o in ops_of(ops, "add", "interface bridge vlan")]
        self.assertIn("bridge=bridge vlan-ids=200 tagged=bond1,bridge,sfp-sfpplus1,sfp-sfpplus3", adds)
        self.assertIn("bridge=bridge vlan-ids=310 tagged=bond1,bridge,sfp-sfpplus1", adds)
        self.assertIn({"op": "update", "path": "interface bridge vlan", "args": ".id=*51 tagged=sfp-sfpplus1 untagged="}, ops,
                      "410 is no longer tagged on the managed port; the other port keeps it")

    def test_park(self):
        ops, changed, _ = mc.plan(raw(), {"sfp-sfpplus4": {"parked": True, "zone": "iotLocal", "mode": "access", "nativeVlan": 430}})
        self.assertEqual(ops, [{"op": "update", "path": "interface bridge port",
                                "args": ".id=*43 pvid=430 frame-types=admit-only-untagged-and-priority-tagged"}])
        self.assertEqual(changed[0]["to"]["nativeVlan"], 430)

    def test_access_to_trunk_frames(self):
        ops, _, _ = mc.plan(raw(), {"sfp-sfpplus2": {"type": "device", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [410]}})
        self.assertIn({"op": "update", "path": "interface bridge port", "args": ".id=*41 pvid=1 frame-types=admit-all"}, ops)
        self.assertIn({"op": "update", "path": "interface bridge vlan", "args": ".id=*51 tagged=sfp-sfpplus1,sfp-sfpplus2,sfp-sfpplus3 untagged="}, ops)
        self.assertIn({"op": "update", "path": "interface bridge vlan", "args": ".id=*52 tagged= untagged="}, ops,
                      "a static untagged membership of the managed port goes; the PVID gives it")

    def test_lag_form(self):
        ops, _, lags = mc.plan(raw(), {
            "sfp-sfpplus3": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [410], "lag": "n1", "lagMembers": ["sfp-sfpplus3", "sfp-sfpplus4"]},
            "sfp-sfpplus4": {"type": "node", "lag": "n1", "lagLead": "sfp-sfpplus3"}})
        names = [(o["op"], o["path"]) for o in ops]
        self.assertEqual(names[:4], [("remove", "interface bridge port"), ("remove", "interface bridge port"),
                                     ("add", "interface bonding"), ("add", "interface bridge port")])
        self.assertEqual(ops[2]["args"], "name=bond-sfp-sfpplus3 mode=802.3ad lacp-rate=1sec transmit-hash-policy=layer-2-and-3 slaves=sfp-sfpplus3,sfp-sfpplus4")
        self.assertEqual(ops[3]["args"], "bridge=bridge interface=bond-sfp-sfpplus3 pvid=1 frame-types=admit-all")
        self.assertIn({"op": "update", "path": "interface bridge vlan", "args": ".id=*51 tagged=bond-sfp-sfpplus3,sfp-sfpplus1 untagged="}, ops)
        self.assertEqual(lags[0]["action"], "form")

    def test_lag_mlag_id(self):
        ops, _, _ = mc.plan(raw(), {"sfp-sfpplus3": {"type": "node", "mode": "trunk", "taggedVlans": [], "lagMembers": ["sfp-sfpplus3", "sfp-sfpplus4"]}},
                            mlag_ids={"sfp-sfpplus3": 10})
        self.assertTrue(ops_of(ops, "add", "interface bonding")[0]["args"].endswith("mlag-id=10 up-delay=20s"))

    def test_mlag_one_member(self):
        ops, _, lags = mc.plan(raw(), {"sfp-sfpplus3": {"type": "node", "mode": "trunk", "taggedVlans": [], "lagMembers": ["sfp-sfpplus3"], "mlagId": 10}},
                               mlag_ids={"sfp-sfpplus3": 10})
        self.assertEqual(ops_of(ops, "add", "interface bonding")[0]["args"],
                         "name=bond-sfp-sfpplus3 mode=802.3ad lacp-rate=1sec transmit-hash-policy=layer-2-and-3 slaves=sfp-sfpplus3 mlag-id=10 up-delay=20s",
                         "one member here, the other on the peer")
        self.assertEqual(lags[0]["action"], "form")

    def test_mlag_id_reported(self):
        r = raw(); r["interface bonding"][0]["mlag-id"] = 12
        p = mc.interrogate(r, "crs-a", "10.0.0.5")["switches"]["crs-a"]["ports"]
        self.assertEqual(p["sfp-sfpplus5"]["liveMlagId"], 12)

    def test_mlag_id_changed(self):
        r = raw(); r["interface bonding"][0]["mlag-id"] = 12
        ops, _, _ = mc.plan(r, {"sfp-sfpplus5": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310],
                                                 "lagMembers": ["sfp-sfpplus5", "sfp-sfpplus6"]}}, mlag_ids={"sfp-sfpplus5": 14})
        self.assertEqual(ops, [{"op": "update", "path": "interface bonding", "args": ".id=*20 mlag-id=14 up-delay=20s"}])

    def test_mlag_bond_gets_up_delay(self):
        r = raw(); r["interface bonding"][0].update({"mlag-id": 12, "up-delay": "0ms"})
        ops, _, _ = mc.plan(r, {"sfp-sfpplus5": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310],
                                                 "lagMembers": ["sfp-sfpplus5", "sfp-sfpplus6"]}}, mlag_ids={"sfp-sfpplus5": 12})
        self.assertEqual(ops, [{"op": "update", "path": "interface bonding", "args": ".id=*20 up-delay=20s"}])
        r["interface bonding"][0]["up-delay"] = "20s"
        ops, _, _ = mc.plan(r, {"sfp-sfpplus5": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310],
                                                 "lagMembers": ["sfp-sfpplus5", "sfp-sfpplus6"]}}, mlag_ids={"sfp-sfpplus5": 12})
        self.assertEqual(ops, [], "set once, then in sync")

    def test_lag_existing_in_sync(self):
        ops, _, lags = mc.plan(raw(), {"sfp-sfpplus5": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310],
                                                        "lagMembers": ["sfp-sfpplus5", "sfp-sfpplus6"]}})
        self.assertEqual((ops, lags), ([], []))

    def test_lag_take_apart(self):
        ops, _, lags = mc.plan(raw(), {"sfp-sfpplus5": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200], "lagMembers": []}})
        self.assertEqual(ops[0], {"op": "remove", "path": "interface bridge port", "id": "*44"})
        self.assertEqual(ops[1], {"op": "remove", "path": "interface bonding", "id": "*20"})
        adds = [o["args"] for o in ops_of(ops, "add", "interface bridge port")]
        self.assertIn("bridge=bridge interface=sfp-sfpplus5 pvid=1 frame-types=admit-all", adds)
        self.assertIn("bridge=bridge interface=sfp-sfpplus6 pvid=1 frame-types=admit-all", adds, "the other member comes back as it was")
        self.assertEqual(lags[0]["action"], "take apart")

    def test_routed_port_refused(self):
        with self.assertRaises(mc.Refused) as e:
            mc.plan(raw(), {"ether1": {"type": "node", "mode": "trunk", "taggedVlans": [200]}})
        self.assertIn("not a port of bridge", str(e.exception))

    def test_unknown_member_refused(self):
        with self.assertRaises(mc.Refused):
            mc.plan(raw(), {"sfp-sfpplus3": {"type": "node", "mode": "trunk", "lagMembers": ["sfp-sfpplus3", "sfp-sfpplus99"]}})

    def test_fix_empty(self):
        self.assertEqual(mc.fix_empty([{"args": ".id=*1 tagged= untagged="}])[0]["args"], '.id=*1 tagged="" untagged=""')


def mlag_raw():
    """crs-a with an MLAG peer link: a bond of sfp-sfpplus15/16, tagged in 200,310."""
    r = raw()
    r["interface ethernet"] += [{".id": "*9", "name": "sfp-sfpplus15", "running": True},
                                {".id": "*10", "name": "sfp-sfpplus16", "running": True}]
    r["interface bonding"].append({".id": "*21", "name": "peer-link", "slaves": "sfp-sfpplus15,sfp-sfpplus16", "mode": "802.3ad", "running": True})
    r["interface bridge port"].append({".id": "*46", "bridge": "bridge", "interface": "peer-link", "pvid": 99, "frame-types": "admit-all"})
    r["interface bridge vlan"][0]["tagged"] += ",peer-link"
    r["interface bridge mlag"] = [{"bridge": "bridge", "peer-port": "peer-link"}]
    return r


def mlag_raw_723():
    """The same, as RouterOS 7.23 keeps it: no MLAG menu, the peer port on the bridge."""
    r = mlag_raw()
    r["interface bridge mlag"] = []
    r["interface bridge"][0].update({"mlag-peer-port": "peer-link", "mlag-priority": 0, "mlag-heartbeat": "none"})
    return r


class Mlag723(unittest.TestCase):
    def test_peer_link_from_bridge(self):
        p = mc.interrogate(mlag_raw_723(), "crs-a", "10.0.0.21")["switches"]["crs-a"]
        self.assertEqual(p["mlag"]["peerPort"], "peer-link")
        self.assertTrue(p["ports"]["sfp-sfpplus16"]["peerLink"])

    def test_peer_link_never_programmed(self):
        with self.assertRaises(mc.Refused):
            mc.plan(mlag_raw_723(), {"sfp-sfpplus15": {"type": "switch", "mode": "trunk", "taggedVlans": [200]}})

    def test_vlans_on_peer_link(self):
        ops, _, _ = mc.plan(mlag_raw_723(), {"sfp-sfpplus1": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310, 410, 610]}})
        self.assertIn({"op": "add", "path": "interface bridge vlan", "args": "bridge=bridge vlan-ids=610 tagged=peer-link,sfp-sfpplus1"}, ops)

    def test_mlag_settings_reported(self):
        r = mlag_raw_723(); r["interface bridge"][0]["priority"] = "0x4000"
        mlag = mc.interrogate(r, "crs-a", "10.0.0.21")["switches"]["crs-a"]["mlag"]
        self.assertEqual((mlag["heartbeat"], mlag["priority"], mlag["stpPriority"]), ("none", 0, "0x4000"))

    def test_none_is_no_mlag(self):
        r = raw(); r["interface bridge"][0]["mlag-peer-port"] = "none"
        self.assertIsNone(mc.model(r, "bridge")["peer"])


class Mlag(unittest.TestCase):
    def test_peer_link_reported_off_limits(self):
        p = mc.interrogate(mlag_raw(), "crs-a", "10.0.0.21")["switches"]["crs-a"]
        self.assertTrue(p["ports"]["sfp-sfpplus15"]["peerLink"] and p["ports"]["sfp-sfpplus15"]["disabled"])
        self.assertEqual(p["mlag"]["peerPort"], "peer-link")

    def test_peer_link_never_programmed(self):
        with self.assertRaises(mc.Refused) as e:
            mc.plan(mlag_raw(), {"sfp-sfpplus15": {"type": "switch", "mode": "trunk", "taggedVlans": [200]}})
        self.assertIn("MLAG peer link", str(e.exception))

    def test_new_vlan_on_peer_link(self):
        ops, _, _ = mc.plan(mlag_raw(), {"sfp-sfpplus1": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310, 410, 610]}})
        self.assertIn({"op": "add", "path": "interface bridge vlan", "args": "bridge=bridge vlan-ids=610 tagged=peer-link,sfp-sfpplus1"}, ops)
        self.assertIn({"op": "update", "path": "interface bridge vlan", "args": ".id=*51 tagged=peer-link,sfp-sfpplus1,sfp-sfpplus3 untagged="}, ops,
                      "an existing VLAN the managed port carries gets the peer link")

    def test_native_vlan_on_peer_link(self):
        ops, _, _ = mc.plan(mlag_raw(), {"sfp-sfpplus1": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310, 410]}})
        self.assertIn({"op": "add", "path": "interface bridge vlan", "args": "bridge=bridge vlan-ids=1 tagged=peer-link"}, ops,
                      "the untagged mgmt VLAN (PVID 1) of an MLAG-side port is tagged on the peer link")

    def test_parked_vlan_on_peer_link(self):
        ops, _, _ = mc.plan(mlag_raw(), {"sfp-sfpplus4": {"parked": True, "mode": "access", "nativeVlan": 430}})
        self.assertIn({"op": "update", "path": "interface bridge vlan", "args": ".id=*52 tagged=peer-link untagged=sfp-sfpplus2"}, ops)

    def test_no_peer_no_pvid_entries(self):
        ops, _, _ = mc.plan(raw(), {"sfp-sfpplus1": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": [200, 310, 410]}})
        self.assertEqual(ops, [], "without MLAG nothing is added for the PVID")

    def test_peer_link_kept(self):
        ops, _, _ = mc.plan(mlag_raw(), {"sfp-sfpplus1": {"type": "node", "mode": "trunk", "nativeVlan": 0, "taggedVlans": []}})
        upd = [o["args"] for o in ops if o["path"] == "interface bridge vlan"]
        self.assertTrue(all("peer-link" in a for a in upd if "*50" in a), f"the peer link stays tagged where it was ({upd})")


class Values(unittest.TestCase):
    def test_vlan_ranges(self):
        self.assertEqual(mc.vlan_ids("200,310-312"), [200, 310, 311, 312])

    def test_raw_strings(self):
        self.assertTrue(mc.truthy("true"))
        self.assertFalse(mc.truthy("false"))

    def test_settled_lacp_members(self):
        lags = [{"bond": "bond1", "members": ["sfp-sfpplus5", "sfp-sfpplus6"], "action": "form"}]
        self.assertEqual(mc.bonds_settled(raw(), lags, "bridge", {"bond1": ["sfp-sfpplus5", "sfp-sfpplus6"]}), [])
        self.assertIn("sfp-sfpplus6 not active in LACP yet", mc.bonds_settled(raw(), lags, "bridge", {"bond1": ["sfp-sfpplus5"]})[0])

    def test_settled(self):
        r = raw()
        lags = [{"bond": "bond1", "members": ["sfp-sfpplus5", "sfp-sfpplus6"], "action": "form"}]
        self.assertEqual(mc.bonds_settled(r, lags, "bridge"), [])
        r["interface bonding"][0]["running"] = False
        self.assertIn("not running", mc.bonds_settled(r, lags, "bridge")[0])


class Verbs(unittest.TestCase):
    def test_supports(self):
        self.assertEqual(mc.main(["supports", "mikrotik"]), 0)
        self.assertEqual(mc.main(["supports", "unifi"]), 3)

    def test_interrogate_controller_is_not_mine(self):
        self.assertEqual(mc.main(["interrogate", "--controller", "x", "--ip", "1.2.3.4"]), 3)

    def test_missing_credentials(self):
        os.environ["MIKROTIK_CREDENTIALS_DIR"] = "/nonexistent"
        mc.CRED_DIR = "/nonexistent"
        self.assertEqual(mc.main(["interrogate", "--switch", "crs-a", "--ip", "1.2.3.4"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
