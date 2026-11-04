"""webhost-portal core: paths, helpers and page chrome shared by the page modules.

Mutable state (ANALYTICS_MAP, COUNTRIES, STYLE, Umami) lives here only; page
modules read it as portal_core.X so patching it here reaches every page.
"""
import base64
import datetime
import hashlib
import hmac
import html
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request


CONF = os.environ.get("WEBHOST_PORTAL_CONF", "/etc/webhost/portal.json")
KEY = os.environ.get("WEBHOST_PORTAL_KEY", "/etc/webhost/portal-gate.json")
DATA = os.environ.get("WEBHOST_PORTAL_DATA", "/srv/webhost/portal")
INSPECT = os.environ.get("WEBHOST_INSPECT", "/srv/webhost/inspect")
UMAMI = os.environ.get("WEBHOST_UMAMI", "http://127.0.0.1:3000/api")
UMAMI_LOGIN = "/etc/webhost/portal-umami.json"
ANALYTICS_MAP = "/etc/webhost/analytics-sites.json"
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

# The CSP allows inline styles and inline SVG markup and nothing else: no
# scripts, no web fonts. What changes on a form changes through :has(). The
# design tokens and components follow design/Components.dc.html and Main.dc.html;
# everything is written for 390 px and widened with media or @container queries.
# Page modules use these class names: shell (.shell .topbar .menu .side .top),
# .card .tiles/.tile .pill .btn(.ghost/.danger) .actions .src .meter .ml .spark,
# .frame/.tbl/.rw (role=table list), .arow .panel .find .fix .heat .tmap, forms
# (.f .err .errsum .opts .tick), details/summary, pre.log.
STYLE = """
:root{--bg:#f4f0e6;--soft:#fbf9f4;--card:#fff;--ink:#1e1f1b;--mute:#5f5e55;--line:#e6dfd0;--div:#efe9db;--field:#d8cfbc;
--acc:#1f6b4f;--acc2:#134a36;--ok:#16573f;--okbg:#ddeee3;--calm:#ddebe2;--bad:#8e2518;--badbg:#fbe0dc;--bad2:#6f1c12;--red:#8e2518;
--run:#7a4a00;--runbg:#f8e8c4;--warn:#7a4a00;--warnbg:#f8e8c4;--note:#f5ebcb;--notetx:#4c4023;--attn:#ead9a6;--findline:#f0c3bc;
--s0:#efe9db;--s1:#d6e6dc;--s2:#a9cdb9;--s3:#5e9a7d;--s4:#1f6b4f;
--sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 var(--sans);background:var(--bg);color:var(--ink)}
a{color:var(--acc)}a:hover{color:var(--acc2)}code,.mono{font-family:var(--mono)}
code{font-size:.92em;padding:0 4px;border-radius:4px;background:var(--bg);overflow-wrap:anywhere}
:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
time[title]{text-decoration:underline dotted var(--mute);text-underline-offset:3px}
/* shell: top bar with a Menu below 1000 px, side menu from 1000 px */
.shell{min-height:100vh;display:flex;flex-direction:column}
.topbar{position:relative;z-index:2;display:flex;justify-content:space-between;align-items:center;gap:8px;padding:6px 12px;min-height:56px;border-bottom:1px solid var(--line);background:var(--soft)}
.topbar .brand{min-height:44px;padding:0}.topbar .tools{display:flex;align-items:center;gap:10px}
.brand{display:flex;align-items:center;gap:10px;padding:0 8px;color:var(--ink);text-decoration:none}.brand b{font:500 15px/18px var(--mono);display:block}.brand small{font-size:12px;color:var(--mute)}
.menu{position:relative}.menu summary{list-style:none;display:flex;align-items:center;min-height:44px;padding:0 16px;border-radius:10px;border:1px solid var(--field);background:var(--card);font-weight:600;color:var(--ink);cursor:pointer}
.menu summary::-webkit-details-marker{display:none}
.menu nav{position:absolute;right:0;top:48px;width:220px;background:var(--soft);border:1px solid var(--line);border-radius:12px;padding:8px;display:flex;flex-direction:column;gap:2px;box-shadow:0 6px 20px rgba(30,31,27,.12)}
.nav{display:flex;flex-direction:column;gap:2px}.navh{font-size:12px;color:var(--mute);padding:0 10px 4px}
.nav a{display:flex;align-items:center;min-height:44px;padding:0 10px;border-radius:10px;color:var(--ink);text-decoration:none}.nav a:hover{background:var(--div)}
.nav a[aria-current],.nav a.on{background:var(--acc);color:#fff;font-weight:600}
.avatar{flex:0 0 32px;width:32px;height:32px;border-radius:99px;background:var(--note);display:flex;align-items:center;justify-content:center;font-weight:600}
.side{display:none}
.body{flex:1 1 auto;min-width:0}
.top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:6px 16px;padding:10px 12px;border-bottom:1px solid var(--line);background:var(--soft);font-size:13px;color:var(--mute)}
.top a{color:var(--mute)}.top b{color:var(--ink);font-weight:600}.top .sep{margin:0 4px}
.who{display:none;align-items:center;gap:10px;font-weight:600;font-size:13px;color:var(--ink);overflow-wrap:anywhere}.who .avatar{flex-basis:30px;width:30px;height:30px}
main{max-width:1200px;padding:20px 12px 40px;display:flex;flex-direction:column;gap:16px}
@media(min-width:1000px){
.shell{flex-direction:row}.topbar{display:none}
.side{display:flex;flex:0 0 240px;flex-direction:column;gap:20px;position:sticky;top:0;align-self:flex-start;height:100vh;background:var(--soft);border-right:1px solid var(--line);padding:18px 12px}
.nav a{min-height:0;padding:9px 10px}.top{padding:10px 24px}.who{display:flex}
main{padding:28px 24px 48px;gap:20px}}
h1{margin:0;font-size:24px;line-height:1.25;font-weight:500}h1 b{font-weight:700}h1 .mono{font-weight:500}
h2{margin:0;font-size:16px;font-weight:600}h3{margin:0;font-size:14px;font-weight:600}p{margin:0}
@media(min-width:760px){h1{font-size:26px}}
.sub{margin-top:6px;font-size:13px;color:var(--mute)}.mute{color:var(--mute)}.small{font-size:13px}.tiny{font-size:12px}.src{font-size:12px;color:var(--mute)}
.hdr{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:baseline;gap:4px 8px}
.row{display:flex;flex-wrap:wrap;gap:16px;justify-content:space-between;align-items:flex-start}.row>.grow{flex:1 1 420px;min-width:0}
.cols{display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start}.cols>.wide{flex:999 1 520px;min-width:0;display:flex;flex-direction:column;gap:16px}.cols>.aside{flex:1 1 320px;min-width:0;display:flex;flex-direction:column;gap:16px}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:20px;align-items:stretch}.grid3{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,320px),1fr));gap:20px;align-items:start}
/* cards, tiles */
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px;display:flex;flex-direction:column;gap:12px;min-width:0}
@media(min-width:600px){.card{padding:18px 20px}}
.card.flush{padding:0;gap:0}.card.flush>h2{padding:16px 20px 8px}.card.flush>p{padding:12px 20px 16px;border-top:1px solid var(--div)}
.card.attn{border-color:var(--attn)}.card.find,.card.dangerzone{border-color:var(--findline)}.card.row{flex-direction:row;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px 16px}
.inset{padding:14px 16px;border-radius:12px;background:var(--soft);display:flex;flex-direction:column;gap:6px}
.panel{display:flex;flex-direction:column;gap:10px;padding:14px 16px;border-radius:12px;background:var(--soft);border:1px solid var(--line)}
.fix{padding:10px 12px;border-radius:10px;background:var(--soft)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,160px),1fr));gap:12px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px;display:flex;flex-direction:column;gap:2px;font-size:13px;color:var(--mute);text-decoration:none;min-width:0}
a.tile:hover{border-color:var(--field)}.tile b{display:block;font-size:24px;font-weight:600;color:var(--ink)}.tile small{font-size:12px}
.big{font-size:40px;font-weight:600;line-height:1;color:var(--ink)}
.up{color:var(--ok)}.down{color:var(--bad)}
.call{padding:20px 24px;border-radius:16px;display:flex;flex-direction:column;gap:10px}.call.note{background:var(--note);color:var(--notetx)}.call.calm{background:var(--calm);color:var(--acc2)}.call h2{font-size:20px;line-height:1.3;color:var(--ink)}.call.calm h2{color:inherit;font-size:16px}
/* attention rows: stacked on a phone, one line from 760 px */
.arow{display:flex;flex-direction:column;align-items:flex-start;gap:10px;padding:14px 0;border-top:1px solid var(--div)}.arow>div{min-width:0}.arow .btn{align-self:stretch}.arow:last-child{padding-bottom:0}
@media(min-width:760px){.arow{flex-direction:row;flex-wrap:wrap;align-items:center;gap:12px 16px;padding:12px 0}.arow>div{flex:1 1 360px}.arow .btn{align-self:auto}}
/* buttons: one primary per card or form, bottom right; ghost to its left */
.acts{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.actions{display:flex;flex-wrap:wrap;justify-content:flex-end;align-items:center;gap:8px;margin-top:4px}.actions .btn{flex:1 1 100%}
@media(min-width:560px){.actions .btn{flex:none}}
.btn{display:inline-flex;align-items:center;justify-content:center;min-height:44px;padding:0 16px;border:1px solid var(--acc);border-radius:10px;background:var(--acc);color:#fff;font:inherit;font-weight:600;white-space:nowrap;cursor:pointer;text-decoration:none}.btn:hover{background:var(--acc2);color:#fff}
.btn.ghost{background:var(--card);border-color:var(--field);color:var(--ink)}.btn.ghost:hover{background:var(--soft);color:var(--ink)}
.btn.danger{background:var(--bad);border-color:var(--bad);color:#fff}.btn.danger:hover{background:var(--bad2);border-color:var(--bad2);color:#fff}
.btn.block{width:100%}
form:has(input:invalid) .guarded,form:has(input:invalid) .guarded:hover{background:var(--div);border-color:var(--div);color:#6b6a5f;cursor:not-allowed}
/* pills: the word carries the meaning, colour only helps */
.pill{display:inline-block;padding:1px 9px;border-radius:99px;font-size:12px;font-weight:600;background:var(--div);color:var(--notetx);white-space:nowrap}
.pill.ok{background:var(--okbg);color:var(--ok)}.pill.bad{background:var(--badbg);color:var(--bad)}.pill.run,.pill.warn{background:var(--runbg);color:var(--run)}
/* bars and meters */
.bar{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);gap:6px}.bar i{height:4px;border-radius:2px;background:var(--line)}.bar i.g{background:var(--acc)}.bar i.r{background:var(--red)}
.meter{height:6px;border-radius:99px;background:var(--div);overflow:hidden}.meter>i{display:block;height:100%;background:var(--acc);border-radius:99px}.m+.meter{margin-top:4px}
.ml{display:flex;flex-direction:column;gap:10px}.ml .m{display:flex;justify-content:space-between;gap:8px;font-size:13px}.ml .m>span:first-child{min-width:0;overflow-wrap:anywhere}.ml .m b{font-weight:600}.ml .n{color:var(--mute)}
.ml+details,.ml details{font-size:13px}.ml details .ml{margin-top:8px}
.meters{display:flex;flex-direction:column;gap:10px;font-size:14px}.meters .m{display:flex;justify-content:space-between;gap:8px}.meters .m b{font-weight:600}
.spark{flex:none;vertical-align:middle}
/* hour grid (24 columns wide, 8 three-hour blocks narrow) and tile map: render both grids, the container shows one */
.heatwrap,.tmapwrap{container-type:inline-size}
.heat{display:grid;gap:3px;font-size:11px;color:var(--mute)}.heat>span{text-align:center;align-self:center}.heat>span:first-child{text-align:left}.heat i{display:block;border-radius:4px;height:30px}
.heat.h3{grid-template-columns:36px repeat(8,minmax(0,1fr))}.heat.h24{display:none;grid-template-columns:40px repeat(24,minmax(0,1fr))}.heat.h24 i{height:22px}
@container (min-width:560px){.heat.h24{display:grid}.heat.h3{display:none}}
.s0{background:var(--s0)}.s1{background:var(--s1)}.s2{background:var(--s2)}.s3{background:var(--s3);color:#fff}.s4{background:var(--s4);color:#fff}
.legend{display:flex;flex-wrap:wrap;align-items:center;gap:8px;font-size:12px;color:var(--mute)}.legend i{display:inline-block;width:18px;height:12px;border-radius:3px}
.tmap{--g:1px;display:grid;grid-template-columns:repeat(20,minmax(0,1fr));grid-template-rows:repeat(10,calc((100cqw - 19 * var(--g)) / 20));gap:var(--g);max-width:676px}
.tmap span{border-radius:3px;display:flex;align-items:center;justify-content:center;overflow:hidden;font:600 7px var(--mono)}
@container (min-width:520px){.tmap{--g:4px}.tmap span{border-radius:6px;font-size:10px}}
/* the sites list: one set of markup, cards below 760 px of the list's own width, a table from there */
.frame{container-type:inline-size}
.tbl{display:flex;flex-direction:column;gap:12px}.ttl{margin:0}.hd{display:none}
.rw{display:grid;grid-template-columns:minmax(0,1fr) auto;grid-template-areas:"name state" "say say" "vis vis" "fold fold" "act act";gap:10px;padding:16px;background:var(--card);border:1px solid var(--line);border-radius:14px}
.rw.attn{order:-1;border-color:var(--attn)}
.c-name{grid-area:name;min-width:0}.c-state{grid-area:state}.c-say{grid-area:say;display:flex;gap:8px;align-items:flex-start;font-size:13px}
.c-vis{grid-area:vis}.c-fold{grid-area:fold}.c-act{grid-area:act}
.c-rel,.c-now,.c-bk,.c-own{display:none}
.c-fold summary{min-height:44px;display:flex;align-items:center;padding:0;cursor:pointer;color:var(--acc);font-weight:600;font-size:13px}
.c-act .btn{width:100%}.c-act .btn:not(.pri){background:var(--card);color:var(--ink);border-color:var(--field)}
.wide-label{display:none}.off{font-size:13px;color:var(--mute)}
@container (min-width:760px){
.tbl{gap:0;background:var(--card);border:1px solid var(--line);border-radius:16px;overflow:hidden}.ttl{padding:16px 20px 8px}
.hd,.rw{display:grid;grid-template-columns:minmax(180px,1.5fr) 70px minmax(160px,1.4fr) minmax(210px,1.6fr) 44px 140px 80px;grid-template-areas:"name state rel vis now bk act";gap:12px;align-items:center;padding:12px 20px}
.tbl.inst .hd,.tbl.inst .rw{grid-template-columns:minmax(160px,1.4fr) 70px 70px minmax(150px,1.3fr) minmax(200px,1.5fr) 44px 130px 80px;grid-template-areas:"name own state rel vis now bk act"}
.hd{font-size:12px;color:var(--mute);border-bottom:1px solid var(--line)}
.rw{border:0;border-radius:0;border-bottom:1px solid var(--div)}.rw.attn{order:0}.rw:last-child{border-bottom:0}
.c-say,.c-fold,.own-inline{display:none}.c-rel,.c-now,.c-bk{display:block}
.tbl.inst .c-own{display:block;grid-area:own}.c-rel{grid-area:rel}.c-now{grid-area:now}.c-bk{grid-area:bk}
.c-act{text-align:right}.c-act .btn{width:auto;min-height:40px}.c-act .btn.pri{background:var(--card);border-color:var(--field);color:var(--ink)}
.phone-label,.vis-sub{display:none}.wide-label{display:inline}}
/* tables for the pages not yet ported */
.scroll{overflow-x:auto}table{width:100%;min-width:880px;border-collapse:collapse}th{text-align:left;padding:8px 12px;font-size:12px;font-weight:500;color:var(--mute)}td{padding:12px;border-top:1px solid var(--div);vertical-align:top}th:first-child,td:first-child{padding-left:20px}th:last-child,td:last-child{padding-right:20px}
/* steps */
ol.steps{margin:0;padding:0;list-style:none}.steps li{display:flex;gap:12px;padding-bottom:14px}.steps li:last-child{padding-bottom:0}.steps .dot{flex:0 0 26px;height:26px;border-radius:99px;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;background:var(--div);color:var(--mute)}
.steps .done .dot{background:var(--acc);color:#fff}.steps .now .dot{background:#fff;border:2px solid var(--acc);color:var(--acc)}.steps .stop .dot{background:var(--bad);color:#fff}.steps li>div:last-child{flex:1;min-width:0}.step{display:flex;flex-wrap:wrap;gap:4px 10px;justify-content:space-between;align-items:baseline}.step b{font-weight:600}
dl{margin:0;display:grid;grid-template-columns:auto minmax(0,1fr);gap:6px 14px;font-size:13px}dt{color:var(--mute)}dd{margin:0;text-align:right;overflow-wrap:anywhere}.kv dd{text-align:left}
/* forms */
.tpls{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,240px),1fr));gap:10px}.tpl{display:block;padding:12px 14px;border:1px solid var(--line);border-radius:12px;background:var(--card);cursor:pointer}.tpl:has(input:checked){outline:2px solid var(--acc);outline-offset:-1px}
.tpl input{accent-color:var(--acc);margin:0 6px 0 0}.tpl small{display:block;font-size:13px;color:var(--mute);margin-top:4px}.tpl small.mono{font-size:12px;margin-top:0}.tpl small.good{color:var(--ok);margin-top:6px}
.fields{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,220px),1fr));gap:12px}.fields .all{grid-column:1/-1}
label.f{display:flex;flex-direction:column;gap:4px;font-weight:600}label.f small{font-weight:400;font-size:12px;color:var(--mute)}
input[type=text],input[type=password],input[type=url],input[type=search],input[type=email],input[type=number],textarea,select{width:100%;min-height:44px;padding:0 12px;border:1px solid var(--field);border-radius:10px;background:var(--soft);color:var(--ink);font:400 14px var(--mono)}
textarea{padding:10px 12px;min-height:88px}select{font-family:var(--sans)}
input[aria-invalid=true],textarea[aria-invalid=true]{border-color:var(--bad);border-width:2px}
.err{color:var(--bad);font-size:13px;font-weight:400}.errsum{padding:14px 16px;border-radius:12px;background:var(--badbg);color:var(--bad);display:flex;flex-direction:column;gap:6px}.errsum a{color:var(--bad);font-weight:600}.errsum ul{margin:0;padding-left:18px}
input[type=file]{font:inherit;font-weight:400;max-width:100%}.tick{display:flex;gap:10px;align-items:flex-start;cursor:pointer}.tick input{width:18px;height:18px;margin:1px 0 0;accent-color:var(--acc);flex:none}
.opts{display:flex;flex-direction:column;gap:8px}.opts label{display:flex;gap:10px;align-items:center;min-height:44px;padding:6px 12px;border:1px solid var(--line);border-radius:10px;background:var(--card);cursor:pointer}.opts label:has(input:checked){outline:2px solid var(--acc);outline-offset:-1px}.opts input{accent-color:var(--acc);width:18px;height:18px;flex:none}
.box{padding:12px;border:1px solid var(--line);border-radius:10px;display:flex;flex-direction:column;gap:8px}
.tabs{display:inline-flex;align-self:flex-start;padding:3px;border-radius:10px;background:var(--div)}.tabs label{min-height:38px;padding:0 14px;border-radius:8px;display:flex;align-items:center;font-weight:600;cursor:pointer}.tabs input{position:absolute;opacity:0}.tabs label:has(input:checked){background:var(--card)}.tabs label:has(input:focus-visible){outline:2px solid var(--acc)}
.pane-src,.pane-git{display:flex;flex-direction:column;gap:12px}.pane-pkg,.pane-wp{display:none}form:has(#mode-package:checked) .pane-pkg{display:flex}form:has(#mode-package:checked) .pane-git{display:none}form:has(input[data-wp]:checked) .pane-wp{display:block}form:has(input[data-wp]:checked) .pane-src{display:none}
.pane-db{display:none}form:has(input[data-db]:checked) .pane-db{display:flex;flex-direction:column;gap:6px}
.drop{padding:20px;border:1px dashed #bdb29a;border-radius:10px;background:var(--soft);flex-direction:column;gap:4px;font-weight:600}.drop small{font-weight:400;font-size:13px;color:var(--mute)}
.guide{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,280px),1fr));gap:12px;font-size:13px}.guide>div{padding:14px;border:1px solid var(--div);border-radius:12px}.guide h3{margin-bottom:6px}.guide ul{margin:0;padding-left:16px;display:flex;flex-direction:column;gap:5px}
ul.files{margin:0;padding:0;list-style:none;border:1px solid var(--div);border-radius:10px;font:13px var(--mono)}.files li{display:flex;flex-wrap:wrap;justify-content:space-between;gap:4px 12px;padding:8px 12px;border-top:1px solid var(--div);overflow-wrap:anywhere}.files li:first-child{border-top:0}.files span{color:var(--mute);font-family:inherit}
ol.next{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:6px;font-size:13px}ul.plain{margin:0;padding:0;list-style:none;display:flex;flex-direction:column;gap:10px}
.seg{display:inline-flex;flex-wrap:wrap;gap:4px;padding:4px;border-radius:12px;background:var(--div)}.seg a{display:inline-flex;align-items:center;min-height:36px;padding:0 14px;border-radius:9px;color:var(--ink);text-decoration:none;font-size:14px}.seg a.on,.seg a[aria-current]{background:var(--card);font-weight:600}
/* charts */
.chart{display:flex;align-items:flex-end;gap:6px;height:180px;border-bottom:1px solid var(--line);padding-top:8px}.chart .day{flex:1;display:flex;align-items:flex-end;justify-content:center;gap:3px;height:100%;min-width:0}.chart .pv,.chart .vi{width:min(18px,40%);border-radius:4px 4px 0 0}.chart .pv{background:#a9cdb9}.chart .vi{background:var(--acc)}
.days{display:flex;gap:6px;font-size:12px;color:var(--mute);text-align:center}.days>div{flex:1;min-width:0;overflow:hidden;white-space:nowrap}.days .mono{font-size:11px}.key{display:inline-flex;align-items:center;gap:6px;font-size:13px;color:var(--mute)}.key i{width:10px;height:10px;border-radius:3px;display:inline-block}
.kv{display:grid;grid-template-columns:auto minmax(0,1fr);gap:6px 14px;font-size:13px}.kv dt{color:var(--mute)}
/* details: Show all, Show technical log, folded options */
details>summary{cursor:pointer;color:var(--acc);font-weight:600;padding:11px 0}details[open]>summary{padding-bottom:6px}details.plain>summary{color:var(--ink)}
.logbox>summary{font-size:13px}.logbox .src{margin:0 0 6px}
pre.log{margin:6px 0 0;max-height:420px;overflow:auto;padding:12px;border-radius:10px;background:#13261f;color:var(--calm);font:12px/1.45 var(--mono);white-space:pre-wrap;word-break:break-word}
.path{padding:10px 12px;border-radius:10px;background:#13261f;color:var(--calm);font:12px var(--mono);overflow-wrap:anywhere}
.livedot{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--mute)}
"""

