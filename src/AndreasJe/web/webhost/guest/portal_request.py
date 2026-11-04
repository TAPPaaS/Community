"""A request's progress page and retry (portal v2). Handler bodies; the Portal class delegates here."""
import os
import re
import portal_core as core
from portal_core import DATA, INSPECT, RULES, ago, auto_tag, blocked_rules, details_log, esc, guide_block, load, page, parse_ts, pill, plural, stamp

OK = ("live", "done")
RUNNING = ("new", "checking", "inspecting", "creating", "applying", "restoring", "deleting")
NUMBERS = {2: "two", 3: "three", 4: "four", 5: "five", 6: "six"}

CSS = """<style>
.rq-top{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:6px 16px}
.rq-card h1{font-size:24px;overflow-wrap:anywhere}.rq-card .big-out{font-size:16px}
@media(min-width:760px){.rq-card h1{font-size:26px}}
.rq-foot{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px 16px;margin-top:6px}
.rq-foot .actions{margin:0 0 0 auto}.rq-foot form{display:contents}
.rq-steps{list-style:none;margin:0;padding:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,170px),1fr));gap:12px}
.rq-steps li{border-top:4px solid var(--div);padding-top:10px;display:flex;flex-direction:column;gap:4px;min-width:0}
.rq-steps li.done{border-color:var(--acc)}.rq-steps li.now{border-color:#c98a1a}.rq-steps li.stop{border-color:var(--bad)}
.rq-steps .hd2{display:flex;align-items:center;gap:8px}
.rq-dot{flex:none;width:24px;height:24px;border-radius:99px;border:1.5px solid var(--field);background:#fff;color:var(--mute);display:inline-flex;align-items:center;justify-content:center;font-size:12px;font-weight:700}
.done .rq-dot{background:var(--acc);border-color:var(--acc);color:#fff}.now .rq-dot{background:var(--runbg);border-color:#c98a1a;color:var(--run)}.stop .rq-dot{background:var(--badbg);border-color:var(--bad);color:var(--bad)}
.rq-lab{font-size:12px;font-weight:600;color:var(--mute)}.now .rq-lab{color:var(--run)}.stop .rq-lab{color:var(--bad)}
.rq-log{list-style:none;margin:0;padding:0;display:flex;flex-direction:column}
.rq-log li{display:flex;gap:12px;align-items:flex-start;padding:9px 0;border-top:1px solid var(--div)}
.rq-log .ic{flex:none;margin-top:2px;width:16px;height:16px}.rq-log .t{min-width:0}.rq-log .t>div:first-child{font-weight:500}
.rq-log li.now .t>div:first-child,.rq-log li.stop .t>div:first-child{font-weight:600}
.rq-log li.wait .t>div:first-child,.rq-log li.skip .t>div:first-child{color:var(--mute)}
.rq-log .note{font-size:13px;color:var(--mute)}.rq-log .now .note{color:var(--run)}.rq-log .stop .note{color:var(--bad)}
.rq-tech{border-top:1px solid var(--div);padding-top:4px}
.rq-files{display:flex;flex-direction:column;gap:4px}
.rq-files>div{display:flex;flex-wrap:wrap;justify-content:space-between;gap:4px 16px;padding:8px 12px;border-radius:10px;background:var(--soft)}
.rq-files .mono{font-size:13px;overflow-wrap:anywhere}
.rq-start{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,220px),1fr));gap:14px}
.rq-start p{margin:4px 0 0;color:var(--mute)}
</style>"""

ICONS = {
    "done": '<svg width="16" height="16" viewBox="0 0 16 16"><circle cx="8" cy="8" r="8" fill="#1f6b4f"/><path d="M4.6 8.4l2.2 2.2 4.4-4.8" fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    "now": '<svg width="16" height="16" viewBox="0 0 16 16"><circle cx="8" cy="8" r="7" fill="#f8e8c4" stroke="#c98a1a" stroke-width="1.5"/><circle cx="8" cy="8" r="3" fill="#7a4a00"/></svg>',
    "stop": '<svg width="16" height="16" viewBox="0 0 16 16"><circle cx="8" cy="8" r="8" fill="#8e2518"/><path d="M8 4.2v4.6M8 11.1v.4" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/></svg>',
    "wait": '<svg width="16" height="16" viewBox="0 0 16 16"><circle cx="8" cy="8" r="7" fill="#fff" stroke="#d8cfbc" stroke-width="1.5"/></svg>',
}
TICK = '<svg width="12" height="12" viewBox="0 0 12 12"><path d="M2.5 6.5l2.3 2.3 4.7-5" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>'

