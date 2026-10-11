#!/usr/bin/env python3
"""The mirror-side rules of ms-chronicle-backup.sh (python3 standard library only).

verify-pull.py, beside this file, is the contract's own check of a download against its sender
(theOrg memory-system, ms-chronicle-mcp/README.md, "Off-host copy: the pull contract"). This file
holds what that check leaves to the puller: taking the staging names, the snapshot's name, the
comparison with the copy the mirror already holds, and retention. Every path it creates or
deletes is directly inside the mirror directory it is given.

  claim  <mirror> <stale-seconds>   take the three .partial names for this run, or say who has them
  name   <headers-file>             print X-Chronicle-Snapshot if it is a snapshot name
  guard  <manifest> <headers-file> <mirror>
                                    the new snapshot against the clock and the newest held pair
  prune  <mirror> <keep-name>       delete pairs older than <keep-name>, by exact name only
  held   <mirror>                   check the newest held pair against its own manifest
"""
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time

SNAPSHOT = re.compile(r"chronicle-\d{8}T\d{6}Z")
PARTIALS = (".download.partial", ".headers.partial", ".manifest.partial")
MAX_AGE = dt.timedelta(days=2)  # the Mini takes a snapshot daily; an older newest one is a stopped backup


def fail(message):
    sys.exit("FAILED: " + message)


def held_names(mirror):
    """Names with both files in the mirror, oldest first. The stamp sorts as time."""
    names = []
    for entry in os.listdir(mirror):
        if entry.endswith(".manifest.json"):
            name = entry[: -len(".manifest.json")]
            if SNAPSHOT.fullmatch(name) and os.path.isfile(os.path.join(mirror, name + ".tar.gz")):
                names.append(name)
    return sorted(names)


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def created(manifest, what):
    try:
        when = dt.datetime.fromisoformat(str(manifest.get("created")))
    except ValueError:
        fail("%s has no readable 'created': %r" % (what, manifest.get("created")))
    if when.tzinfo is None:
        when = when.replace(tzinfo=dt.timezone.utc)
    return when


def headers_of(path):
    headers = {}
    with open(path, encoding="latin-1") as handle:
        for line in handle:
            key, sep, value = line.partition(":")
            if sep:
                headers[key.strip().lower()] = value.strip()
    return headers


def cmd_claim(mirror, stale_seconds):
    """A pull in flight is seen by its .partial files. Fresh ones belong to a running pull: refuse.
    Old ones were left by a pull that died: remove them. Then take .download.partial exclusively."""
    paths = [os.path.join(mirror, p) for p in PARTIALS]
    present = [p for p in paths if os.path.lexists(p)]
    if present:
        age = time.time() - max(os.lstat(p).st_mtime for p in present)
        if age < float(stale_seconds):
            fail("another pull is in flight: %s changed %d s ago (taken as dead after %s s)"
                 % (os.path.basename(present[0]), age, stale_seconds))
        for p in present:
            os.unlink(p)
        print("removed %d .partial file(s) left by a pull that died %d s ago" % (len(present), age))
    try:
        os.close(os.open(paths[0], os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    except FileExistsError:
        fail("another pull took %s at the same moment" % PARTIALS[0])


def cmd_name(headers_path):
    name = headers_of(headers_path).get("x-chronicle-snapshot", "")
    if not SNAPSHOT.fullmatch(name):
        fail("X-Chronicle-Snapshot is not a snapshot name: %r" % name)
    print(name)


def cmd_guard(manifest_path, headers_path, mirror):
    new, headers = load(manifest_path), headers_of(headers_path)
    name = str(new.get("name"))
    if not SNAPSHOT.fullmatch(name):
        fail("the manifest's name is not a snapshot name: %r" % name)
    when = created(new, "the new manifest")
    if str(new.get("created")) != headers.get("x-chronicle-created"):
        fail("created: the manifest has %r, the sender said %r" % (new.get("created"), headers.get("x-chronicle-created")))
    age = dt.datetime.now(dt.timezone.utc) - when
    if age > MAX_AGE:
        fail("%s was taken %d h ago: the Mini's newest snapshot is older than %d h, so its backup has stopped"
             % (name, age.total_seconds() // 3600, MAX_AGE.total_seconds() // 3600))
    names = held_names(mirror)
    if not names:
        print("first %s" % name)
        return
    old_name = names[-1]
    old = load(os.path.join(mirror, old_name + ".manifest.json"))
    if name < old_name or when < created(old, "the held manifest"):
        fail("%s is older than the held copy %s" % (name, old_name))
    if name == old_name and new.get("tarball_sha256") != old.get("tarball_sha256"):
        fail("%s is held already with another checksum" % name)
    if int(new.get("episodes", -1)) < int(old.get("episodes", 0)):
        fail("episodes: %s has %s, the held copy %s has %s" % (name, new.get("episodes"), old_name, old.get("episodes")))
    if "observations" in old:
        if "observations" not in new:
            fail("%s does not cover observations; the held copy %s does" % (name, old_name))
        if int(new["observations"]) < int(old["observations"]):
            fail("observations: %s has %s, the held copy %s has %s"
                 % (name, new["observations"], old_name, old["observations"]))
    print("%s %s" % ("same" if name == old_name else "newer", name))


def cmd_prune(mirror, keep):
    """Only names of the exact snapshot form, only older than the pair just published. Manifest
    first: a tarball without its manifest is not a snapshot, so a half-pruned pair is not one."""
    if not SNAPSHOT.fullmatch(keep):
        fail("not a snapshot name: %r" % keep)
    if keep not in held_names(mirror):
        fail("%s is not a complete pair in the mirror: nothing pruned" % keep)
    removed = []
    for entry in sorted(os.listdir(mirror)):
        for suffix in (".manifest.json", ".tar.gz"):
            if entry.endswith(suffix):
                name = entry[: -len(suffix)]
                if SNAPSHOT.fullmatch(name) and name < keep:
                    os.unlink(os.path.join(mirror, entry))
                    removed.append(entry)
    print("pruned %d file(s)%s" % (len(removed), ": " + ", ".join(removed) if removed else ""))


def cmd_held(mirror):
    names = held_names(mirror)
    if not names:
        print("none")
        return
    name = names[-1]
    manifest = load(os.path.join(mirror, name + ".manifest.json"))
    digest, size = hashlib.sha256(), 0
    with open(os.path.join(mirror, name + ".tar.gz"), "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
            size += len(block)
    if digest.hexdigest() != manifest.get("tarball_sha256") or size != manifest.get("tarball_bytes"):
        fail("%s.tar.gz is not what its manifest recorded (sha256 or size differs)" % name)
    age = dt.datetime.now(dt.timezone.utc) - created(manifest, "the held manifest")
    print("%s episodes=%s observations=%s bytes=%d taken %d h ago; sha256 and size equal its manifest"
          % (name, manifest.get("episodes"), manifest.get("observations", "not-covered"), size,
             age.total_seconds() // 3600))


COMMANDS = {"claim": (cmd_claim, 2), "name": (cmd_name, 1), "guard": (cmd_guard, 3),
            "prune": (cmd_prune, 2), "held": (cmd_held, 1)}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS or len(sys.argv) - 2 != COMMANDS[sys.argv[1]][1]:
        sys.exit(__doc__)
    try:
        COMMANDS[sys.argv[1]][0](*sys.argv[2:])
    except (OSError, ValueError, TypeError) as exc:  # a file that does not read or parse fails the pull
        fail("%s: %s" % (type(exc).__name__, exc))
