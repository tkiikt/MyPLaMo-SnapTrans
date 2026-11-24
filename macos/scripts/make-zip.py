#!/usr/bin/env python3 -I
"""Deterministic ZIP for distribution: make-zip.py <source-dir> <out.zip> <epoch>

Stores <source-dir> under its own name. Unlike `ditto -c -k`, entries carry no Unix UID/GID extra fields (and no
extended attributes or resource forks); only the permission bits are kept (external attributes), and every entry gets
the same timestamp (<epoch>, e.g. the last commit time) so rebuilding the same tree gives the same bytes.
Symbolic links are refused (the app bundle has none)."""
import os
import stat
import sys
import time
import zipfile

src, out, epoch = sys.argv[1], sys.argv[2], int(sys.argv[3])
src = os.path.abspath(src)
base = os.path.dirname(src)
stamp = time.gmtime(max(epoch, 315532800))[:6]  # ZIP cannot store dates before 1980


def info(rel, mode, is_dir):
    zi = zipfile.ZipInfo(rel + ("/" if is_dir else ""), date_time=stamp)
    zi.create_system = 3  # Unix: external_attr carries the mode
    zi.external_attr = ((stat.S_IFDIR if is_dir else stat.S_IFREG) | (0o755 if is_dir else mode & 0o777)) << 16
    if is_dir:
        zi.external_attr |= 0x10  # MS-DOS directory flag
    zi.extra = b""
    return zi


tmp = out + ".tmp"
with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    entries = []
    for root, dirs, files in os.walk(src):
        dirs.sort()
        for d in dirs:
            entries.append(os.path.join(root, d))
        for f in sorted(files):
            entries.append(os.path.join(root, f))
    for p in [src] + entries:
        st = os.lstat(p)
        rel = os.path.relpath(p, base)
        if stat.S_ISLNK(st.st_mode):
            sys.exit(f"symbolic link not allowed in the package: {rel}")
        if stat.S_ISDIR(st.st_mode):
            z.writestr(info(rel, st.st_mode, True), b"")
        elif stat.S_ISREG(st.st_mode):
            with open(p, "rb") as fh:
                z.writestr(info(rel, st.st_mode, False), fh.read(), compress_type=zipfile.ZIP_DEFLATED)
        else:
            sys.exit(f"unexpected file type: {rel}")
os.replace(tmp, out)
