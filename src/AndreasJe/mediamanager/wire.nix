# The wiring script run by mediamanager-wire.service (a .nix file because
# update-os.sh ships only .nix siblings to the guest). Python, stdlib only.
# Idempotent: it adds what is missing, corrects what it owns and removes the
# links of apps that are no longer enabled. Nothing else is touched.
#
#   argv[1]                              static config from mediamanager.nix
#   <APP>__AUTH__APIKEY (env)            the keys mediamanager-keys generated
#   /etc/mediamanager/jellyfin.json      written by update.sh when Jellyfin is installed
#   /etc/secrets/jellyfin-api-key        the Jellyfin API key, if any
#   /var/lib/mediamanager/wire-state.json  fingerprints of the keys last written
''
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CONF = json.load(open(sys.argv[1]))
APPS = CONF["apps"]
QBT_PORT = CONF["qbittorrent"]["port"]
SUFFIX = CONF.get("publicSuffix")
JF_FILE = os.environ.get("JF_FILE", "/etc/mediamanager/jellyfin.json")
JF_KEY_FILE = os.environ.get("JF_KEY_FILE", "/etc/secrets/jellyfin-api-key")
STATE_FILE = os.environ.get("WIRE_STATE", "/var/lib/mediamanager/wire-state.json")
SERVARR = {"sonarr": "Sonarr", "radarr": "Radarr", "lidarr": "Lidarr"}
SERVARR_PORTS = {"sonarr": 8989, "radarr": 7878, "lidarr": 8686}
problems = []

try:
    STATE = json.load(open(STATE_FILE))
except (OSError, ValueError):
    STATE = {}


def log(msg):
    print(msg, flush=True)


def warn(msg):
    problems.append(msg)
    print("WARN: " + msg, flush=True)


def key(app):
    return os.environ.get(app.upper() + "__AUTH__APIKEY", "")


def fp(secret):
    return hashlib.sha256(secret.encode()).hexdigest()[:16]


def secret_changed(tag, secret):
    # The apps return stored keys masked, so a key is compared by the
    # fingerprint of what was last written, not by what the app shows.
    return STATE.get(tag) != fp(secret)


def remember(tag, secret):
    STATE[tag] = fp(secret)


def call(method, url, apikey=None, body=None, form=None, header="X-Api-Key"):
    data, headers = None, {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if apikey:
        headers[header] = apikey
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=60) as resp:
        text = resp.read()
    try:
        return json.loads(text) if text.strip() else None
    except ValueError:
        return text.decode(errors="replace")


def wait_for(name, url, apikey=None, header="X-Api-Key", tries=24):
    for _ in range(tries):
        try:
            call("GET", url, apikey, header=header)
            return True
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                warn(name + " rejects its API key (HTTP " + str(e.code) + ")")
                return False
            time.sleep(5)
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError):
            time.sleep(5)
    warn(name + " did not answer at " + url)
    return False


def field(item, name):
    for f in item.get("fields", []):
        if f["name"] == name:
            return f.get("value")
    return None


def set_fields(item, values):
    for f in item.get("fields", []):
        if f["name"] in values:
            f["value"] = values[f["name"]]
    return item


SECRET = ("apiKey", "password")


def differs(item, want, tag=None, secret=None):
    if tag and secret_changed(tag, secret):
        return True
    return any(field(item, n) != v for n, v in want.items() if n not in SECRET)


def from_schema(base, kind, implementation, apikey):
    for item in call("GET", base + "/" + kind + "/schema", apikey):
        if item.get("implementation") == implementation:
            return item
    raise RuntimeError("no " + implementation + " in " + kind + " schema")


def post_or_put(base, kind, item, apikey, label, force=False):
    q = "?forceSave=true" if force else ""
    try:
        if item.get("id"):
            call("PUT", base + "/" + kind + "/" + str(item["id"]) + q, apikey, item)
            log("  " + label + ": updated")
        else:
            call("POST", base + "/" + kind + q, apikey, item)
            log("  " + label + ": added")
        return True
    except urllib.error.HTTPError as e:
        warn(label + ": HTTP " + str(e.code) + " " + e.read().decode(errors="replace")[:300])
        return False


def ours(url):
    return str(url or "").startswith("http://127.0.0.1:")