STATE_CLASS = {"live": "ok", "passed": "ok", "done": "ok", "blocked": "bad", "failed": "bad", "waiting": "", "applying": "run",
               "warning": "run", "new": "run", "checking": "run", "inspecting": "run", "creating": "run", "restoring": "run", "deleting": "run",
               "quarantined": "run"}
STATE_ALIAS = {"pass": "passed", "block": "blocked", "ok": "done", "active": "live", "rejected": "blocked", "fail": "failed", "warn": "warning"}
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
    "analytics": [("new", "New", "Your request is saved. webhost picks it up within a minute."),
                  ("applying", "Applying", "The site's web server is reloaded with or without the analytics route. Visitors are not interrupted."),
                  ("done", "Done", "The change is live.")],
    "dbinit": [("new", "New", "Your request is saved. webhost picks it up within a minute."),
               ("applying", "Loading", "The file is loaded into the database, but only while the database has no tables."),
               ("done", "Done", "The database is ready.")],
    "token": [("new", "New", "Your request is saved. webhost picks it up within a minute."),
              ("done", "Done", "The next fetch uses the new token.")],
}


def esc(v):
    """HTML-escape any value (text and attributes)."""
    return html.escape(str(v), quote=True)


def mono(v):
    """An escaped value in the monospace face, for site names, files and addresses."""
    return f'<span class="mono">{esc(v)}</span>'


