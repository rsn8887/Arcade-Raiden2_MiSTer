#!/usr/bin/env python3
"""Check that a Raiden II / Raiden DX install is intact.

Answers the two questions that actually come up when the core will not run:

  1. Is the .rbf the file it is supposed to be?  A truncated or half-downloaded
     bitstream is rejected by the FPGA *silently* -- MiSTer prints nothing and
     restarts, which looks exactly like "the core is missing" and sends people
     hunting for filenames instead. Size and md5 settle it in a second.

  2. Are the ROMs the right ones?  The zip's own md5 is nearly useless here
     (re-zipping the same files changes it), so this checks the per-file CRC32s
     that the MRA actually asks for -- and it resolves them the way MiSTer does,
     by CRC first and filename second (file_io.cpp FileOpenZip). That order is
     why a set carrying the two background ROMs under transposed u-numbers still
     loads correctly.

It also parses each MRA with a strict XML parser. MiSTer's own parser (sxmlc)
is lenient and will happily load a malformed MRA, so a file can be broken for
every other tool while working on hardware -- which has happened here before.

Usage:
    tools/check_files.py                     # ROMs alongside the MRAs
    tools/check_files.py --roms /path/to/mame
    tools/check_files.py --update            # rewrite releases/md5sums.txt

Exit status is 0 only if everything checked passed.
"""

import argparse
import hashlib
import os
import sys
import zipfile
import xml.etree.ElementTree as ET

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELEASES = os.path.join(REPO, "releases")
MANIFEST = os.path.join(RELEASES, "md5sums.txt")

OK, BAD, WARN = "  ok  ", " FAIL ", " warn "


class Report:
    def __init__(self):
        self.failed = False

    def line(self, tag, text):
        if tag is BAD:
            self.failed = True
        print(f"[{tag}] {text}")

    def head(self, text):
        print(f"\n{text}\n" + "-" * len(text))


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_manifest():
    """Standard md5sum format, so `md5sum -c md5sums.txt` also works."""
    want = {}
    if not os.path.exists(MANIFEST):
        return want
    with open(MANIFEST) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            digest, _, name = line.partition("  ")
            if digest and name:
                want[name.strip()] = digest.strip()
    return want


def write_manifest(rep):
    names = sorted(n for n in os.listdir(RELEASES) if n.lower().endswith(".rbf"))
    if not names:
        rep.line(BAD, "no .rbf in releases/ -- nothing to record")
        return
    with open(MANIFEST, "w") as f:
        f.write("# md5 of each released bitstream. Regenerate with:\n")
        f.write("#     tools/check_files.py --update\n")
        f.write("# Verify with either:\n")
        f.write("#     tools/check_files.py\n")
        f.write("#     md5sum -c md5sums.txt      (run from releases/)\n")
        for n in names:
            f.write(f"{md5_of(os.path.join(RELEASES, n))}  {n}\n")
    rep.line(OK, f"wrote {os.path.relpath(MANIFEST, REPO)} ({len(names)} bitstream(s))")


def check_bitstreams(rep):
    rep.head("Bitstream")
    want = read_manifest()
    names = sorted(n for n in os.listdir(RELEASES) if n.lower().endswith(".rbf"))
    if not names:
        rep.line(BAD, "no .rbf found in releases/")
        return
    if not want:
        rep.line(WARN, "no releases/md5sums.txt -- run with --update to create it")
    for n in names:
        path = os.path.join(RELEASES, n)
        size = os.path.getsize(path)
        got = md5_of(path)
        if n not in want:
            rep.line(WARN, f"{n}: {size} bytes, md5 {got} (not in manifest)")
        elif got == want[n]:
            rep.line(OK, f"{n}: {size} bytes, md5 matches")
        else:
            rep.line(BAD, f"{n}: {size} bytes, md5 {got}")
            rep.line(BAD, f"{' ' * len(n)}  expected {want[n]} -- file is corrupt "
                          f"or was not downloaded as a raw binary")


