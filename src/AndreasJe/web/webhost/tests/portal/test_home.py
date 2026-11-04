#!/usr/bin/env python3
"""The sites dashboard (portal_home). Runnable alone: python3 tests/portal/test_home.py"""
import importlib.util, json, os, re, sys, tempfile, time, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = tempfile.mkdtemp()
NOW = 1793700240  # Tue 3 Nov 2026, 10:04 UTC
os.environ.update(WEBHOST_PORTAL_DATA=f"{WORK}/portal", WEBHOST_INSPECT=f"{WORK}/inspect")
os.makedirs(f"{WORK}/portal/requests"); os.makedirs(f"{WORK}/inspect")
time.time = lambda: float(NOW)
sys.path.insert(0, os.path.join(HERE, "..", "..", "guest"))
spec = importlib.util.spec_from_file_location("portal", os.path.join(HERE, "..", "..", "guest", "webhost-portal.py"))
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)
import portal_core as C

C.ANALYTICS_MAP = f"{WORK}/analytics-sites.json"
C.COUNTRIES.update({"DK": "Denmark", "DE": "Germany"})
fails = []


def check(name, ok):
    print(f"{name} {'ok' if ok else 'FAIL'}")
    if not ok:
        fails.append(name)


def wj(path, obj):
    json.dump(obj, open(path, "w"))


def site(name, owner="ann", analytics=False, **kw):
    return dict({"name": name, "owner": owner, "template": "static", "runtime": "static", "domain": f"{name}.x.dk", "public": True,
                 "source": {"repo": "https://x.example/a.git"}, "analytics": analytics, "state": "live"}, **kw)


def fake(path, ttl=3600):
    if path.endswith("/active"):
        return (NOW, {"visitors": 3})
    if "/event-data/values" in path:
        return (NOW, [])
    if "/stats" in path:
        return (NOW, {"pageviews": 400, "visitors": 120, "visits": 150, "bounces": 60, "totaltime": 9000, "comparison": {"pageviews": 300, "visitors": 100, "visits": 140, "bounces": 70, "totaltime": 8000}})
    if "/pageviews" in path:
        return (NOW, {"pageviews": [{"x": "2026-11-03T09:00:00Z", "y": 7}], "sessions": [{"x": "2026-11-03T09:00:00Z", "y": 4}]})
    if "type=country" in path:
        return (NOW, [{"x": "DK", "y": 90}, {"x": "DE", "y": 30}])
    return (NOW, [{"x": "", "y": 50}])


def render(sites, counting=(), admin=False, user="ann", backups=None, cached=fake, verdicts=None):
    for s in sites:
        s["analytics"] = s["name"] in counting
    wj(f"{WORK}/portal/sites.json", sites)
    wj(C.ANALYTICS_MAP, {n: f"{i:08d}-aaaa" for i, n in enumerate(counting, 1)})
    fresh = {"sites": {s["name"]: [{"volid": "tappaas_backup:backup/ct/1/2026-11-03T01:30:00Z", "time": NOW}] for s in sites}, "deleted": []}
    wj(f"{WORK}/portal/backups.json", backups or fresh)
    for s in sites:
        wj(f"{WORK}/inspect/{s['name']}.json", (verdicts or {}).get(s["name"]) or {"verdict": "pass", "checked": "2026-11-03T08:40:00Z", "findings": []})
    C.Umami.cached = staticmethod(cached)
    got = {}
    h = P.Portal.__new__(P.Portal)
    h.server = type("S", (), {"conf": {"templates": [{"name": "static", "label": "Static files"}]}})
    h.send = lambda code, body, *a, **k: got.update(code=code, body=body)
    who = {"user": user, "groups": ["installer" if admin else "webhost"], "admin": admin, "csrf": "c"}
    h.home(who)
    return got["body"]


def text(markup):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", re.sub(r"<style>.*?</style>", "", markup, flags=re.S)))


mine = [site("alpha"), site("beta"), site("gamma")]
theirs = site("secret-bo", owner="bo")

# owners see only their sites; installers see all, with the Owner column
page = render(mine + [theirs])
check("owner-never-sees-another-owner", "secret-bo" not in page and "alpha" in page)
check("owner-has-no-owner-column", "class='c-own'" not in page and "Owner" not in text(page))
page = render(mine + [theirs], admin=True, user="root")
check("installer-sees-every-site", "secret-bo" in page and "alpha" in page)
check("installer-has-owner-column", 'class="tbl inst"' in page and "<span role='columnheader' class='c-own'>Owner</span>" in page and 'role="cell">bo</div>' in page)
check("installer-pill-in-shell", ">installer<" in page)

