#!/usr/bin/env python3
"""New site form and the error page. Runnable alone: python3 tests/portal/test_new.py"""
import base64, hashlib, hmac, importlib.util, json, os, re, sys, tempfile, time, types

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
TMP = tempfile.mkdtemp()
os.makedirs(f"{TMP}/requests"); os.makedirs(f"{TMP}/tokens")
os.environ.update(WEBHOST_PORTAL_DATA=TMP, WEBHOST_INSPECT=f"{TMP}/inspect")
sys.path.insert(0, os.path.join(ROOT, "guest"))
spec = importlib.util.spec_from_file_location("portal", os.path.join(ROOT, "guest", "webhost-portal.py"))
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)

fails = []


def check(name, ok):
    print(f"{name} {'ok' if ok else 'FAIL'}")
    if not ok:
        fails.append(name)


tpls = [{"name": n, "runtime": rt, "summary": f"summary of {n}", "group": g, "label": lab, "hint": f"hint of {n}", "database": db, "app": app}
        for n, rt, g, lab, db, app in (
            ("static", "static", "sites", "Static files", "none", None), ("wordpress", "php", "sites", "WordPress", "mariadb", "wordpress"),
            ("lamp", "php", "stacks", "PHP app with a database", "mariadb", None), ("php-app", "php", "stacks", "PHP app", "none", None),
            ("django", "python", "stacks", "Django app", "postgresql", None), ("node-app", "node", "stacks", "Node.js app", "none", None))]
conf = {"base_domain": "x.dk", "site_limit": 10, "templates": tpls}
got = {}
h = P.Portal.__new__(P.Portal)
h.server = types.SimpleNamespace(conf=conf)
h.send = lambda code, body, *a, **k: got.update(code=code, body=body)
h.redirect = lambda to: got.update(code=303, to=to)
ann = {"user": "ann", "groups": ["webhost"], "admin": False, "csrf": "c"}
bob = dict(ann, user="bob")
root = {"user": "root", "groups": ["installer"], "admin": True, "csrf": "c"}
json.dump([{"name": "mine", "owner": "ann", "template": "static", "domain": "mine.x.dk", "state": "live"},
           {"name": "theirs", "owner": "bob", "template": "lamp", "domain": "theirs.x.dk", "state": "live"}], open(f"{TMP}/sites.json", "w"))


def text(markup):
    return re.sub(r"<[^>]+>", "", markup)


# every validation error: at its field, in the summary, with a link to the field id
GOOD = {"template": "static", "name": "fresh", "domain": "", "mode": "git", "repo": "https://x.example/a.git", "ref": "main"}
cases = [
    ("template", "template", {"template": ""}),
    ("name", "name", {"name": "My Site"}),
    ("name-taken", "name", {"name": "mine"}),
    ("domain", "domain", {"domain": "not a domain"}),
    ("repo", "repo", {"repo": "git@x:y"}),
    ("repo-and-package", "repo", {"mode": ""}),
    ("token", "token", {"token": "has space"}),
    ("no-source-git", "repo", {"repo": ""}),
    ("no-source-package", "package", {"repo": "", "mode": "package"}),
    ("dbinit", "dbinit", {"template": "lamp", "dbInit": "../etc/passwd"}),
    ("package-type", "package", {"repo": "", "mode": "package", "_file": ("x.exe", b"x")}),
]
for label, fid, over in cases:
    fields = dict(GOOD, **{k: v for k, v in over.items() if k != "_file"})
    files = {"package": over["_file"]} if "_file" in over else {}
    if label == "repo-and-package":
        files = {"package": ("a.zip", b"x")}
    got.clear()
    h.create(ann, fields, files)
    body = got.get("body", "")
    summary = re.search(r'<section class="errsum".*?</section>', body, re.S)
    summary = summary.group(0) if summary else ""
    at_field = re.search(rf'<small id="{fid}-msg" class="err">(.+?)</small>|<p id="{fid}-msg" class="err">(.+?)</p>', body)
    msg = (at_field.group(1) or at_field.group(2)) if at_field else None
    check(f"error-{label}-is-400", got.get("code") == 400)
    check(f"error-{label}-at-field", msg is not None and f'id="{fid}"' in body or fid == "template" and msg is not None)
    check(f"error-{label}-in-summary-with-link", msg is not None and f'<a href="#{fid}">{msg}</a>' in summary and "1 thing to fix" in summary)
    if label != "template":
        check(f"error-{label}-marks-input", re.search(rf'<input id="{fid}"[^>]*aria-invalid="true"', body) is not None)
check("error-keeps-what-was-typed", 'value="My Site"' in (h.create(ann, dict(GOOD, name="My Site"), {}) or got["body"]) )
check("good-form-redirects", (h.create(ann, dict(GOOD), {}), got["code"])[1] == 303 and "/requests/" in got["to"])
check("string-error-still-shown", (h.new(ann, "Plain message"), "Plain message" in got["body"] and 'class="errsum"' in got["body"])[1])
h.new(ann); body = got["body"]
check("no-summary-without-error", 'class="errsum"' not in body and got["code"] == 200)

