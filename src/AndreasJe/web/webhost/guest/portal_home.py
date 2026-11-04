"""The sites dashboard: needs a person, visitor numbers summed over the sites that count them, the sites list. Handler bodies; the Portal class delegates here."""
import os
import re
import time
import urllib.error
import portal_core
from portal_core import (DAYS, INSPECT, LIVE_STATES, Umami, attn_row, backups, blocked_rules, change, country, day, duration, esc, hour_window,
                         load, meter_list, mono, page, parse_ts, pill, plural, rule_title, sparkline, stamp, stamp_text, ago, tile)

WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
STALE_BACKUP = 48 * 3600
# One square per country: (code, column, row) on a 20 by 10 grid.
GEO = [("IS", 8, 1), ("NO", 11, 1), ("SE", 12, 1), ("FI", 13, 1), ("CA", 3, 2), ("IE", 9, 2), ("GB", 10, 2), ("DK", 11, 2), ("EE", 13, 2), ("RU", 15, 2),
       ("US", 3, 3), ("BE", 9, 3), ("NL", 10, 3), ("DE", 11, 3), ("PL", 12, 3), ("LT", 13, 3), ("UA", 14, 3), ("MX", 3, 4), ("FR", 10, 4), ("CH", 11, 4),
       ("AT", 12, 4), ("CZ", 13, 4), ("CN", 17, 4), ("KR", 18, 4), ("JP", 19, 4), ("CO", 4, 5), ("PT", 9, 5), ("ES", 10, 5), ("IT", 11, 5), ("GR", 12, 5),
       ("TR", 13, 5), ("IN", 16, 5), ("BR", 5, 6), ("MA", 10, 6), ("EG", 12, 6), ("IL", 13, 6), ("AE", 14, 6), ("SG", 17, 6), ("AR", 5, 7), ("NG", 10, 7),
       ("KE", 12, 7), ("ID", 18, 7), ("ZA", 11, 9), ("AU", 19, 9), ("NZ", 20, 10)]
DOING_NOW = {"create": "Creating", "restore": "Restoring", "delete": "Deleting", "analytics": "Changing analytics for", "dbinit": "Loading the database file for",
             "token": "Saving the access token for"}
DOING = {"create": "Creating the site", "restore": "Restoring from a backup", "delete": "Deleting the site", "analytics": "Changing analytics",
         "dbinit": "Loading the database file", "token": "Saving the access token"}

CSS = """<style>
.hhead{display:flex;flex-wrap:wrap;gap:16px;justify-content:space-between;align-items:flex-end}.hhead>div{flex:1 1 420px;min-width:0}
@media(max-width:559px){.hhead>.btn{width:100%}}
.live-row{display:grid;grid-template-columns:minmax(70px,30%) minmax(0,1fr) 28px;gap:10px;align-items:center}.live-row .mono{font-size:13px;overflow-wrap:anywhere}.live-row b{text-align:right;font-weight:600}
.pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,180px),1fr));gap:10px}.pair>div{padding:12px 14px;border-radius:12px;background:var(--soft)}
.scope{flex-direction:row;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px 16px}.scope>div{flex:1 1 360px;min-width:0}
.mapcols{display:flex;flex-wrap:wrap;gap:20px 24px;align-items:flex-start}.mapcols>.tmapwrap{flex:999 1 400px;min-width:0}.mapcols>div:last-child{flex:1 1 260px;min-width:0}
.between{display:flex;justify-content:space-between;align-items:center;gap:8px;min-height:44px}
.delrow{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px 16px;padding:12px 14px;border-radius:12px;background:var(--soft)}.delrow>div{min-width:0}
.howto{font-size:13px;color:var(--mute)}.howto summary{font-weight:400}
ul.kinds{margin:0;padding:0;list-style:none;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,240px),1fr));gap:12px}
ul.kinds li{padding:16px;border-radius:12px;background:var(--soft);border:1px solid var(--div);display:flex;flex-direction:column;gap:6px;min-width:0}
ul.kinds b{font-weight:600;font-size:16px}
</style>"""

KINDS = (
    ('<path d="M7 3h10l5 5v17H7z" fill="none" stroke="#1f6b4f" stroke-width="1.8" stroke-linejoin="round"/><path d="M17 3v5h5M11 14h7M11 18h7" fill="none" stroke="#1f6b4f" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
     "A site made of files", "Bring finished pages, styles and images. Good for a portfolio, a landing page or documentation.", "Static files"),
    ('<circle cx="14" cy="14" r="10.5" fill="none" stroke="#1f6b4f" stroke-width="1.8"/><path d="M8.5 9.5l3.5 10 2-6 2 6 3.5-10" fill="none" stroke="#1f6b4f" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
     "WordPress", "Write and edit in your browser. Good for a blog or a site several people update.", "WordPress"),
    ('<rect x="3.5" y="5" width="21" height="8" rx="2.5" fill="none" stroke="#1f6b4f" stroke-width="1.8"/><rect x="3.5" y="15" width="21" height="8" rx="2.5" fill="none" stroke="#1f6b4f" stroke-width="1.8"/><path d="M8 9h.01M8 19h.01" stroke="#1f6b4f" stroke-width="2.4" stroke-linecap="round"/>',
     "An app with its own server code", "Run your own code, with a database if you need one. Good for a shop or an API.", "PHP + MariaDB, or Node.js"),
)


