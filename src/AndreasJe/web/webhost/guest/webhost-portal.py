#!/usr/bin/env python3
"""webhost-portal — the site portal, inside the webhost container.

People in the gate's groups pick a template, give a git repository or upload a
package, and follow their site from request to live. The portal holds no
rights: it writes a request (/srv/webhost/portal/requests) and the mothership
picks it up (webhost-manager portal sync), validates it, and creates the site.

Trust: only the firewall (Caddy behind the Authentik gate) may connect; every
request carries the gate's token (X-Authentik-Jwt), HS256 with the gate
provider's secret, which is checked as the TAPPaaS console checks it.
"""

import base64
import email.parser
import email.policy
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

CONF = os.environ.get("WEBHOST_PORTAL_CONF", "/etc/webhost/portal.json")
KEY = os.environ.get("WEBHOST_PORTAL_KEY", "/etc/webhost/portal-gate.json")
DATA = os.environ.get("WEBHOST_PORTAL_DATA", "/srv/webhost/portal")
INSPECT = os.environ.get("WEBHOST_INSPECT", "/srv/webhost/inspect")
LEEWAY = 60
SITE_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
DOMAIN_RE = re.compile(r"^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$")
REPO_RE = re.compile(r"^https://[A-Za-z0-9._/:-]+\.git$")
REF_RE = re.compile(r"^[A-Za-z0-9._/-]+$")
PACKAGE_RE = re.compile(r"\.(zip|tgz|tar\.gz)$", re.I)
TOKEN_RE = re.compile(r"[\x21-\x7e]{1,512}")


