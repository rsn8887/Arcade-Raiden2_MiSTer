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

Before any of that it identifies what each file actually *is*, because the
commonest broken install is not a corrupt file, it is the wrong file: saving
GitHub's file viewer instead of the raw download leaves you with 200 KB of HTML
named Raiden2_20260811.rbf. An md5 mismatch and an XML syntax error are both
true of that, and neither says what happened. "This is an HTML page, not an
FPGA bitstream" does.

Whenever a file is wrong, missing or the wrong type, the run ends with the exact
commands to fetch it again -- or pass --repair and the script fetches everything
itself, verifying each download before it replaces anything.

Usage:
    tools/check_files.py                     # ROMs alongside the MRAs
    tools/check_files.py --roms /path/to/mame
    tools/check_files.py --repair            # re-download and reinstall the core
    tools/check_files.py --update            # rewrite releases/md5sums.txt

Exit status is 0 only if everything checked passed.
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
RELEASES = os.path.join(REPO, "releases")

# Normally releases/md5sums.txt in a checkout. But this script is also meant to
# be dropped onto a MiSTer on its own, next to a downloaded manifest, so fall
# back to whatever sits beside it.
MANIFEST = os.path.join(RELEASES, "md5sums.txt")
if not os.path.exists(MANIFEST) and os.path.exists(os.path.join(HERE, "md5sums.txt")):
    MANIFEST = os.path.join(HERE, "md5sums.txt")

OK, BAD, WARN = "  ok  ", " FAIL ", " warn "


class Report:
    def __init__(self):
        self.failed = False

    def line(self, tag, text):
        if tag is BAD:
            self.failed = True
        print(f"[{tag}] {text}")

    def head(self, text):
        print(f"\n{text}\n" + "-" * min(len(text), 60))


def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


RAW = "https://raw.githubusercontent.com/spacestate1/Arcade-Raiden2_MiSTer/main"
RELEASE_URL = RAW + "/releases"
MRA_NAMES = ("Raiden II.mra", "Raiden DX.mra")

BITSTREAM, MRA = "an FPGA bitstream", "an MRA"

# Why each wrong type turns up, said in one line. Being told "this is a zip"
# is only half an answer; the other half is what you did to get one.
WHY = {
    "an HTML page":
        "you saved GitHub's file view instead of the file itself",
    "a plain-text error page":
        "the download URL was wrong -- the server sent an error, and wget saved it",
    "a Git LFS pointer":
        "the file was fetched without Git LFS, so you have the stub, not the data",
    "a zip archive":
        "that is the packaged release; unzip it and use the file inside",
    "a gzip archive":
        "still compressed -- gunzip it first",
    "empty":
        "the download produced nothing at all",
}


def sniff(path):
    """What this file actually is, as a phrase that fits 'this is ___'.

    Deliberately positive about the two types that matter. A Cyclone V raw .rbf
    opens with a run of 0xFF and then the 0x6A sync word, and an MRA is XML with
    a <misterromdescription> root, so both can be confirmed rather than merely
    failing to look like HTML.
    """
    size = os.path.getsize(path)
    if size == 0:
        return "empty"
    with open(path, "rb") as f:
        head = f.read(4096)

    if head.startswith(b"PK\x03\x04"):
        return "a zip archive"
    if head.startswith(b"\x1f\x8b"):
        return "a gzip archive"
    if head.startswith(b"version https://git-lfs."):
        return "a Git LFS pointer"

    pad = len(head) - len(head.lstrip(b"\xff"))
    if pad >= 16 and head[pad:pad + 4] == b"\x6a\x6a\x6a\x6a":
        return BITSTREAM

    stripped = head.lstrip()
    if stripped[:512].lower().startswith((b"<!doctype html", b"<html", b"<head")):
        return "an HTML page"
    if b"<misterromdescription" in head.lower():
        return MRA
    if stripped.startswith(b"<"):
        return "some other XML"

    # Reading a fixed 4096 bytes can cut a UTF-8 sequence in half, so back off a
    # few bytes before calling a text file binary.
    for end in range(len(head), max(len(head) - 4, 0), -1):
        try:
            text = head[:end].decode("utf-8")
            break
        except UnicodeDecodeError:
            continue
    else:
        return "binary data of some other kind"
    if size < 4096 and re.match(r"\s*(\d{3}\b|not found|error)", text, re.I):
        return "a plain-text error page"
    return "a text file"


