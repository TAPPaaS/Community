#!/usr/bin/env python3
"""portal_analytics: site analytics periods, not-available state, setup states. Runnable alone: python3 tests/portal/test_analytics.py"""
import json, os, re, sys, tempfile, time, types

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "guest"))
NOW = 1793700240  # Tue 3 Nov 2026, 10:04 UTC
time.time = lambda: float(NOW)
import portal_core as C
import portal_analytics as A

WORK = tempfile.mkdtemp()
C.ANALYTICS_MAP = f"{WORK}/map.json"
WID, OTHER = "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"
json.dump({"portfolio": WID, "docs": OTHER, "api": "00000000-0000-4000-8000-000000000003"}, open(C.ANALYTICS_MAP, "w"))
ISO_TEXT = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d")
SITES = {
    "portfolio": {"name": "portfolio", "template": "static", "runtime": "static", "domain": "portfolio.example.org", "public": True, "analytics": True},
    "docs": {"name": "docs", "template": "static", "runtime": "static", "domain": "docs.example.org", "public": False, "analytics": True},
    "shop": {"name": "shop", "template": "lamp", "runtime": "php", "domain": "shop.example.org", "public": True, "analytics": False},
    "api": {"name": "api", "template": "node-app", "runtime": "node", "domain": "api.example.org", "public": False, "analytics": True},
    "api-off": {"name": "api-off", "template": "node-app", "runtime": "node", "domain": "api-off.example.org", "public": False, "analytics": False},
}
fails = []


def check(name, ok):
    print(f"{name} {'ok' if ok else 'FAIL'}")
    if not ok:
        fails.append(name)


def text(markup):
    return re.sub(r"<[^>]+>", "", re.sub(r"<style>.*?</style>", "", markup, flags=re.S))


def handler():
    out = {}
    h = types.SimpleNamespace(out=out)
    h.site = lambda who, name: SITES.get(name)
    h.send = lambda code, body, *a, **k: out.update(code=code, body=body)
    h.redirect = lambda to: out.update(redirect=to)
    h.fail = lambda code, msg: out.update(code=code, body=msg)
    return h


WHO = {"user": "ann", "groups": ["webhost"], "csrf": "tok"}


def render(name, period=None, data=None):
    """Page for a site with Umami answering `data` (callable path -> answer), or failing when data is None."""
    h = handler()
    real = C.Umami.cached
    def fake(path, ttl=3600):
        if data is None:
            raise OSError("down")
        return (NOW, data(path))
    C.Umami.cached = staticmethod(fake)
    try:
        A.site_analytics(h, WHO, name, {"period": [period]} if period else {})
    finally:
        C.Umami.cached = real
    return h.out


def visits(path):
    if "/active" in path:
        return {"visitors": 3}
    if "/stats" in path:
        return {"pageviews": 40, "visitors": 12, "visits": 15, "bounces": 6, "totaltime": 1500, "comparison": {"pageviews": 30, "visitors": 10, "visits": 14, "bounces": 4, "totaltime": 1000}}
    if "/pageviews" in path:
        return {"pageviews": [{"x": "2026-11-03T09:00:00Z", "y": 5}, {"x": "2026-11-02 00:00:00", "y": 7}], "sessions": [{"x": "2026-11-03T09:00:00Z", "y": 2}]}
    if "/event-data/values" in path:
        return [{"value": "cv.pdf", "total": 4}]
    return [{"x": "/", "y": 9}]


def no_visits(path):
    if "/stats" in path:
        return {"pageviews": 0, "visitors": 0, "visits": 0, "bounces": 0, "totaltime": 0, "comparison": {}}
    return visits(path)


def empty_tags(path):
    return [] if ("type=event" in path or "/event-data/values" in path) else visits(path)


# periods
for key, words in (("24h", "24 hours"), ("7d", "7 days"), ("30d", "30 days"), ("90d", "90 days")):
    out = render("portfolio", key, visits)
    body = out["body"]
    tabs = re.search(r'<nav aria-label="Time period"[^>]*>(.*?)</nav>', body, re.S).group(1)
    current = re.findall(r'<a href="\?period=(\w+)" aria-current="page">', tabs)
    check(f"period-{key}-renders", out["code"] == 200 and f"in the last {words}" in text(body) and f"than the previous {words}." in text(body))
    check(f"period-{key}-aria-current-once", current == [key] and tabs.count("aria-current") == 1)
    check(f"period-{key}-no-raw-iso", not ISO_TEXT.search(text(body)))
check("period-default-and-bad-value", 'href="?period=7d" aria-current="page"' in render("portfolio", None, visits)["body"]
      and 'href="?period=7d" aria-current="page"' in render("portfolio", "nonsense", visits)["body"])
check("never-says-quarter", all("quarter" not in render("portfolio", k, visits)["body"].lower() for k in ("24h", "7d", "30d", "90d")))