# the three analytics states
page = render([site(n) for n in ("alpha", "beta", "gamma")], counting=("alpha", "beta", "gamma"))
t = text(page)
check("all-state-shows-dashboard", "Right now" in t and "Most popular site this week" in t and "This week, all sites" in t and "Compare your sites" not in t)
check("all-state-has-no-scope-note", "The numbers below cover" not in t and "No site counts" not in t)
page = render([site(n) for n in ("alpha", "beta", "gamma")], counting=("alpha",))
t = text(page)
check("some-state-scope-note", "The numbers below cover alpha only" in t and "1 of 3 sites counts its visitors" in t)
check("some-state-headings-name-the-site", "This week, alpha" in t)
check("some-state-compare-card", "Compare your sites" in t and "Most popular site this week" not in t and 'href="/sites/beta/analytics"' in page and 'href="/sites/gamma/analytics"' in page)
check("some-state-list-marks-uncounted", "Not counted · Turn on" in t and "<b>Off</b>" in page)
page = render([site(n) for n in ("alpha", "beta", "gamma")], counting=("alpha", "beta"))
check("two-counting-sites-compare", "Most popular site this week" in text(page) and "Compare your sites" not in text(page))
page = render([site(n) for n in ("alpha", "beta")], counting=())
t = text(page)
check("none-state-single-card", "No site counts its visitors yet" in t and "Right now" not in t and "Where visitors come from" not in t)
check("none-state-turn-on-links", 'href="/sites/alpha/analytics"' in page and 'href="/sites/beta/analytics"' in page and t.count("Not counted · Turn on") == 2)

# umami failing never raises
def broken(path, ttl=3600):
    raise urllib.error.URLError("refused")
page = render([site("alpha")], counting=("alpha",), cached=broken)
check("umami-down-shows-not-available", "not available right now" in text(page) and "Everything else on this page is unaffected" in text(page))
check("umami-down-list-still-renders", "alpha.x.dk" in page and "Not available right now" in page)

# needs a person
blocked = site("docs")
verdicts = {"docs": {"verdict": "block", "checked": "2026-11-03T08:41:00Z", "findings": [{"level": "block", "rule": "secret", "file": "a"}]}}
old = {"sites": {"alpha": [{"volid": "tappaas_backup:backup/ct/1/2026-10-30T01:30:00Z", "time": 0}], "docs": [{"volid": "tappaas_backup:backup/ct/2/2026-11-03T01:30:00Z", "time": 0}]}, "deleted": []}
page = render([site("alpha"), blocked], backups=old, verdicts=verdicts)
t = text(page)
check("needs-blocked-inspection", "Needs a person" in t and "docs The newest release stopped at inspection: a leaked key" in t)
check("needs-no-backup-in-48h", "alpha The last nightly backups did not run" in t and "The newest restore point is from Fri 30 Oct 01:30 UTC" in t)
check("needs-heading-counts", "2 things need a person" in t)
check("needs-rows-first-by-css-order", page.count('<div class="rw attn"') == 2)
wj(f"{WORK}/portal/requests/20261103T080000Z-aaaaaa.json", {"id": "20261103T080000Z-aaaaaa", "kind": "restore", "user": "ann", "site": "alpha", "status": "failed", "created": "2026-11-03T08:00:00Z", "message": "VMID 630 failed, see /var/log/x"})
page = render([site("alpha")])
check("needs-failed-request", "Restoring from a backup failed" in text(page) and "/requests/20261103T080000Z-aaaaaa" in page and "VMID" not in page and "/var/log" not in page)
os.remove(f"{WORK}/portal/requests/20261103T080000Z-aaaaaa.json")
page = render([site("alpha")])
check("calm-when-nothing-needs-a-person", "Nothing needs a person right now." in text(page) and "Needs a person" not in text(page))

# time and layout
page = render(mine, counting=("alpha",), admin=True, user="root")
check("no-raw-iso-timestamps", not re.search(r"\d{4}-\d\d-\d\dT\d\d:\d\d", re.sub(r'(datetime|title|content)="[^"]*"', "", re.sub(r"<style>.*?</style>", "", page, flags=re.S))))
check("times-have-exact-title", 'title="Tue 3 Nov 2026, 08:40 UTC"' in page)
c = {}
real = C.page
import portal_home
portal_home.page = lambda *a, **k: (c.update(k), real(*a, **k))[1]
render(mine)
check("refresh-60", c.get("refresh") == 60)
page = render(mine, counting=("alpha",))
check("both-hour-grids", 'class="heat h24"' in page and 'class="heat h3"' in page and 'class="heatwrap"' in page.replace(' aria-hidden="true"', ""))
check("one-markup-two-layouts", page.count('role="row"') == 3 and 'class="frame"' in page and 'class="phone-label"' in page)

# deleted sites keep their restore links; no sites is the first-visit page
gone = {"sites": {}, "deleted": [{"name": "old-landing", "owner": "ann", "template": "static", "domain": "l.x.dk", "deleted": "2026-10-28T10:12:00Z",
                                  "backups": [{"volid": "tappaas_backup:backup/ct/9/2026-10-28T01:30:00Z", "time": 0}]}]}
page = render(mine, backups=gone)
check("deleted-sites-restore-link", "/deleted/old-landing/restore" in page and "Restore old-landing" in page and "Deleted Wed 28 Oct" in text(page))
page = render([], backups=gone)
t = text(page)
check("empty-state", "No sites yet." in t and "Create your first site" in t and "A site made of files" in t and "Needs a person" not in t)

print("")
sys.exit(1 if fails else 0)