# Fields the tappaas tooling checks, as a person would name them.
FIELDS = {"memory": ("Memory", " MB"), "cores": ("Cores", ""), "diskSize": ("Disk size", " GB")}
FIELD_RE = re.compile(r"Field (\w+): value (-?\d+) is (below minimum|above maximum) (-?\d+)")
# What the sync says when it refuses a request: (message, what happened, what to do).
REFUSALS = (
    (r"^A site named (.+) exists\.$", "A site named {0} already exists.", "Open the existing site, or choose a different name for the new one."),
    (r"^Invalid site name\.", "That name cannot be used.", "Use lowercase letters, digits and hyphens, starting with a letter, like my-site."),
    (r"^(.+) is used by another site\.$", "The address {0} is already used by another site.", "Choose a different name; the address follows from it."),
    (r"^The limit of (\d+) sites is reached\.", "You have reached the limit of {0} sites.", "Delete a site you no longer need, then create this one."),
    (r"^Unknown template", "That template is no longer offered.", "Choose another template."),
    (r"^Unknown user", "Your account was not recognised.", "Sign in again. If it keeps happening, ask whoever installed webhost."),
    (r"^The (access )?token is not valid", "The access token was not accepted.", "Give the token again: a single line, without spaces."),
    (r"^The request does not validate", "Some of the settings were not accepted.", "Change the settings and try again. If it keeps happening, give the technical log to whoever installed webhost."),
    (r"^(.+) is not yours\.$", "{0} belongs to someone else.", "Only its owner or an installer can change it."),
    (r"^No site (.+?)( to restore)?\.$", "There is no site named {0}.", "Check the name on your sites page."),
    (r"^(.+) is not running yet\.$", "{0} is not running yet.", "Wait until it is live, then try again."),
    (r"^Unknown backup", "That backup is not known.", "Choose a backup on the site page."),
    (r"^Give a \.sql file", "The database file must be a .sql file of your site, such as schema.sql or db/schema.sql.", "Set the file again on the site page."),
    (r"^The file must be inside your site", "The database file must be inside your site.", "Set a file from your site, such as db/schema.sql."),
)
SECRETISH = re.compile(r"\d{4}-\d\d-\d\dT|/(?:home|srv|etc|var|usr|opt)/|VMID", re.I)


def _a(href, label, primary=False):
    return f'<a class="btn{"" if primary else " ghost"}" href="{esc(href)}">{esc(label)}</a>'


def _foot(note, *buttons):
    left = f'<span class="src">{note}</span>' if note else ""
    return f'<div class="rq-foot">{left}<div class="actions">{"".join(buttons)}</div></div>'


def field_problem(msg):
    """"Memory must be 512 MB or more. You chose 256 MB." from the tooling's field message; "" when it is not one."""
    m = FIELD_RE.search(msg or "")
    if not m:
        return ""
    key, val, rel, lim = m.groups()
    name, unit = FIELDS.get(key, (re.sub(r"(?<!^)([A-Z])", r" \1", key).capitalize(), ""))
    return f"{name} must be {lim}{unit} or {'more' if rel.startswith('below') else 'less'}. You chose {val}{unit}."


def refusal(msg):
    """(what happened, what to do) in plain words for a refusal message; generic when unknown."""
    for rx, out, nxt in REFUSALS:
        m = re.search(rx, msg or "")
        if m:
            return out.format(*[esc(g) for g in m.groups()]), nxt
    return "The request was refused.", "Check the settings and try again. If it keeps happening, ask whoever installed webhost."


def _started(rid, r):
    t = parse_ts(r.get("created"))
    if t is None:
        m = re.match(r"\d{8}T\d{6}Z", str(rid))
        t = parse_ts(m.group(0)) if m else None
    return t


def _steps(r):
    steps = core.STEPS.get(r.get("kind")) or [("new", "New", "Your request is saved. webhost picks it up within a minute."), ("done", "Done", "The change is made.")]
    if r.get("kind") == "create" and not r.get("source"):
        steps = [s for s in steps if s[0] != "inspecting"]
    return steps


def _stop_key(r, status, inspection_stop):
    """The step that was running when the request stopped."""
    keys = [s[0] for s in _steps(r)]
    if status == "rejected":
        if inspection_stop and "inspecting" in keys:
            return "inspecting"
        return "checking" if r.get("kind") == "create" else "new"
    return keys[-2] if len(keys) > 2 else keys[0]


def _marks(keys, status, stop):
    """{step key: done|now|stop|skip|wait}; stop is the key a failure or refusal stopped at, None otherwise."""
    if status in OK:
        return {k: "done" for k in keys}
    at = keys.index(stop) if stop in keys else (keys.index(status) if status in keys else 0)
    if stop:
        return {k: ("done" if i < at else "stop" if i == at else "skip") for i, k in enumerate(keys)}
    return {k: ("done" if i < at else "now" if i == at else "wait") for i, k in enumerate(keys)}


def stepper(r, status, stop, stop_word, marks):
    steps = _steps(r)
    words = {"done": "Done", "now": "Now", "stop": stop_word, "skip": "Did not run", "wait": "Waiting"}
    items = ""
    for i, (key, name, what) in enumerate(steps):
        m = marks[key]
        dot = TICK if m == "done" else ("!" if m == "stop" else str(i + 1))
        cur = ' aria-current="step"' if m in ("now", "stop") else ""
        items += (f'<li class="{m}"{cur}><div class="hd2"><span class="rq-dot" aria-hidden="true">{dot}</span><b>{esc(name)}</b></div>'
                  f'<span class="rq-lab">{esc(words[m])}</span><span class="src">{esc(what)}</span></li>')
    ol = f'<ol class="rq-steps">{items}</ol>'
    if status in RUNNING:
        return f'<section class="card" aria-labelledby="stepsh"><h2 id="stepsh">Where it is</h2>{ol}</section>'
    name = next((n for k, n, _ in steps if k == stop), "")
    summary = "all done" if status in OK else f"stopped at {name}"
    count = NUMBERS.get(len(steps), str(len(steps)))
    return (f'<section class="card" aria-label="The steps" style="padding-top:6px;padding-bottom:6px"><details><summary>Show the {count} steps · {esc(summary)}</summary>'
            f'<div style="margin-top:10px">{ol}</div></details></section>')