# blocks
body = render("portfolio", "7d", visits)["body"]
t = text(body)
check("right-now-card", "Right now" in t and "3visitorsinthelast5minutes" in t.replace(" ", "") and 'content="60"' in body)
check("tiles-and-bounce-good", all(w in t for w in ("Visitors", "Visits", "Pageviews", "Bounce rate", "Average visit")) and "A lower bounce rate is better." in t)
bounce = re.search(r"Bounce rate<b>(\d+)%</b><small class=\"(\w+)\">([^<]*)", body)
check("bounce-higher-is-bad", bounce and bounce.group(1) == "40" and bounce.group(2) == "down" and "higher" in bounce.group(3))
check("chart-table-details", "Show the numbers as a table" in body and 'role="img"' in body and "Tallest bar" in t)
check("lists-present", all(h in t for h in ("Top pages", "Sources", "Countries", "Devices", "Browsers", "Downloads", "Events")))
check("downloads-from-event-values", "cv.pdf" in t and "No downloads counted yet" not in t)
check("privacy-once-at-bottom", t.count("Umami sets no cookies") == 1 and body.rindex("Umami sets no cookies") > body.rindex("Browsers"))
check("one-source-line-for-numbers", t.count("Numbers from Umami") == 1)
many = lambda path: [{"x": f"/p{i}", "y": 50 - i} for i in range(9)] if "type=path" in path else visits(path)
check("show-all-folds-the-rest", "Show all 9" in render("portfolio", "7d", many)["body"])

# empty tags show the tagging line
t0 = render("portfolio", "7d", empty_tags)["body"]
check("downloads-empty-tagging-line", "No downloads counted yet" in text(t0) and 'data-umami-event="download"' in t0.replace("&quot;", '"') and 'data-umami-event-file="cv.pdf"' in t0.replace("&quot;", '"'))
check("events-empty-tagging-line", "No events counted yet" in text(t0) and "data-umami-event-product" in t0)

# Umami failure
down = render("portfolio", "7d", None)
check("umami-down-not-available", down["code"] == 503 and "not available right now" in text(down["body"]) and "Traceback" not in down["body"])
part = lambda path: (_ for _ in ()).throw(OSError("x")) if "type=country" in path or "/active" in path else visits(path)
pb = render("portfolio", "7d", part)
check("one-block-down-rest-renders", pb["code"] == 200 and "Not available right now." in pb["body"] and "Top pages" in pb["body"])
nologin = render("portfolio", "7d", lambda path: None)
check("no-umami-login-not-available", nologin["code"] == 503)

# setup states
waiting = render("docs", None, no_visits)["body"]
check("waiting-static-nothing-to-do", text(waiting).index("Nothing to do.") < text(waiting).index("Count clicks and forms")
      and "No visits recorded yet" in text(waiting) and re.search(r"<details><summary>Options you can add", waiting))
check("waiting-turn-off-has-consequence", "Turn analytics off" in text(waiting) and "Numbers collected so far are kept." in text(waiting))
check("waiting-no-tick", 'type="checkbox"' not in waiting and 'name="confirm" value="1"' in waiting and 'name="enabled" value="0"' in waiting)
off = render("shop", None, visits)["body"]
check("off-one-button-no-tick", text(off).count("Turn analytics on") == 1 and "Analytics are off" in text(off) and 'type="checkbox"' not in off
      and 'name="confirm" value="1"' in off and 'name="enabled" value="1"' in off and 'name="csrf" value="tok"' in off)
check("off-button-bottom-right", re.search(r'<div class="actions">.*<button class="btn" type="submit">Turn analytics on</button></div></form>', off, re.S) is not None)
app_off = render("api-off", None, visits)["body"]
check("app-off-three-steps", all(s in text(app_off) for s in ("Turn analytics on", "Add one line to your app", "Release it")) and "data-website-id=&quot;…&quot;" in app_off)
app = render("api", None, no_visits)["body"]
check("app-on-three-steps", all(s in text(app) for s in ("Analytics are on", "Add one line to your app", "Release it", "No visits recorded yet"))
      and "Nothing to do." not in text(app))
tag = re.search(r"&lt;script defer.*?&lt;/script&gt;", app).group(0)
check("tracker-has-only-own-id", "00000000-0000-4000-8000-000000000003" in tag and WID not in app and OTHER not in app and "api.example.org" in tag)
doc_tag = re.search(r"&lt;script defer.*?&lt;/script&gt;", render("docs", None, no_visits)["body"])
check("auto-sites-show-no-tracker-line", doc_tag is None)
check("setup-no-raw-iso", not any(ISO_TEXT.search(text(b)) for b in (waiting, off, app, app_off)))
check("setup-breadcrumbs-link", '<a href="/sites/api">api</a>' in app and '<b aria-current="page">Analytics</b>' in app)

# overview folded into the Sites dashboard
h = handler()
A.analytics(h, WHO, {})
check("overview-redirects-home", h.out.get("redirect") == "/")
check("unknown-site-404", render("nope", None, visits)["code"] == 404)

sys.exit(1 if fails else 0)
