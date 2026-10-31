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
RID_RE = re.compile(r"[0-9TZ]+-[0-9a-f]{6}")


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

# The CSP allows inline styles and nothing else: no scripts, no web fonts. What
# changes on a form changes through :has(). Named fonts apply only if installed.
STYLE = """
:root{--bg:#f4f0e6;--soft:#fbf9f4;--card:#fff;--ink:#1e1f1b;--mute:#5f5e55;--line:#e6dfd0;--div:#efe9db;--field:#d8cfbc;
--acc:#1f6b4f;--acc2:#134a36;--ok:#16573f;--okbg:#ddeee3;--calm:#ddebe2;--bad:#8e2518;--badbg:#fbe0dc;--red:#b23a2b;--note:#f5ebcb;--notetx:#4c4023;--warn:#7a4a00;--warnbg:#f8e8c4;
--mono:"DM Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 "Instrument Sans",ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;background:var(--bg);color:var(--ink)}
a{color:var(--acc)}a:hover{color:var(--acc2)}code,.mono{font-family:var(--mono)}
code{font-size:.92em;padding:0 4px;border-radius:4px;background:var(--bg);overflow-wrap:anywhere}
:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
.shell{display:flex;flex-wrap:wrap;min-height:100vh}
.side{flex:1 1 240px;background:var(--soft);border-right:1px solid var(--line);padding:18px 12px;display:flex;flex-direction:column;gap:20px}
.brand{display:flex;align-items:center;gap:10px;padding:0 8px;color:var(--ink);text-decoration:none}.brand b{font:500 15px/18px var(--mono);display:block}.brand small{font-size:12px;color:var(--mute)}
.navh{font-size:12px;color:var(--mute);padding:0 10px 4px}.side nav a{display:block;padding:8px 10px;border-radius:10px;color:var(--ink);text-decoration:none}
.side nav a.on{background:var(--acc);color:#fff;font-weight:600}
.who{display:flex;align-items:center;gap:10px;font-weight:600;font-size:13px;color:var(--ink);overflow-wrap:anywhere}.who span{flex:0 0 30px;height:30px;border-radius:99px;background:var(--note);display:flex;align-items:center;justify-content:center}
.body{flex:999 1 560px;min-width:0}.top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:8px 16px;padding:10px 24px;border-bottom:1px solid var(--line);background:var(--soft);font-size:13px;color:var(--mute)}.top a{color:var(--mute)}.top b{color:var(--ink);font-weight:600}
main{max-width:1200px;padding:28px 24px 48px;display:flex;flex-direction:column;gap:20px}
h1{margin:0;font-size:26px;line-height:1.25;font-weight:500}h1 b{font-weight:700}h1 .mono{font-weight:500}
h2{margin:0;font-size:16px;font-weight:600}h3{margin:0;font-size:14px;font-weight:600}p{margin:0}
.sub{margin-top:6px;font-size:13px;color:var(--mute)}.mute{color:var(--mute)}.small{font-size:13px}.tiny{font-size:12px}
.row{display:flex;flex-wrap:wrap;gap:16px;justify-content:space-between;align-items:flex-start}.row>.grow{flex:1 1 420px;min-width:0}
.cols{display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start}.cols>.wide{flex:999 1 520px;min-width:0;display:flex;flex-direction:column;gap:16px}.cols>.aside{flex:1 1 320px;min-width:0;display:flex;flex-direction:column;gap:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px 20px;display:flex;flex-direction:column;gap:10px}
.card.flush{padding:0;gap:0}.card.flush>h2{padding:16px 20px 8px}.card.flush>p{padding:12px 20px 16px;border-top:1px solid var(--div)}
.card.dangerzone{border-color:#ebc7c1}.inset{padding:14px 16px;border-radius:12px;background:var(--soft);display:flex;flex-direction:column;gap:6px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.tile{padding:14px 16px;border:1px solid var(--line);border-radius:14px;background:var(--card);font-size:13px;color:var(--mute)}
.tile b{display:block;font-size:22px;font-weight:600;color:var(--ink)}.tile small{font-size:12px}
.call{padding:20px 24px;border-radius:16px;display:flex;flex-direction:column;gap:10px}.call.note{background:var(--note);color:var(--notetx)}.call.calm{background:var(--calm);color:var(--acc2)}.call h2{font-size:20px;line-height:1.3;color:var(--ink)}.call.calm h2{color:inherit;font-size:16px}
.acts{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.scroll{overflow-x:auto}table{width:100%;min-width:880px;border-collapse:collapse}th{text-align:left;padding:8px 12px;font-size:12px;font-weight:500;color:var(--mute)}td{padding:12px;border-top:1px solid var(--div);vertical-align:top}th:first-child,td:first-child{padding-left:20px}th:last-child,td:last-child{padding-right:20px}
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:44px;padding:0 18px;border:1px solid var(--acc);border-radius:10px;background:var(--acc);color:#fff;font:inherit;font-weight:600;cursor:pointer;text-decoration:none}.btn:hover{background:var(--acc2);color:#fff}
.btn.ghost{background:var(--card);border-color:var(--line);color:var(--ink)}.btn.ghost:hover{background:var(--soft);color:var(--ink)}.btn.danger{background:var(--red);border-color:var(--red)}.btn.danger:hover{background:var(--bad)}
form:has(input:invalid) .guarded,form:has(input:invalid) .guarded:hover{background:var(--div);border-color:var(--div);color:#6b6a5f;cursor:not-allowed}
.pill{display:inline-block;padding:2px 8px;border-radius:6px;background:var(--div);font:12px/1.4 var(--mono);color:#4f4e45}.pill.ok{background:var(--okbg);color:var(--ok)}.pill.bad{background:var(--badbg);color:var(--bad)}.pill.warn{background:var(--warnbg);color:var(--warn)}
.bar{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);gap:6px}.bar i{height:4px;border-radius:2px;background:var(--line)}.bar i.g{background:var(--acc)}.bar i.r{background:var(--red)}
ol.steps{margin:0;padding:0;list-style:none}.steps li{display:flex;gap:12px;padding-bottom:14px}.steps li:last-child{padding-bottom:0}.steps .dot{flex:0 0 26px;height:26px;border-radius:99px;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;background:var(--div);color:var(--mute)}
.steps .done .dot{background:var(--acc);color:#fff}.steps .now .dot{background:#fff;border:2px solid var(--acc);color:var(--acc)}.steps .stop .dot{background:var(--red);color:#fff}.steps li>div:last-child{flex:1;min-width:0}.step{display:flex;flex-wrap:wrap;gap:4px 10px;justify-content:space-between;align-items:baseline}.step b{font-weight:600}
dl{margin:0;display:grid;grid-template-columns:auto minmax(0,1fr);gap:6px 14px;font-size:13px}dt{color:var(--mute)}dd{margin:0;text-align:right;overflow-wrap:anywhere}
.tpls{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:10px}.tpl{display:block;padding:12px 14px;border:1px solid var(--line);border-radius:12px;background:var(--card);cursor:pointer}.tpl:has(input:checked){outline:2px solid var(--acc);outline-offset:-1px}
.tpl input{accent-color:var(--acc);margin:0 6px 0 0}.tpl small{display:block;font-size:13px;color:var(--mute);margin-top:4px}.tpl small.mono{font-size:12px;margin-top:0}.tpl small.good{color:var(--ok);margin-top:6px}
.fields{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}.fields .all{grid-column:1/-1}
label.f{display:flex;flex-direction:column;gap:4px;font-weight:600}label.f small{font-weight:400;font-size:12px;color:var(--mute)}
input[type=text],input[type=password]{width:100%;min-height:44px;padding:0 12px;border:1px solid var(--field);border-radius:10px;background:var(--soft);color:var(--ink);font:400 14px var(--mono)}
input[type=file]{font:inherit;font-weight:400}.tick{display:flex;gap:10px;align-items:flex-start;cursor:pointer}.tick input{width:18px;height:18px;margin:1px 0 0;accent-color:var(--acc);flex:none}.box{padding:12px;border:1px solid var(--line);border-radius:10px;display:flex;flex-direction:column;gap:8px}
.tabs{display:inline-flex;align-self:flex-start;padding:3px;border-radius:10px;background:var(--div)}.tabs label{min-height:38px;padding:0 14px;border-radius:8px;display:flex;align-items:center;font-weight:600;cursor:pointer}.tabs input{position:absolute;opacity:0}.tabs label:has(input:checked){background:var(--card)}.tabs label:has(input:focus-visible){outline:2px solid var(--acc)}
.pane-src,.pane-git{display:flex;flex-direction:column;gap:12px}.pane-pkg,.pane-wp{display:none}form:has(#mode-package:checked) .pane-pkg{display:flex}form:has(#mode-package:checked) .pane-git{display:none}form:has(input[data-wp]:checked) .pane-wp{display:block}form:has(input[data-wp]:checked) .pane-src{display:none}
.drop{padding:20px;border:1px dashed #bdb29a;border-radius:10px;background:var(--soft);flex-direction:column;gap:4px;font-weight:600}.drop small{font-weight:400;font-size:13px;color:var(--mute)}
.guide{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px;font-size:13px}.guide>div{padding:14px;border:1px solid var(--div);border-radius:12px}.guide h3{margin-bottom:6px}.guide ul{margin:0;padding-left:16px;display:flex;flex-direction:column;gap:5px}
ul.files{margin:0;padding:0;list-style:none;border:1px solid var(--div);border-radius:10px;font:13px var(--mono)}.files li{display:flex;flex-wrap:wrap;justify-content:space-between;gap:4px 12px;padding:8px 12px;border-top:1px solid var(--div);overflow-wrap:anywhere}.files li:first-child{border-top:0}.files span{color:var(--mute);font-family:inherit}
ol.next{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:6px;font-size:13px}ul.plain{margin:0;padding:0;list-style:none;display:flex;flex-direction:column;gap:10px}
pre.log{margin:6px 0 0;max-height:420px;overflow:auto;padding:12px;border-radius:10px;background:#13261f;color:var(--calm);font:12px/1.45 var(--mono);white-space:pre-wrap;word-break:break-word}
.path{padding:10px 12px;border-radius:10px;background:#13261f;color:var(--calm);font:12px var(--mono);overflow-wrap:anywhere}details summary{cursor:pointer;font-weight:600;min-height:24px}
"""