# -- Sonarr / Radarr / Lidarr ---------------------------------------------------
def wire_servarr(name, a, jellyfin, qbt_up):
    base = "http://127.0.0.1:" + str(a["port"]) + "/api/" + a["api"]
    k = key(name)
    if not wait_for(name, base + "/system/status", k):
        return
    log(name + ":")

    if not any(r["path"].rstrip("/") == a["root"] for r in call("GET", base + "/rootfolder", k)):
        body = {"path": a["root"]}
        if name == "lidarr":
            body.update(
                name="Music",
                defaultQualityProfileId=call("GET", base + "/qualityprofile", k)[0]["id"],
                defaultMetadataProfileId=call("GET", base + "/metadataprofile", k)[0]["id"],
                defaultMonitorOption="all",
                defaultNewItemMonitorOption="all",
                defaultTags=[],
            )
        post_or_put(base, "rootfolder", body, k, "root folder " + a["root"])

    # Saved without a connection test while qBittorrent is down (no VPN config yet).
    want = {"host": "127.0.0.1", "port": QBT_PORT, "useSsl": False, "urlBase": "",
            "username": "", "password": "", a["categoryField"]: a["category"]}
    have = [d for d in call("GET", base + "/downloadclient", k) if d.get("implementation") == "QBittorrent"]
    if not have:
        item = from_schema(base, "downloadclient", "QBittorrent", k)
        item.update(name="qBittorrent", enable=True, priority=1)
        post_or_put(base, "downloadclient", set_fields(item, want), k, "download client qBittorrent", not qbt_up)
    elif differs(have[0], want):
        post_or_put(base, "downloadclient", set_fields(have[0], want), k, "download client qBittorrent", not qbt_up)

    mm = call("GET", base + "/config/mediamanagement", k)
    if not mm.get("copyUsingHardlinks"):
        mm["copyUsingHardlinks"] = True
        call("PUT", base + "/config/mediamanagement/" + str(mm["id"]), k, mm)
        log("  hardlinks: on")

    notes = [n for n in call("GET", base + "/notification", k)
             if n.get("implementation") == "MediaBrowser" and n.get("name") == "Jellyfin"]
    if not jellyfin:
        for n in notes:
            call("DELETE", base + "/notification/" + str(n["id"]), k)
            log("  Jellyfin library refresh: removed (Jellyfin not wired)")
        return
    item = notes[0] if notes else from_schema(base, "notification", "MediaBrowser", k)
    want = {"host": jellyfin["host"], "port": jellyfin["port"], "useSsl": False,
            "apiKey": jellyfin["apiKey"], "updateLibrary": True,
            "mapFrom": jellyfin["mapFrom"], "mapTo": jellyfin["mapTo"]}
    tag = "jellyfin:" + name
    if not notes or differs(item, want, tag, jellyfin["apiKey"]):
        item["name"] = "Jellyfin"
        for flag in ("onDownload", "onUpgrade", "onImportComplete", "onRename",
                     "onSeriesDelete", "onEpisodeFileDelete", "onMovieDelete",
                     "onMovieFileDelete", "onArtistDelete", "onAlbumDelete", "onTrackRetag"):
            sup = "supports" + flag[0].upper() + flag[1:]
            if flag in item and item.get(sup, True):
                item[flag] = True
        if post_or_put(base, "notification", set_fields(item, want), k, "Jellyfin library refresh"):
            remember(tag, jellyfin["apiKey"])


# -- Prowlarr: push indexers to every enabled *arr, drop the others ---------------
def wire_prowlarr(a):
    base = "http://127.0.0.1:" + str(a["port"]) + "/api/v1"
    k = key("prowlarr")
    if not wait_for("prowlarr", base + "/system/status", k):
        return
    log("prowlarr:")
    have = call("GET", base + "/applications", k)
    for name, impl in SERVARR.items():
        mine = [x for x in have if x.get("implementation") == impl and ours(field(x, "baseUrl"))]
        if name not in APPS:
            for x in mine:
                call("DELETE", base + "/applications/" + str(x["id"]), k)
                log("  sync to " + impl + ": removed (not enabled)")
            continue
        want = {"prowlarrUrl": "http://127.0.0.1:" + str(a["port"]),
                "baseUrl": "http://127.0.0.1:" + str(APPS[name]["port"]), "apiKey": key(name)}
        tag = "prowlarr:" + name
        if not mine:
            item = from_schema(base, "applications", impl, k)
            item.update(name=impl, syncLevel="fullSync")
            if post_or_put(base, "applications", set_fields(item, want), k, "sync to " + impl):
                remember(tag, key(name))
        elif differs(mine[0], want, tag, key(name)):
            if post_or_put(base, "applications", set_fields(mine[0], want), k, "sync to " + impl):
                remember(tag, key(name))


# -- Bazarr: subtitles for what Sonarr/Radarr import ------------------------------
def wire_bazarr(a):
    base = "http://127.0.0.1:" + str(a["port"]) + "/api"
    k = key("bazarr")
    if not wait_for("bazarr", base + "/system/status", k, header="X-API-KEY"):
        return
    log("bazarr:")
    cur = call("GET", base + "/system/settings", k, header="X-API-KEY")
    form = {}
    for name in ("sonarr", "radarr"):
        used = bool(cur.get("general", {}).get("use_" + name))
        if name not in APPS:
            if used:
                form["settings-general-use_" + name] = "false"
            continue
        want = {"ip": "127.0.0.1", "port": str(APPS[name]["port"]), "apikey": key(name), "ssl": "false"}
        sect = cur.get(name, {})
        if not used or any(str(sect.get(n)).lower() != v.lower() for n, v in want.items()):
            form["settings-general-use_" + name] = "true"
            form["settings-" + name + "-base_url"] = "/"
            for n, v in want.items():
                form["settings-" + name + "-" + n] = v
    if form:
        try:
            call("POST", base + "/system/settings", k, form=form, header="X-API-KEY")
            log("  links: " + ", ".join(n + "=" + form[n] for n in sorted(form) if n.startswith("settings-general-use_")))
        except urllib.error.HTTPError as e:
            warn("bazarr settings: HTTP " + str(e.code))
    log("  pick subtitle languages in Bazarr itself (Settings > Languages)")


