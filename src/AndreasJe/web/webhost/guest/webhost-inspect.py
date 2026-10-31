#!/usr/bin/env python3
"""webhost-inspect — inspect a release before any site may serve it.

Runs inside the webhost container on an exported tree (no .git). Prints one JSON
object: {"verdict": "pass"|"block", "findings": [{level, rule, file, detail}]}.
A finding of level "block" stops the release unless its rule or id is accepted
(the site declaration's inspection.accept). Exit 0 always; the verdict decides.

Usage: webhost-inspect.py <dir> <template> <runtime> [accepted,ids,...]
"""

import json
import os
import re
import shutil
import subprocess
import sys

MAX_FILE = 100 * 1024 * 1024          # one file
MAX_TOTAL = 2 * 1024 * 1024 * 1024    # the whole release
SERVER_CODE = re.compile(r"\.(php\d?|phtml|phar|cgi|pl|asp|aspx|jsp|shtml)$", re.I)
WEB_SHELL = [
    (re.compile(rb"eval\s*\(\s*(base64_decode|gzinflate|gzuncompress|str_rot13|gzdecode)\s*\(", re.I), "eval of an encoded payload"),
    (re.compile(rb"(assert|eval|system|exec|passthru|shell_exec|popen|proc_open)\s*\(\s*\$_(GET|POST|REQUEST|COOKIE|SERVER)", re.I), "request input passed to code execution"),
    (re.compile(rb"preg_replace\s*\(\s*['\"](.).*\1[a-z]*e[a-z]*['\"]", re.I), "preg_replace with /e"),
    (re.compile(rb"\$\{?\s*['\"]?_(GET|POST|REQUEST)['\"]?\s*\}?\s*\[[^\]]+\]\s*\(", re.I), "request input called as a function"),
]
SECRETS = [
    (re.compile(rb"-----BEGIN (RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY-----"), "private key"),
    (re.compile(rb"\bAKIA[0-9A-Z]{16}\b"), "AWS access key"),
    (re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{36,}\b"), "GitHub token"),
    (re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), "Slack token"),
    (re.compile(rb"\bsk_live_[A-Za-z0-9]{20,}\b"), "Stripe secret key"),
]
TEXT_SCAN_LIMIT = 2 * 1024 * 1024     # only the first 2 MB of a file is read for patterns
SKIP_DIRS = {"node_modules", "vendor", ".git"}
OSV = "/usr/local/bin/osv-scanner"


def finding(level, rule, path, detail):
    return {"level": level, "rule": rule, "file": path, "detail": detail}


def walk(root):
    for base, dirs, files in os.walk(root):
        for name in dirs + files:
            yield os.path.join(base, name)


def files_and_links(root, template, findings):
    total = 0
    rootreal = os.path.realpath(root)
    for path in walk(root):
        rel = os.path.relpath(path, root)
        if os.path.islink(path):
            target = os.path.realpath(path)
            if target != rootreal and not target.startswith(rootreal + os.sep):
                findings.append(finding("block", "symlink-outside", rel, f"points outside the release: {os.readlink(path)}"))
            continue
        if not os.path.isfile(path):
            continue
        size = os.path.getsize(path)
        total += size
        if size > MAX_FILE:
            findings.append(finding("block", "file-too-large", rel, f"{size // (1024 * 1024)} MB; the limit is {MAX_FILE // (1024 * 1024)} MB"))
        if template == "static" and SERVER_CODE.search(path):
            findings.append(finding("block", "server-code-in-static", rel, "a static site serves files as they are; this would be served as source"))
        if template == "static" and os.access(path, os.X_OK) and not rel.startswith("media" + os.sep):
            with open(path, "rb") as fh:
                if fh.read(4) == b"\x7fELF":
                    findings.append(finding("block", "executable-in-static", rel, "an ELF executable in a static site"))
    if total > MAX_TOTAL:
        findings.append(finding("block", "release-too-large", ".", f"{total // (1024 * 1024)} MB in total"))


def patterns(root, findings):
    for path in walk(root):
        rel = os.path.relpath(path, root)
        parts = set(rel.split(os.sep))
        if parts & SKIP_DIRS or os.path.islink(path) or not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                data = fh.read(TEXT_SCAN_LIMIT)
        except OSError:
            continue
        if b"\x00" in data[:1024]:
            continue
        if re.search(r"\.(php\d?|phtml|inc)$", path, re.I):
            for rx, what in WEB_SHELL:
                if rx.search(data):
                    findings.append(finding("block", "web-shell", rel, what))
                    break
        for rx, what in SECRETS:
            if rx.search(data):
                findings.append(finding("block", "secret", rel, what))
                break
        if os.path.basename(path) in (".env", ".env.production", "wp-config.php"):
            findings.append(finding("warn", "config-file", rel, "a configuration file that may hold passwords; it is served if it lies under the web root"))


def dependencies(root, findings):
    lockfiles = ("composer.lock", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
                 "requirements.txt", "poetry.lock", "uv.lock", "Pipfile.lock")
    if not any(os.path.basename(p) in lockfiles for p in walk(root) if "node_modules" not in p):
        return
    if not shutil.which(OSV) and not os.access(OSV, os.X_OK):
        findings.append(finding("warn", "dependency-scan-unavailable", ".", "osv-scanner is not installed"))
        return
    try:
        out = subprocess.run([OSV, "scan", "source", "--recursive", "--format", "json", root],
                             capture_output=True, text=True, timeout=300).stdout
        report = json.loads(out or "{}")
    except (subprocess.SubprocessError, ValueError, OSError) as err:
        findings.append(finding("warn", "dependency-scan-unavailable", ".", f"osv-scanner failed: {err}"))
        return
    for result in report.get("results") or []:
        source = os.path.relpath((result.get("source") or {}).get("path", root), root)
        for pkg in result.get("packages") or []:
            name = (pkg.get("package") or {}).get("name", "?")
            version = (pkg.get("package") or {}).get("version", "?")
            for group in pkg.get("groups") or []:
                try:
                    score = float(group.get("max_severity") or 0)
                except ValueError:
                    score = 0.0
                ids = group.get("ids") or []
                level = "block" if score >= 9.0 else "warn"
                findings.append(finding(level, "vulnerable-dependency", source,
                                        f"{name} {version}: {', '.join(ids)} (CVSS {score or 'unknown'})") | {"ids": ids})


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    root, template, runtime = sys.argv[1], sys.argv[2], sys.argv[3]
    accepted = {a for a in (sys.argv[4] if len(sys.argv) > 4 else "").split(",") if a and a != "-"}
    findings = []
    files_and_links(root, template, findings)
    patterns(root, findings)
    if runtime != "static":
        dependencies(root, findings)
    for f in findings:
        if f["level"] == "block" and (f["rule"] in accepted or accepted & set(f.get("ids", []))):
            f["level"] = "accepted"
    verdict = "block" if any(f["level"] == "block" for f in findings) else "pass"
    print(json.dumps({"verdict": verdict, "findings": findings}))


if __name__ == "__main__":
    main()