# ── reading Umami ────────────────────────────────────────────────────

class Down(Exception):
    """Umami does not answer at all; stop asking for this page."""


def get(fn, *args):
    """(fetched_at, data) from an Umami helper, or None when this one answer is missing; Down when the service is unreachable."""
    try:
        got = fn(*args)
    except urllib.error.HTTPError:
        return None
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        raise Down from e
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return got if got and got[1] is not None else None


def rows_of(got):
    return [r for r in (got[1] if got else None) or [] if isinstance(r, dict)]


def site_numbers(wid, start, end):
    """Everything the dashboard needs from one counting site, or None when its week cannot be read."""
    week = get(Umami.stats, wid, start, end)
    if not week or not isinstance(week[1], dict):
        return None
    prev_start = start - 7 * 86400000
    d = {"stats": week[1], "prev": week[1].get("comparison") or {}, "fetched": week[0]}
    now = get(Umami.active, wid)
    d["now"] = int((now[1] or {}).get("visitors", 0) or 0) if now and isinstance(now[1], dict) else None
    daily = get(Umami.series, wid, start, end, "day")
    hourly = get(Umami.series, wid, start, end, "hour")
    pick = lambda got: ((got[1] or {}).get("sessions") or (got[1] or {}).get("pageviews") or []) if got and isinstance(got[1], dict) else []
    d["daily"], d["hourly"] = pick(daily), pick(hourly)
    d["countries"] = rows_of(get(Umami.metrics, wid, "country", start, end, 100))
    d["referrers"] = rows_of(get(Umami.metrics, wid, "referrer", start, end, 50))
    vals = lambda event, prop, s, e: [(str(r.get("value", "")), int(r.get("total", 0) or 0)) for r in rows_of(get(Umami.event_values, wid, event, prop, s, e))]
    d["downloads"] = vals("download", "file", start, end)
    d["downloads_before"] = sum(n for _, n in vals("download", "file", prev_start, start)) if d["downloads"] else 0
    d["views"], d["carts"] = vals("product-view", "product", start, end), vals("add-to-cart", "product", start, end)
    return d


def week_days(daily, end):
    """Visitors for each of the last seven UTC days, oldest first."""
    by = {}
    for r in daily:
        t = parse_ts(r.get("x"))
        if t is not None:
            by[time.strftime("%Y-%m-%d", time.gmtime(t))] = by.get(time.strftime("%Y-%m-%d", time.gmtime(t)), 0) + (r.get("y", 0) or 0)
    return [by.get(time.strftime("%Y-%m-%d", time.gmtime(end / 1000 - 1 - n * 86400)), 0) for n in range(6, -1, -1)]


# ── what needs a person ──────────────────────────────────────────────

def restore_point(b):
    """When a backup was taken, read from the restore point itself (its name carries the time); the listed time is the fallback."""
    m = re.search(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)", str(b.get("volid", "")))
    return parse_ts(m.group(1)) if m else parse_ts(b.get("time"))


def newest_backup(name):
    pts = [t for t in (restore_point(b) for b in backups().get("sites", {}).get(name, [])) if t is not None]
    return max(pts) if pts else None


def failed_requests(h, who):
    """Requests that failed in the last week and were not followed by a success for the same site and action; newest first."""
    mine, seen, out = h.requests(who), set(), []
    horizon = time.time() - 7 * 86400
    for r in mine:
        key = (r.get("kind"), r.get("site"))
        made = parse_ts(r.get("created")) or parse_ts(str(r.get("id", "")).split("-")[0])
        if r.get("status") in ("live", "done") and key not in seen:
            seen.add(key)
        elif r.get("status") == "failed" and key not in seen and (made is None or made >= horizon):
            seen.add(key)
            out.append((r, made))
    return out


def new_sites(h, who):
    """Sites created in the last 48 hours: they have had no night for a backup yet."""
    return {r.get("site") for r in h.requests(who) if r.get("kind") == "create" and r.get("status") in ("live", "done")
            and time.time() - (parse_ts(r.get("created")) or parse_ts(str(r.get("id", "")).split("-")[0]) or 0) < STALE_BACKUP}