def load(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def b64(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


# ── the gate's token ─────────────────────────────────────────────────

def verify_token(token, key, now):
    """Returns (claims, None) or (None, reason)."""
    if not token:
        return None, "no X-Authentik-Jwt: the request did not come through the identity gate"
    parts = token.split(".")
    if len(parts) != 3:
        return None, "X-Authentik-Jwt is not a JWT"
    try:
        head, body = json.loads(b64(parts[0])), json.loads(b64(parts[1]))
        sig = b64(parts[2])
    except ValueError:
        return None, "X-Authentik-Jwt cannot be read"
    if head.get("alg") != "HS256":
        return None, "X-Authentik-Jwt is not HS256"
    want = hmac.new(key["secret"].encode(), f"{parts[0]}.{parts[1]}".encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(sig, want):
        return None, "X-Authentik-Jwt has a wrong signature"
    aud = body.get("aud") if isinstance(body.get("aud"), list) else [body.get("aud")]
    if key["client_id"] not in aud:
        return None, "X-Authentik-Jwt is for another application"
    iss = str(body.get("iss", ""))
    if not iss.rstrip("/").endswith(f"/application/o/{key['slug']}"):
        return None, "X-Authentik-Jwt has another issuer"
    if not isinstance(body.get("exp"), (int, float)) or body["exp"] + LEEWAY < now:
        return None, "X-Authentik-Jwt has expired"
    user = body.get("preferred_username")
    if not isinstance(user, str) or not user:
        return None, "X-Authentik-Jwt names no user"
    groups = [g for g in body.get("groups") or [] if isinstance(g, str)]
    return {"user": user, "groups": groups, "name": body.get("name") or user}, None


# ── pages ────────────────────────────────────────────────────────────

STYLE = """
:root{--bg:#f6f7f9;--card:#fff;--ink:#1d2330;--mute:#5b6475;--line:#dde1e8;--acc:#1f6feb;--ok:#1a7f37;--bad:#cf222e;--warn:#9a6700}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#171a21;--ink:#e6e9ef;--mute:#9aa3b2;--line:#2a2f3a;--acc:#4c8dff;--ok:#3fb950;--bad:#f85149;--warn:#d29922}}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 system-ui,sans-serif;background:var(--bg);color:var(--ink)}
header{display:flex;justify-content:space-between;align-items:center;padding:14px 20px;border-bottom:1px solid var(--line);background:var(--card)}
header a{color:var(--ink);text-decoration:none;font-weight:600}main{max-width:960px;margin:0 auto;padding:20px 16px}
a{color:var(--acc)}h1{font-size:22px;margin:0 0 16px}h2{font-size:17px;margin:24px 0 10px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin-bottom:14px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--mute);font-weight:500}
.btn{display:inline-block;background:var(--acc);color:#fff;border:0;border-radius:8px;padding:9px 16px;font:inherit;cursor:pointer;text-decoration:none}
.btn.danger{background:var(--bad)}.mute{color:var(--mute)}
.tpls{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:10px}
.tpl{display:block;border:1px solid var(--line);border-radius:10px;padding:12px;cursor:pointer;background:var(--card)}
.tpl input{margin-right:6px}.tpl small{display:block;color:var(--mute);margin-top:4px}
label.f{display:block;margin:12px 0 4px;font-weight:500}input[type=text],input[type=file]{width:100%;padding:8px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--ink);font:inherit}
.pill{display:inline-block;border-radius:99px;padding:1px 9px;font-size:13px;border:1px solid var(--line)}
.ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}.err{border-color:var(--bad)}
pre.log{max-height:420px;overflow:auto;font-size:12px;line-height:1.45;padding:10px;border:1px solid var(--line);border-radius:8px;white-space:pre-wrap;word-break:break-word}
details summary{cursor:pointer;margin:8px 0}.failed{font-weight:600;color:var(--bad)}
"""

STATE_CLASS = {"live": "ok", "active": "ok", "pass": "ok", "passed": "ok", "blocked": "bad", "rejected": "bad", "failed": "bad", "block": "bad",
               "quarantined": "warn", "warn": "warn"}


def esc(v):
    return html.escape(str(v), quote=True)


def pill(state):
    return f'<span class="pill {STATE_CLASS.get(state, "")}">{esc(state)}</span>'


def page(title, who, body, refresh=False):
    meta = '<meta http-equiv="refresh" content="8">' if refresh else ""
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">{meta}<title>{esc(title)} · Sites</title>
<style>{STYLE}</style></head><body><header><a href="/">Sites</a><span class="mute">{esc(who)}</span></header>
<main>{body}</main></body></html>"""


def release_cell(site, insp):
    if not site.get("source"):
        return "<span class='mute'>not applicable</span>"
    v = insp.get("verdict")
    if v == "block":
        rules = sorted({f["rule"] for f in insp.get("findings", []) if f.get("level") == "block"})
        n = sum(1 for f in insp.get("findings", []) if f.get("level") == "block")
        return f"{pill('blocked')} <a href='/sites/{esc(site['name'])}'>{esc(', '.join(rules))} ({n})</a>"
    return {"pass": pill("passed")}.get(v, "<span class='mute'>not inspected yet</span>")


def backups():
    return load(os.path.join(DATA, "backups.json"), {"sites": {}, "deleted": []})


def when(ts):
    return time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(int(ts)))


def restore_form(who, action, volid, label):
    return (f"<form method='post' action='{action}' enctype='multipart/form-data' style='margin:6px 0'>"
            f"<input type='hidden' name='csrf' value='{who['csrf']}'><input type='hidden' name='backup' value='{esc(volid)}'>"
            f"<label><input type='checkbox' name='confirm' value='1' required> {label}</label> "
            "<button class='btn' type='submit'>Restore</button></form>")


def guide_block(conf, template):
    t = {t["name"]: t for t in conf.get("templates", [])}.get(template) or {}
    items = "".join(f"<li>{esc(g)}</li>" for g in t.get("guide", []))
    return f"<h2>What your site gets</h2><div class='card'><ul>{items}</ul></div>" if items else ""


def read_log(rid):
    try:
        with open(os.path.join(DATA, "logs", f"{rid}.log"), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def log_block(rid, status):
    text = read_log(rid)
    if not text:
        return ""
    if status in ("creating", "deleting", "restoring"):
        tail = "\n".join(text.rstrip().splitlines()[-15:])
        return f"<h2>Progress</h2><pre class='log'>{esc(tail)}</pre>"
    return f"<details><summary>Show the log</summary><pre class='log'>{esc(text)}</pre></details>"


def findings_table(result):
    if not result:
        return '<p class="mute">Not inspected yet.</p>'
    rows = "".join(f"<tr><td>{pill(f['level'])}</td><td>{esc(f['rule'])}</td><td><code>{esc(f['file'])}</code></td><td>{esc(f['detail'])}</td></tr>"
                   for f in result.get("findings", []))
    head = f"<p>Inspection {pill(result.get('verdict', '?'))} <span class='mute'>{esc(result.get('checked', ''))}"
    head += f" · revision {esc((result.get('rev') or '')[:12])}</span></p>"
    return head + (f"<table><tr><th></th><th>Rule</th><th>File</th><th>Detail</th></tr>{rows}</table>" if rows else "<p class='mute'>No findings.</p>")


class Portal(BaseHTTPRequestHandler):
    server_version = "webhost-portal"
    sys_version = ""

    # ── plumbing ──
    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="text/html; charset=utf-8", headers=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, to):
        self.send(303, "", headers={"Location": to})

    def fail(self, code, msg):
        self.send(code, page("Error", "", f'<div class="card err"><h1>{code}</h1><p>{esc(msg)}</p><p><a href="/">Back</a></p></div>'))

    def identify(self):
        conf = self.server.conf
        if self.client_address[0] != conf.get("firewall"):
            self.fail(403, "Reach the portal through its address, not the container.")
            return None
        key = load(KEY, None)
        if not key:
            self.fail(503, "The portal has no gate key yet; the mothership's next sync brings it.")
            return None
        claims, why = verify_token(self.headers.get("X-Authentik-Jwt"), key, time.time())
        if not claims:
            self.fail(401, why)
            return None
        groups = set(claims["groups"])
        if not groups & set(conf.get("groups", ["webhost", "installer"])):
            self.fail(403, "Your account is not in a group that may use the site portal.")
            return None
        claims["admin"] = bool(groups & set(conf.get("admin_groups", ["installer"])))
        claims["csrf"] = hmac.new(key["secret"].encode(), f"csrf:{claims['user']}".encode(), hashlib.sha256).hexdigest()[:32]
        return claims

    def form(self, who):
        limit = int(self.server.conf.get("max_upload_mb", 100)) * 1024 * 1024
        length = int(self.headers.get("Content-Length") or 0)
        if length > limit + 1024 * 1024:
            self.fail(413, f"Packages may be at most {limit // (1024 * 1024)} MB.")
            return None
        body = self.rfile.read(length)
        ctype = self.headers.get("Content-Type", "")
        fields, files = {}, {}
        if ctype.startswith("multipart/form-data"):
            msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
                b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + body)
            for part in msg.iter_parts():
                name = part.get_param("name", header="content-disposition")
                if not name:
                    continue
                if part.get_filename():
                    files[name] = (part.get_filename(), part.get_payload(decode=True) or b"")
                else:
                    fields[name] = (part.get_payload(decode=True) or b"").decode("utf-8", "replace").strip()
        else:
            fields = {k: v[0].strip() for k, v in parse_qs(body.decode("utf-8", "replace")).items()}
        if not hmac.compare_digest(fields.get("csrf", ""), who["csrf"]):
            self.fail(403, "The form expired; reload the page and try again.")
            return None
        return fields, files

    # ── data ──
    def sites(self, who):
        all_sites = load(os.path.join(DATA, "sites.json"), [])
        return [s for s in all_sites if who["admin"] or s.get("owner") == who["user"]]

    def site(self, who, name):
        return next((s for s in self.sites(who) if s.get("name") == name), None)

    def requests(self, who):
        d = os.path.join(DATA, "requests")
        out = []
        for f in sorted(os.listdir(d), reverse=True) if os.path.isdir(d) else []:
            r = load(os.path.join(d, f), None)
            if r and (who["admin"] or r.get("user") == who["user"]):
                out.append(r)
        return out

    def write_request(self, req, token=None):
        d = os.path.join(DATA, "requests")
        req["id"] = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(3)
        if token is not None:
            # Only the sync on the mothership reads it, and it removes it.
            fd = os.open(os.path.join(DATA, "tokens", req["id"]), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(token + "\n")
            req["token"] = True
        req["status"] = "new"
        req["created"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        tmp = os.path.join(d, f".{req['id']}.json")
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(req, fh)
        os.chmod(tmp, 0o664)
        os.replace(tmp, os.path.join(d, f"{req['id']}.json"))
        return req["id"]

    def save_package(self, site, user, filename, data):
        ext = PACKAGE_RE.search(filename).group(1).lower()
        d = os.path.join(DATA, "uploads", site)
        os.makedirs(d, mode=0o2770, exist_ok=True)
        path = os.path.join(d, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{secrets.token_hex(3)}.{ext}")
        with open(path, "wb") as fh:
            fh.write(data)
        os.chmod(path, 0o660)

    # ── routes ──
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/healthz" and self.client_address[0] in ("127.0.0.1", "::1"):
            return self.send(200, "ok\n", "text/plain")
        who = self.identify()
        if not who:
            return
        if path == "/":
            return self.home(who)
        if path == "/new":
            return self.new(who)
        m = re.fullmatch(r"/sites/([a-z][a-z0-9-]{0,30})", path)
        if m:
            return self.detail(who, m.group(1))
        m = re.fullmatch(r"/requests/([0-9TZ]+-[0-9a-f]{6})", path)
        if m:
            return self.request_page(who, m.group(1))
        self.fail(404, "No such page.")

    def do_POST(self):
        path = urlparse(self.path).path
        who = self.identify()
        if not who:
            return
        got = self.form(who)
        if not got:
            return
        fields, files = got
        if path == "/new":
            return self.create(who, fields, files)
        m = re.fullmatch(r"/sites/([a-z][a-z0-9-]{0,30})/(upload|delete|token|restore)", path)
        if m:
            return {"upload": self.upload, "delete": self.delete, "token": self.token,
                    "restore": self.restore}[m.group(2)](who, m.group(1), fields, files)
        m = re.fullmatch(r"/deleted/([a-z][a-z0-9-]{0,30})/restore", path)
        if m:
            return self.restore(who, m.group(1), fields, files, deleted=True)
        self.fail(404, "No such page.")

    def home(self, who):
        rows = ""
        for s in self.sites(who):
            insp = load(os.path.join(INSPECT, f"{s['name']}.json"), {})
            owner = f"<td>{esc(s.get('owner', ''))}</td>" if who["admin"] else ""
            rows += (f"<tr><td><a href='/sites/{esc(s['name'])}'>{esc(s['name'])}</a></td>"
                     f"<td><a href='https://{esc(s['domain'])}'>{esc(s['domain'])}</a></td><td>{esc(s['template'])}</td>"
                     f"<td>{pill(s.get('state', '?'))}</td><td>{release_cell(s, insp)}</td>{owner}</tr>")
        owner_h = "<th>Owner</th>" if who["admin"] else ""
        table = (f"<table><tr><th>Site</th><th>Address</th><th>Template</th><th>State</th><th>Latest release</th>{owner_h}</tr>{rows}</table>"
                 "<p class='mute'>Latest release: the security check of your newest content. A blocked release never goes live; "
                 "the last passed one keeps running. Open the site for the findings.</p>"
                 if rows else '<p class="mute">No sites yet.</p>')
        pending = [r for r in self.requests(who) if r.get("status") not in ("live", "rejected", "failed", "done")]
        preq = "".join(f"<li><a href='/requests/{esc(r['id'])}'>{esc(r.get('kind'))} {esc(r.get('site'))}</a> {pill(r.get('status'))}</li>" for r in pending[:10])
        gone = "".join(f"<li><b>{esc(d['name'])}</b> <span class='mute'>{esc(d.get('domain', ''))} · {esc(d.get('template', ''))} · deleted {esc(d.get('deleted', ''))}</span>"
                       f"{restore_form(who, f'/deleted/{esc(d['name'])}/restore', d['backups'][0]['volid'], 'Bring it back from ' + when(d['backups'][0]['time']))}</li>"
                       for d in self.deleted(who))
        body = (f'<h1>Your sites</h1><div class="card">{table}</div><p><a class="btn" href="/new">New site</a></p>'
                + (f"<h2>In progress</h2><div class='card'><ul>{preq}</ul></div>" if preq else "")
                + (f"<h2>Deleted sites</h2><div class='card'><p class='mute'>Their backups are kept; a restored site comes back as it was at that backup.</p><ul>{gone}</ul></div>" if gone else ""))
        self.send(200, page("Sites", who["user"], body))

    def new(self, who, error="", values=None):
        v = values or {}
        def card(t):
            checked = " checked" if v.get("template") == t["name"] else ""
            db = f" · {esc(t['database'])}" if t.get("database") not in (None, "", "none") else ""
            return (f'<label class="tpl"><input type="radio" name="template" value="{esc(t["name"])}"{checked} required>'
                    f'<b>{esc(t.get("label") or t["name"])}</b><small>{esc(t["name"])} · {esc(t["runtime"])}{db}</small><small>{esc(t["summary"])}</small></label>')
        tpls = self.server.conf.get("templates", [])
        cards = ""
        for grp, head in (("sites", "Sites — nothing of yours runs on the server"), ("stacks", "Stacks — your code runs on the server")):
            items = [t for t in tpls if (t.get("group") if t.get("group") in ("sites", "stacks") else "stacks") == grp]
            if items:
                cards += f'<h2>{esc(head)}</h2><div class="tpls">{"".join(card(t) for t in items)}</div>'
        base = self.server.conf.get("base_domain", "")
        err = f'<div class="card err">{esc(error)}</div>' if error else ""
        public = " checked" if v.get("public") else ""
        body = f"""<h1>New site</h1>{err}
<form method="post" action="/new" enctype="multipart/form-data" class="card">
<input type="hidden" name="csrf" value="{who['csrf']}">
<p class="mute">webhost is where you deploy, not where you develop: bring finished files or an app with its dependencies; nothing is built here.</p>
<label class="f">1. Template</label>{cards}
<label class="f" for="name">2. Name</label><input type="text" id="name" name="name" value="{esc(v.get('name', ''))}" required pattern="[a-z][a-z0-9-]{{0,30}}" placeholder="my-site">
<label class="f" for="domain">3. Address</label><input type="text" id="domain" name="domain" value="{esc(v.get('domain', ''))}" placeholder="my-site.{esc(base)}">
<p class="mute">Leave empty for <code>&lt;name&gt;.{esc(base)}</code>.</p>
<label><input type="checkbox" name="public" value="1"{public}> Public on the internet (otherwise only from your own networks)</label>
<label class="f">4. Content</label>
<p class="mute">A repository with the finished files (nothing is built here), or a package (.zip / .tar.gz). WordPress needs neither.</p>
<input type="text" name="repo" value="{esc(v.get('repo', ''))}" placeholder="https://codeberg.org/you/site.git">
<input type="text" name="ref" value="{esc(v.get('ref', 'main'))}" placeholder="branch, e.g. main or release" style="margin-top:6px">
<input type="password" name="token" autocomplete="off" placeholder="access token, for a private repository (optional)" style="margin-top:6px">
<p class="mute">or</p><input type="file" name="package" accept=".zip,.tgz,.tar.gz">
<p style="margin-top:16px"><button class="btn" type="submit">Create site</button></p>
<p class="mute">Every release is inspected before it goes live: server code in static sites, web shells, leaked keys and known critical vulnerabilities in dependencies stop it.</p>
</form>"""
        self.send(200 if not error else 400, page("New site", who["user"], body))

    def create(self, who, fields, files):
        conf = self.server.conf
        tpl = {t["name"]: t for t in conf.get("templates", [])}.get(fields.get("template", ""))
        name = fields.get("name", "")
        domain = fields.get("domain") or f"{name}.{conf.get('base_domain', '')}"
        repo, ref = fields.get("repo", ""), fields.get("ref") or "main"
        pkg = files.get("package")
        has_pkg = bool(pkg and pkg[0] and pkg[1])
        mine = [s for s in self.sites(who) if s.get("owner") == who["user"]]
        taken = {s.get("name") for s in load(os.path.join(DATA, "sites.json"), [])}
        taken |= {r.get("site") for r in self.requests({"admin": True}) if r.get("status") not in ("rejected", "failed")}
        err = None
        if not tpl:
            err = "Pick a template."
        elif not SITE_RE.match(name):
            err = "The name is lowercase letters, digits and hyphens, starting with a letter, at most 31 characters."
        elif name in taken or name.startswith("canary-"):
            err = f"A site named {name} exists or is being created."
        elif not DOMAIN_RE.match(domain):
            err = f"{domain} is not a valid address."
        elif not who["admin"] and len(mine) >= int(conf.get("site_limit", 10)):
            err = f"You have reached the limit of {conf.get('site_limit', 10)} sites."
        elif tpl.get("app") == "wordpress":
            repo, has_pkg = "", False
        elif repo and has_pkg:
            err = "Give a repository or a package, not both."
        elif repo and not (REPO_RE.match(repo) and REF_RE.match(ref) and not ref.startswith("-")):
            err = "The repository must be an https:// address ending in .git, and the branch a plain name."
        elif fields.get("token") and not (repo and TOKEN_RE.fullmatch(fields["token"])):
            err = "An access token goes with a repository, as one line of printable characters."
        elif not repo and not has_pkg:
            err = "Give a repository or upload a package."
        elif has_pkg and not PACKAGE_RE.search(pkg[0]):
            err = "Packages are .zip, .tgz or .tar.gz files."
        if err:
            return self.new(who, err, fields)
        if has_pkg:
            self.save_package(name, who["user"], pkg[0], pkg[1])
        source = {"repo": repo, "ref": ref} if repo else ({"upload": True} if has_pkg else {})
        rid = self.write_request({"kind": "create", "user": who["user"], "groups": who["groups"], "site": name,
                                  "template": tpl["name"], "runtime": tpl["runtime"], "domain": domain,
                                  "public": bool(fields.get("public")), "source": source},
                                 token=fields.get("token") or None)
        self.redirect(f"/requests/{rid}")

    def request_page(self, who, rid):
        r = load(os.path.join(DATA, "requests", f"{rid}.json"), None)
        if not r or not (who["admin"] or r.get("user") == who["user"]):
            return self.fail(404, "No such request.")
        status = r.get("status", "new")
        steps = ["new", "checking", "inspecting", "creating", "live"]
        trail = " → ".join(f"<b>{s}</b>" if s == status else s for s in steps)
        insp = load(os.path.join(INSPECT, f"{r.get('site')}.json"), None) if status in ("inspecting", "rejected", "creating", "live") else None
        if status == "failed":
            msg = f"<p class='failed'>FAILED – {esc(r.get('message', ''))}</p>"
        else:
            msg = f"<p>{esc(r.get('message', ''))}</p>" if r.get("message") else ""
        done = status in ("live", "rejected", "failed", "done")
        if r.get("kind") == "restore":
            steps = ["new", "restoring", "live"]
            trail = " → ".join(f"<b>{s}</b>" if s == status else s for s in steps)
        link = f"<p><a class='btn' href='/sites/{esc(r['site'])}'>Open {esc(r['site'])}</a></p>" if status == "live" else ""
        body = (f"<h1>{esc(r.get('kind'))} {esc(r.get('site'))}</h1><div class='card'><p>{pill(status)} <span class='mute'>{trail}</span></p>{msg}"
                f"{findings_table(insp) if insp else ''}{log_block(rid, status)}</div>{link}"
                + (guide_block(self.server.conf, r.get("template")) if status == "live" else "")
                + ("" if done else "<p class='mute'>This page updates by itself.</p>"))
        self.send(200, page(f"Request {rid}", who["user"], body, refresh=not done))

    def detail(self, who, name):
        s = self.site(who, name)
        if not s:
            return self.fail(404, "No such site, or not yours.")
        insp = load(os.path.join(INSPECT, f"{name}.json"), None)
        src = s.get("source", {})
        if src.get("upload"):
            content = (f"<form method='post' action='/sites/{esc(name)}/upload' enctype='multipart/form-data'>"
                       f"<input type='hidden' name='csrf' value='{who['csrf']}'><input type='file' name='package' accept='.zip,.tgz,.tar.gz' required>"
                       "<p><button class='btn' type='submit'>Upload a new version</button></p></form>")
        elif src.get("repo"):
            content = (f"<p>Push to <code>{esc(src.get('ref', 'main'))}</code> of <code>{esc(src['repo'])}</code>; a passing revision is live within about two minutes.</p>"
                       f"<form method='post' action='/sites/{esc(name)}/token' enctype='multipart/form-data'>"
                       f"<input type='hidden' name='csrf' value='{who['csrf']}'>"
                       "<input type='password' name='token' autocomplete='off' placeholder='new access token (empty removes it)'>"
                       "<p><button class='btn' type='submit'>Set access token</button></p>"
                       "<p class='mute'>For a private repository: a read-only deploy token. It is never shown again.</p></form>")
        else:
            content = "<p>WordPress: manage content in its own admin, reachable from your own networks.</p>"
        body = (f"<h1>{esc(name)}</h1><div class='card'><p><a href='https://{esc(s['domain'])}'>{esc(s['domain'])}</a> · {esc(s['template'])} · {pill(s.get('state', '?'))}"
                f"{' · public' if s.get('public') else ' · your networks only'}</p>{content}</div>"
                f"{guide_block(self.server.conf, s['template'])}"
                f"<h2>Last inspection</h2><div class='card'>{findings_table(insp)}</div>"
                f"<h2>Backups</h2><div class='card'>{self.backup_list(who, name)}</div>"
                f"<h2>Delete</h2><div class='card'><form method='post' action='/sites/{esc(name)}/delete'>"
                f"<input type='hidden' name='csrf' value='{who['csrf']}'><p>Type <b>{esc(name)}</b> to remove the site. Its container goes; its backup stays.</p>"
                f"<input type='text' name='confirm' required><p><button class='btn danger' type='submit'>Delete {esc(name)}</button></p></form></div>")
        self.send(200, page(name, who["user"], body))

    def backup_list(self, who, name):
        pts = backups().get("sites", {}).get(name, [])
        if not pts:
            return "<p class='mute'>No backups yet; they are taken nightly.</p>"
        rows = "".join(f"<li>{esc(when(b['time']))}"
                       f"{restore_form(who, f'/sites/{esc(name)}/restore', b['volid'], 'Put this back; changes since then are lost')}</li>"
                       for b in pts)
        return f"<ul>{rows}</ul>"

    def deleted(self, who):
        return [d for d in backups().get("deleted", []) if d.get("backups") and (who["admin"] or d.get("owner") == who["user"])]

    def restore(self, who, name, fields, files, deleted=False):
        if deleted:
            d = next((d for d in self.deleted(who) if d["name"] == name), None)
            pts = d["backups"] if d else []
            if d and name in {s.get("name") for s in load(os.path.join(DATA, "sites.json"), [])}:
                return self.fail(409, f"A site named {name} exists again; delete it before restoring the old one.")
        else:
            pts = backups().get("sites", {}).get(name, []) if self.site(who, name) else []
        if not pts:
            return self.fail(404, "No such site with backups, or not yours.")
        if fields.get("confirm") != "1" or fields.get("backup") not in {b["volid"] for b in pts}:
            return self.fail(400, "Pick a backup and confirm.")
        rid = self.write_request({"kind": "restore", "user": who["user"], "groups": who["groups"], "site": name,
                                  "backup": fields["backup"]})
        self.redirect(f"/requests/{rid}")

    def upload(self, who, name, fields, files):
        s = self.site(who, name)
        pkg = files.get("package")
        if not s or not s.get("source", {}).get("upload"):
            return self.fail(404, "No such upload site, or not yours.")
        if not pkg or not pkg[1] or not PACKAGE_RE.search(pkg[0]):
            return self.fail(400, "Upload a .zip, .tgz or .tar.gz package.")
        self.save_package(name, who["user"], pkg[0], pkg[1])
        self.redirect(f"/sites/{name}")

    def token(self, who, name, fields, files):
        s = self.site(who, name)
        if not s or not s.get("source", {}).get("repo"):
            return self.fail(404, "No such repository site, or not yours.")
        t = fields.get("token", "")
        if t and not TOKEN_RE.fullmatch(t):
            return self.fail(400, "A token is one line of printable characters.")
        rid = self.write_request({"kind": "token", "user": who["user"], "groups": who["groups"], "site": name}, token=t)
        self.redirect(f"/requests/{rid}")

    def delete(self, who, name, fields, files):
        s = self.site(who, name)
        if not s:
            return self.fail(404, "No such site, or not yours.")
        if fields.get("confirm") != name:
            return self.fail(400, "Type the site's name to delete it.")
        rid = self.write_request({"kind": "delete", "user": who["user"], "groups": who["groups"], "site": name})
        self.redirect(f"/requests/{rid}")


def main():
    conf = load(CONF, {})
    host, port = conf.get("listen", "0.0.0.0:8080").rsplit(":", 1)
    os.makedirs(os.path.join(DATA, "requests"), exist_ok=True)
    os.makedirs(os.path.join(DATA, "tokens"), mode=0o700, exist_ok=True)
    srv = ThreadingHTTPServer((host, int(port)), Portal)
    srv.conf = conf

    def reload_conf():
        srv.conf = load(CONF, srv.conf)
    srv.reload_conf = reload_conf
    orig = Portal.handle_one_request

    def handle(self):
        self.server.reload_conf()
        orig(self)
    Portal.handle_one_request = handle
    srv.serve_forever()


if __name__ == "__main__":
    main()
