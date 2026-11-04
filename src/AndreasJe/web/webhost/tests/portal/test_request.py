#!/usr/bin/env python3
"""portal_request: the request page for every kind and status, the stepper's failure step, retry. Runnable alone: python3 tests/portal/test_request.py"""
import importlib.util, json, os, re, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GUEST = os.path.join(HERE, "..", "..", "guest")
ROOT = tempfile.mkdtemp()
for d in ("requests", "logs", "tokens"):
    os.makedirs(f"{ROOT}/portal/{d}")
os.makedirs(f"{ROOT}/inspect")
os.environ.update(WEBHOST_PORTAL_DATA=f"{ROOT}/portal", WEBHOST_INSPECT=f"{ROOT}/inspect")
sys.path.insert(0, GUEST)
spec = importlib.util.spec_from_file_location("portal", os.path.join(GUEST, "webhost-portal.py"))
P = importlib.util.module_from_spec(spec)
spec.loader.exec_module(P)

fails = []


def check(name, ok):
    print(f"{name} {'ok' if ok else 'FAIL'}")
    if not ok:
        fails.append(name)


class Srv:
    conf = {"base_domain": "x.dk", "templates": [{"name": "lamp", "runtime": "php", "label": "PHP + MariaDB", "database": "mariadb", "guide": []},
                                                  {"name": "static", "runtime": "static", "label": "Static files", "database": "none", "guide": []}]}


got = {}
h = P.Portal.__new__(P.Portal)
h.server = Srv
h.send = lambda code, body, *a, **k: got.update(code=code, body=body)
h.fail = lambda code, msg: got.update(code=code, body=msg)
ann = {"user": "ann", "groups": ["webhost"], "admin": False, "csrf": "c"}
json.dump([{"name": "shop", "owner": "ann", "runtime": "php", "template": "lamp", "domain": "shop.x.dk", "state": "live"},
           {"name": "api", "owner": "ann", "runtime": "node", "template": "node-app", "domain": "api.x.dk", "state": "live"},
           {"name": "other", "owner": "bob", "runtime": "php", "template": "lamp", "domain": "other.x.dk", "state": "live"}], open(f"{ROOT}/portal/sites.json", "w"))
json.dump({"abc": 1}, open(f"{ROOT}/analytics.json", "w"))
BLOCK = {"rev": "fd435d7b4157aa", "checked": "2026-11-03T08:41:00Z", "verdict": "block",
         "findings": [{"level": "block", "rule": "secret", "file": "private/send-sms.php", "detail": "an API key"}]}
json.dump(BLOCK, open(f"{ROOT}/inspect/docs.json", "w"))
json.dump({"rev": "8890f8fd3bcb", "checked": "2026-11-03T08:40:00Z", "verdict": "pass", "findings": []}, open(f"{ROOT}/inspect/shop.json", "w"))
SRC = {"repo": "https://x.example/a.git", "ref": "main"}
n = [0]


def make(kind, status, message="", site="shop", **kw):
    n[0] += 1
    rid = f"20261103T0800{n[0]:02d}Z-{n[0]:06x}"
    r = dict({"id": rid, "kind": kind, "user": "ann", "groups": ["webhost"], "site": site, "status": status, "message": message,
              "created": "2026-11-03T08:00:00Z", "updated": "2026-11-03T08:05:00Z"}, **kw)
    if kind == "create":
        r.setdefault("template", "lamp"); r.setdefault("domain", f"{site}.x.dk"); r.setdefault("source", SRC)
    json.dump(r, open(f"{ROOT}/portal/requests/{rid}.json", "w"))
    return rid


def render(rid, who=ann):
    h.request_page(who, rid)
    return got["body"]


def steps(doc):
    return {m.group(2): m.group(1) for m in re.finditer(r'<li class="(\w+)"[^>]*><div class="hd2"><span[^>]*>.*?</span><b>(\w+)</b>', doc)}


def outside_log(doc):
    doc = re.sub(r'<details class="logbox">.*?</details>', "", doc, flags=re.S)
    return re.sub(r'datetime="[^"]*"', "", doc)


# bug 3: a refused schema is a failure at Loading, not at New
d = render(make("dbinit", "failed", "The database refused db/schema.sql: ERROR 1064 (42000) at line 3: syntax", file="db/schema.sql"))
check("bug3-dbinit-failed-at-loading", steps(d) == {"New": "done", "Loading": "stop", "Done": "skip"} and "Failed here" in d)
# and the same for every kind: the step that was running is marked
at = {("create", "failed"): "Creating", ("restore", "failed"): "Restoring", ("delete", "failed"): "Deleting", ("analytics", "failed"): "Applying",
      ("dbinit", "failed"): "Loading", ("token", "failed"): "New", ("create", "rejected"): "Checking", ("restore", "rejected"): "New",
      ("dbinit", "rejected"): "New", ("delete", "rejected"): "New", ("analytics", "rejected"): "New", ("token", "rejected"): "New"}