STATE_CLASS = {"live": "ok", "active": "ok", "pass": "ok", "passed": "ok", "done": "ok", "blocked": "bad", "rejected": "bad", "failed": "bad", "block": "bad",
               "quarantined": "warn", "warn": "warn"}
LIVE_STATES = ("live", "active")

# What a blocking rule means to the person who has to fix it.
RULES = {
    "server-code-in-static": ("Server code in a static site",
                              "A static site only serves finished files. Code meant to run on a server would be served as source.",
                              "Remove the server code, or ship only the built output (e.g. <code>dist/</code>). If the site needs that code, create a new site with a stack template."),
    "executable-in-static": ("A program in a static site", "A static site only serves files, and programs have no place in it.",
                             "Remove the executable from the release."),
    "symlink-outside": ("A link that points outside the release", "A symbolic link leads out of your content, which could expose other files.",
                        "Remove the link, or copy the file it points to into the release."),
    "file-too-large": ("A file is too large", "One file may be at most 100 MB.", "Remove the file or make it smaller."),
    "release-too-large": ("The release is too large", "A release may be at most 2 GB in total.", "Leave out what the site does not need."),
    "web-shell": ("A possible web shell", "This code would let someone run commands on the server through a web request.",
                  "Remove the code. If you did not put it there, find out how it got into your content."),
    "secret": ("A leaked key", "A private key or token is in your content, where others could read it.",
               "Remove it and replace the key where it was issued: treat the old one as exposed."),
    "package-refused": ("The package could not be read", "webhost could not unpack this package safely.", "Check the file and upload the package again."),
    "vulnerable-dependency": ("A dependency with a known critical vulnerability", "A package your app uses has a published critical security flaw.",
                              "Update the package to a fixed version and ship the new lockfile."),
}