def _log_entries(r, has_db):
    """(text, step key) for the plain-language progress log of a kind."""
    site, kind = r.get("site", ""), r.get("kind")
    saved = ("Saving your request", "new")
    if kind == "create":
        rows = [saved, ("Checking the name, address and template", "checking")]
        if r.get("source"):
            rows.append(("Inspecting your content", "inspecting"))
        rows += [("Copying your files", "creating"), ("Starting the container", "creating")]
        if has_db:
            rows.append(("Setting up the database", "creating"))
        return rows + [("Waiting for the address to answer", "live")]
    if kind == "restore":
        return [saved, (f"Putting {site} back as it was at the backup", "restoring"), ("Waiting for the site to answer", "live")]
    if kind == "delete":
        return [saved, (f"Removing the container of {site}", "deleting"), ("Keeping the backup", "done")]
    if kind == "analytics":
        return [saved, (f"Reloading the web server {'with' if r.get('enabled') else 'without'} the analytics route", "applying"), ("The change is live", "done")]
    if kind == "dbinit":
        what = f"Loading {r['file']} into the database" if r.get("file") else "Changing the database file"
        return [saved, (what, "applying"), ("The database is ready", "done")]
    if kind == "token":
        return [saved, ("Saving the access token for the next fetch", "done")]
    return [saved, ("Working on the request", "done")]


def progress(rid, r, status, stop, stop_word, marks, notes, refused, raw, has_db):
    keys = [s[0] for s in _steps(r)]
    rows = _log_entries(r, has_db)
    if refused:
        rows = rows[:max(1, next((i for i, (_, k) in enumerate(rows) if k == stop), 0) + 1)]
    seen, items = set(), ""
    for i, (text, key) in enumerate(rows):
        first = key not in seen
        seen.add(key)
        m = marks.get(key, "wait")
        if not first and m in ("now", "stop"):
            m = "wait" if m == "now" else "skip"
        note = notes.get(key, "") if first else ""
        if m == "skip" and not note:
            note = "Did not run."
        cur = ' aria-current="step"' if m in ("now", "stop") else ""
        items += (f'<li class="{m}"{cur}><span class="ic" aria-hidden="true">{ICONS["stop" if m == "stop" else "wait" if m in ("skip", "wait") else m]}</span>'
                  f'<div class="t"><div>{esc(text)}</div><div class="note">{note}</div></div></li>')
    hint = "In plain words. Updates with the page." if status in RUNNING else "In plain words."
    return (f'<section class="card" aria-labelledby="prog"><div class="hdr"><h2 id="prog">Progress</h2><span class="src">{hint}</span></div>'
            f'<ol class="rq-log">{items}</ol><div class="rq-tech">{details_log(raw)}</div></section>')


def technical_log(rid, r, status):
    lines = [f"Request {rid}: {r.get('kind')} {r.get('site')}, status {status}"]
    raw = core.read_log(rid).rstrip()
    if raw:
        lines.append(raw)
    if r.get("message") and str(r["message"]) not in raw:
        lines.append(("[Error] " if status in ("failed", "rejected") else "[Info] ") + str(r["message"]))
    if status == "failed" and r.get("kind") in ("create", "restore"):
        lines.append(f"Log: /home/tappaas/logs/webhost-{r.get('site')}-{r['kind']}.log")
    return "\n".join(lines)


def inspection_card(insp, blocked):
    if not insp:
        return ""
    bad = len(blocked_rules(insp)) and sum(len(v) for v in blocked_rules(insp).values())
    warns = [f for f in insp.get("findings", []) if f.get("level") != "block"]
    if insp.get("verdict") == "block":
        text = f"{plural(bad, 'problem')} found. They are listed above." if bad else "Inspection stopped this release."
    else:
        text = "No findings." if not warns else f"Passed, with {plural(len(warns), 'note')}."
    notes = ("<ul class='files'>" + "".join(f"<li>{esc(f.get('file'))}<span>{esc(f.get('detail'))}</span></li>" for f in warns) + "</ul>") if warns else ""
    rev = (insp.get("rev") or "")[:7]
    when = f'<span>Checked {ago(insp["checked"])}</span>' if parse_ts(insp.get("checked")) is not None else "<span>Checked</span>"
    ver = f' · content version <span class="mono">{esc(rev)}</span>' if rev else ""
    return (f'<section class="card" aria-labelledby="insp"><div class="hdr"><h2 id="insp">Inspection</h2>{pill("blocked" if insp.get("verdict") == "block" else "passed")}</div>'
            f'<p>{text}</p>{notes}<p class="src">Searched for server code in static sites, web shells, leaked keys and known critical vulnerabilities.</p>'
            f'<p class="src">{when}{ver}</p></section>')