for (kind, status), want in at.items():
    d = render(make(kind, status, "x is not yours." if status == "rejected" else "boom", file="db/schema.sql", enabled=True))
    st = steps(d)
    if (kind, status) != ("create", "rejected"):
        check(f"stops-at-{kind}-{status}", st.get(want) == "stop" and list(st.values()).count("stop") == 1)
check("refused-create-has-no-stepper", "The steps" not in render(make("create", "rejected", "A site named shop exists.")))
d = render(make("create", "rejected", "The inspection blocked the content: secret (private/send-sms.php).", site="docs"))
check("blocked-stops-at-inspecting", steps(d).get("Inspecting") == "stop" and "Blocked here" in d and steps(d).get("Checking") == "done")
d = render(make("create", "rejected", "No content could be fetched from the source.", site="docs"))
check("nothing-fetched-stops-at-inspecting", steps(d).get("Inspecting") == "stop" and "No content could be fetched" in d and "Inspection</h2>" not in d)
d = render(make("create", "failed", "Field memory: value 256 is below minimum 512"))
check("create-failed-marks-creating", steps(d) == {"New": "done", "Checking": "done", "Inspecting": "done", "Creating": "stop", "Live": "skip"})
check("no-source-has-no-inspecting-step", "Inspecting" not in steps(render(make("create", "creating", source={}, site="wp"))))
d = render(make("create", "creating"))
check("running-stepper-open-and-marks-now", "Where it is" in d and steps(d)["Creating"] == "now" and steps(d)["Live"] == "wait" and "Step 4 of 5" in d)
d = render(make("create", "live", "Your site is live."))
check("finished-stepper-folded", "Where it is" not in d and "<details><summary>Show the five steps · all done" in d)

# what the person can change
check("field-memory", "Memory must be 512 MB or more. You chose 256 MB." in render(make("create", "failed", "Field memory: value 256 is below minimum 512")))
check("field-above-maximum", "Cores must be 8 or less. You chose 12." in render(make("create", "failed", "Field cores: value 12 is above maximum 8")))
d = render(make("create", "failed", "<script>boom"))
check("unknown-message-only-in-technical-log", "<script>boom" not in d and "&lt;script&gt;boom" in d
      and "&lt;script&gt;boom" not in outside_log(d) and "webhost-shop-create.log" in d and "webhost-shop-create.log" not in outside_log(d))

# retry button only for retryable creates
retry = lambda rid: f"/requests/{rid}/retry"
rid = make("create", "failed", "<script>boom")
check("retry-for-plain-failed-create", retry(rid) in render(rid))
rid = make("create", "failed", "<script>boom", token=True)
d = render(rid); check("no-retry-with-token", retry(rid) not in d and f"/new?from={rid}" in d)
rid = make("create", "failed", "<script>boom", source={"upload": True})
check("no-retry-with-package", retry(rid) not in render(rid))
rid = make("create", "failed", "Field memory: value 256 is below minimum 512")
d = render(rid); check("no-retry-when-a-setting-is-wrong", retry(rid) not in d and "Change the settings and try again" in d)
check("no-retry-after-restore-failed", "/retry" not in render(make("restore", "failed", "boom")))
check("no-retry-while-running-or-live", all("/retry" not in render(make("create", s, "")) for s in ("creating", "live", "rejected")))

# refused create links to the existing site; the inspection card only where one ran
d = render(make("create", "rejected", "A site named shop exists."))
check("refused-links-existing-site", 'href="/sites/shop"' in d and "The existing site is" in d and "Choose a different name" in d and "Inspection</h2>" not in d)
d = render(make("create", "rejected", "A site named other exists.", site="other"))
check("refused-no-link-to-someone-elses-site", "/sites/other" not in d)
check("inspection-card-after-pass", "Inspection</h2>" in render(make("create", "live", "ok")))
check("inspection-card-when-blocked", "Inspection</h2>" in render(make("create", "rejected", "The inspection blocked the content: secret (private/send-sms.php).", site="docs")) )
check("no-inspection-card-for-other-kinds", all("Inspection</h2>" not in render(make(k, s, "x")) for k, s in (("restore", "live"), ("delete", "done"), ("dbinit", "done"), ("token", "done"))))
d = render(make("create", "rejected", "The inspection blocked the content: secret (private/send-sms.php).", site="docs"))
check("blocked-findings-explained", "A leaked key" in d and "How to fix it" in d and "Fix it and create the site again" in d and "secret (" not in outside_log(d))

# live pages refresh; finished ones do not
check("running-refreshes", all('http-equiv="refresh"' in render(make(k, s)) for k, s in (("create", "new"), ("create", "checking"), ("create", "inspecting"), ("create", "creating"),
                                                                                         ("restore", "restoring"), ("delete", "deleting"), ("analytics", "applying"), ("dbinit", "applying"), ("token", "new"))))