MARK = ('<svg width="30" height="30" viewBox="0 0 30 30" aria-hidden="true"><rect x="3" y="5" width="24" height="20" rx="5" fill="#1f6b4f"/>'
        '<rect x="3" y="11" width="24" height="2" fill="#ddebe2"/><circle cx="7.5" cy="8" r="1.2" fill="#ddebe2"/><circle cx="11.5" cy="8" r="1.2" fill="#ddebe2"/></svg>')

STEPS = {
    "create": [("new", "New", "Your request is saved. webhost picks it up within a minute."),
               ("checking", "Checking", "webhost checks the name, the address and the template."),
               ("inspecting", "Inspecting", "Your content is fetched and searched for server code in static sites, web shells, leaked keys and known critical vulnerabilities."),
               ("creating", "Creating", "Your site gets its own container and, if the template has one, its database. This takes two to three minutes."),
               ("live", "Live", "The address answers and your site is running.")],
    "restore": [("new", "New", "Your request is saved. webhost picks it up within a minute."),
                ("restoring", "Restoring", "The site is put back as it was at the backup. This takes a few minutes."),
                ("live", "Live", "The site is running again.")],
    "delete": [("new", "New", "Your request is saved. webhost picks it up within a minute."),
               ("deleting", "Deleting", "The container is removed. The backup stays."),
               ("done", "Done", "The site is gone. It can come back from its backup.")],
    "token": [("new", "New", "Your request is saved. webhost picks it up within a minute."),
              ("done", "Done", "The next fetch uses the new token.")],
}


def esc(v):
    return html.escape(str(v), quote=True)


def pill(state):
    return f'<span class="pill {STATE_CLASS.get(state, "")}">{esc(state)}</span>'