def check_type(rep, path, expected):
    """Confirm the file is the type it is named after. True if it is."""
    name = os.path.basename(path)
    actual = sniff(path)
    if actual == expected:
        return True
    size = os.path.getsize(path)
    indent = " " * len(name)
    rep.line(BAD, f"{name}: {size} bytes -- this is {actual}, not {expected}")
    if actual in WHY:
        rep.line(BAD, f"{indent}  ({WHY[actual]})")
    if expected == BITSTREAM:
        rep.line(BAD, f"{indent}  the FPGA rejects it without a message, which "
                      f"looks exactly like a missing core")
    return False


def default_dir(*mister):
    """Where to look when the matching option was not given.

    In a checkout that is releases/. Dropped on a MiSTer on its own there is no
    checkout: REPO comes out as "/" and the old default was the nonexistent
    /releases, which reads as "your files are missing" when the truth is "you
    did not say where they are". Falling back to the standard MiSTer paths means
    the whole thing runs as a bare `python3 check_files.py` on hardware.
    """
    if os.path.isdir(RELEASES):
        return RELEASES
    for guess in mister:
        if os.path.isdir(guess):
            return guess
    return HERE


# MRAs for this core, identified by the bitstream they ask for rather than by
# their filename: matching on "raiden" pulled in Raiden (World).mra, a different
# core's MRA, and then hard-failed on its raiden.zip. A regex rather than an XML
# parse on purpose -- the files most worth reporting on are the ones that will
# not parse.
OUR_RBF = re.compile(rb"<\s*rbf\s*>\s*raiden2\s*<", re.I)


def wants_our_core(path):
    with open(path, "rb") as f:
        return OUR_RBF.search(f.read(8192)) is not None


def is_our_rbf(name):
    """Would MiSTer accept this filename for <rbf>Raiden2</rbf>?

    Same rule as get_rbf in support/arcade/mra_loader.cpp: the Raiden2 stem,
    optionally Arcade- prefixed, case-insensitive, followed by a '.' or a '_'.
    """
    stem = name.lower()
    if stem.startswith("arcade-"):
        stem = stem[len("arcade-"):]
    return bool(re.match(r"raiden2[._]", stem))


def fetch(url, dest):
    """Download url to dest. Raises on any failure, leaving dest untouched.

    wget first because that is what a MiSTer has and what its certificate store
    is set up for; urllib is the fallback for desktops without it.
    """
    for tool, cmd in (("wget", ["wget", "-q", "-O", dest, url]),
                      ("curl", ["curl", "-fsSL", "-o", dest, url])):
        if shutil.which(tool):
            r = subprocess.run(cmd)
            if r.returncode == 0:
                return
            raise RuntimeError(f"{tool} failed with status {r.returncode}")
    with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
        shutil.copyfileobj(r, f)


def release_url(name):
    return f"{RELEASE_URL}/{urllib.parse.quote(name)}"


