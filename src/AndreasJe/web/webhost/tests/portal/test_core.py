#!/usr/bin/env python3
"""portal_core: the time helper, status words, crumbs, builders. Runnable alone: python3 tests/portal/test_core.py"""
import os, re, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "guest"))
import portal_core as C

NOW = 1793700240  # Tue 3 Nov 2026, 10:04 UTC
ISO_TEXT = re.compile(r"\d{4}-\d\d-\d\dT\d\d:\d\d")
fails = []


def check(name, ok):
    print(f"{name} {'ok' if ok else 'FAIL'}")
    if not ok:
        fails.append(name)


def text(markup):
    return re.sub(r"<[^>]+>", "", markup)


# time: relative text, exact time in title, never an ISO string as text
check("just-now", text(C.ago(NOW - 20, NOW)) == "just now")
check("minutes", text(C.ago(NOW - 12 * 60, NOW)) == "12 minutes ago")
check("hours", text(C.ago(NOW - 2 * 3600, NOW)) == "2 hours ago")
check("last-night", text(C.ago("2026-11-03T01:30:00Z", NOW)) == "Last night 01:30")
check("yesterday", text(C.ago("2026-11-02T16:12:00Z", NOW)) == "Yesterday 16:12")
check("older-is-a-date", text(C.ago("2026-10-31T01:30:00Z", NOW)) == "Sat 31 Oct")
check("other-year-has-year", text(C.ago("2025-10-31T01:30:00Z", NOW)) == "Fri 31 Oct 2025")
check("title-carries-exact-time", 'title="Tue 3 Nov 2026, 10:04 UTC">2 hours ago</time>' in C.ago("2026-11-03T10:04:00Z", NOW + 7200))
check("datetime-attribute", 'datetime="2026-11-03T10:04:00Z"' in C.ago(NOW, NOW))
check("seconds-ms-iso-agree", len({C.iso(NOW), C.iso(NOW * 1000), C.iso("2026-11-03T10:04:00Z"), C.iso("2026-11-03T10:04:00+00:00"), C.iso("20261103T100400Z")}) == 1)
check("never-iso-text", not any(ISO_TEXT.search(text(f(t, NOW))) for f in (C.ago, C.stamp) for t in (NOW, NOW * 1000, "2026-10-01T08:12:00Z", "2025-01-01T00:00:00Z", NOW + 99999)))
check("stamp-today", text(C.stamp("2026-11-03T08:40:00Z", NOW)) == "Today 08:40 UTC")
check("stamp-older", text(C.stamp("2026-10-31T01:30:00Z", NOW)) == "Sat 31 Oct 01:30 UTC")
check("unreadable-time-is-quiet", text(C.ago("garbage", NOW)) == "unknown" and text(C.ago(None, NOW)) == "unknown")
check("time-defaults-to-the-clock", text(C.ago(C.time.time() - 600)) == "10 minutes ago")

# status words
for word, cls in (("live", "ok"), ("passed", "ok"), ("blocked", "bad"), ("failed", "bad"), ("waiting", ""), ("applying", "run"), ("done", "ok")):
    check(f"pill-{word}", C.pill(word) == f'<span class="{("pill " + cls).strip()}">{word}</span>')
check("pill-aliases", text(C.pill("pass")) == "passed" and text(C.pill("block")) == "blocked" and "bad" in C.pill("block") and text(C.pill("ok")) == "done")
check("pill-label", text(C.pill("applying", "no backup")) == "no backup" and "run" in C.pill("applying", "no backup"))
check("pill-escapes", "<script>" not in C.pill("<script>"))
check("scope-pills", text(C.scope_pill(True)) == "Public" and text(C.scope_pill(False)) == "Your networks only")

# page shell
crumbs = [("Sites", "/"), ("portfolio", "/sites/portfolio"), ("Analytics", None)]
doc = C.page("Analytics", "ann", "<p>x</p>", crumbs=crumbs, refresh=60)
trail = re.search(r'<nav aria-label="Breadcrumb">(.*?)</nav>', doc).group(1)
check("crumbs-link-all-but-last", trail.count("<a ") == 2 and '<a href="/sites/portfolio">portfolio</a>' in trail
      and trail.rstrip().endswith('<b aria-current="page">Analytics</b>') and "<a href=\"/\">Analytics" not in trail)
check("refresh-seconds", '<meta http-equiv="refresh" content="60">' in doc and "http-equiv" not in C.page("t", "ann", "x"))
legacy = C.page("t", "ann", "x", refresh=True, crumb="shop")
check("legacy-crumb-and-refresh", 'content="8"' in legacy and '<a href="/">Sites</a>' in legacy and '<b aria-current="page">shop</b>' in legacy)
check("nav-sites-only", 'href="/analytics"' not in doc and "New site" not in re.search(r'<aside.*?</aside>', doc, re.S).group(0))
check("menu-details", "<details class=\"menu\"><summary>Menu</summary>" in doc)
check("current-nav", 'href="/" class="on" aria-current="page"' in C.page("t", "ann", "x", nav="sites") or 'aria-current="page"' in C.page("t", "ann", "x", nav="sites"))
check("no-script-or-web-font", "<script" not in doc and "googleapis" not in doc and "Instrument" not in doc and "DM Mono" not in doc)
check("escapes-user", "<b>x" not in C.page("t", "<b>x", "y") and "&lt;b&gt;x" in C.page("t", "<b>x", "y"))

# builders
check("tile", C.tile("Visitors", "3,912", "14% more", True) == '<div class="tile">Visitors<b>3,912</b><small class="up">14% more</small></div>')
check("tile-bad", 'class="down"' in C.tile("Bounce", "41%", "3 points higher", False))
ml = C.meter_list([{"x": "a", "y": 5}, {"x": "b", "y": 3}, {"x": "", "y": 1}], top=2, label=lambda x: x or "Direct")
check("meter-list-show-all", "Show all 3" in ml and "Direct" in ml and ml.index("Show all") < ml.index("Direct"))
check("meter-list-short-has-no-fold", "Show all" not in C.meter_list([{"x": "a", "y": 1}]))
check("sparkline", C.sparkline([1, 2, 3]).startswith("<svg") and C.sparkline([1]) == "")
check("details-log", "Show technical log" in C.details_log("x<y") and "For the installer" in C.details_log("x") and "x&lt;y" in C.details_log("x<y"))

print(f"test_core: {len(fails)} failed")
sys.exit(1 if fails else 0)