def mra_parts(path):
    """(zipname -> [(partname, crc)]) required by one MRA.

    Parts without both a name and a crc are literal fill bytes, not files.
    """
    tree = ET.parse(path)                      # strict: raises on malformed XML
    root = tree.getroot()
    out = {}
    for rom in root.iter("rom"):
        z = rom.get("zip")
        if not z:
            continue
        for zname in [s.strip() for s in z.split("|") if s.strip()]:
            need = out.setdefault(zname, [])
            for part in rom.iter("part"):
                name, crc = part.get("name"), part.get("crc")
                if name and crc:
                    entry = (name, crc.lower().zfill(8))
                    if entry not in need:
                        need.append(entry)
    return out


def zip_index(path):
    """(crc32 -> [names], name -> crc32) for one zip."""
    by_crc, by_name = {}, {}
    with zipfile.ZipFile(path) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            base = os.path.basename(info.filename)
            crc = f"{info.CRC:08x}"
            by_crc.setdefault(crc, []).append(base)
            by_name[base.lower()] = crc
    return by_crc, by_name


def check_mra(rep, mra_path, roms_dir):
    name = os.path.basename(mra_path)
    rep.head(f"{name}")

    try:
        needed = mra_parts(mra_path)
    except ET.ParseError as e:
        rep.line(BAD, f"{name} is not valid XML: {e}")
        rep.line(BAD, "  MiSTer's parser may still load it, but every other tool "
                      "will reject it")
        return
    rep.line(OK, "valid XML")

    if not needed:
        rep.line(WARN, "no <rom zip=...> entries -- nothing to check")
        return

    for zname, parts in sorted(needed.items()):
        zpath = os.path.join(roms_dir, zname)
        if not os.path.exists(zpath):
            rep.line(BAD, f"{zname}: not found in {roms_dir}")
            continue
        try:
            by_crc, by_name = zip_index(zpath)
        except zipfile.BadZipFile:
            rep.line(BAD, f"{zname}: not a readable zip (truncated download?)")
            continue

        good = renamed = 0
        problems = []
        for pname, pcrc in parts:
            if pcrc in by_crc:
                if pname.lower() in (n.lower() for n in by_crc[pcrc]):
                    good += 1
                else:
                    renamed += 1
                    problems.append(
                        (WARN, f"{pname}: present as {by_crc[pcrc][0]} "
                               f"(crc {pcrc} matches -- MiSTer resolves by CRC, "
                               f"so this loads)"))
            elif pname.lower() in by_name:
                problems.append(
                    (BAD, f"{pname}: crc {by_name[pname.lower()]}, "
                          f"MRA wants {pcrc} -- wrong revision of this ROM"))
            else:
                problems.append((BAD, f"{pname}: missing (crc {pcrc})"))

        total = len(parts)
        summary = f"{zname}: {good}/{total} exact"
        if renamed:
            summary += f", {renamed} matched by CRC under another name"
        bad_n = sum(1 for t, _ in problems if t is BAD)
        rep.line(BAD if bad_n else OK, summary + (f", {bad_n} bad" if bad_n else ""))
        for tag, text in problems:
            rep.line(tag, f"    {text}")

        rep.line(OK, f"    {zname} md5 {md5_of(zpath)} "
                     f"(informational -- CRCs above are the real test)")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--roms", default=RELEASES,
                    help="directory holding raiden2.zip / raidendx.zip "
                         "(default: releases/; on a MiSTer: /media/fat/games/mame)")
    ap.add_argument("--update", action="store_true",
                    help="rewrite releases/md5sums.txt from the current bitstreams")
    args = ap.parse_args()

    rep = Report()
    if args.update:
        write_manifest(rep)
        return 1 if rep.failed else 0

    check_bitstreams(rep)

    mras = sorted(os.path.join(RELEASES, n) for n in os.listdir(RELEASES)
                  if n.lower().endswith(".mra"))
    if not mras:
        rep.line(BAD, "no .mra found in releases/")
    for m in mras:
        check_mra(rep, m, args.roms)

    print()
    if rep.failed:
        print("FAILED -- see the lines marked FAIL above.")
    else:
        print("All checks passed.")
    return 1 if rep.failed else 0


if __name__ == "__main__":
    sys.exit(main())
