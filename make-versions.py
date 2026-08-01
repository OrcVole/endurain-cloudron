#!/usr/bin/env python3
"""Generate CloudronVersions.json, the community install channel's feed.

A stranger installs this package with:

    cloudron install --versions-url <raw url to CloudronVersions.json> \
                     --location endurain.example.com

The feed inlines the whole manifest, with every ``file://`` field expanded to
the content of the file it names. Generated rather than hand-written, because
the fields being inlined are Markdown documents containing quotes, backslashes
and newlines, and hand-editing them into JSON is how a feed ends up with
subtly broken escaping that only fails on someone else's install.

The feed's schema is STRICTER than CloudronManifest.json, and each of these
fails at install time rather than at build time, which means on a stranger's
server rather than on yours:

  - packagerName must be non-empty
  - contactEmail must be present and valid
  - iconUrl must be non-empty (and it is what really forces minBoxVersion 9.1.0)
  - mediaLinks must have at least one entry
  - the changelog must be in bracket format, "[1.0.1]" at line start, not
    Markdown "## 1.0.1"

Those are checked here, loudly, so the failure happens on the packager's
machine while it is cheap.

``icon`` deliberately stays as ``file://logo.png``: it is resolved from the
repository, unlike ``iconUrl``, which is the store-facing URL and must be
fetchable by a stranger.

Usage:

    ./make-versions.py                 # write CloudronVersions.json
    ./make-versions.py --check         # verify only, change nothing
"""

from __future__ import annotations

import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "CloudronManifest.json"
FEED = ROOT / "CloudronVersions.json"

# Fields the feed must carry as content rather than as a file:// reference.
INLINE_FIELDS = ("description", "changelog", "postInstallMessage")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def load_manifest() -> dict:
    try:
        return json.loads(MANIFEST.read_text())
    except json.JSONDecodeError as exc:
        fail(f"{MANIFEST.name} is not valid JSON: {exc}")


def inline(manifest: dict) -> dict:
    out = dict(manifest)
    for field in INLINE_FIELDS:
        value = out.get(field)
        if not isinstance(value, str) or not value.startswith("file://"):
            continue
        target = ROOT / value[len("file://"):]
        if not target.is_file():
            fail(f"{field} points at {target.name}, which does not exist")
        out[field] = target.read_text()
    return out


def check(manifest: dict) -> None:
    """Fail on anything the feed's schema requires and the manifest's does not."""
    problems: list[str] = []

    for field in INLINE_FIELDS:
        if isinstance(manifest.get(field), str) and manifest[field].startswith("file://"):
            problems.append(f"{field} was not inlined")

    if not manifest.get("packagerName"):
        problems.append("packagerName is empty; a versions-url install is rejected on 9.x")
    if not manifest.get("contactEmail"):
        problems.append("contactEmail is missing")
    if not manifest.get("iconUrl"):
        problems.append("iconUrl is empty; the feed requires it")
    if not manifest.get("mediaLinks"):
        problems.append("mediaLinks needs at least one entry")

    image = manifest.get("dockerImage", "")
    if "@sha256:" not in image:
        problems.append(f"dockerImage must be pinned by registry digest, got {image!r}")

    changelog = manifest.get("changelog", "")
    if not re.match(r"^\[\d+\.\d+\.\d+\]", changelog.lstrip()):
        problems.append(
            "changelog must be in bracket format with [x.y.z] at line start, not Markdown headings"
        )

    version = manifest.get("version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        problems.append(f"version must be a bare semver, got {version!r}")
    if not changelog.lstrip().startswith(f"[{version}]"):
        problems.append(
            f"the changelog's newest entry must be [{version}], matching the manifest version"
        )

    # Local assets the feed's URLs promise a stranger will be able to fetch.
    # Their existence in the repository is necessary but not sufficient: they
    # must also be pushed and public, which only publication can settle.
    for field in ("iconUrl", "mediaLinks"):
        entries = manifest.get(field, [])
        for url in [entries] if isinstance(entries, str) else entries:
            match = re.search(r"raw\.githubusercontent\.com/[^/]+/[^/]+/[^/]+/(.+)$", url)
            if match and not (ROOT / match.group(1)).is_file():
                problems.append(
                    f"{field} references {match.group(1)}, which is not in the repository, "
                    "so the URL will 404 even after publication"
                )

    if problems:
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        fail(f"{len(problems)} problem(s) would fail a stranger's install")


def main() -> None:
    check_only = "--check" in sys.argv[1:]

    manifest = inline(load_manifest())
    check(manifest)

    version = manifest["version"]
    now = datetime.now(timezone.utc)
    feed = {
        "stable": True,
        "versions": {
            version: {
                "manifest": manifest,
                "creationDate": now.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                "ts": int(time.time() * 1000),
                "publishState": "published",
            }
        },
    }

    if check_only:
        print(f"CloudronVersions.json would be valid for version {version}")
        return

    FEED.write_text(json.dumps(feed, indent=2) + "\n")
    print(f"wrote {FEED.name} for version {version}")
    print(f"  image  : {manifest['dockerImage']}")
    print(f"  inlined: {', '.join(INLINE_FIELDS)}")


if __name__ == "__main__":
    main()