class Repair:
    """The files this run found wrong, and how to put them back.

    Collected as it goes rather than guessed at the end, so the commands printed
    name the directories actually being checked -- an install under a
    non-standard path gets commands for that path, not for the documented one.
    """

    def __init__(self):
        self.items = []          # (destination path, url)
        self.notes = []
        self.rbf_into = None     # dir wanting the current release, name unknown

    def need(self, dest, url):
        if not any(d == dest for d, _ in self.items):
            self.items.append((dest, url))

    def note(self, text):
        if text not in self.notes:
            self.notes.append(text)

    def print_commands(self):
        if not self.items and not self.notes:
            return
        print("\nTo put this install back, paste:")
        print("-" * 34)
        if self.items:
            print(f'R={RELEASE_URL}')
            for d in sorted({os.path.dirname(p) for p, _ in self.items if
                             os.path.dirname(p)}):
                print(f"mkdir -p '{d}'")
            for dest, url in self.items:
                tail = url[len(RELEASE_URL) + 1:]
                print(f'wget -O \'{dest}\' "$R/{tail}"')
            print("\nOr let this script do it:  python3 "
                  f"{os.path.basename(__file__)} --repair <same arguments>")
        for n in self.notes:
            print(f"\n{n}")

    def run(self, rep):
        """Re-download every file, verify it, and only then install it.

        Verifying in a temporary file is the point: a repair that runs into a
        captive portal or a stale CDN must not overwrite a good copy with
        whatever it got back. Returns whether every intended file was installed.
        """
        rep.head("Repair")
        done = 0
        tmp = tempfile.mkdtemp(prefix="raiden2-repair.")
        try:
            manifest = os.path.join(tmp, "md5sums.txt")
            try:
                fetch(f"{RELEASE_URL}/md5sums.txt", manifest)
                want = read_manifest(manifest)
            except Exception as e:
                rep.line(BAD, f"could not fetch md5sums.txt: {e}")
                rep.line(BAD, "  no network, or no route to raw.githubusercontent.com")
                return False
            if self.rbf_into:
                if not want:
                    rep.line(BAD, "the manifest names no bitstream -- cannot tell "
                                  "which release to fetch")
                else:
                    self.need(os.path.join(self.rbf_into, max(want)),
                              release_url(max(want)))
            for dest, url in self.items:
                name = os.path.basename(dest)
                staged = os.path.join(tmp, name)
                try:
                    fetch(url, staged)
                except Exception as e:
                    rep.line(BAD, f"{name}: download failed -- {e}")
                    continue
                expected = BITSTREAM if name.lower().endswith(".rbf") else MRA
                got = sniff(staged)
                if got != expected:
                    rep.line(BAD, f"{name}: downloaded {got}, not {expected} "
                                  f"-- left the existing file alone")
                    continue
                if name in want and md5_of(staged) != want[name]:
                    rep.line(BAD, f"{name}: downloaded copy fails its own md5 "
                                  f"-- left the existing file alone")
                    continue
                os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
                shutil.move(staged, dest)
                done += 1
                rep.line(OK, f"{name}: reinstalled to {dest} "
                             f"({os.path.getsize(dest)} bytes)")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return done == len(self.items)


_FETCHED_MANIFEST = None      # (dict, note) once we have gone to the network


def read_manifest(path=None):
    """Expected bitstream hashes, from the manifest.

    With no local copy -- the normal case for a script wget'd onto a MiSTer on
    its own -- fetch it. Without one there is nothing to compare a bitstream
    against, and the whole first half of this check quietly degrades to a
    warning. One small GET beats telling someone their core is unverifiable.
    """
    global _FETCHED_MANIFEST
    explicit = path is not None
    path = path or MANIFEST
    if not explicit and not os.path.exists(path):
        if _FETCHED_MANIFEST is None:
            tmp = tempfile.mkdtemp(prefix="raiden2-manifest.")
            try:
                got = os.path.join(tmp, "md5sums.txt")
                fetch(f"{RELEASE_URL}/md5sums.txt", got)
                _FETCHED_MANIFEST = (read_manifest(got), None)
            except Exception as e:
                _FETCHED_MANIFEST = ({}, f"could not fetch md5sums.txt ({e})")
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        return _FETCHED_MANIFEST[0]

    want = {}
    if not os.path.exists(path):
        return want
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            digest, _, name = line.partition("  ")
            if digest and name:
                want[name.strip()] = digest.strip()
    return want