def findings(insp, rid):
    cards = ""
    for rule, found in blocked_rules(insp).items():
        title, why, fix = RULES.get(rule, ("A problem inspection found", "Inspection stopped this release.", "Fix what the files below name."))

        def row(f):
            return f'<div><span class="mono">{esc(f.get("file"))}</span><span class="src">{esc(f.get("detail") or "")}</span></div>'
        shown = "".join(row(f) for f in found[:5])
        more = (f'<details><summary>Show all {len(found)} files</summary><div class="rq-files">{"".join(row(f) for f in found[5:])}</div></details>') if len(found) > 5 else ""
        cards += (f'<article class="card find"><div class="acts">{pill("blocked")}<h3 style="font-size:17px">{esc(title)}</h3><span class="src">{plural(len(found), "finding")}</span></div>'
                  f'<p>{esc(why)}</p><div><div class="src" style="margin-bottom:4px">Files</div><div class="rq-files">{shown}</div>{more}</div>'
                  f'<div class="inset"><h3>How to fix it</h3><ol class="next"><li>{fix}</li></ol></div></article>')
    if not cards:
        return ""
    foot = _foot("The new release is inspected by itself. Visitors see nothing at this address until it passes.",
                 _a(f"/new?from={rid}", "Fix it and create the site again", True))
    return f'<section aria-labelledby="finds" style="display:flex;flex-direction:column;gap:14px"><h2 id="finds">What inspection found</h2>{cards}{foot}</section>'


def _blocked_from_message(msg):
    """Findings named in "The inspection blocked the content: rule (file), ..." when the inspection file is gone."""
    found = [{"level": "block", "rule": a, "file": b} for a, b in re.findall(r"([a-z][a-z-]+) \(([^)]+)\)", msg.partition(":")[2])]
    return {"verdict": "block", "findings": found} if found else None


def _repo_label(src):
    repo = re.sub(r"^https?://|\.git$", "", src.get("repo", ""))
    return f"Branch <span class='mono'>{esc(src.get('ref', 'main'))}</span> of <span class='mono'>{esc(repo)}</span>"


def asked_card(h, r, site):
    kind = r.get("kind")
    if kind == "create":
        src = r.get("source") or {}
        content = _repo_label(src) if src.get("repo") else ("Uploaded package" if src.get("upload") else "None needed")
        tpl = {t["name"]: t for t in h.server.conf.get("templates", [])}.get(r.get("template", "")) or {}
        label = tpl.get("label") or r.get("template", "")
        rows = (f"<dt>Template</dt><dd>{esc(label)}</dd><dt>Address</dt><dd class='mono'>{esc(r.get('domain', ''))}</dd>"
                f"<dt>Reachable from</dt><dd>{'The internet' if r.get('public') else 'Your networks only'}</dd><dt>Content</dt><dd>{content}</dd>")
        head = "New site"
    elif kind == "restore":
        vol = str(r.get("backup") or "")
        when = parse_ts(vol.rsplit("/", 1)[-1]) if vol else None
        rows = f"<dt>Backup</dt><dd>{stamp(when) if when is not None else 'The newest one'}</dd>"
        head = "Restore"
    elif kind == "dbinit":
        rows = f"<dt>Database file</dt><dd class='mono'>{esc(r['file'])}</dd>" if r.get("file") else "<dt>Database file</dt><dd>None</dd>"
        head = "Database"
    elif kind == "analytics":
        return ("<section class='card'><h2>About analytics</h2><dl class='kv'><dt>Service</dt><dd>Umami</dd>"
                "<dt>Address</dt><dd>your own site, under <code>/_a/</code></dd><dt>Cookies</dt><dd>none</dd><dt>Refresh</dt><dd>every hour</dd></dl></section>")
    else:
        return ""
    return (f"<section class='card' aria-labelledby='asked'><div><div class='src'>{head}</div><h2 id='asked' class='mono' style='font-size:20px;font-weight:500'>{esc(site)}</h2></div>"
            f"<dl class='kv'>{rows}</dl></section>")


def getting_started(r):
    src = r.get("source") or {}
    if src.get("repo"):
        update = f"Push to the <span class='mono'>{esc(src.get('ref', 'main'))}</span> branch. The new release is inspected, then goes live in about 2 minutes."
    elif src.get("upload"):
        update = "Upload a new package on the site page. It is inspected, then goes live in about 2 minutes."
    else:
        update = "Manage the content in the admin of the site, reachable from your own networks."
    cols = f"<div><h3>Update the site</h3><p>{update}</p></div>"
    if src:
        cols += ("<div><h3>If a release fails</h3><p>The last good release stays live. The site page says what was wrong and how to fix it.</p></div>"
                 "<div><h3>Build the frontend first</h3><p>Ship the built output (for example <span class='mono'>dist/</span>) in the branch, not the build tools.</p></div>")
    return f'<section class="card" aria-labelledby="start"><h2 id="start">Getting started</h2><div class="rq-start">{cols}</div></section>'