def page(title, who, body, refresh=False, crumb="", nav="sites"):
    meta = '<meta http-equiv="refresh" content="8">' if refresh else ""
    me = f'<div class="who"><span aria-hidden="true">{esc(who[:1].upper())}</span>{esc(who)}</div>' if who else ""
    trail = f' / <b>{esc(crumb)}</b>' if crumb else ""
    on = {k: ' class="on" aria-current="page"' if k == nav else "" for k in ("sites", "new")}
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">{meta}<title>{esc(title)} · webhost</title>
<style>{STYLE}</style></head><body><div class="shell"><div class="side"><a class="brand" href="/">{MARK}<span><b>webhost</b><small>Self-hosted websites</small></span></a>
<nav aria-label="webhost"><div class="navh">Websites</div><a href="/"{on['sites']}>Sites</a><a href="/new"{on['new']}>New site</a></nav></div>
<div class="body"><div class="top"><div><a href="/">Sites</a>{trail}</div>{me}</div><main>{body}</main></div></div></body></html>"""


def plural(n, word):
    return f"{n} {word}" + ("" if n == 1 else "s")


def blocked_rules(insp):
    """{rule: [findings]} of what stopped a release, in a stable order."""
    out = {}
    for f in (insp or {}).get("findings", []):
        if f.get("level") == "block":
            out.setdefault(f.get("rule", "?"), []).append(f)
    return dict(sorted(out.items()))


def rule_title(rule):
    return RULES.get(rule, (rule,))[0]


def release_cell(site, insp):
    if not site.get("source"):
        return "<span class='mute'>not applicable</span>"
    v = insp.get("verdict")
    if v == "block":
        found = blocked_rules(insp)
        n = sum(len(fs) for fs in found.values())
        keep = "<span class='small' style='display:block;color:var(--ok)'>Last passed release still running</span>" if site.get("state") in LIVE_STATES else ""
        return (f"{pill('blocked')}<span class='small mute' style='display:block;margin-top:4px'>"
                f"{esc(', '.join(rule_title(r) for r in found))} · {plural(n, 'finding')}</span>{keep}")
    return {"pass": pill("passed")}.get(v, "<span class='mute'>not inspected yet</span>")


def backups():
    return load(os.path.join(DATA, "backups.json"), {"sites": {}, "deleted": []})


def when(ts):
    return time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(int(ts)))


def restore_form(who, action, volid, label):
    return (f"<form class='box' method='post' action='{action}' enctype='multipart/form-data'>"
            f"<input type='hidden' name='csrf' value='{who['csrf']}'><input type='hidden' name='backup' value='{esc(volid)}'>"
            f"<label class='tick small'><input type='checkbox' name='confirm' value='1' required><span>{label}</span></label>"
            "<button class='btn guarded' type='submit'>Restore this backup</button></form>")


def guide_text(text):
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", esc(text))


def guide_block(conf, template):
    t = {t["name"]: t for t in conf.get("templates", [])}.get(template) or {}
    # Built-in templates group their guide; a custom template's may be a flat list.
    flat = [g for g in t.get("guide", []) if isinstance(g, str)]
    groups = [g for g in t.get("guide", []) if isinstance(g, dict)] + ([{"group": "", "items": flat}] if flat else [])
    cards = "".join((f"<h3>{esc(g.get('group', ''))}</h3>" if g.get("group") else "").join(("<div>", ""))
                    + "<ul>" + "".join(f"<li>{guide_text(i)}</li>" for i in g.get("items", [])) + "</ul></div>" for g in groups)
    if not cards:
        return ""
    return ("<section class='card'><div><h2>What your site gets</h2><p class='small mute'>What this template gives you, and what it expects from you.</p></div>"
            f"<div class='guide'>{cards}</div></section>")


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
        return f"<section class='card'><h2>Progress</h2><pre class='log'>{esc(tail)}</pre></section>"
    return f"<section class='card'><details><summary>Show the log</summary><pre class='log'>{esc(text)}</pre></details></section>"


def inspection_line(result):
    if not result:
        return '<p class="small mute">Not inspected yet.</p>'
    return (f"<p class='mono tiny mute'>{esc(result.get('checked', ''))}<br>revision {esc((result.get('rev') or '')[:12])}</p>")


def inspection_card(result, title="Last inspection"):
    badge = pill(result.get("verdict", "?")) if result else ""
    warns = [f for f in (result or {}).get("findings", []) if f.get("level") != "block"]
    extra = "" if warns or (result or {}).get("verdict") != "pass" else "<p class='small'>No findings.</p>"
    if warns:
        extra = "<ul class='files'>" + "".join(f"<li>{esc(f.get('file'))}<span>{esc(f.get('rule'))}: {esc(f.get('detail'))}</span></li>" for f in warns) + "</ul>"
    return f"<section class='card'><div class='row' style='align-items:center'><h2>{esc(title)}</h2>{badge}</div>{extra}{inspection_line(result)}</section>"


def findings_block(result, after):
    """What stopped a release, and how to fix it. `after` is the last fix step."""
    out = ""
    for rule, found in blocked_rules(result).items():
        title, why, fix = RULES.get(rule, (rule, "Inspection stopped this release.", "Fix what the findings name."))
        rows = "".join(f"<li>{esc(f.get('file'))}<span>{esc(f.get('detail'))}</span></li>" for f in found[:5])
        more = ("<details><summary>" + f"Show all {len(found)} findings</summary><ul class='files'>"
                + "".join(f"<li>{esc(f.get('file'))}<span>{esc(f.get('detail'))}</span></li>" for f in found) + "</ul></details>") if len(found) > 5 else ""
        out += (f"<section class='card'><div class='acts'>{pill('blocked')}<h2 style='font-size:18px'>{esc(title)}</h2><span class='small mute'>{plural(len(found), 'finding')} · <span class='mono'>{esc(rule)}</span></span></div>"
                f"<p>{why}</p><ul class='files'>{rows}</ul>{more}"
                f"<div class='inset'><h3>How to fix it</h3><ol class='next'><li>{fix}</li><li>{after}</li></ol></div></section>")
    return out


def pull_log(site):
    """The newest revisions the mirror fetched, and when it last looked."""
    base = os.path.join(INSPECT, site)
    try:
        with open(f"{base}.history.jsonl", encoding="utf-8") as fh:
            rows = [json.loads(line) for line in fh if line.strip()]
    except (OSError, ValueError):
        rows = []
    try:
        looked = when(os.path.getmtime(f"{base}.fetched"))
    except OSError:
        looked = ""
    items = "".join(f"<li>{esc(r.get('checked', ''))} <span>{esc((r.get('rev') or '')[:12])}</span> "
                    f"{pill('passed' if r.get('verdict') == 'pass' else 'blocked')}</li>" for r in reversed(rows))
    log = f"<ul class='files' style='font-size:12px'>{items}</ul>" if items else "<p class='small mute'>Nothing yet. The next new revision shows up here.</p>"
    last = f"<p class='tiny mute'>Last looked for changes: {esc(looked)}</p>" if looked else ""
    return ("<section class='card'><div><h2>Recent pulls</h2><p class='small mute'>Each new revision webhost fetched. Passed ones go live; blocked ones do not.</p></div>"
            f"{log}{last}</section>")


def stepper(r, status, stopped_at=None):
    """The pipeline; `stopped_at` is the step that failed or was blocked."""
    steps = STEPS.get(r.get("kind"), STEPS["create"])
    if r.get("kind") == "create" and not r.get("source"):
        steps = [s for s in steps if s[0] != "inspecting"]
    keys = [s[0] for s in steps]
    finished = status in ("live", "done")
    at = keys.index(stopped_at) if stopped_at in keys else (keys.index(status) if status in keys else 0)
    bar, items = "", ""
    for i, (key, label, what) in enumerate(steps):
        if finished or i < at:
            cls, note, mark, seg = "done", "Done", "✓", "g"
        elif i == at and stopped_at:
            blocked = status == "rejected"
            cls, note, mark, seg = "stop", "Blocked here" if blocked else "Failed here", "!", "r"
        elif i == at:
            cls, note, mark, seg = "now", "Now", str(i + 1), "g"
        else:
            cls, note, mark, seg = "", "Did not run" if stopped_at else "", str(i + 1), ""
        current = ' aria-current="step"' if cls in ("now", "stop") else ""
        bar += f"<i class='{seg}'></i>"
        items += (f"<li class='{cls}'{current}><div class='dot' aria-hidden='true'>{mark}</div><div><div class='step'><b>{label}</b>"
                  f"<span class='tiny mute'>{note}</span></div><div class='small mute'>{what}</div></div></li>")
    return f"<section class='card' aria-label='Progress'><div class='bar' aria-hidden='true'>{bar}</div><ol class='steps'>{items}</ol></section>"


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
        self.send(code, page("Error", "", f'<div class="card"><h1><b>{code}</b></h1><p>{esc(msg)}</p><p><a href="/">Back</a></p></div>'))

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
        url = urlparse(self.path)
        path = url.path
        if path == "/healthz" and self.client_address[0] in ("127.0.0.1", "::1"):
            return self.send(200, "ok\n", "text/plain")
        who = self.identify()
        if not who:
            return
        if path == "/":
            return self.home(who)
        if path == "/new":
            return self.new(who, query=parse_qs(url.query))
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
        m = re.fullmatch(r"/requests/([0-9TZ]+-[0-9a-f]{6})/retry", path)
        if m:
            return self.retry(who, m.group(1))
        m = re.fullmatch(r"/deleted/([a-z][a-z0-9-]{0,30})/restore", path)
        if m:
            return self.restore(who, m.group(1), fields, files, deleted=True)
        self.fail(404, "No such page.")

    def home(self, who):
        sites = self.sites(who)
        rows, calls, passed, blocked = "", "", 0, 0
        for s in sites:
            insp = load(os.path.join(INSPECT, f"{s['name']}.json"), {})
            stopped = bool(s.get("source")) and insp.get("verdict") == "block"
            passed += bool(s.get("source")) and insp.get("verdict") == "pass"
            blocked += stopped
            owner = f"<td>{esc(s.get('owner') or 'None')}</td>" if who["admin"] else ""
            link = f"/sites/{esc(s['name'])}"
            action = (f"<a class='btn ghost' href='{link}' style='background:var(--div);border-color:var(--div)'>See what to fix</a>" if stopped
                      else f"<a class='btn ghost' href='{link}'>Open</a>")
            rows += (f"<tr><td><a class='mono' style='color:inherit' href='{link}'>{esc(s['name'])}</a></td>"
                     f"<td><a href='https://{esc(s['domain'])}'>{esc(s['domain'])}</a></td><td class='mono small'>{esc(s['template'])}</td>"
                     f"<td>{pill(s.get('state', '?'))}</td><td>{release_cell(s, insp)}</td>{owner}<td style='text-align:right;white-space:nowrap'>{action}</td></tr>")
            if stopped:
                found = blocked_rules(insp)
                n = sum(len(fs) for fs in found.values())
                calls += (f"<section class='call note'><div class='small'>Needs a person</div><h2><span class='mono'>{esc(s['name'])}</span>: the newest release stopped at inspection.</h2>"
                          f"<p>Visitors still see the last release that passed. Inspection found {esc(', '.join(rule_title(r).lower() for r in found))}, {plural(n, 'finding')} in all. Nothing goes live until that is fixed.</p>"
                          f"<div class='acts'><a class='btn' href='{link}'>See what to fix</a></div></section>")
        live = sum(1 for s in sites if s.get("state") in LIVE_STATES)
        owner_h = "<th>Owner</th>" if who["admin"] else ""
        table = (f"<section class='card flush'><h2>Your sites</h2><div class='scroll'><table><tr><th>Site</th><th>Address</th><th>Template</th><th>State</th><th>Latest release</th>{owner_h}<th><span class='mute'>Action</span></th></tr>{rows}</table></div>"
                 "<p class='small mute'>Latest release is the security check of your newest content. A blocked release never goes live; the last passed one keeps running. Open a site for its findings.</p></section>"
                 if rows else "<section class='card'><h2>No sites yet</h2><p class='mute'>Create your first site: pick a template, then bring finished files or an app.</p><div class='acts'><a class='btn' href='/new'>New site</a></div></section>")
        if not sites:
            head = "<b>No sites yet.</b>"
        else:
            lead = f"Your {plural(len(sites), 'site')} {'is' if len(sites) == 1 else 'are'} live." if live == len(sites) else f"{live} of {plural(len(sites), 'site')} {'is' if live == 1 else 'are'} live."
            rest = (f"{plural(blocked, 'new release')} {'was' if blocked == 1 else 'were'} stopped before reaching visitors." if blocked else "Nothing needs you right now.")
            head = f"<b>{lead}</b> {rest}"
        tiles = ""
        if sites:
            tiles = (f"<div class='tiles'><div class='tile'>Sites<b>{live} live</b><small>{plural(len(sites) - live, 'other')}</small></div>"
                     f"<div class='tile'>Latest releases<b>{passed} · {blocked}</b><small>passed · blocked</small></div>"
                     f"<div class='tile'>Needs a person<b>{plural(blocked, 'site')}</b><small>{'live version not affected' if blocked else 'all clear'}</small></div></div>")
        pending = [r for r in self.requests(who) if r.get("status") not in ("live", "rejected", "failed", "done")]
        preq = "".join(f"<li><a href='/requests/{esc(r['id'])}'>{esc(r.get('kind'))} {esc(r.get('site'))}</a> {pill(r.get('status'))}</li>" for r in pending[:10])
        gone = "".join(f"<li><b class='mono'>{esc(d['name'])}</b> <span class='small mute'>{esc(d.get('domain', ''))} · {esc(d.get('template', ''))} · deleted {esc(d.get('deleted', ''))}</span>"
                       f"{restore_form(who, f'/deleted/{esc(d['name'])}/restore', d['backups'][0]['volid'], 'Bring it back from ' + when(d['backups'][0]['time']))}</li>"
                       for d in self.deleted(who))
        body = (f"<div class='row'><div class='grow'><h1>{head}</h1><p class='sub'>Each site runs in its own container. webhost inspects every release before it goes live.</p></div>"
                f"<a class='btn' href='/new'>New site</a></div>{tiles}{calls}{table}"
                + (f"<section class='card'><h2>In progress</h2><ul class='plain'>{preq}</ul></section>" if preq else "")
                + (f"<section class='card'><h2>Deleted sites</h2><p class='small mute'>Their backups are kept; a restored site comes back as it was at that backup.</p><ul class='plain'>{gone}</ul></section>" if gone else ""))
        self.send(200, page("Sites", who["user"], body))

    def new(self, who, error="", values=None, query=None):
        v = values or {}
        if not values and query and query.get("from"):
            # Back from a failed or refused request: its settings, without secrets.
            rid = query["from"][0]
            r = load(os.path.join(DATA, "requests", f"{rid}.json"), None) if RID_RE.fullmatch(rid) else None
            if r and r.get("kind") == "create" and (who["admin"] or r.get("user") == who["user"]):
                src = r.get("source") or {}
                v = {"template": r.get("template"), "name": r.get("site"), "domain": r.get("domain"), "public": r.get("public"),
                     "repo": src.get("repo", ""), "ref": src.get("ref", "main"), "mode": "package" if src.get("upload") else "git"}

        def card(t):
            checked = " checked" if v.get("template") == t["name"] else ""
            db = f" · {esc(t['database'])}" if t.get("database") not in (None, "", "none") else ""
            wp = " data-wp" if t.get("app") == "wordpress" else ""
            good = f'<small class="good">Good for: {esc(t["hint"])}</small>' if t.get("hint") else ""
            return (f'<label class="tpl"><input type="radio" id="t-{esc(t["name"])}" name="template" value="{esc(t["name"])}"{checked}{wp} required>'
                    f'<b>{esc(t.get("label") or t["name"])}</b><small class="mono">{esc(t["name"])} · {esc(t["runtime"])}{db}</small>{good}<small>{esc(t["summary"])}</small></label>')
        tpls = self.server.conf.get("templates", [])
        cards = ""
        for grp, head, sub in (("sites", "Sites", "Nothing of yours runs on the server."), ("stacks", "Stacks", "Your code runs on the server.")):
            items = [t for t in tpls if (t.get("group") if t.get("group") in ("sites", "stacks") else "stacks") == grp]
            if items:
                cards += f'<div><h3>{esc(head)}</h3><p class="small mute" style="margin-bottom:8px">{esc(sub)}</p><div class="tpls">{"".join(card(t) for t in items)}</div></div>'
        base = self.server.conf.get("base_domain", "")
        err = f'<section class="call note" role="alert"><h2 style="font-size:16px">That did not work</h2><p>{esc(error)}</p></section>' if error else ""
        public = " checked" if v.get("public") else ""
        package = v.get("mode") == "package"
        again = ("<p class='small mute'>Secrets and packages are not kept: give the access token or the package again.</p>" if v.get("name") and not error else "")
        body = f"""<div><h1><b>New site.</b> Bring finished files or an app with its dependencies.</h1>