# ── time: one helper family, UTC, never a raw timestamp in the text ───

DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def parse_ts(ts):
    """Epoch seconds from epoch seconds, epoch milliseconds, a datetime or an ISO string (Z ok); None if unreadable."""
    if ts is None or ts == "" or isinstance(ts, bool):
        return None
    if isinstance(ts, datetime.datetime):
        return (ts if ts.tzinfo else ts.replace(tzinfo=datetime.timezone.utc)).timestamp()
    if isinstance(ts, (int, float)):
        v = float(ts)
    else:
        s = str(ts).strip()
        if re.fullmatch(r"-?\d+(\.\d+)?", s):
            v = float(s)
        else:
            m = re.fullmatch(r"(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z?", s)
            try:
                if m:
                    d = datetime.datetime(*map(int, m.groups()))
                else:
                    d = datetime.datetime.fromisoformat(re.sub(r"[zZ]$", "+00:00", s))
            except ValueError:
                return None
            return (d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)).timestamp()
    if v != v or v in (float("inf"), float("-inf")):
        return None
    return v / 1000 if abs(v) > 1e11 else v


def _utc(sec):
    return datetime.datetime.fromtimestamp(sec, datetime.timezone.utc)


def iso(ts):
    """ISO 8601 (UTC, with Z) for a <time datetime> attribute; "" if unreadable. Not for display."""
    sec = parse_ts(ts)
    return "" if sec is None else _utc(sec).strftime("%Y-%m-%dT%H:%M:%SZ")


