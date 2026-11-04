"""Visitor numbers: per-site page and setup (v2). Handler bodies; the Portal class delegates here."""
import time
import portal_core
from portal_core import (Umami, auto_tag, change, country, duration, empty_state, esc, hour_window, load, meter_list,
                         mono, page, parse_ts, pill, scope_pill, source_line, stamp, tile)

# key: (days, "last 7 days", "previous 7 days", table unit, column head, chart gap, label every n-th)
PERIODS = {
    "24h": (1, "24 hours", "hour", "Hour (UTC)", "3px", 4),
    "7d": (7, "7 days", "day", "Day", "10px", 1),
    "30d": (30, "30 days", "day", "Day", "4px", 5),
    "90d": (90, "90 days", "day", "Day", "1px", 15),
}
FAILS = (OSError, ValueError, KeyError, TypeError, AttributeError)
KIND = {"static": "Static files", "php": "PHP", "node": "Node.js", "python": "Python"}
DOWNLOAD_TAG = '<a href="/cv.pdf" data-umami-event="download" data-umami-event-file="cv.pdf">Download my CV</a>'
EVENT_TAG = '<button data-umami-event="contact-form-sent">Send</button>'
PRODUCT_TAG = '<a href="/apron" data-umami-event="product-view" data-umami-event-product="Linen apron">Linen apron</a>'

CSS = """<style>
.sa-now{display:flex;flex-wrap:wrap;align-items:baseline;gap:6px 12px}.sa-now b{font-size:40px;font-weight:600;line-height:1}
.sa-live{display:inline-flex;align-items:center;gap:6px}.sa-live i{width:8px;height:8px;border-radius:99px;background:var(--acc)}
.sa-chart{display:grid;grid-template-columns:36px minmax(0,1fr);column-gap:8px}
.sa-axis{position:relative;height:200px;font-size:11px;color:var(--mute)}.sa-axis span{position:absolute;right:0}
.sa-bars{height:200px;display:grid;grid-template-columns:repeat(var(--n),minmax(0,1fr));gap:var(--gap);
background:linear-gradient(var(--div),var(--div)) top/100% 1px no-repeat,linear-gradient(var(--div),var(--div)) 0 50%/100% 1px no-repeat,linear-gradient(var(--field),var(--field)) bottom/100% 1px no-repeat}
.sa-bar{position:relative;height:200px}.sa-bar i{position:absolute;left:0;right:0;bottom:0;border-radius:2px 2px 0 0}.sa-bar .pv{background:var(--s2)}.sa-bar .vi{background:var(--acc)}
.sa-lbl{display:grid;grid-template-columns:repeat(var(--n),minmax(0,1fr));gap:var(--gap);margin-top:8px;font-size:11px;line-height:1.3;color:var(--mute)}
.sa-lbl div{display:flex;flex-direction:column;align-items:center;white-space:nowrap}
.sa-tbl{margin-top:10px;max-height:320px;overflow:auto;border:1px solid var(--div);border-radius:10px}
.sa-tbl .r{display:grid;grid-template-columns:minmax(0,1.6fr) minmax(0,1fr) minmax(0,1fr);gap:12px;padding:7px 14px;border-bottom:1px solid var(--div);font-size:13px}
.sa-tbl .r.h{position:sticky;top:0;background:var(--soft);border-bottom-color:var(--line);font-size:12px;color:var(--mute)}.sa-tbl .r>span+span{text-align:right}
.sa-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:20px;align-items:stretch}
.sa-steps .num{flex:none;width:28px;height:28px;border-radius:99px;background:var(--calm);color:var(--ok);font-weight:700;display:flex;align-items:center;justify-content:center}
.sa-h{display:flex;gap:12px;align-items:center}
.sa-two{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,240px),1fr));gap:12px}
.sa-two ul{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:6px}
.sa-cols{display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start}.sa-main{flex:999 1 520px;min-width:0;display:flex;flex-direction:column;gap:20px}.sa-side{flex:1 1 260px;min-width:0;display:flex;flex-direction:column;gap:20px}
pre.line{margin:0;padding:12px 14px;border-radius:12px;background:var(--soft);border:1px solid var(--line);font:13px/1.5 var(--mono);white-space:pre-wrap;overflow-wrap:anywhere;user-select:all}
.sa-off{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:12px}.sa-off>span{flex:1 1 280px;min-width:0}
</style>"""