def needs(h, who, sites, insp):
    """[(site, kind, html row)] for blocked inspections, failed requests and sites with no backup in 48 hours."""
    out = []
    names = {s["name"] for s in sites}
    for s in sites:
        name, i = s["name"], insp[s["name"]]
        if s.get("source") and i.get("verdict") == "block":
            found = [rule_title(r).lower() for r in blocked_rules(i)]
            what = " and ".join([", ".join(found[:-1]), found[-1]] if len(found) > 1 else found)
            keep = " Visitors still see the last release that passed." if s.get("state") in LIVE_STATES else " Nothing goes live until that is fixed."
            out.append((name, "blocked", attn_row("blocked", name, f"The newest release stopped at inspection: {esc(what)}.{keep}", stamp(i.get("checked")),
                                                  f'<a class="btn" href="/sites/{esc(name)}">See what to fix</a>')))
    for r, made in failed_requests(h, who):
        site = r.get("site") or ""
        if r.get("kind") == "create" and site in names:
            continue
        out.append((site if site in names else "", "failed", attn_row("failed", site, f"{esc(DOING.get(r.get('kind'), 'A request'))} failed.", ago(made) if made else "",
                                                                    f'<a class="btn ghost" href="/requests/{esc(r.get("id"))}">See what went wrong</a>')))
    young = new_sites(h, who)
    for s in sites:
        if s.get("state") not in LIVE_STATES:
            continue
        last = newest_backup(s["name"])
        if last is None and s["name"] in young:
            continue
        if last is None or time.time() - last > STALE_BACKUP:
            text = "The last nightly backups did not run." if last else "No backup exists yet."
            when = f"The newest restore point is from {stamp(last)}." if last else ""
            out.append((s["name"], "backup", attn_row("applying", s["name"], text, when, f'<a class="btn ghost" href="/sites/{esc(s["name"])}">See backups</a>', label="no backup")))
    return out


# ── the sites list (variant E) ───────────────────────────────────────

def template_name(h, s):
    t = {t.get("name"): t for t in (getattr(getattr(h, "server", None), "conf", None) or {}).get("templates", [])}.get(s.get("template")) or {}
    return t.get("label") or s.get("template") or ""


def sites_list(h, who, sites, insp, flagged, state, nums):
    inst = who["admin"]
    head = ("<div class='hd' role='row'><span role='columnheader'>Site</span>" + ("<span role='columnheader' class='c-own'>Owner</span>" if inst else "")
            + "<span role='columnheader'>State</span><span role='columnheader'>Latest release</span><span role='columnheader'>Visitors, 7 days</span>"
            "<span role='columnheader'>Now</span><span role='columnheader'>Newest backup</span>"
            "<span role='columnheader' style='position:absolute;left:-9999px'>Action</span></div>")
    rows = ""
    for s in sites:
        name, i = s["name"], insp[s["name"]]
        link = f"/sites/{esc(name)}"
        reasons = flagged.get(name, [])
        kind = reasons[0] if reasons else None
        say, btn, target = ({"blocked": (pill("blocked") + "<span>Newest release stopped at inspection. Visitors still see the last one that passed.</span>", "See what to fix", link),
                             "failed": (pill("failed") + "<span>A recent request for this site failed.</span>", "See what went wrong", link),
                             "backup": (pill("applying", "no backup") + "<span>The last nightly backups did not run.</span>", "See backups", link)}.get(kind)
                            or (pill("done", "fine") + "<span>Nothing needs doing.</span>", f"Open {name}", link))
        if kind == "blocked" and s.get("state") not in LIVE_STATES:
            say = pill("blocked") + "<span>Newest release stopped at inspection. Nothing goes live until that is fixed.</span>"
        if not s.get("source"):
            rel, when = pill("waiting", "not applicable"), "Edited in WordPress" if "wordpress" in str(s.get("template")) else "Nothing to inspect"
        elif i.get("verdict") == "block":
            rel, when = pill("blocked"), ago(i.get("checked")) + (" · last passed one still live" if s.get("state") in LIVE_STATES else "")
        elif i.get("verdict") == "pass":
            rel, when = pill("passed"), ago(i.get("checked"))
        else:
            rel, when = pill("waiting", "not inspected"), ""
        st, d = state[name], nums.get(name)
        if st == "on" and d:
            vis, prev = int(d["stats"].get("visitors", 0) or 0), d["prev"].get("visitors")
            txt, cls = change(vis, prev) if prev else ("", "")
            vis_cell = (f'<div class="acts"><b style="min-width:40px">{vis:,}</b><span class="vis-sub src">visitors, 7 days</span>{sparkline(d["days"])}'
                        + (f'<span class="{cls} tiny" style="white-space:nowrap">{esc(txt)}</span>' if txt and txt != "–" else "") + "</div>")
            now_cell, now_long = (f"<b>{d['now']}</b>", f"{plural(d['now'], 'visitor')}") if d["now"] is not None else ("<b>–</b>", "Not available")
        elif st == "on":
            vis_cell, now_cell, now_long = '<span class="off">Not available right now</span>', "<b>–</b>", "Not available"
        elif st == "pending":
            vis_cell, now_cell, now_long = '<span class="off">Being set up</span>', "<b>–</b>", "Being set up"
        else:
            vis_cell = f'<div class="off">Not counted · <a href="{link}/analytics" style="font-weight:600">Turn on</a></div>'
            now_cell, now_long = "<b>Off</b>", "Not counted"
        last = newest_backup(name)
        stale = last is None or time.time() - last > STALE_BACKUP
        bk = f'<span class="{"down" if stale else ""}" style="font-size:13px">{ago(last) if last else "None yet"}</span>'
        owner = esc(s.get("owner") or "None")
        rows += (f'<div class="rw{" attn" if kind else ""}" role="row"><div class="c-name" role="cell"><a class="mono" href="{link}" style="color:var(--ink);font-weight:500;font-size:15px">{esc(name)}</a>'
                 f'<div class="src">{esc(s.get("domain", ""))} · {esc(template_name(h, s))}' + (f'<span class="own-inline"> · {owner}</span>' if inst else "") + "</div></div>"
                 + (f'<div class="c-own" role="cell">{owner}</div>' if inst else "")
                 + f'<div class="c-state" role="cell">{pill(s.get("state", "?"))}</div><div class="c-say" role="cell">{say}</div>'
                 f'<div class="c-rel" role="cell">{rel}<div class="src">{when}</div></div><div class="c-vis" role="cell">{vis_cell}</div>'
                 f'<div class="c-now" role="cell">{now_cell}</div><div class="c-bk" role="cell">{bk}</div>'
                 f'<details class="c-fold"><summary>Release, backup and visitors now</summary><dl class="kv"><dt>Latest release</dt><dd>{rel} {when}</dd>'
                 f'<dt>Now</dt><dd>{esc(now_long)}</dd><dt>Newest backup</dt><dd class="{"down" if stale else ""}">{ago(last) if last else "None yet"}</dd></dl></details>'
                 f'<div class="c-act" role="cell"><a class="btn{" pri" if kind else ""}" href="{target}"><span class="phone-label">{esc(btn)}</span><span class="wide-label">Open</span></a></div></div>')
    title = "All sites" if inst else "Your sites"
    return f'<div class="frame"><div class="tbl{" inst" if inst else ""}" role="table" aria-labelledby="yours"><h2 id="yours" class="ttl">{title}</h2>{head}{rows}</div></div>'