class Ctx:
    """Everything a request's wording depends on."""

    def __init__(self, h, who, rid, r):
        self.h, self.who, self.rid, self.r = h, who, rid, r
        self.status, self.kind, self.site = r.get("status", "new"), r.get("kind"), r.get("site") or ""
        self.msg, self.src, self.n = str(r.get("message") or ""), r.get("source") or {}, esc(r.get("site") or "")
        self.exists = bool(self.site) and bool(h.site(who, self.site))
        self.insp_stop = self.status == "rejected" and self.kind == "create" and bool(self.src) and self.msg.startswith(("The inspection blocked", "No content could be fetched"))
        self.blocked = self.insp_stop and self.msg.startswith("The inspection blocked")
        self.finished = self.status in OK or self.status in ("failed", "rejected")
        self.keys = [s[0] for s in _steps(r)]
        self.at = self.keys.index(self.status) if self.status in self.keys else 0
        self.file = esc(r.get("file") or "")
        self.on = bool(r.get("enabled"))

    def step(self):
        return pill("applying", f"Step {self.at + 1} of {len(self.keys)}")

    def back(self, primary=True):
        if self.exists:
            return _a(f"/sites/{self.site}", "Go to the site page", primary)
        return _a("/", "Back to your sites", primary)


def R(p, headline, outcome, nxt="", extra="", foot="", stop_note=""):
    return {"pill": p, "headline": headline, "outcome": outcome, "next": nxt, "extra": extra, "foot": foot, "stop_note": stop_note or outcome}


def _create(c):
    r, n, msg = c.r, c.n, c.msg
    domain = esc(r.get("domain", ""))
    if c.status == "live" or c.status == "done":
        reach = "Anyone on the internet can reach" if r.get("public") else "Only your own networks can reach"
        open_ = _a(f"https://{r['domain']}", f"Open {c.site}", True) if r.get("domain") else ""
        return R(pill("live"), f"{n} is live.", "It passed inspection and the address answers." if c.src else "The address answers and the site is running.",
                 "Open the site to look at it, or go to the site page to manage it.",
                 foot=_foot(f"{reach} <span class='mono'>{domain}</span>." if domain else "", _a(f"/sites/{c.site}", "Go to the site page", not open_), open_))
    if c.status == "failed":
        field = field_problem(msg)
        retry_ok = retryable(r)
        outcome = esc(field) if field else "The site’s container could not be set up."
        tail = "If it stops at the same step, ask whoever installed webhost and give them the technical log."
        nxt = ("Nothing went live, and visitors see nothing at this address yet. " + ("Change the setting named above, then try again. " if field else "Try again; it takes two to three minutes. ") + tail)
        change = f"/new?from={c.rid}"
        if field:
            foot = _foot("The name, address, template and content are kept." if retry_ok else "Give the access token or package again: they are not kept.", _a(change, "Change the settings and try again", True))
        elif retry_ok:
            form = (f"<form method='post' action='/requests/{esc(c.rid)}/retry'><input type='hidden' name='csrf' value='{esc(c.who['csrf'])}'>"
                    f"<button class='btn' type='submit'>Try creating {n} again</button></form>")
            foot = _foot("Trying again uses the same name, address, template and content.", _a(change, "Change the settings"), form)
        else:
            foot = _foot("This opens the form with your settings. Give the access token or package again: they are not kept.", _a(change, "Change the settings and try again", True))
        return R(pill("failed"), f"{n} was not created.", outcome, nxt, foot=foot)
    if c.blocked:
        return R(pill("blocked"), f"{n} is not live yet.", "Its first release was blocked at inspection.",
                 "Nothing is running at this address yet. Fix the problems below; the site goes live with the first release that passes.", stop_note="Nothing was created.")
    if c.insp_stop:
        return R(pill("failed"), f"{n} was not created.", "No content could be fetched from the source.",
                 "Nothing was created. Check the repository address, the branch and the access token, then create the site again.",
                 foot=_foot("", _a(f"/new?from={c.rid}", "Change the settings and try again", True)))
    if c.status == "rejected":
        out, nxt = refusal(msg)
        taken = re.match(r"A site named (.+) exists\.", msg)
        theirs = taken and c.h.site(c.who, taken.group(1))
        extra = f"<p>The existing site is <a class='mono' href='/sites/{esc(taken.group(1))}'>{esc(taken.group(1))}</a>.</p>" if theirs else ""
        if theirs:
            btns = (_a(f"/sites/{taken.group(1)}", f"Go to the existing {taken.group(1)}"), _a(f"/new?from={c.rid}", "Choose a different name", True))
        elif re.match(r"The limit of", msg):
            btns = (_a("/", "Back to your sites", True),)
        else:
            btns = (_a(f"/new?from={c.rid}", "Change the settings and try again", True),)
        return R(pill("failed"), f"{n} could not be created.", out, nxt, extra, _foot("Nothing was created and nothing was changed.", *btns))
    texts = {"new": "Your request is saved. webhost picks it up within a minute.", "checking": "webhost is checking the name, the address and the template.",
             "inspecting": "Your content is being fetched and searched before anything is created."}
    return R(c.step(), f"Creating {n}", texts.get(c.status, "Setting up the container and the database. This takes two to three minutes."),
             f"Nothing to do. You can leave this page; {n} appears in your list when it is live.")