# -- Seerr: needs its own first sign-in (with Jellyfin), then gets Sonarr/Radarr --
def wire_seerr(a):
    base = "http://127.0.0.1:" + str(a["port"]) + "/api/v1"
    if not wait_for("seerr", base + "/status"):
        return
    log("seerr:")
    if not call("GET", base + "/settings/public").get("initialized"):
        where = ("https://seerr." + SUFFIX) if SUFFIX else "Seerr"
        log("  not set up yet: open " + where + " and sign in with Jellyfin; the next update adds Sonarr/Radarr")
        return
    try:
        sk = json.load(open(CONF["seerrSettings"]))["main"]["apiKey"]
    except (OSError, KeyError, ValueError) as e:
        warn("seerr: cannot read its API key (" + str(e) + ")")
        return
    for name, extra in (("sonarr", {"activeDirectory": APPS.get("sonarr", {}).get("root"),
                                     "enableSeasonFolders": True, "seriesType": "standard",
                                     "animeSeriesType": "anime", "animeTags": []}),
                        ("radarr", {"activeDirectory": APPS.get("radarr", {}).get("root"),
                                     "minimumAvailability": "released"})):
        servers = [s for s in call("GET", base + "/settings/" + name, sk) if s.get("hostname") == "127.0.0.1"]
        if name not in APPS:
            for s in servers:
                call("DELETE", base + "/settings/" + name + "/" + str(s["id"]), sk)
                log("  " + name + ": removed (not enabled)")
            continue
        tag = "seerr:" + name
        if servers and not secret_changed(tag, key(name)):
            continue
        app_base = "http://127.0.0.1:" + str(APPS[name]["port"]) + "/api/v3"
        profile = call("GET", app_base + "/qualityprofile", key(name))[0]
        body = {"name": name.capitalize(), "hostname": "127.0.0.1", "port": APPS[name]["port"],
                "apiKey": key(name), "useSsl": False, "baseUrl": "",
                "activeProfileId": profile["id"], "activeProfileName": profile["name"],
                "is4k": False, "isDefault": True, "syncEnabled": False, "preventSearch": False,
                "tags": [], "externalUrl": ("https://" + name + "." + SUFFIX) if SUFFIX else ""}
        body.update(extra)
        try:
            if servers:
                body["id"] = servers[0]["id"]
                call("PUT", base + "/settings/" + name + "/" + str(servers[0]["id"]), sk, body)
                log("  " + name + ": updated")
            else:
                call("POST", base + "/settings/" + name, sk, body)
                log("  " + name + ": added")
            remember(tag, key(name))
        except urllib.error.HTTPError as e:
            warn("seerr " + name + ": HTTP " + str(e.code) + " " + e.read().decode(errors="replace")[:300])


def jellyfin_target():
    try:
        jf = json.load(open(JF_FILE))
    except (OSError, ValueError):
        log("jellyfin: not installed on this site, or not on the same share -- library refresh not wired")
        return None
    try:
        jf["apiKey"] = open(JF_KEY_FILE).read().strip()
    except OSError:
        jf["apiKey"] = ""
    if not jf["apiKey"]:
        log("jellyfin: installed, but no API key in " + JF_KEY_FILE + " -- library refresh not wired")
        return None
    log("jellyfin: " + jf["host"] + ":" + str(jf["port"]) + " (" + jf["mapFrom"] + " -> " + jf["mapTo"] + ")")
    return jf


def main():
    qbt_up = wait_for("qbittorrent", "http://127.0.0.1:" + str(QBT_PORT) + "/api/v2/app/version", tries=6)
    if not qbt_up:
        log("qbittorrent: not answering -- download clients are saved without a connection test")
    jellyfin = jellyfin_target()
    steps = [(n, lambda n=n: wire_servarr(n, APPS[n], jellyfin, qbt_up)) for n in SERVARR if n in APPS]
    steps += [(n, lambda n=n, f=f: f(APPS[n])) for n, f in
              (("prowlarr", wire_prowlarr), ("bazarr", wire_bazarr), ("seerr", wire_seerr)) if n in APPS]
    for name, step in steps:
        try:
            step()
        except Exception as e:  # one app's failure must not stop the others
            warn(name + ": " + type(e).__name__ + ": " + str(e))
    try:
        os.makedirs(os.path.dirname(STATE_FILE), mode=0o700, exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(STATE, f)
    except OSError as e:
        warn("cannot save " + STATE_FILE + ": " + str(e))
    log("wired: " + (", ".join(sorted(APPS)) or "qBittorrent only"))
    try:
        with open(os.path.join(os.path.dirname(STATE_FILE), "wire-result"), "w") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S") + " " + ("ok" if not problems else "problems=" + str(len(problems))) + "\n")
    except OSError:
        pass
    if problems:
        sys.exit(1)


main()
''
