"""One site: detail, backups, restore, upload, token, database, analytics switch, delete. Handler bodies; the Portal class delegates here."""
import json
import os
import re
import time
import portal_core
from portal_core import (DATA, DBINIT_RE, DB_NAMES, INSPECT, LIVE_STATES, PACKAGE_RE, RULES, TOKEN_RE, ago, auto_tag, backups, blocked_rules,
                         change, day, esc, exact, guide_text, hour_window, load, mono, page, parse_ts, pill, plural, scope_pill, sparkline, stamp_text)

CSS = """<style>
.site-pulls{border:1px solid var(--div);border-radius:12px;overflow:hidden}
.site-pulls .pr{display:grid;grid-template-columns:minmax(0,1fr) auto auto;gap:6px 12px;align-items:center;padding:9px 14px;border-top:1px solid var(--div);font-size:13px}
.site-pulls .pr:first-child{border-top:0}
.site-pulls .hash{font-family:var(--mono);font-size:12px;color:var(--mute)}
.site-ok{border-color:#b9d8c6;background:#f6fbf8;flex-direction:row;align-items:flex-start;gap:12px}
.site-ok svg{flex:none;margin-top:1px}
.site-find{border-color:var(--findline)}
.site-find ol{margin:0;padding-left:20px;display:flex;flex-direction:column;gap:4px}
.site-where{display:flex;flex-wrap:wrap;gap:2px 10px}
.site-where .mono{font-size:13px;overflow-wrap:anywhere}
.site-bk fieldset{border:0;margin:0;padding:0;min-width:0}
.site-bk legend{position:absolute;left:-9999px}
.site-warn{font-size:13px;color:var(--bad);font-weight:600}
.site-sw{display:flex;flex-wrap:wrap;align-items:flex-end;justify-content:space-between;gap:12px}
.site-sw>*{min-width:0}
.site-row{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px 16px}
.site-row>p{flex:1 1 260px}
.site-stat{display:flex;flex-wrap:wrap;align-items:flex-end;justify-content:space-between;gap:12px}
.site-gets>summary{font-size:16px;font-weight:600;color:var(--ink)}
</style>"""
CHECK = ('<svg width="24" height="24" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10" fill="#ddeee3" stroke="#1f6b4f" stroke-width="1.5"/>'
         '<path d="M7.5 12.5l3 3 6-7" fill="none" stroke="#1f6b4f" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>')
VOLID_TIME = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$")