def _restore(c):
    n = c.n
    if c.status in OK:
        m = re.search(r"\(([^()]+)\)\.?$", c.msg)
        t = parse_ts(m.group(1)) if m else None
        out = f"It is back to the state of {stamp(t)}." if t is not None else "It is running again as it was at the backup."
        return R(pill("done", "restored"), f"{n} is restored.", out, "Changes made after that backup are gone. Check the site, then carry on.", foot=_foot("", c.back()))
    if c.status == "failed":
        return R(pill("failed"), f"{n} was not restored.", "The restore did not finish.",
                 "Check the site page to see whether the site still answers. You can try again from the backups there. If it stops the same way, ask whoever installed webhost and give them the technical log.",
                 foot=_foot("", c.back()))
    if c.status == "rejected":
        out, nxt = refusal(c.msg)
        return R(pill("failed"), f"{n} was not restored.", out, nxt, foot=_foot("Nothing was changed.", c.back()))
    return R(c.step(), f"Restoring {n}", "The site is being put back as it was at the backup. This takes a few minutes.",
             "Changes made after the backup are lost. Nothing to do; you can leave this page.")


def _delete(c):
    n = c.n
    if c.status in OK:
        return R(pill("done"), f"{n} is deleted.", "The site no longer answers. Its backups are kept.", "You can bring it back under Deleted sites on your sites page.", foot=_foot("", _a("/", "Back to your sites", True)))
    if c.status == "failed":
        return R(pill("failed"), f"{n} was not deleted.", "Something stopped the delete. An administrator has been told.",
                 "The site may still answer. Check it on your sites page, and try again if it is still there.", foot=_foot("", c.back()))
    if c.status == "rejected":
        out, nxt = refusal(c.msg)
        return R(pill("failed"), f"{n} was not deleted.", out, nxt, foot=_foot("Nothing was changed.", c.back()))
    return R(c.step(), f"Deleting {n}", "The container is removed. The backup stays.", "Nothing to do. The site can come back from its backup under Deleted sites.")


def _token(c):
    n = c.n
    if c.status in OK:
        if "removed" in c.msg:
            return R(pill("done"), f"The access token for {n} is removed.", "webhost no longer sends a token when it fetches your repository.",
                     "A public repository keeps working. A private one can no longer be read.", foot=_foot("", c.back()))
        return R(pill("done"), f"The access token for {n} is saved.", "It is kept for fetching your repository and is never shown again.", "The next fetch uses it.", foot=_foot("", c.back()))
    if c.status == "failed":
        return R(pill("failed"), f"The access token for {n} was not saved.", "Something stopped it. Nothing was changed.", "Try again from the site page. If it fails the same way, ask whoever installed webhost.", foot=_foot("", c.back()))
    if c.status == "rejected":
        out, nxt = refusal(c.msg)
        return R(pill("failed"), f"The access token for {n} was not saved.", out, nxt, foot=_foot("Nothing was changed.", c.back()))
    return R(c.step(), f"Saving the access token for {n}", "Your token is being saved.", "Nothing to do. The next fetch uses it.")


def _analytics(c):
    n, on = c.n, c.on
    word = "on" if on else "off"
    site_page = _a(f"/sites/{c.site}", "Go to site page")
    if c.status == "failed":
        return R(pill("failed"), f"Analytics for {n} are unchanged.", f"Analytics could not be turned {word}. Nothing changed on your site.",
                 "The site serves as before. You can try again; if it fails the same way, ask an administrator and give them the technical log.",
                 foot=_foot("", site_page, _a(f"/sites/{c.site}/analytics", "Try again", True)))
    if c.status == "rejected":
        out, nxt = refusal(c.msg)
        return R(pill("failed"), f"Analytics for {n} are unchanged.", out, nxt, foot=_foot("Nothing was changed.", c.back()))
    if c.status in OK and on:
        if auto_tag(c.h.site(c.who, c.site) or {}):
            return R(pill("done"), f"Analytics are on for {n}.", "Your pages are counted from now on. webhost adds the analytics line to every page and takes it out again if you turn analytics off.",
                     "Nothing else to do. The first visits show on the analytics page within an hour.", foot=_foot("", site_page, _a(f"/sites/{c.site}/analytics", "Open analytics", True)))
        wid = load(core.ANALYTICS_MAP, {}).get(c.site)
        tag = ""
        if wid and c.r.get("domain"):
            line = f'<script defer src="/_a/script.js" data-website-id="{wid}" data-domains="{c.r["domain"]}"></script>'
            tag = f"<pre class='log'>{esc(line)}</pre>"
        extra = (f"{tag}<p>Put it inside <code>&lt;head&gt;</code> on every page, then push or upload as usual.</p>" if tag
                 else "<p>The setup page has the line, ready to copy. Put it inside <code>&lt;head&gt;</code> on every page, then push or upload as usual.</p>")
        return R(pill("waiting", "one step left"), f"Analytics are on for {n}. One step left.", "Add one line to your pages to start counting.",
                 "The first visits show on the analytics page within an hour.", extra, _foot("", site_page, _a(f"/sites/{c.site}/analytics", "Open the setup page", True)))
    if c.status in OK:
        return R(pill("done"), f"Analytics are off for {n}.", "Visitors are no longer counted. The numbers collected so far are kept.",
                 "The script tag left on your pages does nothing now; you can remove it with your next release.", foot=_foot("", _a(f"/sites/{c.site}", "Go to the site page", True)))
    out = f"Your site keeps serving the whole time. Only its web server reloads, {'with' if on else 'without'} the analytics route, and visitors are not interrupted."
    if on:
        out += " The first site to turn analytics on also starts the analytics service: allow a minute or two."
    return R(c.step(), f"Turning analytics {word} for {n}", out, "Nothing to do. You can leave this page.")