# ── the dashboard blocks ─────────────────────────────────────────────

def names_text(names, total):
    if len(names) == total and total > 1:
        return "all sites"
    return names[0] if len(names) == 1 else (" and ".join(names) if len(names) == 2 else f"{len(names)} sites")


def head_row(title, note, hid):
    return f'<div class="hdr"><h2 id="{hid}">{esc(title)}</h2><span class="src">{esc(note)}</span></div>'


def shade(n, top):
    r = n / top if top else 0
    return 0 if n <= 0 else 1 if r <= .2 else 2 if r <= .45 else 3 if r <= .75 else 4


def merge(pairs):
    out = {}
    for k, n in pairs:
        out[k] = out.get(k, 0) + n
    return out


def source_host(x):
    h = re.sub(r"^https?://", "", str(x or "").strip().lower()).split("/")[0]
    return re.sub(r"^www\.", "", h) or "Direct or none"


def hour_grid(counts):
    """Both grids (24 columns wide, 3-hour blocks narrow); the container shows one. counts[(weekday, hour)] = visits."""
    top24 = max(counts.values(), default=0)
    block = {(d, b): sum(counts.get((d, 3 * b + k), 0) for k in range(3)) for d in range(7) for b in range(8)}
    top3 = max(block.values(), default=0)
    h24 = '<div class="heat h24"><span></span>' + "".join(f"<span>{h:02d}</span>" if h % 3 == 0 else "<span></span>" for h in range(24))
    h3 = '<div class="heat h3"><span></span>' + "".join(f"<span>{3 * b:02d}</span>" for b in range(8))
    for d in range(7):
        h24 += f"<span>{DAYS[d]}</span>" + "".join(f'<i class="s{shade(counts.get((d, h), 0), top24)}" title="{DAYS[d]} {h:02d}:00, {counts.get((d, h), 0):,} visits"></i>' for h in range(24))
        h3 += f"<span>{DAYS[d]}</span>" + "".join(f'<i class="s{shade(block[(d, b)], top3)}" title="{DAYS[d]} {3 * b:02d}:00 to {3 * b + 3:02d}:00, {block[(d, b)]:,} visits"></i>' for b in range(8))
    h24, h3 = h24 + "</div>", h3 + "</div>"
    busy = max(counts, key=counts.get) if counts and top24 else None
    return f'<div class="heatwrap" aria-hidden="true">{h24}{h3}</div>', busy


