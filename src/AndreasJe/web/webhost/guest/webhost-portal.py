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

import os
import sys

sys.path.insert(0, os.environ.get("WEBHOST_PORTAL_LIB", "/usr/local/lib/webhost-portal"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import email.parser
import email.policy
import hashlib
import hmac
import json
import re
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import portal_analytics
import portal_home
import portal_new
import portal_request
import portal_site
from portal_core import *  # noqa: F401,F403  (the unit tests and render script read these through this module)


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

    def fail(self, code, msg, who=None):
        titles = {400: "That did not work.", 401: "You are not signed in.", 403: "You cannot do that.", 404: "We cannot find that page.",
                  409: "That cannot be done right now.", 413: "That file is too big.", 503: "The portal is not ready yet."}
        if code == 404 and who is None:
            try:
                claims, _ = verify_token(self.headers.get("X-Authentik-Jwt"), load(KEY, None) or {}, time.time())
                if claims:
                    who = {"user": claims["user"], "admin": bool(set(claims["groups"]) & set(self.server.conf.get("admin_groups", ["installer"])))}
            except Exception:
                who = None
        name = who["user"] if who else ""
        mine = self.sites(who) if (code == 404 and who) else []
        tn = {t["name"]: t.get("label") or t["name"] for t in self.server.conf.get("templates", [])}
        note = " You only see sites you own." if code == 404 and who and not who.get("admin") else ""
        if code == 404 and who:
            rows = "".join(f'<a class="siterow" href="/sites/{esc(s["name"])}"><span style="min-width:0"><b class="mono" style="font-weight:500">{esc(s["name"])}</b> '
                           f'<span class="src">{esc(s.get("domain", ""))} · {esc(tn.get(s.get("template"), s.get("template", "")))}</span></span>{pill(s.get("state") or "live")}</a>'
                           for s in mine)
            yours = (f'<section class="card"><h2>Your sites</h2><p class="src">If you were looking for one of these, open it from here.</p><div style="display:flex;flex-direction:column">{rows}</div>'
                     '<div class="actions"><a class="btn" href="/">Go to your sites</a></div></section>' if mine else
                     '<section class="card"><h2>You have no sites yet</h2><p class="src">Create one and it will be listed here.</p>'
                     '<div class="actions"><a class="btn" href="/new">Create your first site</a></div></section>')
        else:
            yours = '<div class="actions" style="justify-content:flex-start"><a class="btn" href="/">Go to your sites</a></div>'
        body = (f'<style>.siterow{{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:6px 12px;min-height:44px;padding:8px 4px;border-top:1px solid var(--div);'
                f'text-decoration:none;color:var(--ink);border-radius:8px}}.siterow:hover{{background:var(--soft);color:var(--ink)}}</style>'
                f'<div style="max-width:760px;display:flex;flex-direction:column;gap:20px"><div><div class="src" style="margin-bottom:4px">Error {code}</div>'
                f'<h1><b>{esc(titles.get(code, "Something went wrong."))}</b></h1><p class="sub" style="font-size:14px;color:var(--ink)">{esc(msg)}{esc(note)}</p></div>{yours}</div>')
        self.send(code, page("Not found" if code == 404 else "Error", name, body, crumbs=[("Sites", "/"), ("Not found" if code == 404 else "Error", None)]))

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
        m = re.fullmatch(r"/sites/([a-z][a-z0-9-]{0,30})/analytics", path)
        if m:
            return self.site_analytics(who, m.group(1), parse_qs(urlparse(self.path).query))
        if path == "/analytics":
            return self.analytics(who, parse_qs(urlparse(self.path).query))
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
        m = re.fullmatch(r"/sites/([a-z][a-z0-9-]{0,30})/(upload|delete|token|restore|analytics|dbinit)", path)
        if m:
            return {"upload": self.upload, "delete": self.delete, "token": self.token, "restore": self.restore,
                    "analytics": self.analytics_toggle, "dbinit": self.dbinit}[m.group(2)](who, m.group(1), fields, files)
        m = re.fullmatch(r"/requests/([0-9TZ]+-[0-9a-f]{6})/retry", path)
        if m:
            return self.retry(who, m.group(1))
        m = re.fullmatch(r"/deleted/([a-z][a-z0-9-]{0,30})/restore", path)
        if m:
            return self.restore(who, m.group(1), fields, files, deleted=True)
        self.fail(404, "No such page.")

    # ── pages (bodies in portal_*.py) ──
    def home(self, who):
        return portal_home.home(self, who)

    def new(self, who, error="", values=None, query=None):
        return portal_new.new(self, who, error, values, query)

    def create(self, who, fields, files):
        return portal_new.create(self, who, fields, files)

    def request_page(self, who, rid):
        return portal_request.request_page(self, who, rid)

    @staticmethod
    def retryable(r):
        return portal_request.retryable(r)

    def retry(self, who, rid):
        return portal_request.retry(self, who, rid)

    def detail(self, who, name):
        return portal_site.detail(self, who, name)

    def backup_list(self, who, name):
        return portal_site.backup_list(self, who, name)

    def deleted(self, who):
        return portal_home.deleted(self, who)

    def restore(self, who, name, fields, files, deleted=False):
        return portal_site.restore(self, who, name, fields, files, deleted)

    def upload(self, who, name, fields, files):
        return portal_site.upload(self, who, name, fields, files)

    def token(self, who, name, fields, files):
        return portal_site.token(self, who, name, fields, files)

    def analytics_toggle(self, who, name, fields, files):
        return portal_site.analytics_toggle(self, who, name, fields, files)

    def analytics_card(self, who, s):
        return portal_site.analytics_card(self, who, s)

    def database_card(self, who, s):
        return portal_site.database_card(self, who, s)

    def dbinit(self, who, name, fields, files):
        return portal_site.dbinit(self, who, name, fields, files)

    def toggle_form(self, who, name, on):
        return portal_site.toggle_form(self, who, name, on)

    def analytics(self, who, query):
        return portal_analytics.analytics(self, who, query)

    def site_analytics(self, who, name, query):
        return portal_analytics.site_analytics(self, who, name, query)

    def analytics_setup(self, who, s, wid, crumb):
        return portal_analytics.analytics_setup(self, who, s, wid, crumb)

    def delete(self, who, name, fields, files):
        return portal_site.delete(self, who, name, fields, files)


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