def _dbinit(c):
    n, f, msg = c.n, c.file, c.msg
    mono_f = f"<span class='mono'>{f}</span>"
    if c.status in OK:
        if msg.startswith("Loaded"):
            R_ = (f"The database of {n} is ready.", f"{mono_f} was loaded into the empty database.", "Your site can use the tables now.")
        elif msg.startswith("The database already has"):
            R_ = (f"The database of {n} was left as it is.", f"The database already has tables, so {mono_f} was not loaded. Nothing was changed.", "A file is only loaded into an empty database, so your data is safe.")
        elif msg.startswith("No schema file"):
            R_ = (f"The database file of {n} is cleared.", "No file is set any more.", "Nothing else to do.")
        else:
            R_ = (f"The database file of {n} is saved.", f"{mono_f} is loaded with the next release while the database is empty.", "Nothing else to do.")
        return R(pill("done"), *R_, foot=_foot("", _a(f"/sites/{c.site}", "Go to the site page", True)))
    if c.status == "failed":
        site_btn = _foot("", c.back())
        if msg.startswith("The database refused"):
            detail = re.match(r"The database refused .+?: (.*)$", msg, re.S)
            said = (detail.group(1).strip() if detail else "")
            extra = f"<p class='src'>It said: <span class='mono'>{esc(said)}</span></p>" if said and not SECRETISH.search(said) else ""
            return R(pill("failed"), f"The database of {n} did not take the file.", f"The database refused {mono_f}.",
                     "Nothing was loaded, and the live site is unchanged. Fix the file, push or upload it, then set it again on the site page.", extra, site_btn)
        if msg.startswith("There is no"):
            return R(pill("failed"), f"{mono_f} was not found.", f"There is no {mono_f} in the live release.",
                     "Nothing was changed. Push or upload the file, then set it again on the site page.", foot=site_btn)
        return R(pill("failed"), f"The database of {n} could not be reached.", "The site’s container cannot be reached right now.",
                 "Try again in a few minutes. If it stays like this, ask whoever installed webhost and give them the technical log.", foot=site_btn)
    if c.status == "rejected":
        out, nxt = refusal(c.msg)
        return R(pill("failed"), "The database file was not set.", out, nxt, foot=_foot("Nothing was changed.", c.back()))
    return R(c.step(), f"Loading the database of {n}", "The file is loaded into the database, but only while the database has no tables." if f else "The database file is being changed.",
             "Nothing to do. You can leave this page.")


def _other(c):
    if c.status in OK:
        return R(pill("done"), f"{c.n}: done.", "The request is done.", foot=_foot("", c.back()))
    if c.status in ("failed", "rejected"):
        return R(pill("failed"), f"{c.n}: the request did not go through.", "The request did not finish.", "Ask whoever installed webhost and give them the technical log.", foot=_foot("", c.back()))
    return R(c.step(), f"Working on {c.n}", "Your request is being handled.", "Nothing to do. You can leave this page.")


WHAT = {
    "create": ("Creating {site}", "Creating the site"), "restore": ("Restoring {site}", "Restoring from a backup"),
    "delete": ("Deleting {site}", "Deleting the site"), "token": ("Saving the access token", "Saving the access token"),
    "analytics": ("Turning analytics {on} for {site}", "Turning analytics {on}"), "dbinit": ("Loading the database file", "Loading the database file"),
}


def took(started, ended):
    if started is None or ended is None or ended - started < 60:
        return ""
    m = round((ended - started) / 60)
    return f" · took {m} minute{'' if m == 1 else 's'}"