def tile_map(countries, total):
    top = max(countries.values(), default=0)
    squares = ""
    for code, col, row in GEO:
        n = countries.get(code, 0)
        squares += f'<span class="s{shade(n, top)}" title="{esc(country(code))}: {n:,} visitors" style="grid-column:{col};grid-row:{row}">{code}</span>'
    legend = '<div class="legend">Fewer ' + "".join(f'<i class="s{k}"></i>' for k in range(5)) + " More</div>"
    return f'<div class="tmapwrap"><div class="tmap" aria-hidden="true">{squares}</div>{legend}</div>'


def dashboard(counting, others, total_sites, nums, start, end):
    """The blocks that sum over counting sites. nums: name -> numbers (sites that could not be read are left out)."""
    read = [s for s in counting if s["name"] in nums]
    names = [s["name"] for s in read]
    scope = names_text(names, total_sites)
    out = ""
    unread = [s["name"] for s in counting if s["name"] not in nums]
    if unread:
        out += f'<p class="src">The numbers for {esc(", ".join(unread))} could not be read just now, so they are left out.</p>'

    # right now, and who is most popular
    live = [(n, nums[n]["now"]) for n in names if nums[n]["now"] is not None]
    total_now, peak = sum(v for _, v in live), max([v for _, v in live] + [1])
    checked = max((nums[n]["fetched"] for n in names), default=time.time())
    now_card = (f'<section class="card" aria-labelledby="now"><div class="hdr"><h2 id="now">Right now</h2><span class="src"><svg width="8" height="8" viewBox="0 0 8 8" aria-hidden="true" style="margin-right:6px"><circle cx="4" cy="4" r="4" fill="#1f6b4f"/></svg>Live</span></div>'
                f'<div><span class="big">{total_now}</span> <span class="mute">{"visitor" if total_now == 1 else "visitors"} on {"your sites" if scope == "all sites" else esc(scope)} in the last 5 minutes</span></div>'
                '<div class="ml">' + "".join(f'<div class="live-row">{mono(n)}<div class="meter" aria-hidden="true"><i style="width:{round(100 * v / peak)}%"></i></div><b>{v}</b></div>' for n, v in live)
                + f'</div><p class="src" style="margin-top:auto">Last checked {stamp(checked)}. This block updates every minute; the rest of the page every hour.</p></section>')
    if len(read) >= 2:
        visitors = {n: int(nums[n]["stats"].get("visitors", 0) or 0) for n in names}
        everyone = sum(visitors.values())
        best = max(names, key=lambda n: visitors[n])
        txt, cls = change(visitors[best], nums[best]["prev"].get("visitors"))
        days = nums[best]["days"]
        first, last = day(end / 1000 - 6 * 86400), day(end / 1000)
        alt = f"Visitors per day for {best}, {first} to {last}: " + ", ".join(str(v) for v in days)
        moves = []
        for n in names:
            before, now = int(nums[n]["prev"].get("visitors", 0) or 0), visitors[n]
            if before:
                moves.append((n, before, now, round(100 * (now - before) / before)))
        rise, drop = max(moves, key=lambda m: m[3], default=None), min(moves, key=lambda m: m[3], default=None)
        box = lambda label, m, good: (f'<div><div class="src">{label}</div><div>{mono(m[0])} <b class="{"up" if good else "down"}">{abs(m[3])}% {"more" if good else "fewer"}</b></div>'
                                      f'<div class="src">{m[1]:,} to {m[2]:,} visitors</div></div>')
        boxes = (box("Biggest rise", rise, True) if rise and rise[3] > 0 else "") + (box("Biggest drop", drop, False) if drop and drop[3] < 0 else "")
        second = (f'<section class="card" aria-labelledby="pop"><h2 id="pop">Most popular site this week</h2><div class="hdr" style="align-items:flex-end"><div>'
                  f'<a class="mono" href="/sites/{esc(best)}/analytics" style="font-size:20px;font-weight:500;color:var(--ink);display:inline-flex;align-items:center;min-height:44px">{esc(best)}</a>'
                  f'<div><b style="font-size:24px;font-weight:600">{visitors[best]:,}</b> <span class="mute">visitors · {round(100 * visitors[best] / everyone) if everyone else 0}% of all</span></div>'
                  + (f'<div class="{cls} small">{esc(txt)} than the week before</div>' if cls else "") + f'</div>{sparkline(days, large=True, text=alt)}</div>'
                  + (f'<div class="pair" style="margin-top:auto">{boxes}</div>' if boxes else "") + "</section>")
    else:
        only = names[0] if names else ""
        ask = ("Turn analytics on for another site to see which is most popular and which is rising." if others else "")
        links = "".join(f'<a class="btn ghost" href="/sites/{esc(o["name"])}/analytics">Turn on for&nbsp;{mono(o["name"])}</a>' for o in others)
        second = (f'<section class="card" aria-labelledby="pop1"><h2 id="pop1">Compare your sites</h2><p>Only {mono(only)} counts visitors, so there is nothing to compare yet. {ask}</p>'
                  + (f'<div class="acts" style="margin-top:auto">{links}</div>' if links else "") + "</section>")
    out += f'<div class="grid2">{now_card}{second}</div>'

    # this week
    sums = lambda key, src="stats": sum(int(nums[n][src].get(key, 0) or 0) for n in names)
    v, pv, vs, tt = sums("visitors"), sums("pageviews"), sums("visits"), sums("totaltime")
    pv0, vs0, v0, tt0 = sums("pageviews", "prev"), sums("visits", "prev"), sums("visitors", "prev"), sums("totaltime", "prev")
    dl = sum(n for k in names for _, n in nums[k]["downloads"])
    dl0 = sum(nums[k]["downloads_before"] for k in names)
    avg, avg0 = (tt / vs if vs else 0), (tt0 / vs0 if vs0 else 0)

    def t(label, value, now, before, kind="count", href=None):
        txt, cls = change(now, before, kind) if before else ("", "")
        return tile(label, value, "" if txt in ("", "–") else txt, {"up": True, "down": False}.get(cls), href)
    one = f"/sites/{names[0]}/analytics" if len(names) == 1 else None
    out += ('<section aria-labelledby="week" style="display:flex;flex-direction:column;gap:10px">'
            + head_row(f"This week, {scope}", f"{day(end / 1000 - 6 * 86400)} to {day(end / 1000)}, compared with the 7 days before", "week")
            + '<div class="tiles">' + t("Visitors", f"{v:,}", v, v0, href=one) + t("Pageviews", f"{pv:,}", pv, pv0, href=one)
            + t("Downloads", f"{dl:,}", dl, dl0, href="#downloads") + t("Average visit", duration(avg), avg, avg0, "seconds", one) + "</div></section>")

    # map and countries
    countries = merge((str(r.get("x", "")).upper(), int(r.get("y", 0) or 0)) for n in names for r in nums[n]["countries"])
    ctotal = sum(countries.values()) or 1
    crows = [{"x": c, "y": n, "value": f"{n:,} · {round(100 * n / ctotal)}%"} for c, n in countries.items()]
    out += (f'<section class="card" aria-labelledby="map">{head_row("Where visitors come from", f"This week, {scope}. One square per country.", "map")}'
            f'<div class="mapcols">{tile_map(countries, ctotal)}<div>{meter_list(crows, top=6, label=country, empty="No visits from a known country yet.")}</div></div></section>')

    # downloads, products, sources
    files = {}
    for n in names:
        for f, c in nums[n]["downloads"]:
            files[(f, n)] = files.get((f, n), 0) + c
    drows = [{"x": f, "y": c, "note": f"on {n}"} for (f, n), c in files.items()]
    downloads = (f'<section class="card" id="downloads" aria-labelledby="dl"><h2 id="dl">Downloads</h2><p class="src">Clicks on download links across {"your sites" if scope == "all sites" else esc(scope)} this week.</p>'
                 + meter_list(drows, mono=True, empty="No downloads counted this week.")
                 + '<details class="howto"><summary>How a file gets counted</summary><p style="margin-top:6px">Add <code>data-umami-event="download"</code> and <code>data-umami-event-file="cv.pdf"</code> to the link. '
                   "A file opened from a link outside your site is not counted.</p></details></section>")
    prod = {}
    senders = []
    for n in names:
        for p, c in nums[n]["views"]:
            prod.setdefault(p, [0, 0])[0] += c
        for p, c in nums[n]["carts"]:
            prod.setdefault(p, [0, 0])[1] += c
        if nums[n]["views"] or nums[n]["carts"]:
            senders.append(n)
    tagging = ('<details class="howto"><summary>How products get counted</summary><p style="margin-top:6px">Add <code>data-umami-event="product-view"</code> and <code>data-umami-event-product="Linen apron"</code> '
               "to the product page, and <code>add-to-cart</code> to the button.</p></details>")
    if prod:
        who_sends = (f"From {' and '.join(mono(n) for n in senders[:3])}, the {'one site' if len(senders) == 1 else 'sites'} that send{'s' if len(senders) == 1 else ''} product events."
                     if len(senders) <= 3 else f"From {len(senders)} sites that send product events.")
        prows = [{"x": p, "y": c[0], "value": f"{c[0]:,} views · {c[1]:,} to cart"} for p, c in prod.items()]
        products = f'<section class="card" aria-labelledby="prod"><h2 id="prod">Popular products</h2><p class="src">{who_sends}</p>{meter_list(prows)}{tagging}</section>'
    else:
        maybe = next((o for o in others if o.get("runtime") in ("php", "node")), others[0] if others else None)
        text = ("No counting site sends product events yet." + (f" {mono(maybe['name'])} could, once its analytics are on." if maybe else ""))
        btn = f'<div class="acts"><a class="btn ghost" href="/sites/{esc(maybe["name"])}/analytics">Turn on for&nbsp;{mono(maybe["name"])}</a></div>' if maybe else ""
        products = f'<section class="card" aria-labelledby="prod"><h2 id="prod">Popular products</h2><p>{text}</p>{btn}{tagging}</section>'
    src, by_site = {}, {}
    for n in names:
        for r in nums[n]["referrers"]:
            h, c = source_host(r.get("x")), int(r.get("y", 0) or 0)
            src[h] = src.get(h, 0) + c
            by_site.setdefault(h, {})[n] = by_site.setdefault(h, {}).get(n, 0) + c
    srows = [{"x": h, "y": c, **({"note": "mostly " + max(by_site[h], key=by_site[h].get)} if len(names) > 1 else {})} for h, c in src.items()]
    sources = (f'<section class="card" aria-labelledby="refs"><h2 id="refs">Top sources</h2><p class="src">'
               + (f"Where visits to {esc(names[0])} came from." if len(names) == 1 else "Where visits came from, all counting sites together.") + f"</p>{meter_list(srows, empty='No visits yet.')}</section>")
    out += f'<div class="grid3">{downloads}{products}{sources}</div>'

    # when visitors come
    counts = {}
    for n in names:
        for r in nums[n]["hourly"]:
            t_ = parse_ts(r.get("x"))
            if t_ is not None:
                g = time.gmtime(t_)
                counts[(g.tm_wday, g.tm_hour)] = counts.get((g.tm_wday, g.tm_hour), 0) + int(r.get("y", 0) or 0)
    grid, busy = hour_grid(counts)
    note = f"Visits per hour this week, {scope}, UTC." + (f" Busiest: {WEEKDAYS[busy[0]]} {busy[1]:02d}:00." if busy else "")
    out += f'<section class="card" aria-labelledby="when">{head_row("When visitors come", note, "when")}{grid}</section>'
    return out