def _crumbs(name):
    return [("Sites", "/"), (name, f"/sites/{name}"), ("Analytics", None)]


def _read(fn, *args):
    """(fetched_at, data) from an Umami call, or None when Umami does not answer or the portal has no login."""
    try:
        got = fn(*args)
    except FAILS:
        return None
    return got if got and got[1] is not None else None


def analytics(h, who, query):
    """The old overview now lives on the Sites dashboard."""
    return h.redirect("/")


def _unavailable(h, who, name, hint="Umami does not answer. Try again in a few minutes; if it stays like this, ask an administrator to check the analytics service."):
    body = (f"<h1>{mono(name)} <b>The numbers are not available right now.</b></h1>"
            + empty_state("Not available", esc(hint), f'<a class="btn ghost" href="/sites/{esc(name)}">Back to {esc(name)}</a>'))
    return h.send(503, page(f"{name} analytics", who["user"], body, crumbs=_crumbs(name)))


def _tile(label, value, ch):
    text, cls = ch
    return tile(label, value, text, True if cls == "up" else (False if cls == "down" else None))


def _compare(now, before, prev_words):
    text, cls = change(now, before)
    if not before or text in ("new", "–"):
        return "", ""
    return ("About the same as " if text == "same as before" else f"{text} than ") + prev_words + ".", cls