def human_size(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return ""
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def template_info(h, s):
    t = {t["name"]: t for t in h.server.conf.get("templates", [])}.get(s.get("template")) or {}
    return t, t.get("label") or s.get("template") or ""


def restore_time(b):
    """The moment a restore point was taken: the time inside its volid, else the listed time."""
    m = VOLID_TIME.search(str(b.get("volid", "")))
    return parse_ts(m.group(1)) if m else parse_ts(b.get("time"))


def restore_label(ts):
    """"Last night 01:30 UTC", "Yesterday 01:30 UTC", "Sat 31 Oct 01:30 UTC"."""
    text = stamp_text(ts)
    if text.startswith("Today"):
        return ("Last night" if time.gmtime(ts).tm_hour < 6 else "Today") + text[len("Today"):]
    return text


# ── recent pulls: reads what the mirror writes (webhost-mirror.sh history()): {rev, checked, verdict, rules} per line ──

def pull_rows(site, insp):
    rows = []
    try:
        with open(os.path.join(INSPECT, f"{site}.history.jsonl"), encoding="utf-8") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    rows.append(r)
    except OSError:
        pass
    rev = str(insp.get("rev") or "") if insp else ""
    known = any(rev and str(r.get("rev") or "")[:7] == rev[:7] for r in rows)
    if insp and insp.get("verdict") in ("pass", "block") and not known:
        rows.append({"rev": insp.get("rev"), "checked": insp.get("checked"), "verdict": insp["verdict"]})
    return sorted(rows, key=lambda r: parse_ts(r.get("checked")) or 0, reverse=True)


def pull_log(site, insp=None):
    if insp is None:
        insp = load(os.path.join(INSPECT, f"{site}.json"), None)
    rows = pull_rows(site, insp)

    def one(r):
        rev = str(r.get("rev") or "")[:7]
        passed = r.get("verdict") == "pass"
        return (f"<div role='row' class='pr'><span role='cell'>{ago(r.get('checked'))}</span><span role='cell' class='hash'>{esc(rev or 'package')}</span>"
                f"<span role='cell'>{pill('passed' if passed else 'blocked')}</span></div>")
    if rows:
        more = (f"<details><summary>Show {len(rows) - 5} older</summary><div role='table' aria-label='Older pulls' class='site-pulls'>{''.join(one(r) for r in rows[5:])}</div></details>"
                if len(rows) > 5 else "")
        table = (f"<div role='table' aria-label='Recent pulls' class='site-pulls'>{''.join(one(r) for r in rows[:5])}</div>{more}"
                 "<p class='src' style='margin-top:6px'>Passed revisions go live. Blocked ones do not.</p>")
    else:
        table = "<p class='small mute'>Nothing yet. The next new revision shows up here.</p>"
    return f"<div><h3 style='margin-bottom:6px'>Recent pulls</h3>{table}</div>"


def looked_at(site):
    try:
        return ago(os.path.getmtime(os.path.join(INSPECT, f"{site}.fetched")))
    except OSError:
        return ""


# ── blocks of the page ──

def status_block(s, insp, src, running, stopped, is_wp):
    if stopped:
        if running:
            return ("<section class='card site-ok' aria-labelledby='status'>" + CHECK + "<div><h2 id='status'>Your live site is not affected</h2>"
                    "<p style='margin-top:4px'>Visitors still see the last release that passed. A blocked release never goes live.</p></div></section>")
        return ("<section class='card' aria-labelledby='status'><h2 id='status'>The newest release was blocked</h2>"
                "<p>It never goes live. The findings below say what to change.</p></section>")
    if not running:
        return f"<section class='card' aria-labelledby='status'><h2 id='status'>This site is {esc(s.get('state', 'not running'))}</h2><p>It answers again once it is live.</p></section>"
    when_ = ago(insp.get("checked")) if insp else ""
    if is_wp:
        line = f"WordPress is running and its last inspection passed {when_}. Content is managed in WordPress itself." if insp and insp.get("verdict") == "pass" else "WordPress is running. Content is managed in WordPress itself."
    elif insp and insp.get("verdict") == "pass":
        line = (f"The package uploaded {when_} passed inspection and is live." if src.get("upload") else f"The newest release passed inspection {when_} and is live.")
    elif src:
        line = "The first inspection has not run yet. It happens within a few minutes."
    else:
        line = "The site is running."
    return f"<section class='card site-ok' aria-labelledby='status'>{CHECK}<div><h2 id='status'>Nothing needs doing</h2><p style='margin-top:4px'>{line}</p></div></section>"


def findings_view(insp, src):
    found = blocked_rules(insp)
    if not found:
        return ""
    n = sum(len(fs) for fs in found.values())
    again = "upload a new package" if src.get("upload") else "push to your branch"
    fix_all = "Fix it" if n == 1 else ("Fix both" if n == 2 else "Fix all of them")
    cards = ""
    for rule, fs in found.items():
        title, why, fix = RULES.get(rule, (rule, "Inspection stopped this release.", "Fix what the findings name."))
        line = lambda f: f"<div class='site-where'><span class='mono'>{esc(f.get('file'))}</span><span class='src'>{esc(f.get('detail'))}</span></div>"
        where = "".join(line(f) for f in fs[:5])
        if len(fs) > 5:
            where += f"<details><summary>Show all {len(fs)} findings</summary>{''.join(line(f) for f in fs[5:])}</details>"
        cards += (f"<article class='card site-find'><div class='acts'>{pill('blocked')}<h3 style='font-size:16px'>{esc(title)}</h3></div>"
                  f"<div><div class='src' style='font-weight:600'>What</div><p>{why}</p></div>"
                  f"<div><div class='src' style='font-weight:600'>Where</div><div style='display:flex;flex-direction:column;gap:4px;margin-top:2px'>{where}</div></div>"
                  f"<div class='inset'><div class='src' style='font-weight:600'>How to fix it</div><ol class='next'><li>{fix}</li>"
                  f"<li>Then {again}. The new release is inspected by itself.</li></ol></div></article>")
    return (f"<section aria-labelledby='stopped' style='display:flex;flex-direction:column;gap:12px'><div><h2 id='stopped'>What stopped the newest release</h2>"
            f"<p class='src' style='margin-top:2px'>Pulled {ago(insp.get('checked'))}. It failed inspection with {plural(n, 'finding')}. {fix_all}, then {again.split(' ')[0]} again.</p></div>{cards}</section>")


def token_form(who, name):
    return ("<details class='inset'><summary>Replace access token</summary>"
            f"<form method='post' action='/sites/{esc(name)}/token' enctype='multipart/form-data' style='display:flex;flex-direction:column;gap:10px;margin-top:6px'>"
            f"<input type='hidden' name='csrf' value='{who['csrf']}'>"
            "<label class='f'>New access token<input type='password' name='token' autocomplete='off' style='max-width:420px'></label>"
            "<p class='src'>For a private repository: a read-only deploy token. It is never shown again. Leave the field empty to remove the token: a private repository can then no longer be read, and pushes stop going live.</p>"
            "<div class='actions'><button class='btn' type='submit'>Set access token</button></div></form></details>")


def update_card(h, who, s, insp, src, is_wp):
    name = s["name"]
    head = "<h2 id='upd'>How to update this site</h2>"
    if src.get("upload"):
        info = load(os.path.join(DATA, "uploads", name, "package.json"), {}) or {}
        passed = bool(insp) and insp.get("verdict") == "pass"
        waiting = [f for f in (os.listdir(os.path.join(DATA, "uploads", name)) if os.path.isdir(os.path.join(DATA, "uploads", name)) else []) if PACKAGE_RE.search(f)]
        label = "Live package" if passed else "Newest package"
        bits = ""
        if info.get("name"):
            bits += f"<b class='mono' style='font-weight:500;font-size:15px;overflow-wrap:anywhere'>{esc(info['name'])}</b>"
        if info.get("size"):
            bits += f"<span>{esc(human_size(info['size']))}</span>"
        stamp = info.get("time") or (insp or {}).get("checked")
        if stamp:
            bits += f"<span class='src'>{'Uploaded' if info.get('time') else 'Inspected'} {ago(stamp)}</span>"
        if not passed and insp:
            bits += pill("blocked", "not live")
        current = (f"<div class='inset'><div class='src' style='font-weight:600'>{label}</div><div style='display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 14px'>{bits}</div></div>"
                   if bits else "")
        wait = "<p class='small'>A new package is waiting to be inspected.</p>" if waiting else ""
        keeps = "until then the package above keeps running" if passed and bits else "until then the site keeps its last release"
        return (f"<section class='card' aria-labelledby='upd'>{head}{current}{wait}"
                f"<form method='post' action='/sites/{esc(name)}/upload' enctype='multipart/form-data' style='display:flex;flex-direction:column;gap:10px'>"
                f"<input type='hidden' name='csrf' value='{who['csrf']}'>"
                "<label class='f'>Package (.zip, .tgz or .tar.gz)<input type='file' name='package' accept='.zip,.tgz,.tar.gz' required></label>"
                f"<div class='site-row'><p class='src'>A new package is inspected first. It goes live only if it passes; {keeps}.</p>"
                "<button class='btn' type='submit'>Upload a new version</button></div></form></section>")
    if src.get("repo"):
        look = looked_at(name)
        look = f"<p class='src'>Last looked for changes {look}.</p>" if look else ""
        return (f"<section class='card' aria-labelledby='upd'>{head}"
                f"<p>Push to <code>{esc(src.get('ref', 'main'))}</code> of <code>{esc(src['repo'])}</code>. A passing revision is live within about two minutes.</p>"
                f"{look}{pull_log(name, insp)}{token_form(who, name)}</section>")
    if is_wp:
        return (f"<section class='card' aria-labelledby='upd'>{head}<p>Write posts, change themes and add plugins in WordPress itself. There is no repository to push to.</p>"
                "<div class='site-row'><p class='src'>The admin is reachable only from your own networks. From anywhere else the button will not load.</p>"
                f"<a class='btn' href='https://{esc(s['domain'])}/wp-admin'>Open WordPress admin</a></div></section>")
    return f"<section class='card' aria-labelledby='upd'>{head}<p>This site has no repository or package to update.</p></section>"


def week_card(h, who, s):
    name = s["name"]
    link = f"/sites/{esc(name)}/analytics"
    wid = load(portal_core.ANALYTICS_MAP, {}).get(name)
    if not wid:
        return (f"<section class='card' aria-labelledby='an'><h2 id='an'>Visitors this week</h2><p>Analytics are being set up. This takes a minute or two the first time.</p>"
                f"<div class='actions'><a class='btn ghost' href='{link}'>See analytics</a></div></section>")
    start, end = hour_window(7)
    try:
        st = portal_core.Umami.stats(wid, start, end)[1] or {}
        series = portal_core.Umami.series(wid, start, end, "day")[1] or {}
    except (OSError, ValueError, KeyError, TypeError):
        return (f"<section class='card' aria-labelledby='an'><h2 id='an'>Visitors this week</h2><p class='mute'>The numbers are not available right now. Try again in a few minutes.</p>"
                f"<div class='actions'><a class='btn ghost' href='{link}'>See analytics</a></div></section>")
    v = st.get("visitors", 0) or 0
    prev = (st.get("comparison") or {}).get("visitors")
    chg = ""
    if prev:
        text, cls = change(v, prev)
        chg = f"<div class='{cls}' style='font-size:13px;margin-top:2px'>{esc(text)} than the week before</div>"
    elif not st.get("pageviews"):
        chg = "<div class='src' style='margin-top:2px'>Nothing counted yet. It starts with the next visitor.</div>"
    pts = sorted(series.get("sessions") or [], key=lambda r: str(r.get("x")))[-7:]
    vals = [r.get("y", 0) for r in pts]
    first, last = (end / 1000 - 6 * 86400), end / 1000
    span = f"{day(first)} to {day(last)}"
    spark = sparkline(vals, large=True, text=f"Visitors per day for {name}, {span}: {', '.join(str(int(x)) for x in vals)}") if len(vals) > 1 else ""
    return (f"<section class='card' aria-labelledby='an'><div class='hdr'><h2 id='an'>Visitors this week</h2><span class='src'>{esc(span)}. Counted without cookies.</span></div>"
            f"<div class='site-stat'><div><span class='big'>{v:,}</span> <span class='mute'>visitors</span>{chg}</div>{spark}</div>"
            f"<div class='actions'><a class='btn ghost' href='{link}'>See analytics</a></div></section>")


def analytics_card(h, who, s):
    if s.get("analytics"):
        return week_card(h, who, s)
    name = s["name"]
    app = not auto_tag(s)
    return ("<section class='card' aria-labelledby='an'><h2 id='an'>Visitors are not counted yet</h2>"
            "<p>Count visitors without cookies. The numbers stay on this server, and visitors only ever talk to your own site.</p>"
            + ("<p class='src'>Your app builds its own pages, so counting needs one line in it. The next page shows which.</p>" if app else "")
            + f"<div class='actions'><a class='btn ghost' href='/sites/{esc(name)}/analytics'>{'How to do it' if app else 'Set up analytics'}</a></div></section>")


def inspection_side(insp):
    if not insp:
        return "<section class='card' aria-labelledby='insp'><h2 id='insp'>Last inspection</h2><p class='small mute'>Not inspected yet.</p></section>"
    verdict = insp.get("verdict")
    n = len(blocked_rules(insp)) and sum(len(fs) for fs in blocked_rules(insp).values())
    warns = [f for f in insp.get("findings", []) if f.get("level") != "block"]
    if verdict == "block":
        line = f"Blocked with {plural(n, 'finding')}, listed above." if n else "Blocked."
    else:
        line = "No findings." if not warns else f"Passed with {plural(len(warns), 'warning')}."
    extra = ""
    if warns:
        extra = (f"<details style='font-size:13px'><summary>Show {'the warning' if len(warns) == 1 else 'the warnings'}</summary><ul class='files'>"
                 + "".join(f"<li>{esc(f.get('file'))}<span>{esc(f.get('detail'))}</span></li>" for f in warns) + "</ul></details>")
    rev = str(insp.get("rev") or "")[:12]
    rev = f"<details style='font-size:13px'><summary>Revision</summary><p class='mono mute' style='margin-top:4px'>{esc(rev)}</p></details>" if rev else ""
    return (f"<section class='card' aria-labelledby='insp'><div class='row' style='align-items:center'><h2 id='insp'>Last inspection</h2>{pill(verdict or '?')}</div>"
            f"<p>{line}</p><p class='src'>{ago(insp.get('checked'))}</p>{extra}{rev}</section>")


GUIDE_WORDS = ((" (options.dbInit)", ""), ("listed in `options.dataDirs`", "listed as data folders in the site's settings"), ("set `options.start`", "set the start command"),
               ("set `options.cleanUrls`", "turn on clean URLs in the site's settings"), ("set `options.docroot` to `\".\"`", "set the document root to `.` in the site's settings"))


def plain_guide(text):
    for old, new in GUIDE_WORDS:
        text = text.replace(old, new)
    return re.sub(r"`?options\.(\w+)`?", "the \\1 setting", text)


def guide_fold(conf, template):
    t = {t["name"]: t for t in conf.get("templates", [])}.get(template) or {}
    flat = [g for g in t.get("guide", []) if isinstance(g, str)]
    groups = [g for g in t.get("guide", []) if isinstance(g, dict)] + ([{"group": "", "items": flat}] if flat else [])
    cards = "".join("<div>" + (f"<h3>{esc(g.get('group', ''))}</h3>" if g.get("group") else "")
                    + "<ul>" + "".join(f"<li>{guide_text(plain_guide(i))}</li>" for i in g.get("items", [])) + "</ul></div>" for g in groups)
    if not cards:
        return ""
    return ("<section class='card'><details class='site-gets'><summary>What your site gets</summary>"
            "<p class='src' style='margin:6px 0 10px'>What this template gives you, and what it expects from you. The same for every site of this kind.</p>"
            f"<div class='guide'>{cards}</div></details></section>")


def detail(h, who, name):
    s = h.site(who, name)
    if not s:
        return h.fail(404, "No such site, or not yours.")
    insp = load(os.path.join(INSPECT, f"{name}.json"), None)
    src = s.get("source") or {}
    state = s.get("state", "?")
    running = state in LIVE_STATES
    stopped = bool(src) and bool(insp) and insp.get("verdict") == "block"
    t, label = template_info(h, s)
    is_wp = t.get("app") == "wordpress" or s.get("template") == "wordpress"
    url = f"https://{esc(s['domain'])}"
    pills = pill(state) + (pill("blocked", "newest release blocked") if stopped else "") + scope_pill(s.get("public"))
    head = (f"<div class='row'><div class='grow'><h1><span class='mono'>{esc(name)}</span></h1>"
            f"<div class='acts' style='margin-top:8px'><a class='mono' href='{url}'>{esc(s['domain'])}</a>{pills}<span class='src'>{esc(label)}</span></div></div>"
            f"<a class='btn ghost' href='{url}'>Open site</a></div>")
    db = h.database_card(who, s)
    main = (status_block(s, insp, src, running, stopped, is_wp) + (findings_view(insp, src) if stopped else "")
            + update_card(h, who, s, insp, src, is_wp) + db + h.analytics_card(who, s))
    side = (inspection_side(insp) + h.backup_list(who, name) + guide_fold(h.server.conf, s.get("template")))
    danger = (f"<form class='card dangerzone' method='post' action='/sites/{esc(name)}/delete' aria-labelledby='dz'><input type='hidden' name='csrf' value='{who['csrf']}'>"
              f"<h2 id='dz' style='color:var(--bad)'>Danger zone</h2>"
              f"<p>Deleting {mono(name)} stops the site answering. Its backups are kept, and you can bring it back from Deleted sites on the Sites page.</p>"
              f"<label class='f' style='max-width:320px'>Type {esc(name)} to confirm<input type='text' name='confirm' required pattern='{esc(name)}' autocomplete='off'></label>"
              f"<div class='actions'><button class='btn danger guarded' type='submit'>Delete {esc(name)}</button></div></form>")
    body = f"{CSS}{head}<div class='cols'><div class='wide'>{main}</div><aside class='aside'>{side}</aside></div>{danger}"
    h.send(200, page(name, who["user"], body, crumbs=[("Sites", "/"), (name, None)]))


def backup_list(h, who, name):
    """The backups card: one form with a radio per restore point, one warning, one tick, one button."""
    pts = backups().get("sites", {}).get(name, [])
    head = "<div><h2 id='bk'>Backups</h2><p class='src' style='margin-top:2px'>Taken every night. Choose the moment to go back to.</p></div>"
    if not pts:
        return f"<section class='card' aria-labelledby='bk'>{head}<p class='small mute'>No backups yet; they are taken nightly.</p></section>"
    pts = sorted(pts, key=lambda b: -(restore_time(b) or 0))
    opts = "".join(f"<label><input type='radio' name='backup' value='{esc(b['volid'])}' required><span><b style='font-weight:600' title='{esc(exact(restore_time(b)))}'>{esc(restore_label(restore_time(b)))}</b>"
                   + (f" <span class='src'>{esc(human_size(b['size']))}</span>" if b.get("size") else "") + "</span></label>"
                   for b in pts if restore_time(b) is not None)
    return (f"<form class='card site-bk' method='post' action='/sites/{esc(name)}/restore' enctype='multipart/form-data' aria-labelledby='bk'>"
            f"<input type='hidden' name='csrf' value='{who['csrf']}'>{head}"
            f"<fieldset><legend>Restore points</legend><div class='opts'>{opts}</div></fieldset>"
            "<p class='site-warn'>Changes made since that backup are lost. This cannot be undone.</p>"
            "<label class='tick small'><input type='checkbox' name='confirm' value='1' required><span>I understand, and I want to restore this backup.</span></label>"
            "<div class='actions'><button class='btn guarded' type='submit'>Restore the chosen backup</button></div></form>")


def restore(h, who, name, fields, files, deleted=False):
    if deleted:
        d = next((d for d in h.deleted(who) if d["name"] == name), None)
        pts = d["backups"] if d else []
        if d and name in {s.get("name") for s in load(os.path.join(DATA, "sites.json"), [])}:
            return h.fail(409, f"A site named {name} exists again; delete it before restoring the old one.")
    else:
        pts = backups().get("sites", {}).get(name, []) if h.site(who, name) else []
    if not pts:
        return h.fail(404, "No such site with backups, or not yours.")
    if fields.get("confirm") != "1" or fields.get("backup") not in {b["volid"] for b in pts}:
        return h.fail(400, "Pick a backup and confirm.")
    rid = h.write_request({"kind": "restore", "user": who["user"], "groups": who["groups"], "site": name,
                              "backup": fields["backup"]})
    h.redirect(f"/requests/{rid}")


def upload(h, who, name, fields, files):
    s = h.site(who, name)
    pkg = files.get("package")
    if not s or not s.get("source", {}).get("upload"):
        return h.fail(404, "No such upload site, or not yours.")
    if not pkg or not pkg[1] or not PACKAGE_RE.search(pkg[0]):
        return h.fail(400, "Upload a .zip, .tgz or .tar.gz package.")
    h.save_package(name, who["user"], pkg[0], pkg[1])
    try:
        with open(os.path.join(DATA, "uploads", name, "package.json"), "w", encoding="utf-8") as fh:
            json.dump({"name": os.path.basename(pkg[0]), "size": len(pkg[1]), "time": int(time.time())}, fh)
    except OSError:
        pass
    h.redirect(f"/sites/{name}")


def token(h, who, name, fields, files):
    s = h.site(who, name)
    if not s or not s.get("source", {}).get("repo"):
        return h.fail(404, "No such repository site, or not yours.")
    t = fields.get("token", "")
    if t and not TOKEN_RE.fullmatch(t):
        return h.fail(400, "A token is one line of printable characters.")
    rid = h.write_request({"kind": "token", "user": who["user"], "groups": who["groups"], "site": name}, token=t)
    h.redirect(f"/requests/{rid}")


def delete(h, who, name, fields, files):
    s = h.site(who, name)
    if not s:
        return h.fail(404, "No such site, or not yours.")
    if fields.get("confirm") != name:
        return h.fail(400, "Type the site's name to delete it.")
    rid = h.write_request({"kind": "delete", "user": who["user"], "groups": who["groups"], "site": name})
    h.redirect(f"/requests/{rid}")


def database_card(h, who, s):
    t = {t["name"]: t for t in h.server.conf.get("templates", [])}.get(s["template"]) or {}
    db = t.get("database")
    if db in (None, "", "none") or t.get("app") == "wordpress":
        return ""
    name, cur, ext = s["name"], s.get("dbInit") or "", ".js" if db == "mongodb" else ".sql"
    now = (f"<p class='small'>First schema: <code>{esc(cur)}</code>. It was loaded if the database was empty.</p>" if cur
           else f"<p class='small mute'>The database starts empty. Name a {ext} file in your site to create its tables.</p>")
    return (f"<section class='card' aria-labelledby='db'><div><h2 id='db'>Database</h2><p class='small mute'>{DB_NAMES.get(db, db)}, on this site's own server.</p></div>{now}"
            f"<form method='post' action='/sites/{esc(name)}/dbinit' enctype='multipart/form-data' style='display:flex;flex-direction:column;gap:10px'>"
            f"<input type='hidden' name='csrf' value='{who['csrf']}'>"
            f"<label class='f'>Schema file in your site<input type='text' name='file' value='{esc(cur)}' placeholder='schema{ext}'></label>"
            "<div class='site-row'><p class='src'>Loaded once, and only while the database has no tables, so existing data is never touched.</p>"
            "<button class='btn' type='submit'>Load schema</button></div></form></section>")


def dbinit(h, who, name, fields, files):
    if not h.site(who, name):
        return h.fail(404, "No such site, or not yours.")
    f = fields.get("file", "").strip()
    if f and not DBINIT_RE.fullmatch(f):
        return h.fail(400, "Give a .sql (or .js) file inside your site, such as schema.sql or db/schema.sql.")
    rid = h.write_request({"kind": "dbinit", "user": who["user"], "groups": who["groups"], "site": name, "file": f})
    h.redirect(f"/requests/{rid}")


def toggle_form(h, who, name, on):
    """One button, no tick: turning analytics on or off is reversible, and the consequence sits beside the button."""
    note = ("Your site reloads with analytics. Visitors are not interrupted. You can turn it off again at any time." if on
            else "Stops counting and takes the line out of your pages in a new release. Numbers collected so far are kept.")
    return (f"<form class='site-row' method='post' action='/sites/{esc(name)}/analytics' enctype='multipart/form-data'>"
            f"<input type='hidden' name='csrf' value='{who['csrf']}'><input type='hidden' name='enabled' value='{'1' if on else '0'}'><input type='hidden' name='confirm' value='1'>"
            f"<p class='src'>{note}</p><button class='btn{'' if on else ' ghost'}' type='submit'>{'Turn analytics on' if on else 'Turn analytics off'}</button></form>")


def analytics_toggle(h, who, name, fields, files):
    site = h.site(who, name)
    if not site:
        return h.fail(404, "No such site, or not yours.")
    if fields.get("confirm") != "1":
        return h.fail(400, "Confirm the change first.")
    rid = h.write_request({"kind": "analytics", "user": who["user"], "groups": who["groups"], "site": name,
                              "enabled": fields.get("enabled") == "1", "domain": site.get("domain", "")})
    h.redirect(f"/requests/{rid}")