# ── the page ─────────────────────────────────────────────────────────

def headline(h, who, sites, flagged):
    live = sum(1 for s in sites if s.get("state") in LIVE_STATES)
    n = len(sites)
    if who["admin"]:
        owners = len({s.get("owner") for s in sites if s.get("owner")})
        lead = (f"{plural(n, 'site')} from {plural(owners, 'owner')} {'is' if n == 1 else 'are'} live." if live == n
                else f"{live} of {plural(n, 'site')} {'is' if live == 1 else 'are'} live.")
    else:
        lead = f"Your {plural(n, 'site')} {'is' if n == 1 else 'are'} live." if live == n else f"{live} of {plural(n, 'site')} {'is' if live == 1 else 'are'} live."
    k = len(flagged)
    rest = f"{k} {'thing needs' if k == 1 else 'things need'} a person." if k else "Nothing needs a person right now."
    return f"<b>{lead}</b> {rest}"


def deleted_card(who, gone):
    items = ""
    for d in gone:
        pts = sorted(d["backups"], key=lambda b: restore_point(b) or 0)
        newest = pts[-1]
        name = esc(d["name"])
        items += (f"<form class='delrow' method='post' action='/deleted/{name}/restore' enctype='multipart/form-data'><input type='hidden' name='csrf' value='{who['csrf']}'>"
                  f"<input type='hidden' name='backup' value='{esc(newest['volid'])}'><input type='hidden' name='confirm' value='1'>"
                  f"<div><b class='mono' style='font-weight:500'>{name}</b><div class='src'>Deleted {esc(day(d['deleted'])) if parse_ts(d.get('deleted')) else 'earlier'} · newest backup {esc(stamp_text(restore_point(newest)))}</div></div>"
                  f"<button class='btn ghost' type='submit'>Restore {name}</button></form>")
    return ("<section class='card' aria-labelledby='del'><h2 id='del'>Deleted sites</h2><p class='src'>Their backups are kept. A restored site comes back as it was at that backup.</p>"
            f"<div style='display:flex;flex-direction:column;gap:10px'>{items}</div></section>") if items else ""