# groups, purpose first
groups = re.findall(r"<legend>(.*?)</legend>", body)
check("template-groups", groups == ["A site made of files", "WordPress", "An app with its own server code"])
cards = {m.group(1): m.group(0) for m in re.finditer(r'<label class="tpl"><input[^>]*value="([^"]+)".*?</label>', body, re.S)}
files_part, rest = body.split("<legend>WordPress</legend>")
wp_part, apps_part = rest.split("<legend>An app with its own server code</legend>")
check("static-in-files", 'value="static"' in files_part and 'value="lamp"' not in files_part)
check("wordpress-alone", 'value="wordpress"' in wp_part and 'value="static"' not in wp_part and 'value="lamp"' not in wp_part)
check("apps-grouped", all(f'value="{n}"' in apps_part for n in ("lamp", "php-app", "django", "node-app")))
check("purpose-before-stack", text(cards["lamp"]).index("For hint of lamp.") < text(cards["lamp"]).index("summary of lamp"))
check("label-is-main", "<b>PHP app with a database</b>" in cards["lamp"] and "mono" not in cards["lamp"])
check("takes-two-to-three-minutes", "Takes two to three minutes" in body and body.rindex('type="submit">Create site') > body.index("Takes two to three"))
check("primary-bottom-right", re.search(r'<div class="actions"><a class="btn ghost"[^>]*>Cancel</a><button class="btn" type="submit">Create site</button></div>', body) is not None)

# WordPress hides content; database field only for database templates
check("wordpress-marks-data-wp", 'value="wordpress" data-wp' in body and "data-db" not in cards["wordpress"])
check("content-hidden-by-has-for-wordpress", "form:has(input[data-wp]:checked) .pane-src{display:none}" in body)
check("only-database-templates-open-the-field", [n for n, c in cards.items() if "data-db" in c] == ["lamp", "django"])
check("schema-field-in-hidden-by-default-pane", re.search(r'class="f pane-db"><label for="dbinit">.*?name="dbInit"', body, re.S) is not None
      and ".pane-db{display:none}form:has(input[data-db]:checked) .pane-db" in body)
check("field-names-kept", all(f'name="{n}"' in body for n in ("name", "template", "domain", "public", "mode", "repo", "ref", "token", "package", "dbInit", "csrf")))
check("no-script", "<script" not in body)

# retry prefill
json.dump({"id": "20260101T000000Z-aaaaaa", "kind": "create", "user": "ann", "site": "demo", "template": "lamp", "domain": "demo.x.dk", "public": True,
           "source": {"repo": "https://x.example/a.git", "ref": "dev"}, "dbInit": "db/schema.sql"}, open(f"{TMP}/requests/20260101T000000Z-aaaaaa.json", "w"))
h.new(ann, query={"from": ["20260101T000000Z-aaaaaa"]}); b = got["body"]
check("prefill-from-request", 'value="demo"' in b and 'value="dev"' in b and 'value="db/schema.sql"' in b and 'value="lamp" checked data-db' in b)
h.new(bob, query={"from": ["20260101T000000Z-aaaaaa"]})
check("prefill-needs-owner", 'value="demo"' not in got["body"])

# not found: the viewer's own sites only
h.fail(404, "No such site, or not yours.", ann); b = got["body"]
check("notfound-says-why", got["code"] == 404 and "We cannot find that page." in b and "No such site, or not yours." in b)
check("notfound-lists-own-sites-with-links", 'href="/sites/mine"' in b and "theirs" not in b)
h.fail(404, "No such page.", bob)
check("notfound-other-viewer-sees-theirs", 'href="/sites/theirs"' in got["body"] and "mine" not in got["body"])
h.fail(404, "No such page.", root)
check("notfound-installer-sees-all", 'href="/sites/mine"' in got["body"] and 'href="/sites/theirs"' in got["body"])
h.fail(404, "No such page.", dict(ann, user="nobody"))
check("notfound-no-sites-offers-create", 'href="/new"' in got["body"] and "Create your first site" in got["body"])
h.fail(409, "A site named x exists.", ann)
check("other-codes-short-plain", got["code"] == 409 and "A site named x exists." in got["body"] and "Your sites" not in got["body"] and "mine" not in got["body"])
h.fail(404, "<b>x</b>", ann)
check("fail-escapes", "<b>x</b>" not in got["body"] and "&lt;b&gt;" in got["body"])

# without a passed viewer, fail reads the gate token like identify does
key = {"secret": "s3cret", "client_id": "cid", "slug": "webhost-gate"}
json.dump(key, open(f"{TMP}/key.json", "w"))
P.KEY = f"{TMP}/key.json"


def token(user):
    e = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    hd, bd = e({"alg": "HS256", "typ": "JWT"}), e({"aud": "cid", "iss": "https://a/application/o/webhost-gate/", "exp": time.time() + 300,
                                                  "preferred_username": user, "groups": ["webhost"]})
    return f"{hd}.{bd}." + base64.urlsafe_b64encode(hmac.new(b"s3cret", f"{hd}.{bd}".encode(), hashlib.sha256).digest()).rstrip(b"=").decode()


h.headers = {"X-Authentik-Jwt": token("ann")}
h.fail(404, "No such page.")
check("notfound-reads-viewer-from-gate-token", 'href="/sites/mine"' in got["body"] and "theirs" not in got["body"])
h.headers = {}
h.fail(404, "No such page.")
check("notfound-without-viewer-lists-nothing", "mine" not in got["body"] and "theirs" not in got["body"] and got["code"] == 404)

sys.exit(1 if fails else 0)
