#!/usr/bin/env python3
"""webhost-ingest — unpack an uploaded package (.zip, .tar.gz, .tgz) safely.

Runs inside the webhost container. Refuses absolute paths, '..', links that
leave the package, device files and anything past the size limits. A package
whose content sits in one top-level folder is unpacked from inside it.

Usage: webhost-ingest.py <archive> <empty-target-dir>    (exit 0 ok, 1 refused)
"""

import os
import shutil
import sys
import tarfile
import zipfile

MAX_FILES = 50000
MAX_BYTES = 2 * 1024 * 1024 * 1024


def refuse(msg):
    print(f"refused: {msg}", file=sys.stderr)
    sys.exit(1)


def safe_name(name):
    n = name.replace("\\", "/")
    if n.startswith("/") or any(p == ".." for p in n.split("/")):
        refuse(f"unsafe path in the package: {name}")
    return n


def unzip(path, dest):
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        if len(infos) > MAX_FILES:
            refuse(f"more than {MAX_FILES} files")
        if sum(i.file_size for i in infos) > MAX_BYTES:
            refuse("larger than 2 GB unpacked")
        for i in infos:
            name = safe_name(i.filename)
            mode = (i.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                refuse(f"symbolic link in a zip package: {name}")
            target = os.path.join(dest, name)
            if i.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(i) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)


def untar(path, dest):
    with tarfile.open(path, "r:*") as t:
        members = t.getmembers()
        if len(members) > MAX_FILES:
            refuse(f"more than {MAX_FILES} files")
        if sum(m.size for m in members if m.isfile()) > MAX_BYTES:
            refuse("larger than 2 GB unpacked")
        for m in members:
            safe_name(m.name)
            if not (m.isfile() or m.isdir() or m.issym()):
                refuse(f"not a file, folder or link: {m.name}")
        # The 'data' filter refuses links leaving the target and strips modes and owners.
        t.extractall(dest, filter="data")


def flatten(dest):
    entries = [e for e in os.listdir(dest) if e not in ("__MACOSX", ".DS_Store")]
    if len(entries) == 1 and os.path.isdir(os.path.join(dest, entries[0])) and not os.path.islink(os.path.join(dest, entries[0])):
        inner = os.path.join(dest, entries[0])
        for e in os.listdir(inner):
            shutil.move(os.path.join(inner, e), os.path.join(dest, e))
        os.rmdir(inner)
    shutil.rmtree(os.path.join(dest, "__MACOSX"), ignore_errors=True)


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    archive, dest = sys.argv[1], sys.argv[2]
    if not os.path.isdir(dest) or os.listdir(dest):
        refuse("the target must be an empty folder")
    try:
        if zipfile.is_zipfile(archive):
            unzip(archive, dest)
        elif tarfile.is_tarfile(archive):
            untar(archive, dest)
        else:
            refuse("not a .zip or .tar.gz package")
    except (zipfile.BadZipFile, tarfile.TarError, OSError) as err:
        refuse(f"the package cannot be read: {err}")
    flatten(dest)
    if not os.listdir(dest):
        refuse("the package is empty")


if __name__ == "__main__":
    main()