def in_progress(h, who):
    pending = [r for r in h.requests(who) if r.get("status") not in ("live", "rejected", "failed", "done")]
    if not pending:
        return ""
    lis = "".join(f"<div class='between'><a href='/requests/{esc(r['id'])}'>{esc(DOING_NOW.get(r.get('kind'), 'Working on'))}"
                  + (f" {mono(r['site'])}" if r.get("site") else "") + f"</a>{pill('waiting' if r.get('status') == 'new' else 'applying')}</div>" for r in pending[:10])
    return f"<section class='card' aria-labelledby='prog'><h2 id='prog'>In progress</h2><div style='display:flex;flex-direction:column'>{lis}</div></section>"


def empty_page(h, who, gone):
    kinds = "".join(f'<li><svg width="28" height="28" viewBox="0 0 28 28" aria-hidden="true">{svg}</svg><b>{esc(t)}</b><span>{esc(text)}</span><span class="src">{esc(tag)}</span></li>' for svg, t, text, tag in KINDS)
    body = (CSS + "<div><h1><b>No sites yet.</b> Start with your first one.</h1><p class='sub'>Each site runs in its own container. webhost inspects every release before it goes live.</p></div>"
            f"<section class='card' aria-label='Kinds of site you can create'><div class='src'>You can create three kinds of site</div><ul class='kinds'>{kinds}</ul>"
            "<div class='actions'><span class='src'>Takes two to three minutes</span><a class='btn' href='/new'>Create your first site</a></div></section>"
            + deleted_card(who, gone))
    h.send(200, page("Sites", who["user"], body, refresh=60, installer=who["admin"]))


