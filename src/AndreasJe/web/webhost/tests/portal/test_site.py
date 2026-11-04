#!/usr/bin/env python3
"""Site page: bugs 1, 2 and 4 of the handoff, page order, variants, ownership. Runnable alone: python3 tests/portal/test_site.py"""
import calendar, importlib.util, json, os, re, sys, tempfile, time, types

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
NOW = calendar.timegm((2026, 11, 3, 10, 4, 0))
time.time = lambda: float(NOW)
WORK = tempfile.mkdtemp()
for d in ("requests", "inspect", "uploads"):
    os.makedirs(f"{WORK}/{d}")
os.environ.update(WEBHOST_PORTAL_DATA=WORK, WEBHOST_INSPECT=f"{WORK}/inspect")
sys.path.insert(0, os.path.join(ROOT, "guest"))
spec = importlib.util.spec_from_file_location("portal", os.path.join(ROOT, "guest", "webhost-portal.py"))
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)
import portal_core as C
import portal_site as S

C.ANALYTICS_MAP = f"{WORK}/analytics-sites.json"
json.dump({"portfolio": "w-portfolio"}, open(C.ANALYTICS_MAP, "w"))
fails = []


def check(name, ok):
    print(f"{name} {'ok' if ok else 'FAIL'}")
    if not ok:
        fails.append(name)


def wj(path, obj):
    json.dump(obj, open(path, "w"))


def text(markup):
    markup = re.sub(r"<(style|svg)\b.*?</\1>", "", markup, flags=re.S)
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", markup))


ISO = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d")
TPL = [{"name": "static", "label": "Static files", "runtime": "static", "database": "none", "guide": [{"group": "Deploying", "items": ["Set `options.dataDirs` (options.dbInit)"]}]},
       {"name": "lamp", "label": "PHP + MariaDB", "runtime": "php", "database": "mariadb", "guide": []},
       {"name": "wordpress", "label": "WordPress", "runtime": "php", "database": "mariadb", "app": "wordpress", "guide": []},
       {"name": "node-app", "label": "Node.js", "runtime": "node", "database": "none", "guide": []}]
site = lambda name, tpl, rt, src, **kw: dict({"name": name, "owner": "ann", "template": tpl, "runtime": rt, "domain": f"{name}.x.dk", "public": True, "source": src, "analytics": False, "state": "live"}, **kw)
git = {"repo": "https://codeberg.org/ann/p.git", "ref": "main"}
SITES = [site("portfolio", "static", "static", git, analytics=True), site("docs", "static", "static", git, public=False), site("blog", "wordpress", "php", {}),
         site("shop", "lamp", "php", git, dbInit="db/schema.sql"), site("api", "node-app", "node", {"upload": True}), site("quiet", "static", "static", git)]
wj(f"{WORK}/sites.json", SITES)
ok = {"rev": "8890f8fd3bcb87a3cfa23442bb97999ebf7e9b8b", "checked": "2026-11-03T08:40:00Z", "verdict": "pass", "findings": []}
blocked = {"rev": "fd435d7b4157" + "0" * 28, "checked": "2026-11-03T08:41:00Z", "verdict": "block", "findings": [
    {"level": "block", "rule": "secret", "file": "private/send-sms.php", "detail": "an API key"},
    {"level": "block", "rule": "server-code-in-static", "file": "sources/app/index.php", "detail": "would be served as source"}]}
for n in ("portfolio", "blog", "shop", "api", "quiet"):
    wj(f"{WORK}/inspect/{n}.json", ok)
wj(f"{WORK}/inspect/docs.json", blocked)
# restore points: the listed time is a day after the time inside the volid, and each night has its own time
nights = [("2026-11-03", "01:30"), ("2026-11-02", "02:12"), ("2026-11-01", "01:47")]
bk = [{"volid": f"store:backup/ct/630/{d}T{t}:00Z", "time": NOW - 86400 * (i + 1), "size": 1 << 30} for i, (d, t) in enumerate(nights)]
wj(f"{WORK}/backups.json", {"sites": {s["name"]: bk for s in SITES}, "deleted": []})
os.makedirs(f"{WORK}/uploads/api")
wj(f"{WORK}/uploads/api/package.json", {"name": "api-1.8.2.tgz", "size": 14892032, "time": NOW - 20 * 3600})


def fake_cached(path, ttl=3600):
    if "/stats" in path:
        return (NOW, {"pageviews": 4930, "visitors": 1284, "visits": 1702, "bounces": 698, "totaltime": 1, "comparison": {"visitors": 1088}})
    day = lambda i: time.strftime("%Y-%m-%dT00:00:00Z", time.gmtime(NOW - (6 - i) * 86400))
    return (NOW, {"pageviews": [], "sessions": [{"x": day(i), "y": 140 + 20 * i} for i in range(7)]})