check("finished-does-not-refresh", all('http-equiv="refresh"' not in render(make(k, s, "x")) for k, s in (("create", "live"), ("create", "failed"), ("restore", "live"), ("delete", "done"))))

# breadcrumbs say what the request is, and link the site when it exists
d = render(make("restore", "restoring", site="shop"))
trail = re.search(r'<nav aria-label="Breadcrumb">(.*?)</nav>', d).group(1)
check("crumbs-site-then-words", trail.count("<a ") == 2 and 'href="/sites/shop"' in trail and trail.rstrip().endswith('<b aria-current="page">Restoring from a backup</b>') and "restore" not in re.sub(r"<[^>]+>", "", trail).lower().replace("restoring", ""))
trail = re.search(r'<nav aria-label="Breadcrumb">(.*?)</nav>', render(make("create", "creating", site="newone"))).group(1)
check("crumbs-no-link-to-missing-site", trail.count("<a ") == 1 and "Creating newone" in trail)

# kinds x terminal statuses: no raw ISO, VMID or log path outside the technical log
nasty = "VMID 6302 stopped at 2026-11-03T08:41:00Z, see /home/tappaas/logs/webhost-shop-create.log (2026-11-02T01:30:00Z)."
cases = [("create", "live", "Your site is live."), ("create", "failed", nasty), ("create", "rejected", nasty), ("create", "rejected", "A site named shop exists."),
         ("create", "rejected", "The limit of 10 sites is reached."), ("create", "rejected", "The inspection blocked the content: secret (private/send-sms.php)."),
         ("restore", "live", "shop is restored (2026-11-02T01:30:00Z)."), ("restore", "failed", nasty), ("restore", "rejected", "shop is not yours."),
         ("delete", "done", "shop is deleted."), ("delete", "failed", nasty), ("delete", "rejected", "No site shop."),
         ("token", "done", "The access token is saved; the next fetch uses it."), ("token", "done", "The access token is removed."), ("token", "failed", nasty), ("token", "rejected", "The token is not valid."),
         ("analytics", "done", "Analytics are on."), ("analytics", "done", "Analytics are off."), ("analytics", "failed", nasty), ("analytics", "rejected", "shop is not running yet."),
         ("dbinit", "done", "Loaded db/schema.sql into the empty database."), ("dbinit", "done", "The database already has tables, so db/schema.sql was not loaded. Nothing was changed."),
         ("dbinit", "done", "Saved. db/schema.sql is loaded with the next release while the database is empty."), ("dbinit", "done", "No schema file is set any more."),
         ("dbinit", "failed", "The database refused db/schema.sql: " + nasty), ("dbinit", "failed", "There is no db/schema.sql in the live release. Push or upload it, then set it again."),
         ("dbinit", "failed", "The site's container cannot be reached."), ("dbinit", "rejected", "The file must be inside your site."),
         ("mystery", "failed", nasty), ("mystery", "done", "ok")]
bad = []
for kind, status, msg in cases:
    for site, extra in (("shop", {}), ("gone", {})):
        for en in (True, False):
            d = outside_log(render(make(kind, status, msg, site=site, file="db/schema.sql", enabled=en, domain=f"{site}.x.dk", backup="t:backup/ct/630/2026-11-02T01:30:00Z", **extra)))
            if re.search(r"\d{4}-\d\d-\d\dT\d\d:\d\d|VMID|/home/tappaas|webhost-\w+-(create|restore)\.log|\.log\b", re.sub(r"<style>.*?</style>", "", d, flags=re.S)):
                bad.append((kind, status, msg[:30]))
check("no-iso-vmid-or-log-path-outside-technical-log", not bad)
if bad:
    print("   ", bad[:5])
d = render(make("restore", "live", "shop is restored (2026-11-02T01:30:00Z)."))
check("restore-time-in-words", "Mon 2 Nov 01:30 UTC" in re.sub(r"<[^>]+>", "", d) or "Yesterday 01:30 UTC" in re.sub(r"<[^>]+>", "", d) or "Today 01:30 UTC" in re.sub(r"<[^>]+>", "", d))

# every page has a result block with a pill, one h1 and one primary action at most in it
for kind, status, msg in cases:
    d = render(make(kind, status, msg))
    first = d.split("</section>")[0]
    if d.count("<h1") != 1 or "class=\"pill" not in first:
        check(f"result-block-{kind}-{status}", False)
check("result-blocks-ok", True)

# ownership and the form's own redirect keep working
check("not-yours-is-404", (h.request_page(dict(ann, user="bob"), make("create", "live")), got["code"])[1] == 404)

print()
sys.exit(1 if fails else 0)