<p class="sub">webhost is where you deploy, not where you develop. Nothing is built here.</p></div>{err}
<form method="post" action="/new" enctype="multipart/form-data" class="cols">
<input type="hidden" name="csrf" value="{who['csrf']}">
<div class="wide">
<section class="card"><h2>1. Template</h2>{cards}</section>
<section class="card"><h2>2. Name and address</h2><div class="fields">
<label class="f">Name<input type="text" name="name" value="{esc(v.get('name', ''))}" required pattern="[a-z][a-z0-9-]{{0,30}}" placeholder="my-site"></label>
<label class="f">Address<input type="text" name="domain" value="{esc(v.get('domain', ''))}" placeholder="my-site.{esc(base)}"></label></div>
<p class="small mute">Leave the address empty to use <code>&lt;name&gt;.{esc(base)}</code>.</p>
<label class="tick box" style="flex-direction:row"><input type="checkbox" name="public" value="1"{public}><span><b>Public on the internet</b><span class="small mute" style="display:block">Anyone on the internet can reach the site. Leave it off to allow only your own networks.</span></span></label></section>
<section class="card"><h2>3. Content</h2>
<p class="pane-wp small" style="padding:12px;border-radius:10px;background:var(--calm);color:var(--acc2)">WordPress needs neither a repository nor a package. You add content in WordPress itself.</p>
<div class="pane-src">
<div class="tabs" role="radiogroup" aria-label="Where the content comes from"><label><input type="radio" id="mode-git" name="mode" value="git"{'' if package else ' checked'}>Git repository</label><label><input type="radio" id="mode-package" name="mode" value="package"{' checked' if package else ''}>Uploaded package</label></div>
<div class="pane-git"><p class="small mute">A repository with the finished files. Nothing is built here.</p><div class="fields">
<label class="f all">Repository<input type="text" name="repo" value="{esc(v.get('repo', ''))}" placeholder="https://codeberg.org/you/site.git"></label>
<label class="f">Branch<input type="text" name="ref" value="{esc(v.get('ref', 'main'))}" placeholder="main"></label>
<label class="f">Access token <small>Only for a private repository</small><input type="password" name="token" autocomplete="off"></label></div>
<p class="small mute">Use a read-only deploy token. It is stored and never shown again.</p></div>
<label class="pane-pkg drop">Choose a package<small>A .zip, .tgz or .tar.gz with the finished files.</small><input type="file" name="package" accept=".zip,.tgz,.tar.gz"></label>
</div>{again}</section></div>
<aside class="aside"><section class="card"><div class="small mute">Before you create</div>
<div class="small" style="padding:12px;border-radius:10px;background:var(--calm);color:var(--acc2)"><b>Every release is inspected before it goes live.</b> Server code in static sites, web shells, leaked keys and known critical vulnerabilities in dependencies stop it.</div>
<button class="btn" type="submit">Create site</button>
<p class="tiny mute">Creating takes about two to three minutes. You can follow each step on the next page.</p></section></aside></form>"""
        self.send(200 if not error else 400, page("New site", who["user"], body, crumb="New site", nav="new"))

    def create(self, who, fields, files):
        conf = self.server.conf
        tpl = {t["name"]: t for t in conf.get("templates", [])}.get(fields.get("template", ""))
        name = fields.get("name", "")
        domain = fields.get("domain") or f"{name}.{conf.get('base_domain', '')}"
        repo, ref = fields.get("repo", ""), fields.get("ref") or "main"
        pkg = files.get("package")
        has_pkg = bool(pkg and pkg[0] and pkg[1])
        # The form hides the source not chosen; what stayed in it does not count.
        if fields.get("mode") == "package":
            repo, fields["token"] = "", ""
        elif fields.get("mode") == "git":
            has_pkg = False
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
        status, kind, site = r.get("status", "new"), r.get("kind"), r.get("site")
        done = status in ("live", "rejected", "failed", "done")
        insp = load(os.path.join(INSPECT, f"{site}.json"), None) if status in ("inspecting", "rejected", "creating", "live") else None
        stopped = bool(insp) and insp.get("verdict") == "block" and str(r.get("message", "")).startswith("The inspection blocked")
        msg = esc(r.get("message", ""))
        name = f"<span class='mono'>{esc(site)}</span>"
        if status == "failed":
            at = {"restore": "restoring", "delete": "deleting"}.get(kind, "creating")
        elif status == "rejected":
            at = "inspecting" if stopped else ("checking" if kind == "create" else "new")
        else:
            at = None
        top, side = "", ""
        verb = {"create": "Creating", "restore": "Restoring", "delete": "Deleting", "token": "Saving the token of"}.get(kind, "Working on")
        if status == "failed" and kind == "create":
            head = f"{name} <b>was not created.</b> Setting up the site is what stopped."
            acts = (f"<form method='post' action='/requests/{esc(rid)}/retry' style='display:contents'><input type='hidden' name='csrf' value='{who['csrf']}'>"
                    f"<button class='btn' type='submit'>Try creating {esc(site)} again</button></form>") if self.retryable(r) else f"<a class='btn' href='/new?from={esc(rid)}'>Try creating {esc(site)} again</a>"
            same = ("Trying again uses the same name, address, template and content." if self.retryable(r)
                    else "This opens the form with your settings. Give the access token or package again: they are not kept.")
            top = (f"<section class='call note'><div class='acts'><span class='pill bad'>FAIL</span><h2>The site’s container could not be set up.</h2></div><p>{msg}</p>"
                   f"<p>Nothing went live, and visitors see nothing at this address yet.</p><div class='acts'>{acts}<a class='btn ghost' href='/new?from={esc(rid)}'>Change the settings</a></div><p class='small'>{same}</p></section>")
            side = ("<section class='card'><h2>What to do next</h2><ol class='next'><li>Try again. It takes two to three minutes.</li><li>If it stops at the same step, ask an administrator and give them the log.</li></ol></section>"
                    f"<section class='card'><h3>For an administrator</h3><p class='small mute'>Log on the mothership</p><div class='path'>/home/tappaas/logs/webhost-{esc(site)}-create.log</div></section>")
        elif status == "failed":
            head = f"{name} <b>did not finish.</b>"
            top = f"<section class='call note'><div class='acts'><span class='pill bad'>FAIL</span><h2>{esc(kind)} failed.</h2></div><p>{msg}</p><div class='acts'><a class='btn' href='/'>Back to your sites</a></div></section>"
        elif status == "rejected" and stopped:
            head = f"{name} <b>is not live yet.</b> Its first release was blocked at inspection."
            top = ("<section class='call note'><h2 style='font-size:16px'>Nothing is running at this address yet.</h2><p>The site goes live with the first release that passes inspection.</p>"
                   f"<div class='acts'><a class='btn' href='/new?from={esc(rid)}'>Fix it and create the site again</a></div></section>"
                   + findings_block(insp, "Then create the site again. The new release is inspected by itself."))
            insp = None
        elif status == "rejected":
            head = f"{name} <b>could not be accepted.</b>"
            again = f"<a class='btn' href='/new?from={esc(rid)}'>Change the settings</a>" if kind == "create" else "<a class='btn' href='/'>Back to your sites</a>"
            top = f"<section class='call note'><h2 style='font-size:16px'>The request was refused.</h2><p>{msg}</p><div class='acts'>{again}</div></section>"
        elif status == "live" and kind == "create":
            head = f"{name} <b>is live.</b> It passed inspection." if r.get("source") else f"{name} <b>is live.</b>"
            domain = esc(r.get("domain", ""))
            reach = "Anyone on the internet can reach this address." if r.get("public") else "Only your own networks can reach this address."
            top = (f"<section class='call calm'><div class='row' style='align-items:center'><div class='grow'><div class='mono' style='font-size:18px;overflow-wrap:anywhere'>{domain}</div><p>{reach}</p></div>"
                   f"<div class='acts'><a class='btn' href='https://{domain}'>Open {esc(site)}</a><a class='btn ghost' href='/sites/{esc(site)}'>Go to site page</a></div></div></section>")
        elif done:
            head = f"{name} <b>is done.</b> {msg}"
            top = f"<div class='acts'><a class='btn' href='{'/' if kind == 'delete' else f'/sites/{esc(site)}'}'>{'Back to your sites' if kind == 'delete' else f'Open {esc(site)}'}</a></div>"
        else:
            head = f"<b>{verb}</b> {name}. <span>{msg}</span>"
        summary = ""
        if kind == "create":
            src = r.get("source") or {}
            content = f"{esc(src.get('ref', 'main'))} of {esc(src['repo'])}" if src.get("repo") else ("Uploaded package" if src.get("upload") else "None needed")
            summary = (f"<section class='card'><div><div class='tiny mute'>New site</div><div class='mono' style='font-size:20px;font-weight:500'>{esc(site)}</div></div>"
                       f"<dl><dt>Template</dt><dd class='mono'>{esc(r.get('template', ''))}</dd><dt>Address</dt><dd class='mono'>{esc(r.get('domain', ''))}</dd>"
                       f"<dt>Reachable from</dt><dd>{'The internet' if r.get('public') else 'Your networks only'}</dd><dt>Content</dt><dd class='mono'>{content}</dd></dl></section>")
        guide = guide_block(self.server.conf, r.get("template")) if status == "live" else ""
        wide = f"{stepper(r, status, at)}{log_block(rid, status)}{guide}"
        aside = side + (inspection_card(insp, "Inspection") if insp else "") + summary
        wait = "" if done else "<p role='status' class='sub'>This page updates by itself.</p>"
        body = f"<div><h1>{head}</h1>{wait}</div>{top}<div class='cols'><div class='wide'>{wide}</div><aside class='aside'>{aside}</aside></div>"
        self.send(200, page(f"Request {rid}", who["user"], body, refresh=not done, crumb=f"{kind} {site}"))

    @staticmethod
    def retryable(r):
        # The sync takes tokens and packages away, so those need giving again.
        return not r.get("token") and not (r.get("source") or {}).get("upload")

    def retry(self, who, rid):
        r = load(os.path.join(DATA, "requests", f"{rid}.json"), None)
        if not r or not (who["admin"] or r.get("user") == who["user"]):
            return self.fail(404, "No such request.")
        if r.get("kind") != "create" or r.get("status") != "failed":
            return self.fail(409, "Only a failed create can be tried again.")
        if not self.retryable(r):
            return self.redirect(f"/new?from={rid}")
        conf = self.server.conf
        tpl = {t["name"]: t for t in conf.get("templates", [])}.get(r.get("template", ""))
        site = r.get("site", "")
        taken = {s.get("name") for s in load(os.path.join(DATA, "sites.json"), [])}
        taken |= {q.get("site") for q in self.requests({"admin": True}) if q.get("status") not in ("rejected", "failed")}
        mine = [s for s in self.sites(who) if s.get("owner") == who["user"]]
        if not tpl:
            return self.fail(409, "That template is no longer offered.")
        if site in taken:
            return self.fail(409, f"A site named {site} exists or is being created.")
        if not who["admin"] and len(mine) >= int(conf.get("site_limit", 10)):
            return self.fail(409, f"You have reached the limit of {conf.get('site_limit', 10)} sites.")
        # An administrator retrying someone's site must not become its owner.
        new = self.write_request({"kind": "create", "user": r.get("user"), "groups": r.get("groups", []), "site": site, "template": tpl["name"],
                                  "runtime": tpl["runtime"], "domain": r.get("domain"), "public": bool(r.get("public")), "source": r.get("source") or {}})
        self.redirect(f"/requests/{new}")

    def detail(self, who, name):
        s = self.site(who, name)
        if not s:
            return self.fail(404, "No such site, or not yours.")
        insp = load(os.path.join(INSPECT, f"{name}.json"), None)
        src = s.get("source", {})
        state = s.get("state", "?")
        running = state in LIVE_STATES
        stopped = bool(src) and bool(insp) and insp.get("verdict") == "block"
        if src.get("upload"):
            content = ("<h2>How to update this site</h2>"
                       f"<form class='box' method='post' action='/sites/{esc(name)}/upload' enctype='multipart/form-data'>"
                       f"<input type='hidden' name='csrf' value='{who['csrf']}'><p class='small mute'>A new package is inspected, and goes live only if it passes.</p>"
                       "<input type='file' name='package' accept='.zip,.tgz,.tar.gz' required><div class='acts'><button class='btn' type='submit'>Upload a new version</button></div></form>")
        elif src.get("repo"):
            content = (f"<h2>How to update this site</h2><p>Push to <code>{esc(src.get('ref', 'main'))}</code> of <code>{esc(src['repo'])}</code>. A passing revision is live within about two minutes.</p>"
                       "<div class='inset'><details><summary>Replace access token</summary>"
                       f"<form method='post' action='/sites/{esc(name)}/token' enctype='multipart/form-data' style='display:flex;flex-direction:column;gap:8px;margin-top:8px'>"
                       f"<input type='hidden' name='csrf' value='{who['csrf']}'>"
                       "<label class='f small'>New access token<input type='password' name='token' autocomplete='off'></label>"
                       "<p class='small mute'>This replaces the current token. Leave it empty to remove the token: a private repository can then no longer be read, and pushes stop going live.</p>"
                       "<div class='acts'><button class='btn' type='submit'>Set access token</button></div></form></details>"
                       "<p class='small mute'>For a private repository: a read-only deploy token. It is never shown again.</p></div>")
        else:
            content = "<h2>How to update this site</h2><p>WordPress: manage content in its own admin, reachable from your own networks.</p>"
        rest = "Its newest release was blocked, so visitors see no change." if stopped and running else ("Its newest release passed inspection." if running and src and insp else "")
        reach = "Public" if s.get("public") else "Your networks only"
        blocked = ""
        if stopped:
            safe = ("<section class='call calm'><h2>Your live site is not affected.</h2><p>A blocked release never goes live. The last release that passed keeps running.</p></section>" if running else "")
            blocked = safe + findings_block(insp, "Then push to your branch or upload a new package. The new release is inspected by itself.")
        delete = (f"<form class='card dangerzone' method='post' action='/sites/{esc(name)}/delete'><input type='hidden' name='csrf' value='{who['csrf']}'>"
                  "<h2>Delete this site</h2><p>The container goes and the site stops answering. Its backup stays, and the site can come back from it under Deleted sites.</p>"
                  f"<label class='f small' style='max-width:420px'>Type {esc(name)} to confirm<input type='text' name='confirm' required pattern='{esc(name)}' autocomplete='off'></label>"
                  f"<div class='acts'><button class='btn danger guarded' type='submit'>Delete {esc(name)}</button></div></form>")
        body = (f"<div class='row'><div class='grow'><h1><span class='mono'>{esc(name)}</span> <b>is {esc(state)}.</b> {rest}</h1>"
                f"<div class='acts small mute' style='margin-top:8px'><a class='mono' href='https://{esc(s['domain'])}'>{esc(s['domain'])}</a>{pill(state)}<span class='pill'>{esc(s['template'])}</span><span>{reach}</span></div></div>"
                f"<a class='btn' href='https://{esc(s['domain'])}'>Open {esc(name)}</a></div>{blocked}"
                f"<div class='cols'><div class='wide'><section class='card'>{content}</section>{guide_block(self.server.conf, s['template'])}{delete}</div>"
                f"<aside class='aside'>{inspection_card(insp)}{pull_log(name) if src else ''}<section class='card'><div><h2>Backups</h2><p class='small mute'>Taken nightly. Restoring puts the site back as it was at that moment.</p></div>{self.backup_list(who, name)}</section></aside></div>")
        self.send(200, page(name, who["user"], body, crumb=name))

    def backup_list(self, who, name):
        pts = backups().get("sites", {}).get(name, [])
        if not pts:
            return "<p class='small mute'>No backups yet; they are taken nightly.</p>"
        rows = "".join(f"<li><div class='mono small' style='font-weight:500;margin-bottom:6px'>{esc(when(b['time']))}</div>"
                       f"{restore_form(who, f'/sites/{esc(name)}/restore', b['volid'], 'Put this back. I understand that changes since then are lost.')}</li>"
                       for b in pts)
        return f"<ul class='plain'>{rows}</ul>"

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
