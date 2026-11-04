"""The new-site form and its submission. Handler bodies; the Portal class delegates here."""
import os
from portal_core import DATA, DBINIT_RE, DOMAIN_RE, PACKAGE_RE, REF_RE, REPO_RE, RID_RE, SITE_RE, TOKEN_RE, esc, load, page

GROUPS = (
    ("files", "A site made of files",
     "Nothing of yours runs on the server. A frontend (React, Vue, Astro…) is built beforehand and shipped as its output, for example dist/."),
    ("wordpress", "WordPress", ""),
    ("apps", "An app with its own server code",
     "Your code runs on the server. Analytics: you add one line to your app. If the app has a frontend, build it beforehand and ship the output, for example dist/."),
)
ORDER = ("lamp", "php-app", "node-app", "pern", "mern", "django", "python-app")
NAME_MSG = "Use lowercase letters, digits and hyphens, starting with a letter, like my-site."
STYLE = """<style>
.nf{display:flex;flex-direction:column;gap:20px}.nstep{display:flex;align-items:center;gap:10px}
.nstep i{font-style:normal;width:26px;height:26px;border-radius:99px;background:var(--okbg);color:var(--ok);display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;flex:none}
fieldset.grp{border:0;margin:0;padding:0;min-width:0;display:flex;flex-direction:column;gap:8px}fieldset.grp legend{padding:0;font-weight:600;font-size:14px}
.nf .tpl{display:flex;align-items:flex-start;gap:10px;min-width:0}.nf .tpl:hover{background:var(--soft)}.nf .tpl input{margin:3px 0 0;flex:none;width:16px;height:16px}
.nf .tpl:has(input:focus-visible){outline:3px solid var(--acc);outline-offset:2px}.nf .tpl b{display:block;font-weight:600}
.nf .tpl .what{display:block;margin-top:2px}.nf .tpl .stack{display:block;margin-top:4px;font-size:12px;color:var(--mute)}
.help{font-size:12px;color:var(--mute);margin:0}.nf div.f{display:flex;flex-direction:column;gap:4px;min-width:0;font-weight:600}.nf div.f small,.nf label.f small{font-weight:400;font-size:12px;color:var(--mute)}
.nf div.f.pane-db{display:none}.nf .f .err{font-size:12px}.nf .row2{display:flex;flex-wrap:wrap;gap:12px 20px;align-items:flex-start}.nf .row2>*{flex:1 1 260px;max-width:420px}
.addr{margin-top:4px;min-height:44px;display:flex;align-items:center;padding:0 12px;border-radius:10px;background:var(--soft);border:1px solid var(--line);overflow-wrap:anywhere}
.decision{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:12px 24px;padding:14px 20px;border:1px solid var(--line);border-radius:16px;background:var(--soft)}
.decision>p{flex:1 1 320px;min-width:0}.decision .actions{margin:0;flex:1 1 220px}
</style>"""


def _field(fid, label, control, help_text, err, optional=False, cls=""):
    """One text field: label, input, then the error (red, linked to the input) or the help line."""
    opt = " <small>Optional</small>" if optional else ""
    msg = (f'<small id="{fid}-msg" class="err">{esc(err)}</small>' if err else (f'<small id="{fid}-msg">{help_text}</small>' if help_text else ""))
    return f'<div class="f {cls}"><label for="{fid}">{esc(label)}{opt}</label>{control(fid, bool(err))}{msg}</div>'


def _input(typ, name, value="", placeholder="", extra=""):
    def build(fid, bad):
        inv = ' aria-invalid="true"' if bad else ""
        v = f' value="{esc(value)}"' if typ != "password" else ' autocomplete="off"'
        return f'<input id="{fid}" type="{typ}" name="{name}"{v} placeholder="{esc(placeholder)}" aria-describedby="{fid}-msg"{inv}{extra}>'
    return build