C.Umami.cached = staticmethod(fake_cached)
out = {}
h = P.Portal.__new__(P.Portal)
h.server = types.SimpleNamespace(conf={"base_domain": "x.dk", "templates": TPL})
h.send = lambda code, body, *a, **k: out.update(code=code, body=body)
h.redirect = lambda to: out.update(code=303, to=to)
h.write_request = lambda r, token=None: out.update(req=r) or "rid-1"
ann = {"user": "ann", "groups": ["webhost"], "admin": False, "csrf": "c"}
bob = dict(ann, user="bob")
root = {"user": "root", "groups": ["installer"], "admin": True, "csrf": "c"}


def page(name, who=ann):
    h.detail(who, name)
    return out["code"], out["body"]


# bug 1: recent pulls are formatted times, in the mirror's own format, newest first
rows = [("a91e07c" + "0" * 33, "2026-11-01T09:15:00Z", "pass"), ("4c32cab" + "0" * 33, "2026-11-02T17:30:00Z", "block"), ("8890f8fd3bcb" + "0" * 28, "2026-11-03T08:40:00Z", "pass")]
open(f"{WORK}/inspect/portfolio.history.jsonl", "w").writelines(json.dumps({"rev": r, "checked": c, "verdict": v, "rules": []}) + "\n" for r, c, v in rows)
open(f"{WORK}/inspect/portfolio.fetched", "w").close()
code, body = page("portfolio")
pulls = re.search(r"aria-label='Recent pulls'.*?</div></div>", body, re.S).group(0)
check("pulls-formatted-times", all(t in text(pulls) for t in ("1 hour ago", "Yesterday 17:30", "Sun 1 Nov")) and 'title="Tue 3 Nov 2026, 08:40 UTC"' in pulls)
check("pulls-newest-first-short-hash", text(pulls).index("8890f8f") < text(pulls).index("4c32cab") < text(pulls).index("a91e07c") and "8890f8fd" not in text(pulls))
check("pulls-last-looked", "Last looked for changes" in text(body))
check("no-raw-iso-in-text", not ISO.search(text(body)))
open(f"{WORK}/inspect/portfolio.history.jsonl", "w").writelines(["not json\n", json.dumps({"rev": "abc1234", "checked": "2026-11-03T08:412:00Z", "verdict": "pass"}) + "\n"])
code, body = page("portfolio")
check("pulls-bad-time-is-quiet", code == 200 and not ISO.search(text(body)) and "abc1234" in body)

# bug 4: a blocked pull is listed, also when the mirror has no history file yet, and once when it has
open(f"{WORK}/inspect/docs.history.jsonl", "w").close(); os.remove(f"{WORK}/inspect/docs.history.jsonl")
code, body = page("docs")
check("blocked-pull-listed-without-history", "Nothing yet" not in body and "fd435d7" in body and re.search(r"fd435d7</span><span role='cell'><span class=\"pill bad\">blocked", body) is not None)
open(f"{WORK}/inspect/docs.history.jsonl", "w").writelines(json.dumps(x) + "\n" for x in (
    {"rev": "a91e07c" + "0" * 33, "checked": "2026-10-29T14:20:00Z", "verdict": "pass", "rules": []},
    {"rev": "fd435d7b4157" + "0" * 28, "checked": "2026-11-03T08:41:00Z", "verdict": "block", "rules": ["secret"]}))
code, body = page("docs")
check("blocked-pull-listed-once-with-history", body.count("fd435d7</span>") == 1 and "a91e07c" in body)
check("no-pulls-says-so", "Nothing yet" in S.pull_log("nosuch", None))

# bug 2: label and restored value come from the same restore point, each with its own time
code, body = page("portfolio")
opts = re.findall(r"<input type='radio' name='backup' value='([^']+)' required><span><b style='font-weight:600' title='([^']+)'>([^<]+)</b>", body)
want = {"2026-11-03T01:30": ("Last night 01:30 UTC", "Tue 3 Nov 2026, 01:30 UTC"), "2026-11-02T02:12": ("Yesterday 02:12 UTC", "Mon 2 Nov 2026, 02:12 UTC"),
        "2026-11-01T01:47": ("Sun 1 Nov 01:47 UTC", "Sun 1 Nov 2026, 01:47 UTC")}
check("backup-three-options", len(opts) == 3)
check("backup-label-matches-value", all(want[re.search(r"(\d{4}-\d\d-\d\dT\d\d:\d\d)", v).group(1)] == (lab, ex) for v, ex, lab in opts))
check("backup-times-differ", len({lab for _, _, lab in opts}) == 3)
form = re.search(r"<form class='card site-bk'.*?</form>", body, re.S).group(0)
check("backup-one-form", body.count("name='backup'") == 3 and form.count("<form") == 1 and form.count("type='checkbox'") == 1 and form.count("<button") == 1
      and "Restore the chosen backup" in form and "Changes made since that backup are lost" in form and "class='opts'" in form)