def write_manifest(rep):
    if not os.path.isdir(RELEASES):
        rep.line(BAD, f"--update rewrites {RELEASES}, which does not exist "
                      f"-- run it from a checkout")
        return
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


def check_bitstreams(rep, where, fix):
    rep.head(f"Bitstream ({where})")
    want = read_manifest()

    def refetch(n=None):
        """Queue the release bitstream. Its name comes from the manifest, so a
        new release is picked up without editing this script."""
        n = n or (max(want) if want else None)
        if n:
            fix.need(os.path.join(where, n), release_url(n))
        else:
            fix.note("No md5sums.txt to name the current release from -- see\n"
                     f"{RELEASE_URL}/")

    if not os.path.isdir(where):
        rep.line(BAD, f"{where}: no such directory")
        refetch()
        return
    names = sorted(n for n in os.listdir(where) if n.lower().endswith(".rbf"))
    if not names:
        rep.line(BAD, f"no .rbf found in {where}")
        refetch()
        return
    if want and not os.path.exists(MANIFEST):
        rep.line(OK, "fetched md5sums.txt (no local copy) -- hashes are the "
                     "current release's")
    if not want:
        note = _FETCHED_MANIFEST[1] if _FETCHED_MANIFEST else None
        rep.line(WARN, f"no md5sums.txt: {note}" if note else
                       "no releases/md5sums.txt -- run with --update to create it")
        rep.line(WARN, "  checking what each file is, but not which release it is")
    if not [n for n in names if is_our_rbf(n)]:
        # A cores/ directory full of other people's cores and none of ours: the
        # core is simply not installed. Without this the per-file loop below
        # skips every unrelated .rbf and the section passes in silence.
        rep.line(BAD, f"no Raiden2 bitstream among the {len(names)} .rbf here "
                      f"-- the core is not installed")
        refetch()
        return
    known = [n for n in names if n in want]
    if want and not known:
        rep.line(WARN, f"none of the {len(names)} .rbf here are Raiden2 releases "
                       f"-- checking them all against the manifest anyway")
    for n in names:
        # Another core's bitstream. The old rule skipped these only when there
        # were more than four files in the directory, so a small cores/ folder
        # got every unrelated core hashed and warned about.
        if not is_our_rbf(n) and n not in want:
            continue
        path = os.path.join(where, n)
        if not check_type(rep, path, BITSTREAM):
            refetch(n if n in want else None)
            continue
        size = os.path.getsize(path)
        got = md5_of(path)
        if n not in want:
            rep.line(WARN, f"{n}: {size} bytes, md5 {got} (not in manifest)")
        elif got == want[n]:
            rep.line(OK, f"{n}: {size} bytes, md5 matches")
        else:
            rep.line(BAD, f"{n}: {size} bytes, md5 {got}")
            rep.line(BAD, f"{' ' * len(n)}  expected {want[n]} -- a real bitstream, "
                          f"but not this release's: damaged in transfer, or an "
                          f"older build under the same name")
            refetch(n)


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