def new(h, who, error="", values=None, query=None):
    """error: a message, or a list of (field id, message) from create(). Each shows at its field and in the summary."""
    v = values or {}
    if not values and query and query.get("from"):
        # Back from a failed or refused request: its settings, without secrets.
        rid = query["from"][0]
        r = load(os.path.join(DATA, "requests", f"{rid}.json"), None) if RID_RE.fullmatch(rid) else None
        if r and r.get("kind") == "create" and (who["admin"] or r.get("user") == who["user"]):
            src = r.get("source") or {}
            v = {"template": r.get("template"), "name": r.get("site"), "domain": r.get("domain"), "public": r.get("public"),
                 "repo": src.get("repo", ""), "ref": src.get("ref", "main"), "mode": "package" if src.get("upload") else "git",
                 "dbInit": r.get("dbInit", "")}
    errors = [(None, error)] if isinstance(error, str) and error else list(error or [])
    at = {fid: msg for fid, msg in errors if fid}
    base = h.server.conf.get("base_domain", "")
    tpls = h.server.conf.get("templates", [])

    def has_db(t):
        return t.get("database") not in (None, "", "none")

    def card(t):
        checked = " checked" if v.get("template") == t["name"] else ""
        mark = " data-wp" if t.get("app") == "wordpress" else (" data-db" if has_db(t) else "")
        what = f"For {t['hint']}." if t.get("hint") else t.get("summary", "")
        stack = f'<span class="stack">{esc(t["summary"])}</span>' if t.get("hint") and t.get("summary") else ""
        return (f'<label class="tpl"><input type="radio" id="t-{esc(t["name"])}" name="template" value="{esc(t["name"])}"{checked}{mark} required>'
                f'<span><b>{esc(t.get("label") or t["name"])}</b><span class="what">{esc(what)}</span>{stack}</span></label>')

    def group_of(t):
        if t.get("app") == "wordpress":
            return "wordpress"
        return "files" if t.get("group") == "sites" else "apps"

    cards = ""
    for gid, head, sub in GROUPS:
        items = sorted((t for t in tpls if group_of(t) == gid), key=lambda t: ORDER.index(t["name"]) if t["name"] in ORDER else len(ORDER))
        if items:
            cards += (f'<fieldset class="grp"><legend>{esc(head)}</legend>{f"<p class=help>{esc(sub)}</p>" if sub else ""}'
                      f'<div class="tpls">{"".join(card(t) for t in items)}</div></fieldset>')
    tpl_err = f'<p id="template-msg" class="err">{esc(at["template"])}</p>' if "template" in at else ""

    name = v.get("name") or ""
    domain = v.get("domain") or ""
    valid = bool(SITE_RE.match(name))
    shown = domain if domain else (f"{name}.{base}" if valid else (f"my-site.{base}" if not name else ""))
    addr = f'<span class="mono">{esc(shown)}</span>' if shown else '<span class="src">Shown once the name is valid</span>'
    public = " checked" if v.get("public") else ""
    package = v.get("mode") == "package"
    again = ("<p class='help'>Secrets and packages are not kept: give the access token or the package again.</p>" if v.get("name") and not errors else "")
    if errors:
        n = len(errors)
        items = "".join(f'<li><a href="#{esc(fid)}">{esc(msg)}</a></li>' if fid else f"<li>{esc(msg)}</li>" for fid, msg in errors)
        summary = (f'<section class="errsum" role="alert" aria-labelledby="errh"><h2 id="errh">That did not work. {n} thing{"" if n == 1 else "s"} to fix.</h2>'
                   f'<ul>{items}</ul></section>')
    else:
        summary = ""

    name_f = _field("name", "Name", _input("text", "name", name, "my-site", ' required pattern="[a-z][a-z0-9-]{0,30}"'),
                    "Lowercase letters, digits and hyphens, at most 31 characters.", at.get("name"))
    domain_f = _field("domain", "Own address", _input("text", "domain", domain, f"my-site.{base}"),
                      f"Leave it empty to use the name followed by .{esc(base)}.", at.get("domain"), optional=True)
    repo_f = _field("repo", "Repository", _input("text", "repo", v.get("repo", ""), "https://codeberg.org/you/site.git"), "", at.get("repo"), cls="all")
    ref_f = _field("ref", "Branch", _input("text", "ref", v.get("ref", "main"), "main"), "", None)
    token_f = _field("token", "Access token", _input("password", "token"),
                     "Only for a private repository. Use a read-only deploy token. It is stored and never shown again.", at.get("token"), optional=True)
    pkg_err = f'<small id="package-msg" class="err">{esc(at["package"])}</small>' if "package" in at else ""
    pkg_bad = ' aria-invalid="true"' if pkg_err else ""
    db_f = _field("dbinit", "Database schema file", _input("text", "dbInit", v.get("dbInit", ""), "schema.sql"),
                  "A .sql file in your site that creates the tables (for MongoDB, a .js file). It is loaded once, with the first release, while the database is still empty.",
                  at.get("dbinit"), optional=True, cls="pane-db")

    body = f"""{STYLE}<div><h1><b>New site.</b> Bring finished files or an app with its dependencies.</h1>
<p class="sub">webhost is where you deploy, not where you develop. Nothing is built here.</p></div>{summary}
<form method="post" action="/new" enctype="multipart/form-data" class="nf">
<input type="hidden" name="csrf" value="{who['csrf']}">
<section class="card" aria-labelledby="s1" id="template" tabindex="-1"><div class="nstep"><i aria-hidden="true">1</i><h2 id="s1">What kind of site</h2></div>{cards}{tpl_err}</section>
<section class="card" aria-labelledby="s2"><div class="nstep"><i aria-hidden="true">2</i><h2 id="s2">Name and address</h2></div>
<div class="row2">{name_f}<div><div class="src">Address</div><div class="addr">{addr}</div></div></div>
{domain_f}
<label class="tick box"><input type="checkbox" name="public" value="1"{public}><span><b>Public on the internet</b><span class="small mute" style="display:block">Anyone on the internet can reach the site. Leave it off to allow only your own networks.</span></span></label></section>
<section class="card" aria-labelledby="s3"><div class="nstep"><i aria-hidden="true">3</i><h2 id="s3">Content</h2></div>
<p class="pane-wp small mute">WordPress needs neither a repository nor a package. You add content in WordPress itself.</p>
<div class="pane-src">
<div class="tabs" role="radiogroup" aria-label="Where the content comes from"><label><input type="radio" id="mode-git" name="mode" value="git"{'' if package else ' checked'}>Git repository</label><label><input type="radio" id="mode-package" name="mode" value="package"{' checked' if package else ''}>Uploaded package</label></div>
<div class="pane-git"><p class="help">A repository with the finished files. Nothing is built here.</p><div class="fields">{repo_f}{ref_f}{token_f}</div></div>
<div class="pane-pkg drop"><label for="package">Choose a package</label><small>A .zip, .tgz or .tar.gz with the finished files.</small><input id="package" type="file" name="package" accept=".zip,.tgz,.tar.gz" aria-describedby="package-msg"{pkg_bad}>{pkg_err}</div>
{db_f}
</div>{again}</section>
<div class="decision"><p>Takes two to three minutes. webhost checks your content before it goes live.<span class="src" style="display:block">You can follow each step on the next page.</span></p>
<div class="actions"><a class="btn ghost" href="/">Cancel</a><button class="btn" type="submit">Create site</button></div></div>
</form>"""
    h.send(400 if errors else 200, page("New site", who["user"], body, crumbs=[("Sites", "/"), ("New site", None)]))


