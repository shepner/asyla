#!/usr/bin/env python3
"""Print vmh/survey.sh outputs (one file per node, key=value lines) side by side.

Usage: survey_table.py FILE...   (vmh/apply.sh survey NODE NODE... calls it)
Rows whose values are the same on every node are marked '=' so the differences stand out.
"""
import sys
from pathlib import Path


def read(path: Path) -> dict[str, str]:
    facts: dict[str, str] = {}
    for line in path.read_text(errors="replace").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            facts[key] = value
    return facts


def main(paths: list[str]) -> int:
    nodes = [(Path(p).name, read(Path(p))) for p in paths]
    keys: list[str] = []
    for _, facts in nodes:
        keys += [k for k in facts if k not in keys]
    width = 46
    print(f"{'':<2}{'key':<40}" + "".join(f"{name:<{width}}" for name, _ in nodes))
    for key in keys:
        values = [facts.get(key, "-") for _, facts in nodes]
        same = "=" if len(set(values)) == 1 else " "
        cells = [v if len(v) <= width - 2 else v[: width - 4] + ".." for v in values]
        print(f"{same:<2}{key:<40}" + "".join(f"{c:<{width}}" for c in cells))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
