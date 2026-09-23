#!/usr/bin/env python3
"""Validate release identity and render a separate, fail-closed 0.1.17 harness."""

import json
import os
from pathlib import Path
import re
import shutil
import sys


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: prepare-pinned-inputs.py OUTPUT_HARNESS IDENTITY_JSON")

    source = Path(__file__).resolve().parent
    event = os.environ.get("GITHUB_EVENT_NAME", "workflow_dispatch")
    if event == "push":
        candidate = json.loads((source / "candidate.json").read_text(encoding="utf-8"))
        if set(candidate) != {"version", "assetId", "sha256", "bytes"} or candidate["version"] != "0.1.17":
            raise SystemExit("candidate.json must pin version 0.1.17 and the three artifact identity fields.")
        if any(type(candidate[key]) not in (str, int) for key in ("assetId", "sha256", "bytes")):
            raise SystemExit("candidate.json identity fields must be strings or integers.")
        asset_id, sha256, byte_count = (str(candidate[key]) for key in ("assetId", "sha256", "bytes"))
    elif event == "workflow_dispatch":
        asset_id = os.environ.get("INSTALLER_ASSET_ID", "")
        sha256 = os.environ.get("INSTALLER_SHA256", "")
        byte_count = os.environ.get("INSTALLER_BYTES", "")
    else:
        raise SystemExit("Only workflow_dispatch and the pinned candidate push are supported.")
    for name, value in (("INSTALLER_ASSET_ID", asset_id), ("INSTALLER_BYTES", byte_count)):
        if not re.fullmatch(r"[1-9][0-9]{0,18}", value) or int(value) > 2**63 - 1:
            raise SystemExit(f"{name} must be a positive decimal integer within Int64 range.")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
        raise SystemExit("INSTALLER_SHA256 must contain exactly 64 hexadecimal characters.")
    sha256 = sha256.lower()

    destination = Path(sys.argv[1]).resolve()
    identity_path = Path(sys.argv[2]).resolve()
    if destination.exists() or source == destination or source in destination.parents:
        raise SystemExit("OUTPUT_HARNESS must be a new directory outside the source template.")
    if identity_path.exists():
        raise SystemExit("IDENTITY_JSON already exists; use a fresh result path.")

    # Validate every template before creating output. ASCII byte replacement keeps
    # the Windows PowerShell 5.1 guest script's UTF-8 BOM and all other bytes intact.
    rendered = {}
    for name in ("bootstrap.ps1", "Test-Windows10Startup.ps1", "run-windows10-vm.sh"):
        content = (source / name).read_bytes()
        for token, value in ((b"__INSTALLER_SHA256__", sha256), (b"__INSTALLER_BYTES__", byte_count)):
            if content.count(token) != 1:
                raise SystemExit(f"Unexpected installer identity placeholder count in {name}.")
            content = content.replace(token, value.encode("ascii"))
        if b"__INSTALLER_" in content:
            raise SystemExit(f"Unresolved installer identity in {name}.")
        rendered[name] = content

    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for name, content in rendered.items():
        (destination / name).write_bytes(content)
    identity_path.parent.mkdir(parents=True, exist_ok=True)
    identity = {"version": "0.1.17", "assetId": int(asset_id), "sha256": sha256, "bytes": int(byte_count)}
    identity_path.write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")
    if github_env := os.environ.get("GITHUB_ENV"):
        # Validation above excludes line breaks and shell metacharacters. Subsequent
        # steps consume only these normalized values, including for push events.
        with open(github_env, "a", encoding="utf-8") as output:
            output.write(f"INSTALLER_ASSET_ID={asset_id}\nINSTALLER_SHA256={sha256}\nINSTALLER_BYTES={byte_count}\n")
    print(json.dumps(identity))


if __name__ == "__main__":
    main()
