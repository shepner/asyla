"""Set Home Assistant's stable HTTP config to trust the internal-access proxy. Run by
home-assistant.sh up inside the pinned image, with Home Assistant stopped:

  python3 - SUBNET < http-trust-proxy.py    (/config mounted)

Home Assistant 2026.10 keeps its HTTP settings in .storage/http as a stable/pending pair; http YAML
and UI changes go to `pending`, a 5-minute trial that reverts unless an admin promotes it
(core homeassistant/components/http/config.py, AUTO_REVERT_DELAY). Writing `stable` directly needs
no admin. The file holds no secrets (ConfData: port, CORS, X-Forwarded-For, trusted proxies, bans,
SSL paths); this prints only "set" or "unchanged", never the file.
Exit 0 when set or unchanged, 2 when the file is missing or not the expected format.
"""
import json
import os
import sys

PATH = os.environ.get("HTTP_STORE", "/config/.storage/http")


def main() -> int:
    subnet = sys.argv[1]
    try:
        with open(PATH) as f:
            store = json.load(f)
        data = store["data"]
        stable = data["stable"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"http store unreadable: {type(e).__name__}", file=sys.stderr)
        return 2
    if store.get("version") != 2:
        print(f"http store version {store.get('version')}, expected 2", file=sys.stderr)
        return 2
    want = {"use_x_forwarded_for": True, "trusted_proxies": [subnet]}
    if all(stable.get(k) == v for k, v in want.items()) and data.get("pending") is None:
        print("unchanged")
        return 0
    stable.update(want, error=None, error_message=None)
    data["pending"] = None  # an unpromoted trial would otherwise be reported in the UI
    data["yaml_migration_done"] = True
    tmp = PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(store, f, indent=4)
    os.chmod(tmp, os.stat(PATH).st_mode & 0o777)
    os.replace(tmp, PATH)
    print("set")
    return 0


if __name__ == "__main__":
    sys.exit(main())