def exact(ts):
    """Exact time for a title attribute: "Tue 3 Nov 2026, 10:04 UTC"."""
    d = _utc(parse_ts(ts))
    return f"{DAYS[d.weekday()]} {d.day} {MONTHS[d.month - 1]} {d.year}, {d:%H:%M} UTC"


def day(ts, now=None):
    """The date as words: "Tue 3 Nov" (with the year when it is not this year)."""
    d, n = _utc(parse_ts(ts)), _utc(time.time() if now is None else parse_ts(now))
    return f"{DAYS[d.weekday()]} {d.day} {MONTHS[d.month - 1]}" + ("" if d.year == n.year else f" {d.year}")


def _time_tag(sec, text):
    return f'<time datetime="{iso(sec)}" title="{esc(exact(sec))}">{esc(text)}</time>'


def ago_text(ts, now=None):
    """Relative text without markup: "just now", "12 minutes ago", "Last night 01:30", "Yesterday 16:12", "Tue 3 Nov"."""
    sec = parse_ts(ts)
    if sec is None:
        return "unknown"
    now = time.time() if now is None else parse_ts(now)
    d, n = _utc(sec), _utc(now)
    delta = now - sec
    if abs(delta) < 60:
        return "just now"
    if delta < 0:
        return f"{day(sec, now)} {d:%H:%M}"
    if delta < 3600:
        m = int(delta // 60)
        return f"{m} minute{'' if m == 1 else 's'} ago"
    if d.date() == n.date():
        if d.hour < 6:
            return f"Last night {d:%H:%M}"
        h = int(delta // 3600)
        return f"{h} hour{'' if h == 1 else 's'} ago"
    if d.date() == (n - datetime.timedelta(days=1)).date():
        return f"Yesterday {d:%H:%M}"
    return day(sec, now)


def ago(ts, now=None):
    """Relative time as <time datetime title="Tue 3 Nov 2026, 10:04 UTC">2 hours ago</time>; use in text, never a raw timestamp."""
    sec = parse_ts(ts)
    if sec is None:
        return '<span class="mute">unknown</span>'
    return _time_tag(sec, ago_text(sec, now))


def stamp_text(ts, now=None):
    """Clock time with its day, without markup: "Today 08:40 UTC", "Yesterday 16:12 UTC", "Sat 31 Oct 01:30 UTC"."""
    sec = parse_ts(ts)
    if sec is None:
        return "unknown"
    now = time.time() if now is None else parse_ts(now)
    d, n = _utc(sec), _utc(now)
    if d.date() == n.date():
        lead = "Today"
    elif d.date() == (n - datetime.timedelta(days=1)).date():
        lead = "Yesterday"
    else:
        lead = day(sec, now)
    return f"{lead} {d:%H:%M} UTC"


def stamp(ts, now=None):
    """Clock time with its day as <time ... title=exact>Today 08:40 UTC</time>, for freshness lines and findings."""
    sec = parse_ts(ts)
    if sec is None:
        return '<span class="mute">unknown</span>'
    return _time_tag(sec, stamp_text(sec, now))


def when(ts):
    """Compatibility, plain text (callers escape it): "Tue 3 Nov 2026, 10:04 UTC". New code uses ago() or stamp()."""
    return "unknown" if parse_ts(ts) is None else exact(ts)


# ── status words, scope, small builders ──────────────────────────────

def pill(state, label=None):
    """Status pill for live, passed, blocked, failed, waiting, applying, done (aliases pass/block/ok/warn map on); label overrides the word."""
    word = STATE_ALIAS.get(str(state), str(state))
    return f'<span class="{("pill " + STATE_CLASS.get(word, "")).strip()}">{esc(label or word)}</span>'


def scope_pill(public):
    """Neutral pill "Public" or "Your networks only"."""
    return f'<span class="pill">{"Public" if public else "Your networks only"}</span>'


def source_line(text, raw=False):
    """Muted 12px source-and-freshness line; raw=True when text already holds markup such as stamp()."""
    return f'<p class="src">{text if raw else esc(text)}</p>'


def tile(label, value, change_text="", good=None, href=None):
    """Stat tile: label, big value, change in words; good True=green, False=red, None=plain; href makes the whole tile a link."""
    cls = "" if good is None else (' class="up"' if good else ' class="down"')
    chg = f"<small{cls}>{esc(change_text)}</small>" if change_text else ""
    inner = f"{esc(label)}<b>{esc(value)}</b>{chg}"
    return f'<a class="tile" href="{esc(href)}">{inner}</a>' if href else f'<div class="tile">{inner}</div>'


def _bar(m, peak, pct, total, label, mono_names):
    y = m.get("y", 0) or 0
    name = label(m.get("x"))
    note = f' <span class="n">{esc(m["note"])}</span>' if m.get("note") else ""
    val = m.get("value") or (f"{round(100 * y / total)}%" if pct else f"{y:,}")
    width = round(100 * y / (total if pct else peak))
    return (f'<div><div class="m"><span{' class="mono"' if mono_names else ""}>{esc(name)}{note}</span><b>{esc(val)}</b></div>'
            f'<div class="meter" aria-hidden="true"><i style="width:{width}%"></i></div></div>')


def meter_list(rows, top=5, mono=False, pct=False, label=lambda x: x, empty="Nothing yet."):
    """Labelled bars from [{"x": name, "y": number, "note": muted text, "value": text}] (Umami metrics rows work as they are); rows past top fold into "Show all N"."""
    rows = sorted([r for r in rows or [] if isinstance(r, dict)], key=lambda r: -(r.get("y", 0) or 0))
    if not rows:
        return f'<p class="small mute">{esc(empty)}</p>'
    total = sum(r.get("y", 0) or 0 for r in rows) or 1
    peak = max(r.get("y", 0) or 0 for r in rows) or 1
    bars = lambda part: "".join(_bar(m, peak, pct, total, label, mono) for m in part)
    more = (f'<details><summary>Show all {len(rows)}</summary><div class="ml">{bars(rows[top:])}</div></details>' if len(rows) > top else "")
    return f'<div class="ml">{bars(rows[:top])}</div>{more}'


def sparkline(values, large=False, text=None):
    """Inline SVG line through the values (7 daily numbers); large=True is 140x44 with the last day marked; text is the alternative text (hidden from screen readers when None)."""
    v = [float(x or 0) for x in values or []]
    if len(v) < 2:
        return ""
    w, h, pad, sw = (140, 44, 3, 2.5) if large else (72, 22, 2, 2)
    lo, hi = min(v), max(v)
    pts = [(pad + i * (w - 2 * pad) / (len(v) - 1),
            h / 2 if hi == lo else h - pad - (x - lo) / (hi - lo) * (h - 2 * pad)) for i, x in enumerate(v)]
    line = " ".join(f"{px:.1f},{py:.1f}" for px, py in pts)
    dot = f'<circle cx="{pts[-1][0]:.1f}" cy="{pts[-1][1]:.1f}" r="3" fill="#1f6b4f"/>' if large else ""
    a11y = f'role="img" aria-label="{esc(text)}"' if text else 'aria-hidden="true"'
    return (f'<svg class="spark" width="{w}" height="{h}" viewBox="0 0 {w} {h}" {a11y}><polyline points="{line}" fill="none" stroke="#1f6b4f" '
            f'stroke-width="{sw}" stroke-linejoin="round" stroke-linecap="round"/>{dot}</svg>')


def result_block(state, title, text="", nxt="", actions="", label=None):
    """Result panel: pill, bold outcome, one line of detail, "What happens next", then buttons (ghost first, primary last, bottom right). title/text/nxt/actions are HTML: escape values yourself."""
    nx = f'<div><div class="src">What happens next</div><div>{nxt}</div></div>' if nxt else ""
    ac = f'<div class="actions">{actions}</div>' if actions else ""
    body = f"<p>{text}</p>" if text else ""
    return f'<div class="panel"><div class="acts">{pill(state, label)}<b>{title}</b></div>{body}{nx}{ac}</div>'


def attn_row(state, name, text, when_html="", button="", label=None):
    """One "Needs a person" row: pill, site name in mono, what happened (text is HTML), time line (HTML), one button (HTML)."""
    wh = f'<div class="src" style="margin-top:2px">{when_html}</div>' if when_html else ""
    return (f'<div class="arow">{pill(state, label)}<div><b class="mono" style="display:block;font-weight:600">{esc(name)}</b>'
            f'<div>{text}</div>{wh}</div>{button}</div>')


def finding_card(title, text, fix, found_html="", button=""):
    """Blocked finding: bad pill and title, what it is (HTML), "What to fix" (HTML), when found (HTML) and an optional button."""
    foot = f'<div class="hdr"><span class="src">{found_html}</span>{button}</div>' if found_html or button else ""
    return (f'<article class="card find"><div class="acts">{pill("blocked")}<b>{title}</b></div><p>{text}</p>'
            f'<div class="fix"><div class="src">What to fix</div><div>{fix}</div></div>{foot}</article>')


def empty_state(title, text, actions=""):
    """Panel for "nothing here yet": title (HTML), one explaining paragraph (HTML), buttons bottom right (HTML)."""
    ac = f'<div class="actions">{actions}</div>' if actions else ""
    return f'<div class="panel"><b>{title}</b><p>{text}</p>{ac}</div>'


def details_log(text, summary="Show technical log"):
    """Folded raw log marked "For the installer"; the only place log text, paths or ids may appear."""
    return (f'<details class="logbox"><summary>{esc(summary)}</summary><p class="src">For the installer</p>'
            f'<pre class="log">{esc(text)}</pre></details>')


def page(title, who, body, *, crumbs=(), nav="sites", refresh=None, installer=False, crumb=""):
    """The shell: side menu from 1000 px, top bar with a Menu below; crumbs=[(label, href), ...] link all but the last; refresh=seconds for <meta refresh>.

    Without crumbs the page shows the current menu item. Legacy: crumb="x" means Sites / x, refresh=True means 8 seconds.
    """
    secs = 8 if refresh is True else (int(refresh) if refresh else 0)
    meta = f'<meta http-equiv="refresh" content="{secs}">' if secs > 0 else ""
    if not crumbs:
        crumbs = [("Sites", "/"), (crumb, None)] if crumb else [("Analytics" if nav == "analytics" else "Sites", None)]
    last = len(crumbs) - 1
    trail = '<span class="sep" aria-hidden="true">/</span>'.join(
        f'<b aria-current="page">{esc(label)}</b>' if i == last else f'<a href="{esc(href or "/")}">{esc(label)}</a>'
        for i, (label, href) in enumerate(crumbs))
    inst = ' <span class="pill">installer</span>' if installer else ""
    initial = esc(who[:1].upper()) if who else ""
    me = f'<div class="who"><span class="avatar" aria-hidden="true">{initial}</span>{esc(who)}{inst}</div>' if who else ""
    avatar = f'<span class="avatar" role="img" aria-label="Signed in as {esc(who)}">{initial}</span>' if who else ""
    cur = lambda k: ' aria-current="page"' if k == nav else ""
    links = f'<a href="/"{cur("sites")}>Sites</a>'
    brand = f'<a class="brand" href="/">{MARK}<span><b>webhost</b><small>Self-hosted websites</small></span></a>'
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">{meta}<title>{esc(title)} · webhost</title>
<style>{STYLE}</style></head><body><div class="shell">
<header class="topbar"><a class="brand" href="/">{MARK}<b>webhost</b></a><div class="tools"><details class="menu"><summary>Menu</summary>
<nav aria-label="webhost" class="nav"><div class="navh">Websites</div>{links}</nav></details>{avatar}</div></header>
<aside class="side">{brand}<nav aria-label="webhost" class="nav"><div class="navh">Websites</div>{links}</nav></aside>
<div class="body"><div class="top"><nav aria-label="Breadcrumb">{trail}</nav>{me}</div><main>{body}</main></div></div></body></html>"""


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


def hour_window(days, now=None):
    """(start, end) in epoch milliseconds for the last `days` days, end rounded down to the hour so Umami answers can be cached."""
    end = int((time.time() if now is None else now) // 3600 * 3600 * 1000)
    return end - days * 86400000, end


def _ms(t):
    t = int(t)
    return t * 1000 if abs(t) < 10 ** 11 else t


class Umami:
    """Reads visitor numbers with the portal's view-only Umami account.

    cached() and the methods below return (fetched_at_epoch_seconds, data); data is
    the Umami answer, or None when the portal has no login. They raise urllib errors
    when Umami does not answer: wrap calls in try/except OSError. start and end are
    epoch milliseconds (seconds are accepted); take them from hour_window() so
    answers share a cache entry. Shapes: see BRIEF.md.
    """
    token = None
    cache = {}

    @classmethod
    def cached(cls, path, ttl=3600):
        hit = cls.cache.get(path)
        if hit and time.time() - hit[0] < ttl:
            return hit
        data = cls.get(path)
        cls.cache[path] = (time.time(), data)
        if len(cls.cache) > 500:
            cls.cache = {k: v for k, v in cls.cache.items() if time.time() - v[0] < 86400}
        return cls.cache[path]

    @classmethod
    def active(cls, wid):
        """Visitors right now: {"visitors": 2}; kept 60 seconds."""
        return cls.cached(f"/websites/{wid}/active", ttl=60)

    @classmethod
    def stats(cls, wid, start, end):
        """{"pageviews","visitors","visits","bounces","totaltime","comparison": {same keys, previous period}}; kept an hour."""
        return cls.cached(f"/websites/{wid}/stats?startAt={_ms(start)}&endAt={_ms(end)}")

    @classmethod
    def metrics(cls, wid, type, start, end, limit=10):
        """[{"x": value, "y": count}] for type path|referrer|country|device|browser|event (empty referrer = direct)."""
        return cls.cached(f"/websites/{wid}/metrics?type={urllib.parse.quote(type)}&startAt={_ms(start)}&endAt={_ms(end)}&limit={int(limit)}")

    @classmethod
    def series(cls, wid, start, end, unit="day"):
        """{"pageviews": [{"x": ISO time, "y": n}], "sessions": [...]} per unit hour|day, UTC."""
        return cls.cached(f"/websites/{wid}/pageviews?startAt={_ms(start)}&endAt={_ms(end)}&unit={urllib.parse.quote(unit)}&timezone=UTC")

    @classmethod
    def event_values(cls, wid, event, prop, start, end):
        """[{"value": "cv.pdf", "total": 1}] for one event property, e.g. event "download", property "file"."""
        return cls.cached(f"/websites/{wid}/event-data/values?startAt={_ms(start)}&endAt={_ms(end)}"
                          f"&event={urllib.parse.quote(event)}&propertyName={urllib.parse.quote(prop)}")

    @classmethod
    def get(cls, path, retry=True):
        if not cls.token:
            cred = load(UMAMI_LOGIN, None)
            if not cred:
                return None
            req = urllib.request.Request(f"{UMAMI}/auth/login", method="POST",
                                         data=json.dumps({"username": cred["username"], "password": cred["password"]}).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as r:
                cls.token = json.load(r)["token"]
        try:
            req = urllib.request.Request(f"{UMAMI}{path}", headers={"Authorization": f"Bearer {cls.token}"})
            with urllib.request.urlopen(req, timeout=5) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 401 and retry:
                cls.token = None
                return cls.get(path, retry=False)
            raise


def auto_tag(s):
    """Static and PHP sites (WordPress included) get the analytics line from
    webhost; Node and Python apps build their pages themselves."""
    return s.get("runtime") in ("static", "php")


DBINIT_RE = re.compile(r"(?!.*\.\.)[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.(sql|js)")
DB_NAMES = {"mariadb": "MariaDB", "postgresql": "PostgreSQL", "mongodb": "MongoDB"}


PERIODS = {"24h": (1, "24 hours", "day"), "7d": (7, "7 days", "week"), "30d": (30, "30 days", "month"), "90d": (90, "90 days", "90 days")}
COUNTRIES = {}


def country(code):
    if not COUNTRIES:
        COUNTRIES.update(load("/opt/webhost-analytics/umami/public/intl/country/en-US.json", {}) or {"_": ""})
    return COUNTRIES.get(code) or code or "Unknown"


def change(now, before, kind="count"):
    if kind == "points":
        d = round(now - before)
        return ("same as before", "") if d == 0 else (f"{abs(d)} points {'higher' if d > 0 else 'lower'}", "down" if d > 0 else "up")
    if kind == "seconds":
        d = round(now - before)
        return ("same as before", "") if d == 0 else (f"{abs(d)} seconds {'longer' if d > 0 else 'shorter'}", "up" if d > 0 else "down")
    if not before:
        return ("new", "up") if now else ("–", "")
    p = round(100 * (now - before) / before)
    return ("same as before", "") if p == 0 else (f"{abs(p)}% {'more' if p > 0 else 'fewer'}", "up" if p > 0 else "down")


def duration(sec):
    sec = int(round(sec))
    return f"{sec // 60}m {sec % 60:02d}s" if sec >= 60 else f"{sec}s"


def meters(rows, pct=False, label=lambda x: x, mono=False, top=5):
    if not rows:
        return "<p class='small mute'>Nothing yet.</p>"
    rows = sorted(rows, key=lambda m: -m.get("y", 0))
    total = sum(m.get("y", 0) for m in rows) or 1
    if pct and len(rows) > top:
        rows = rows[:top - 1] + [{"x": None, "other": True, "y": sum(m.get("y", 0) for m in rows[top - 1:])}]
    else:
        rows = rows[:top]
    peak = max(m.get("y", 0) for m in rows) or 1
    out = ""
    for m in rows:
        name = "Other" if m.get("other") else label(m.get("x"))
        val = f"{round(100 * m.get('y', 0) / total)}%" if pct else f"{m.get('y', 0):,}"
        width = round(100 * m.get("y", 0) / (total if pct else peak))
        out += (f"<div><div class='m'><span class='{'mono' if mono and not m.get('other') else ''}'>{esc(name)}</span><b>{val}</b></div>"
                f"<div class='meter'><i style='width:{width}%'></i></div></div>")
    return f"<div class='meters'>{out}</div>"


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