def request_page(h, who, rid):
    r = load(os.path.join(DATA, "requests", f"{rid}.json"), None)
    if not r or not (who["admin"] or r.get("user") == who["user"]):
        return h.fail(404, "No such request.")
    c = Ctx(h, who, rid, r)
    status, kind, site, msg = c.status, c.kind, c.site, c.msg
    running = not c.finished
    d = {"create": _create, "restore": _restore, "delete": _delete, "token": _token, "analytics": _analytics, "dbinit": _dbinit}.get(kind, _other)(c)

    insp = None
    if kind == "create" and c.src and (status in ("creating", "live", "done", "failed") or c.blocked):
        insp = load(os.path.join(INSPECT, f"{site}.json"), None)
        st, ck = _started(rid, r), parse_ts((insp or {}).get("checked"))
        if insp and st is not None and ck is not None and ck < st - 60:
            insp = None
    shown = insp
    if c.blocked and not blocked_rules(insp):
        insp = _blocked_from_message(msg) or insp
        shown = None if insp is not shown else shown
    found = sum(len(v) for v in blocked_rules(insp).values()) if c.blocked else 0
    if c.blocked and found:
        d["outcome"] = f"Its first release was blocked at inspection: {plural(found, 'problem')} found."
        d["stop_note"] = f"{plural(found, 'problem')} found. Nothing was created."

    stop = None if (status in OK or running) else _stop_key(r, status, c.insp_stop)
    marks = _marks(c.keys, status, stop)
    stop_word = "Blocked here" if c.blocked else ("Refused here" if status == "rejected" else "Failed here")
    refused = status == "rejected" and not c.insp_stop and kind == "create"

    notes = {}
    tpl = {t["name"]: t for t in h.server.conf.get("templates", [])}.get(r.get("template", "")) or {}
    has_db = tpl.get("database", "x") not in ("none", "", None)
    if stop:
        notes[stop] = d["stop_note"]
    if kind == "create":
        if marks.get("inspecting") == "done" and shown:
            notes["inspecting"] = "No findings." if shown.get("verdict") != "block" and not any(f.get("level") != "block" for f in shown.get("findings", [])) else "Passed."
        if marks.get("creating") == "now":
            notes["creating"] = "In progress. This takes two to three minutes."
        if status in OK and r.get("domain"):
            notes["live"] = f"{esc(r['domain'])} answers."
    elif kind == "restore" and marks.get("restoring") == "now":
        notes["restoring"] = "In progress. This takes a few minutes."
    elif kind == "delete" and status in OK:
        notes["done"] = "The backup is kept."
    if status in OK and kind in ("dbinit",):
        notes["applying"] = d["outcome"]

    started, ended = _started(rid, r), parse_ts(r.get("updated"))
    ended = ended if ended is not None else started
    if running:
        status_line = (f'<p role="status" class="src" style="margin:4px 0 0">Started {ago(started)} · this page updates by itself</p>' if started is not None
                       else '<p role="status" class="src" style="margin:4px 0 0">This page updates by itself</p>')
        when_right = ""
    else:
        status_line = ""
        word = "Finished" if status in OK else ("Refused" if status == "rejected" and not c.insp_stop else "Stopped")
        when_right = f'<span class="src">{word} {ago(ended)}{took(started, ended) if status in OK and kind == "create" else ""}</span>' if ended is not None else ""

    out = f'<p class="big-out">{d["outcome"]}</p>'
    border = "gap:10px" if status in OK else "border-color:var(--attn);gap:10px"
    card = (f'<section class="card rq-card" aria-labelledby="result" style="{border}">'
            f'<div class="rq-top">{d["pill"]}{when_right}</div><h1 id="result"><b>{d["headline"]}</b></h1>{out}{d["extra"]}'
            f'{"<p class=mute>" + d["next"] + "</p>" if d["next"] else ""}{status_line}{d["foot"]}</section>')

    top = card + (findings(insp, esc(rid)) if c.blocked else "")
    wide = ""
    if not refused:
        wide += stepper(r, status, stop, stop_word, marks)
    wide += progress(rid, r, status, stop, stop_word, marks, notes, refused, technical_log(rid, r, status), has_db)
    if kind == "create" and status in OK:
        wide += getting_started(r) + guide_block(h.server.conf, r.get("template"))
    aside = (inspection_card(shown, c.blocked) if shown and not refused else "") + asked_card(h, r, site)

    what_full, what_short = (s.format(site=site, on="on" if c.on else "off") for s in WHAT.get(kind, ("The request", "The request")))
    crumbs = [("Sites", "/")] + ([(site, f"/sites/{site}"), (what_short, None)] if c.exists else [(what_full, None)])
    body = CSS + top + f'<div class="cols"><div class="wide">{wide}</div><aside class="aside">{aside}</aside></div>'
    h.send(200, page(what_full, who["user"], body, crumbs=crumbs, refresh=8 if running else None))


def retryable(r):
    # The sync takes tokens and packages away, so those need giving again.
    return not r.get("token") and not (r.get("source") or {}).get("upload")


def retry(h, who, rid):
    r = load(os.path.join(DATA, "requests", f"{rid}.json"), None)
    if not r or not (who["admin"] or r.get("user") == who["user"]):
        return h.fail(404, "No such request.")
    if r.get("kind") != "create" or r.get("status") != "failed":
        return h.fail(409, "Only a failed create can be tried again.")
    if not h.retryable(r):
        return h.redirect(f"/new?from={rid}")
    conf = h.server.conf
    tpl = {t["name"]: t for t in conf.get("templates", [])}.get(r.get("template", ""))
    site = r.get("site", "")
    taken = {s.get("name") for s in load(os.path.join(DATA, "sites.json"), [])}
    taken |= {q.get("site") for q in h.requests({"admin": True}) if q.get("status") not in ("rejected", "failed")}
    mine = [s for s in h.sites(who) if s.get("owner") == who["user"]]
    if not tpl:
        return h.fail(409, "That template is no longer offered.")
    if site in taken:
        return h.fail(409, f"A site named {site} exists or is being created.")
    if not who["admin"] and len(mine) >= int(conf.get("site_limit", 10)):
        return h.fail(409, f"You have reached the limit of {conf.get('site_limit', 10)} sites.")
    # An administrator retrying someone's site must not become its owner.
    new = h.write_request({"kind": "create", "user": r.get("user"), "groups": r.get("groups", []), "site": site, "template": tpl["name"],
                              "runtime": tpl["runtime"], "domain": r.get("domain"), "public": bool(r.get("public")), "source": r.get("source") or {}})
    h.redirect(f"/requests/{new}")
