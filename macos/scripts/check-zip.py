#!/usr/bin/env python3 -I
"""Checks the final distribution ZIP: check-zip.py <zip> <needle>...

- every entry: no Unix UID/GID extra fields (0x7875 "ux", 0x5855 "UX", 0x000d PKWARE Unix), no absolute or ".." path,
  no symlink, no AppleDouble / .DS_Store, no model / log / settings / debug-symbol file;
- every file's bytes (as stored after extraction): none of the needles (build-machine paths, user and host names,
  e-mail), compared case-insensitively, as ASCII/UTF-8 and as UTF-16LE.
Exits 1 and lists every hit."""
import stat
import struct
import sys
import zipfile

zpath, needles = sys.argv[1], [n for n in sys.argv[2:] if len(n) >= 4]
bad_ext = (".gguf", ".bin", ".safetensors", ".log", ".traineddata", ".pdb")
bad_names = {"settings.json", "verify-cache.json", ".DS_Store"}
UNIX_IDS = {0x7875, 0x5855, 0x000D}
hits = []


def extra_ids(extra):
    i, ids = 0, []
    while i + 4 <= len(extra):
        hid, size = struct.unpack("<HH", extra[i:i + 4])
        ids.append(hid)
        i += 4 + size
    return ids


with zipfile.ZipFile(zpath) as z:
    # Local headers can carry different extra fields than the central directory: read both.
    raw = open(zpath, "rb").read()
    for zi in z.infolist():
        name = zi.filename
        if name.startswith("/") or ".." in name.split("/"):
            hits.append(f"{name}: unsafe path")
        if any(h in UNIX_IDS for h in extra_ids(zi.extra)):
            hits.append(f"{name}: UID/GID extra field (central)")
        off = zi.header_offset
        n_len, e_len = struct.unpack("<HH", raw[off + 26:off + 30])
        local_extra = raw[off + 30 + n_len:off + 30 + n_len + e_len]
        if any(h in UNIX_IDS for h in extra_ids(local_extra)):
            hits.append(f"{name}: UID/GID extra field (local)")
        mode = zi.external_attr >> 16
        if stat.S_ISLNK(mode):
            hits.append(f"{name}: symbolic link")
        base = name.rstrip("/").split("/")[-1]
        if base.startswith("._") or base in bad_names or base.lower().endswith(bad_ext) or ".dSYM" in name:
            hits.append(f"{name}: unexpected file")
        if name.endswith("/"):
            continue
        data = z.read(zi).lower()
        for n in needles:
            for enc in ("utf-8", "utf-16-le"):
                if n.lower().encode(enc) in data:
                    hits.append(f"{name}: contains '{n}' ({enc})")
    count = len(z.infolist())

if hits:
    sys.stderr.write("ZIP check failed:\n" + "\n".join(hits) + "\n")
    sys.exit(1)
print(f"ZIP check passed ({count} entries, {len(needles)} patterns, no UID/GID fields)")