def home(h, who):
    sites = h.sites(who)
    gone = deleted(h, who)
    if not sites:
        return empty_page(h, who, gone)
    insp = {s["name"]: load(os.path.join(INSPECT, f"{s['name']}.json"), {}) or {} for s in sites}
    ids = load(portal_core.ANALYTICS_MAP, {}) or {}
    state = {s["name"]: ("on" if s.get("analytics") and ids.get(s["name"]) else "pending" if s.get("analytics") else "off") for s in sites}
    counting = [s for s in sites if state[s["name"]] == "on"]
    others = [s for s in sites if state[s["name"]] == "off"]

    nums, down = {}, False
    start, end = hour_window(7)
    for s in counting:
        try:
            got = site_numbers(ids[s["name"]], start, end)
        except Down:
            down = True
            break
        if got:
            got["days"] = week_days(got["daily"], end)
            nums[s["name"]] = got

    items = needs(h, who, sites, insp)
    flagged = {}
    for name, kind, _ in items:
        flagged.setdefault(name, []).append(kind)
    alert = ""
    if items:
        calm = "" if any(k == "failed" for _, k, _ in items) else f"<span class='src'>Your live sites are not affected by {'either' if len(items) == 2 else 'this' if len(items) == 1 else 'any of these'}.</span>"
        alert = (f"<section class='card attn' aria-labelledby='attn'><div class='hdr'><h2 id='attn'>Needs a person</h2>{calm}</div>"
                 f"<div style='display:flex;flex-direction:column'>{''.join(row for _, _, row in items)}</div></section>")

    if not counting:
        block = ("<section class='card' aria-labelledby='noan'><h2 id='noan'>No site counts its visitors yet</h2><p>Turn analytics on for a site to see live visitors, the most popular site, downloads and a map of where visitors come from, here on one page. "
                 "Counting uses no cookies, and the numbers stay on this server.</p><div class='acts'>"
                 + "".join(f'<a class="btn ghost" href="/sites/{esc(s["name"])}/analytics">Turn on for&nbsp;{mono(s["name"])}</a>' for s in others) + "</div></section>")
    elif not nums:
        block = ("<section class='card' aria-labelledby='nodata'><h2 id='nodata'>The visitor numbers are not available right now</h2>"
                 "<p>Umami, the service that counts visitors, does not answer. Try again in a few minutes. Everything else on this page is unaffected.</p></section>")
    else:
        block = dashboard(counting, others, len(sites), nums, start, end)
        if len(counting) < len(sites):
            who_list = [s["name"] for s in counting]
            block = (f"<section class='card scope' aria-labelledby='scope'><div><h2 id='scope'>The numbers below cover {mono(' and '.join(who_list)) if len(who_list) <= 2 else esc(plural(len(who_list), 'site'))} only</h2>"
                     f"<p class='src'>{len(counting)} of {len(sites)} sites {'counts its' if len(counting) == 1 else 'count their'} visitors. Analytics is a choice per site; turning it on for one leaves the others as they are.</p></div></section>") + block

    sub = "You see every owner’s sites because you installed webhost." if who["admin"] else "Each site runs in its own container. webhost checks every release before it goes live."
    body = (CSS + f"<div class='hhead'><div><h1>{headline(h, who, sites, flagged)}</h1><p class='sub'>{sub}</p></div><a class='btn' href='/new'>New site</a></div>"
            + alert + block + sites_list(h, who, sites, insp, flagged, state, nums)
            + (f"<div class='grid2' style='align-items:start'>{in_progress(h, who)}{deleted_card(who, gone)}</div>" if in_progress(h, who) or gone else "")
            + "<p class='src'>Visitor numbers come from Umami on this server, read every hour. Umami sets no cookies and stores no names or IP addresses.</p>")
    h.send(200, page("Sites", who["user"], body, refresh=60, installer=who["admin"]))


def deleted(h, who):
    return [d for d in backups().get("deleted", []) if d.get("backups") and (who["admin"] or d.get("owner") == who["user"])]