def check_mra(rep, mra_path, roms_dir, fix):
    name = os.path.basename(mra_path)
    rep.head(f"{name}")

    if not check_type(rep, mra_path, MRA):
        if name in MRA_NAMES:
            fix.need(mra_path, release_url(name))
        return
    try:
        needed = mra_parts(mra_path)
    except ET.ParseError as e:
        rep.line(BAD, f"{name} is not valid XML: {e}")
        rep.line(BAD, "  It is an MRA, but a malformed one. MiSTer's parser may "
                      "still load it; every other tool will reject it")
        if name in MRA_NAMES:
            fix.need(mra_path, release_url(name))
        return
    rep.line(OK, "valid XML")

    if not needed:
        rep.line(WARN, "no <rom zip=...> entries -- nothing to check")
        return

    for zname, parts in sorted(needed.items()):
        zpath = os.path.join(roms_dir, zname)
        if not os.path.exists(zpath):
            rep.line(BAD, f"{zname}: not found in {roms_dir}")
            fix.note("raiden2.zip and raidendx.zip are your own MAME ROM sets. "
                     "This script cannot\nfetch those; put them in "
                     "/media/fat/games/mame, or point --roms at them.")
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
    # All three default to releases/ in a checkout and to the standard MiSTer
    # paths otherwise, so on hardware the options can simply be left off.
    ap.add_argument("--roms", default=None,
                    help="directory holding raiden2.zip / raidendx.zip "
                         "(default: releases/, or /media/fat/games/mame)")
    ap.add_argument("--install", metavar="DIR",
                    help="where the .rbf is installed (default: releases/, or "
                         "/media/fat/_Arcade/cores). That installed copy is the "
                         "one that has to be good, so check it if the core will "
                         "not start")
    ap.add_argument("--mra", metavar="DIR",
                    help="where the .mra files are (default: releases/, or "
                         "/media/fat/_Arcade)")
    ap.add_argument("--repair", action="store_true",
                    help="re-download the bitstream and both MRAs and reinstall "
                         "them, then check again. Each download is verified "
                         "before it replaces anything, so a failed fetch cannot "
                         "make things worse. Needs network")
    ap.add_argument("--update", action="store_true",
                    help="rewrite releases/md5sums.txt from the current bitstreams")
    args = ap.parse_args()

    rep = Report()
    if args.update:
        write_manifest(rep)
        return 1 if rep.failed else 0

    install_dir = args.install or default_dir("/media/fat/_Arcade/cores")
    mra_dir = args.mra or default_dir("/media/fat/_Arcade")
    roms_dir = args.roms or default_dir("/media/fat/games/mame",
                                        "/media/fat/games/MAME")

    def run_checks(fix):
        check_bitstreams(rep, install_dir, fix)
        mras, others = [], 0
        if not os.path.isdir(mra_dir):
            rep.line(BAD, f"{mra_dir}: no such directory")
        else:
            for n in sorted(os.listdir(mra_dir)):
                if not n.lower().endswith(".mra"):
                    continue
                path = os.path.join(mra_dir, n)
                # Ours by <rbf>, plus anything under one of the release names
                # that came out the wrong type -- a saved web page cannot say
                # which core it belongs to, and is exactly what to report on.
                if wants_our_core(path) or n in MRA_NAMES:
                    mras.append(path)
                else:
                    others += 1
        for n in MRA_NAMES:
            if os.path.join(mra_dir, n) not in mras:
                rep.head(n)
                rep.line(BAD, f"not found in {mra_dir}")
                fix.need(os.path.join(mra_dir, n), release_url(n))
        if others:
            print(f"\n({others} .mra in {mra_dir} belong to other cores "
                  f"-- not checked)")
        for m in mras:
            check_mra(rep, m, roms_dir, fix)

    if args.repair:
        # Repair everything the core ships, not only what this run happened to
        # find broken: "re-pull the lot" is the request behind --repair, and a
        # file can be wrong in ways no check here looks for.
        plan = Repair()
        want = read_manifest()
        if want:
            plan.need(os.path.join(install_dir, max(want)),
                      release_url(max(want)))
        else:
            plan.rbf_into = install_dir                # named by the fetched manifest
        for n in MRA_NAMES:
            plan.need(os.path.join(mra_dir, n), release_url(n))
        repaired = plan.run(rep)
        rep.failed = False                             # judge on the re-check
        print("\nRe-checking:")

    fix = Repair()
    run_checks(fix)

    print()
    if rep.failed:
        print("FAILED -- see the lines marked FAIL above.")
        fix.print_commands()
    elif args.repair and not repaired:
        print("All checks passed, but --repair could not fetch everything "
              "-- see above.")
    else:
        print("All checks passed.")
    return 1 if rep.failed else 0


if __name__ == "__main__":
    sys.exit(main())
