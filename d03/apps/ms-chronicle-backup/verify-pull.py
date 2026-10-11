# verify-pull.py <tarball> <manifest.json> <response-headers-file>
import hashlib, json, sys, tarfile

tarball, manifest_path, headers_path = sys.argv[1:4]
headers = {}
for line in open(headers_path, encoding="latin-1"):
    key, sep, value = line.partition(":")
    if sep:
        headers[key.strip().lower()] = value.strip()
manifest = json.load(open(manifest_path, encoding="utf-8"))
digest, size = hashlib.sha256(), 0
with open(tarball, "rb") as handle:
    for block in iter(lambda: handle.read(1 << 20), b""):
        digest.update(block)
        size += len(block)
problems = []

def same(what, got, want):
    if str(got) != str(want):
        problems.append("%s: the copy has %r, the sender said %r" % (what, got, want))

same("snapshot name", manifest.get("name"), headers.get("x-chronicle-snapshot"))
same("tarball sha256 (header)", digest.hexdigest(), headers.get("x-chronicle-sha256"))
same("tarball sha256 (manifest)", digest.hexdigest(), manifest.get("tarball_sha256"))
same("tarball bytes", size, headers.get("x-chronicle-bytes"))
same("episodes", manifest.get("episodes"), headers.get("x-chronicle-episodes"))
same("schema", manifest.get("schema"), headers.get("x-chronicle-schema"))
if "x-chronicle-observations" in headers:
    same("observations", manifest.get("observations"), headers["x-chronicle-observations"])
# Every file in the tarball, against the table the Mini wrote when it read the volumes.
expected = {"archive/" + path: entry["sha256"] for path, entry in manifest.get("files", {}).items()}
expected.update(
    ("observations/" + path, entry["sha256"]) for path, entry in manifest.get("observation_files", {}).items()
)
found = {}
try:
    with tarfile.open(tarball, "r:gz") as tar:
        for member in tar:
            if not member.isfile():
                problems.append("not a regular file: " + member.name)
                continue
            found[member.name] = hashlib.sha256(tar.extractfile(member).read()).hexdigest()
except (tarfile.TarError, OSError, EOFError) as exc:
    problems.append("the tarball does not read: %s" % exc)
differ = sorted(set(found) ^ set(expected)) + sorted(k for k in set(found) & set(expected) if found[k] != expected[k])
if differ:
    problems.append("%d file(s) differ from the manifest, first: %s" % (len(differ), differ[0]))
if problems:
    sys.exit("FAILED: " + "; ".join(problems))
print("ok %s files=%d episodes=%s observations=%s" % (
    manifest["name"], len(found), manifest.get("episodes"), manifest.get("observations", "not-covered")))