check("backup-form-fields", "action='/sites/portfolio/restore'" in form and "name='confirm' value='1'" in form and "name='csrf'" in form)
good = bk[1]["volid"]
h.restore(ann, "portfolio", {"backup": good, "confirm": "1"}, {})
check("restore-accepts-listed-point", out.get("to") == "/requests/rid-1" and out["req"]["backup"] == good and out["req"]["kind"] == "restore")
out.clear(); h.fail = lambda code, msg: out.update(code=code, msg=msg)
h.restore(ann, "portfolio", {"backup": "store:backup/ct/630/2020-01-01T00:00:00Z", "confirm": "1"}, {}); check("restore-refuses-unlisted-volid", out["code"] == 400)
h.restore(ann, "portfolio", {"backup": good}, {}); check("restore-needs-the-tick", out["code"] == 400)
h.restore(bob, "portfolio", {"backup": good, "confirm": "1"}, {}); check("restore-needs-owner", out["code"] == 404)
check("restore-time-from-volid", S.restore_time(bk[0]) == calendar.timegm((2026, 11, 3, 1, 30, 0)) and S.restore_time({"volid": "x", "time": 5}) == 5)

# ownership
out.clear(); h.detail(bob, "portfolio"); check("other-owner-gets-404", out["code"] == 404 and "body" not in out and "portfolio" not in out["msg"])
out.clear(); h.detail(root, "portfolio"); check("installer-sees-any-site", out.get("code") == 200)
h.send = lambda code, body, *a, **k: out.update(code=code, body=body)

# variants and page order
code, body = page("portfolio")
order = [body.index(m) for m in ("<h1>", "Nothing needs doing", "How to update this site", "Visitors this week", "Last inspection", "Backups</h2>", "What your site gets", "Danger zone")]
check("page-order", order == sorted(order))
check("analytics-on-has-sparkline", "Visitors this week" in body and "<svg class=\"spark\"" in body and "1,284" in body and "18% more than the week before" in body and "Wed 28 Oct to Tue 3 Nov" in body)
check("header", "Open site" in body and "Public" in body and "Static files" in text(body) and '<b aria-current="page">portfolio</b>' in body and '<a href="/">Sites</a>' in body)
_, b = page("quiet")
check("analytics-off-has-setup-link", "Visitors are not counted yet" in b and "href='/sites/quiet/analytics'>Set up analytics" in b and "Visitors this week" not in b)
_, b = page("blog")
check("wordpress-admin", "Open WordPress admin" in b and "https://blog.x.dk/wp-admin" in b and "Recent pulls" not in b and "Replace access token" not in b)
_, b = page("api")
check("app-how-to-do-it", ">How to do it<" in b and "Live package" in b and "api-1.8.2.tgz" in text(b) and "14.2 MB" in b and "name='package'" in b and "action='/sites/api/upload'" in b)
_, b = page("shop")
check("database-card", "Database" in b and "name='file'" in b and "action='/sites/shop/dbinit'" in b and "db/schema.sql" in b and "Load schema" in b)
_, b = page("docs")
check("blocked-order", b.index("Your live site is not affected") < b.index("What stopped the newest release") < b.index("How to update this site"))
check("blocked-findings-what-where-how", all(w in text(b) for w in ("What", "Where", "How to fix it", "A leaked key", "private/send-sms.php", "Server code in a static site")) and "newest release blocked" in b)
check("blocked-two-findings", "Pulled 1 hour ago" in text(b) and "2 findings" in text(b) and "Fix both" in text(b))
check("delete-form", "action='/sites/docs/delete'" in b and "name='confirm' required pattern='docs'" in b and b.index("Danger zone") > b.index("Last inspection"))
check("token-form", "action='/sites/docs/token'" in b and "name='token'" in b)
for n in ("portfolio", "docs", "blog", "shop", "api", "quiet"):
    t = text(page(n)[1])
    check(f"no-internal-words-{n}", not re.search(r"VMID|options\.|mothership|/home/tappaas|/var/log|\bct/\d+|\.log\b", t) and not ISO.search(t))
    check(f"no-script-{n}", "<script" not in page(n)[1] and "http-equiv" not in page(n)[1])
check("guide-folded-and-plain", "<details class='site-gets'>" in page("docs")[1] and "options" not in page("docs")[1].split("What your site gets")[1])

# analytics switch keeps its fields; turning on needs no tick
tf = S.toggle_form(h, ann, "quiet", True)
check("toggle-on-no-tick", "type='checkbox'" not in tf and "name='enabled' value='1'" in tf and "name='confirm' value='1'" in tf and "Turn analytics on" in tf)
check("toggle-off", "name='enabled' value='0'" in S.toggle_form(h, ann, "quiet", False) and "Turn analytics off" in S.toggle_form(h, ann, "quiet", False))
h.redirect = lambda to: out.update(code=303, to=to)
h.analytics_toggle(ann, "quiet", {"enabled": "1", "confirm": "1"}, {}); check("toggle-writes-request", out["req"]["enabled"] is True and out["req"]["kind"] == "analytics")
h.analytics_toggle(ann, "quiet", {"enabled": "1"}, {}); check("toggle-needs-confirm", out["code"] == 400)

print(f"test_site: {len(fails)} failed")
sys.exit(1 if fails else 0)