def _buckets(rows, step):
    out = {}
    for r in rows or []:
        t = parse_ts(r.get("x")) if isinstance(r, dict) else None
        if t is not None:
            out[int(t // step)] = out.get(int(t // step), 0) + (r.get("y", 0) or 0)
    return out


def _chart(h, wid, days, unit, gap, every, end_s):
    """(chart card html, ok); bars per hour for 24 hours, else per day, filled with zeros, with a table in <details>."""
    hourly = unit == "hour"
    step = 3600 if hourly else 86400
    if hourly:
        slots = [end_s - (23 - i) * 3600 for i in range(24)]
        start, stop = slots[0] * 1000, (end_s + 3600) * 1000 - 1
    else:
        today = end_s // 86400 * 86400
        slots = [today - (days - 1 - i) * 86400 for i in range(days)]
        start, stop = (today - days * 86400) * 1000, end_s * 1000
    got = _read(Umami.series, wid, start, stop, unit)
    head = f"Visitors and pageviews per {unit}"
    if not got:
        return f'<section class="card"><h2>{head}</h2><p class="small mute">The chart is not available right now.</p></section>'
    data = got[1] or {}
    pvs, vis = _buckets(data.get("pageviews"), step), _buckets(data.get("sessions"), step)
    pv = [pvs.get(t // step, 0) for t in slots]
    vi = [vis.get(t // step, 0) for t in slots]
    peak = max(pv + vi + [1])
    mag = 10 ** (len(str(peak)) - 1)
    top = next(m * mag for m in (1, 2, 5, 10) if m * mag >= peak)
    n = len(slots)
    bars = lbls = rows = ""
    for i, t in enumerate(slots):
        g = time.gmtime(t)
        dow, dm, hh = time.strftime("%a", g), f"{g.tm_mday} {time.strftime('%b', g)}", time.strftime("%H:00", g)
        full = f"{dow} {dm}, {hh}" if hourly else f"{dow} {dm}"
        bars += (f'<div class="sa-bar" title="{esc(full)}: {vi[i]:,} visitors, {pv[i]:,} pageviews">'
                 f'<i class="pv" style="height:{100 * pv[i] / top:.1f}%"></i><i class="vi" style="height:{100 * vi[i] / top:.1f}%"></i></div>')
        show = (n - 1 - i) % every == 0
        l1, l2 = (hh, "") if hourly else ((dow, dm) if days == 7 else (dm, ""))
        lbls += f"<div>{f'<span>{esc(l1)}</span><span>{esc(l2)}</span>' if show else ''}</div>"
        rows += f'<div class="r" role="row"><span role="cell">{esc(full)}</span><span role="cell">{vi[i]:,}</span><span role="cell">{pv[i]:,}</span></div>'
    cols = "Hour (UTC)" if hourly else "Day"
    word = "hour" if hourly else "day"
    label = f"Bar chart of visitors and pageviews per {word}. The same numbers are in the table below."
    return (f'<section class="card" aria-labelledby="chart"><div class="acts" style="justify-content:space-between"><h2 id="chart">{head}</h2>'
            '<span class="acts"><span class="key"><i style="background:var(--acc)"></i>Visitors</span>'
            '<span class="key"><i style="background:var(--s2)"></i>Pageviews</span></span></div>'
            f'<div class="sa-chart" style="--n:{n};--gap:{gap}"><div class="sa-axis" aria-hidden="true"><span style="top:-8px">{top:,}</span>'
            f'<span style="top:92px">{top // 2:,}</span><span style="bottom:-8px">0</span></div>'
            f'<div class="sa-bars" role="img" aria-label="{esc(label)}">{bars}</div><span></span><div class="sa-lbl" aria-hidden="true">{lbls}</div></div>'
            f'<p class="src">Tallest bar: {max(pv):,} pageviews. A person who visits in more than one {word} is counted in each, so the bars add up to more than the visitor total.</p>'
            f'<details><summary>Show the numbers as a table</summary><div class="sa-tbl" tabindex="0" role="region" aria-label="Visitors and pageviews per {word}, as a table">'
            f'<div role="table" aria-label="Visitors and pageviews per {word}"><div class="r h" role="row"><span role="columnheader">{cols}</span>'
            f'<span role="columnheader">Visitors</span><span role="columnheader">Pageviews</span></div>{rows}</div></div></details></section>')


def _list_card(title, rows, **kw):
    inner = meter_list(rows, **kw) if rows is not None else '<p class="small mute">Not available right now.</p>'
    return f'<section class="card"><h2>{esc(title)}</h2>{inner}</section>'


def _tagged_card(title, intro, rows, empty_title, empty_text, tag, **kw):
    """Downloads or events: rows is None when Umami failed, [] when nothing is tagged yet."""
    if rows is None:
        body = '<p class="small mute">Not available right now.</p>'
    elif not rows:
        body = empty_state(esc(empty_title), empty_text + f'<pre class="line">{esc(tag)}</pre>')
    else:
        body = meter_list(rows, **kw)
    return f'<section class="card"><h2>{esc(title)}</h2><p class="src">{intro}</p>{body}</section>'


def site_analytics(h, who, name, query):
    s = h.site(who, name)
    if not s:
        return h.fail(404, "No such site, or not yours.")
    if not s.get("analytics"):
        return analytics_setup(h, who, s, None, "")
    wid = load(portal_core.ANALYTICS_MAP, {}).get(name)
    if not wid:
        body = (f"<h1><b>Analytics are being set up</b> for {mono(name)}.</h1><div class='panel'><div class='acts'>{pill('applying')}"
                "<b>This takes a minute or two the first time.</b></div><p>This page shows the next step when it is ready.</p></div>")
        return h.send(200, page(f"{name} analytics", who["user"], body, crumbs=_crumbs(name), refresh=8))
    key = query.get("period", ["7d"])[0]
    key = key if key in PERIODS else "7d"
    days, words, unit, _head, gap, every = PERIODS[key]
    start, end = hour_window(days)
    got = _read(Umami.stats, wid, start, end)
    ever = _read(Umami.stats, wid, *hour_window(90))
    if not got or not ever:
        return _unavailable(h, who, name)
    if not (ever[1] or {}).get("pageviews"):
        return analytics_setup(h, who, s, wid, "")
    fetched, st = got
    prev = st.get("comparison") or {}
    prev_words = f"the previous {words}"
    v, pv, vs = st.get("visitors", 0), st.get("pageviews", 0), st.get("visits", 0)
    bounce = 100 * st.get("bounces", 0) / vs if vs else 0
    pbounce = 100 * prev.get("bounces", 0) / prev["visits"] if prev.get("visits") else 0
    avg = st.get("totaltime", 0) / vs if vs else 0
    pavg = prev.get("totaltime", 0) / prev["visits"] if prev.get("visits") else 0
    cmp_text, cmp_cls = _compare(v, prev.get("visitors", 0), prev_words)
    tabs = "".join(f'<a href="?period={k}"{" aria-current=\"page\"" if k == key else ""}>{esc(p[1])}</a>' for k, p in PERIODS.items())
    tiles = ('<div class="tiles">' + _tile("Visitors", f"{v:,}", change(v, prev.get("visitors", 0)))
             + _tile("Visits", f"{vs:,}", change(vs, prev.get("visits", 0)))
             + _tile("Pageviews", f"{pv:,}", change(pv, prev.get("pageviews", 0)))
             + _tile("Bounce rate", f"{round(bounce)}%", change(bounce, pbounce, "points") if prev.get("visits") else ("", ""))
             + _tile("Average visit", duration(avg), change(avg, pavg, "seconds") if prev.get("visits") else ("", "")) + "</div>")
    # right now
    live = _read(Umami.active, wid)
    if live:
        n = int((live[1] or {}).get("visitors", 0) or 0)
        rt = _read(lambda w: Umami.cached(f"/realtime/{w}", ttl=60), wid)
        got = rt[1] if rt and isinstance(rt[1], dict) else {}
        urls = sorted(((u, int(c)) for u, c in (got.get("urls") or {}).items() if str(c).isdigit()), key=lambda x: -x[1])[:5]
        top = max([c for _, c in urls] + [1])
        pages = ("".join(f'<div style="display:grid;grid-template-columns:minmax(80px,140px) minmax(0,1fr) 28px;gap:10px;align-items:center">'
                         f'<span class="mono" style="font-size:13px;overflow-wrap:anywhere">{esc(u)}</span>'
                         f'<div class="meter" aria-hidden="true"><i style="width:{round(100 * c / top)}%"></i></div><b style="text-align:right">{c}</b></div>'
                         for u, c in urls) if urls else '<p class="small mute">No page is being viewed right now.</p>')
        now_body = ('<div style="display:flex;flex-wrap:wrap;gap:16px 40px;align-items:flex-start">'
                    f'<div class="sa-now" style="flex:0 1 260px;min-width:0"><b>{n:,}</b><span>visitor{"" if n == 1 else "s"} in the last 5 minutes</span></div>'
                    f'<div style="flex:1 1 280px;min-width:0;display:flex;flex-direction:column;gap:8px"><div class="src">Pages being viewed now</div>{pages}</div></div>'
                    + source_line(f"Last checked {stamp(live[0])}, updates every minute.", raw=True))
    else:
        now_body = '<p class="small mute">Not available right now.</p>'
    now_card = ('<section class="card" aria-labelledby="now"><div class="acts" style="justify-content:space-between"><h2 id="now">Right now</h2>'
                f'<span class="src sa-live"><i aria-hidden="true"></i>Live</span></div>{now_body}</section>')
    chart = _chart(h, wid, days, unit, gap, every, end // 1000)
    metric = lambda t: (lambda g: g[1] if g else None)(_read(Umami.metrics, wid, t, start, end, 50))
    ev = metric("event")
    ev = None if ev is None else [r for r in ev if r.get("x") != "download"]
    dl = _read(Umami.event_values, wid, "download", "file", start, end)
    dl = None if dl is None else [{"x": r.get("value"), "y": r.get("total", 0)} for r in dl[1] or []]
    grid = ('<div class="sa-grid">'
            + _list_card("Top pages", metric("path"), mono=True)
            + _list_card("Sources", metric("referrer"), label=lambda x: x or "Direct or none")
            + _list_card("Countries", metric("country"), pct=True, label=country)
            + _list_card("Devices", metric("device"), pct=True, label=lambda x: (x or "Unknown").capitalize())
            + _list_card("Browsers", metric("browser"), pct=True, label=lambda x: (x or "Unknown").replace("-", " ").capitalize())
            + _tagged_card("Downloads", "Clicks on download links on your pages.", dl, "No downloads counted yet",
                           "Tag a download link and its clicks show here. No script of your own is needed.", DOWNLOAD_TAG, mono=True)
            + _tagged_card("Events", "Counted from <code>data-umami-event</code> attributes on your pages.", ev, "No events counted yet",
                           "Tag a button or link. Products work the same way: <code>product-view</code> with a <code>data-umami-event-product</code> name.",
                           EVENT_TAG + "\n" + PRODUCT_TAG, mono=True)
            + "</div>")
    body = (CSS + f'<div><h1>{mono(name)} <b>had {v:,} visitor{"" if v == 1 else "s"} in the last {esc(words)}.</b> '
            f'<span class="{cmp_cls}">{esc(cmp_text)}</span></h1>'
            + source_line(f"Numbers from Umami, read every hour · last checked {stamp(fetched)}", raw=True) + "</div>"
            f'<nav aria-label="Time period" class="seg">{tabs}</nav>{now_card}'
            f'<section aria-label="Key numbers" style="display:flex;flex-direction:column;gap:8px">{tiles}'
            f'{source_line(f"Changes compare with {prev_words}. A lower bounce rate is better.")}</section>'
            f"{chart}{grid}"
            + source_line("Umami sets no cookies and stores no names or IP addresses. Visitors are counted per day per site."))
    h.send(200, page(f"{name} analytics", who["user"], body, crumbs=_crumbs(name), refresh=60))


def _form(who, name, on, button, ghost=False, note="", back=None):
    """Turn analytics on/off: no tick, the handler's confirm field goes as a hidden value."""
    btn = f'<button class="btn{" ghost" if ghost else ""}" type="submit">{esc(button)}</button>'
    ac = f'<div class="actions">{back or ""}{btn}</div>'
    return (f'<form method="post" action="/sites/{esc(name)}/analytics" enctype="multipart/form-data" class="sa-off">'
            f'<input type="hidden" name="csrf" value="{esc(who["csrf"])}"><input type="hidden" name="enabled" value="{1 if on else 0}">'
            f'<input type="hidden" name="confirm" value="1">{f"<span class=src>{esc(note)}</span>" if note else ""}{ac}</form>')


def _check(text, plus=True):
    mark = ('<path d="M3 8.5l3.2 3L13 4.5" fill="none" stroke="#1f6b4f" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' if plus
            else '<path d="M3 8h10" fill="none" stroke="#5f5e55" stroke-width="2" stroke-linecap="round"/>')
    return (f'<li style="list-style:none;display:flex;gap:8px;align-items:flex-start"><svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" '
            f'style="flex:none;margin-top:2px">{mark}</svg><span>{esc(text)}</span></li>')


def tracker_line(wid, domain):
    return f'<script defer src="/_a/script.js" data-website-id="{wid}" data-domains="{domain}"></script>'


def analytics_setup(h, who, s, wid, crumb):
    """Setup states: off, on and waiting for the first visit (static/PHP: nothing to do; Node/Python: three steps)."""
    name, domain, on = s["name"], s["domain"], bool(s.get("analytics"))
    wid = wid or (load(portal_core.ANALYTICS_MAP, {}).get(name) if on else None)
    auto = auto_tag(s)
    kind = "WordPress" if s.get("template") == "wordpress" else KIND.get(s.get("runtime"), s.get("template", ""))
    back = f'<a class="btn ghost" href="/sites/{esc(name)}">Back to {esc(name)}</a>'
    if not on:
        title = (f"<h1><b>Analytics are off</b> for {mono(name)}.</h1>" if auto else f"<h1><b>How to count visitors</b> on {mono(name)}.</h1>")
    else:
        title = "<h1><b>Analytics are on.</b> " + ("Your pages are being counted." if auto else "Add one line to your pages to start counting.") + "</h1>"
    head = (f'<div>{title}<div class="acts small mute" style="margin-top:8px"><a class="mono" href="https://{esc(domain)}">{esc(domain)}</a>'
            f'<span class="pill">{esc(kind)}</span>{scope_pill(s.get("public"))}</div></div>')
    about = ('<section class="card"><h2>About analytics</h2><dl class="kv"><dt>Service</dt><dd>Umami</dd><dt>Address</dt>'
             '<dd>Your own site, under <code>/_a/</code></dd><dt>Cookies</dt><dd>None</dd><dt>Refresh</dt><dd>Every hour</dd></dl></section>')
    if not on and auto:
        main = ('<section class="card" aria-labelledby="offh"><h2 id="offh">Turn on visitor counting</h2>'
                "<p>Analytics count visitors without cookies. webhost adds what your pages need, so there is nothing to change in your site.</p>"
                '<div class="sa-two"><div class="panel"><b>What turning on does</b><ul class="plain">'
                + _check("Adds one counting line to every page, in a new release.") + _check("Starts counting visits. The first ones show within an hour.")
                + _check("Shows this site on the Sites dashboard.") + '</ul></div><div class="panel"><b>What stays the same</b><ul class="plain">'
                + _check("Your files. You edit nothing.", False) + _check("Your address and who can reach the site.", False)
                + _check("Visitors. No cookies, no names, no IP addresses stored. Nobody is interrupted.", False) + "</ul></div></div>"
                + _form(who, name, True, "Turn analytics on", note="Your site reloads with analytics. You can turn it off again at any time.", back=back) + "</section>")
        return h.send(200, page(f"{name} analytics", who["user"], CSS + head + f'<div class="sa-cols"><div class="sa-main">{main}</div></div>',
                                crumbs=_crumbs(name)))
    waiting = f'<p>{pill("waiting")} No visits recorded yet. This page shows the first ones within an hour.</p>'
    off_note = ("Stops counting and takes the line out of your pages in a new release. Numbers collected so far are kept." if auto else
                "Stops counting and removes /_a/ from your site. The script tag left on your pages then does nothing. Numbers collected so far are kept.")
    turn_off = _form(who, name, False, "Turn analytics off", ghost=True, note=off_note)
    if auto:
        how = ("webhost adds the analytics line to every page of your site: it is in the release now and in every new one."
               if s.get("runtime") == "static" else
               "PHP adds the analytics line to every page your site sends, through a hook webhost manages. Nothing is added to your code.")
        opts = "".join(f"<dt class='mono'>{k}</dt><dd>{v}</dd>" for k, v in (
            ("data-exclude-search", "Do not record the part of the address after ?"), ("data-exclude-hash", "Do not record the part after #"),
            ("data-do-not-track", "Skip visitors whose browser asks not to be tracked"), ("data-domains", "Count only on these addresses (already set)")))
        main = ('<section class="card" aria-labelledby="waith" style="border-color:#b9d7c5"><h2 id="waith" style="font-size:20px">Nothing to do.</h2>'
                f"<p>Your pages are counted from now on. {esc(how)}</p>{waiting}<div class=\"actions\">{back}</div></section>"
                '<div class="card"><details><summary>Count clicks and forms (optional)</summary>'
                "<p>Add a <code>data-umami-event</code> attribute to a link or button. No script of your own is needed.</p>"
                f'<p class="src" style="margin-top:8px">Downloads:</p><pre class="line">{esc(DOWNLOAD_TAG)}</pre>'
                f'<p class="src" style="margin-top:8px">Products:</p><pre class="line">{esc(PRODUCT_TAG)}</pre></details></div>'
                f'<div class="card"><details><summary>Options you can add to the script tag</summary><dl class="kv">{opts}</dl></details></div>' + turn_off)
        return h.send(200, page(f"{name} analytics", who["user"], CSS + head
                                + f'<div class="sa-cols"><div class="sa-main">{main}</div><aside class="sa-side">{about}</aside></div>', crumbs=_crumbs(name)))
    line = tracker_line(wid or "…", domain)
    s1 = ("Analytics are on" if on else "Turn analytics on")
    step1 = ("<p>The analytics route is on your site and it has its own id. Your site keeps serving; visitors are not interrupted.</p>" if on else
             "<p>This adds the analytics route to your site and gives it its own id. Your site keeps serving; visitors are not interrupted. You can turn it off again at any time.</p>"
             + _form(who, name, True, "Turn analytics on", note="Your site reloads with the route. Nothing else changes."))
    note2 = "Select the line and copy it. It carries your site's own id." if wid else "The real line, with your site's id, appears here once analytics are on."
    h1 = lambda n, t: f'<div class="sa-h"><span class="num" aria-hidden="true">{n}</span><h2>{t}</h2></div>'
    main = (f'<div class="sa-steps" style="display:contents"><section class="card">{h1(1, s1)}{step1}</section>'
            f'<section class="card">{h1(2, "Add one line to your app")}<p>Your app builds its own pages, so webhost cannot add the line for you. '
            f"Put it inside <code>&lt;head&gt;</code> in the layout or template that every page uses.</p><pre class=\"line\">{esc(line)}</pre>"
            f'<p class="src">{esc(note2)}</p></section>'
            f'<section class="card">{h1(3, "Release it")}<p>Push to your branch or upload a new package. It is inspected and goes live as usual. The first visits show within an hour.</p>'
            f'<p class="src">Visitors keep seeing the current release until the new one passes inspection.</p>{waiting if on else ""}</section></div>'
            + (turn_off if on else ""))
    h.send(200, page(f"{name} analytics", who["user"], CSS + head + f'<div class="sa-cols"><div class="sa-main">{main}</div>'
                     + f'<aside class="sa-side">{about}</aside>' + "</div>", crumbs=_crumbs(name)))
