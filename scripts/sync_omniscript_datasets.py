#!/usr/bin/env python3
"""Sync OmniScript overall JSON datasets from devideo work dir into admin/datasets/.

The gateway container does not see /data/ChatGPT/devideo, so the overall JSONs
are snapshotted into the admin static tree and served alongside the app.
Re-run this script whenever new overall JSONs are produced.

Usage:
    python3 scripts/sync_omniscript_datasets.py [--work-dir PATH] [--out-dir PATH]
"""
import argparse
import json
import sys
from pathlib import Path

DEFAULT_WORK = Path("/data/ChatGPT/devideo/work")
DEFAULT_OUT = Path(__file__).resolve().parent.parent / "admin" / "datasets"

MIN_KEYS = {"video_file", "script"}


def is_valid_overall(data) -> bool:
    if not isinstance(data, dict):
        return False
    if not MIN_KEYS.issubset(data.keys()):
        return False
    script = data.get("script")
    if not isinstance(script, dict):
        return False
    scenes = script.get("script")
    if not isinstance(scenes, list) or not scenes:
        return False
    if not isinstance(data.get("video_file"), str) or not data["video_file"]:
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    work_dir: Path = args.work_dir
    out_dir: Path = args.out_dir
    if not work_dir.is_dir():
        print(f"work dir not found: {work_dir}", file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)

    copied = []
    skipped = []
    for path in sorted(work_dir.glob("*.json")):
        name = path.name
        # Skip raw intermediate dumps; they carry no script payload.
        if name.endswith("_raw.json"):
            skipped.append((name, "raw"))
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as err:
            skipped.append((name, f"parse error: {err}"))
            continue
        if not is_valid_overall(data):
            skipped.append((name, "not a valid overall dataset"))
            continue
        # Re-serialize compactly with </ escaped for safe inline embedding later.
        payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        (out_dir / name).write_text(payload + "\n", encoding="utf-8")
        copied.append(name)

    manifest = {"source": str(work_dir), "files": copied}
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"copied {len(copied)} dataset(s) -> {out_dir}")
    for name in copied:
        print(f"  + {name}")
    for name, reason in skipped:
        print(f"  - {name} ({reason})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