def create(h, who, fields, files):
    conf = h.server.conf
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
    mine = [s for s in h.sites(who) if s.get("owner") == who["user"]]
    taken = {s.get("name") for s in load(os.path.join(DATA, "sites.json"), [])}
    taken |= {r.get("site") for r in h.requests({"admin": True}) if r.get("status") not in ("rejected", "failed")}
    source_field = "package" if fields.get("mode") == "package" else "repo"
    err = None
    if not tpl:
        err = ("template", "Pick a template.")
    elif not SITE_RE.match(name):
        err = ("name", NAME_MSG)
    elif name in taken or name.startswith("canary-"):
        err = ("name", f"A site named {name} exists or is being created.")
    elif not DOMAIN_RE.match(domain):
        err = ("domain", f"{domain} is not a valid address.")
    elif not who["admin"] and len(mine) >= int(conf.get("site_limit", 10)):
        err = ("name", f"You have reached the limit of {conf.get('site_limit', 10)} sites.")
    elif tpl.get("app") == "wordpress":
        repo, has_pkg = "", False
    elif repo and has_pkg:
        err = ("repo", "Give a repository or a package, not both.")
    elif repo and not (REPO_RE.match(repo) and REF_RE.match(ref) and not ref.startswith("-")):
        err = ("repo", "The repository must be an https:// address ending in .git, and the branch a plain name.")
    elif fields.get("token") and not (repo and TOKEN_RE.fullmatch(fields["token"])):
        err = ("token", "An access token goes with a repository, as one line of printable characters.")
    elif not repo and not has_pkg:
        err = (source_field, "Give a repository or upload a package.")
    elif fields.get("dbInit") and not DBINIT_RE.fullmatch(fields["dbInit"]):
        err = ("dbinit", "The database schema is a .sql (or .js) file inside your site, such as schema.sql or db/schema.sql.")
    elif has_pkg and not PACKAGE_RE.search(pkg[0]):
        err = ("package", "Packages are .zip, .tgz or .tar.gz files.")
    if err:
        return h.new(who, [err], fields)
    if has_pkg:
        h.save_package(name, who["user"], pkg[0], pkg[1])
    source = {"repo": repo, "ref": ref} if repo else ({"upload": True} if has_pkg else {})
    rid = h.write_request({"kind": "create", "user": who["user"], "groups": who["groups"], "site": name,
                              "template": tpl["name"], "runtime": tpl["runtime"], "domain": domain,
                              "public": bool(fields.get("public")), "source": source,
                              "dbInit": fields.get("dbInit", "") if tpl.get("database") not in (None, "", "none") else ""},
                             token=fields.get("token") or None)
    h.redirect(f"/requests/{rid}")
