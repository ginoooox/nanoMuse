#!/usr/bin/env python3
"""Fence the small personal overlay against the fixed official device-chat source."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = "067384b7e5b3c47a7eeca217895be71493396518"
BASE = "154f076fdaed76f1ef5646895a1954dd74d237f9"
# Use Windows' real Git, not a bundled helper-selector that can block on auth.
SYSTEM_GIT = Path("C:/Program Files/Git/cmd/git.exe")
GIT = os.environ.get("GIT_EXECUTABLE") or (
    str(SYSTEM_GIT) if SYSTEM_GIT.exists() else shutil.which("git")
)
if not GIT:
    raise RuntimeError("Git is required for the integration check")
IOS = "android/src/ios/"


def git(*args: str) -> bytes:
    return subprocess.check_output([GIT, "-C", str(ROOT), *args])


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def normalized(data: bytes) -> bytes:
    return data.replace(b"\r\n", b"\n")


def main() -> None:
    git("merge-base", "--is-ancestor", UPSTREAM, "HEAD")
    # Every new upstream iOS change is byte-preserved, except the additive
    # localization merge and the two existing personal MinisApp integration spots.
    official_changed = (
        git("diff", "--name-only", BASE, UPSTREAM, "--", IOS, "tests/ios").decode().splitlines()
    )
    protected = [
        path
        for path in official_changed
        if path not in {IOS + "Localizable.xcstrings", IOS + "MinisApp.swift"}
    ]
    for path in protected:
        require(
            normalized((ROOT / path).read_bytes()) == normalized(git("show", f"{UPSTREAM}:{path}")),
            f"Official source changed: {path}",
        )
    for path in [IOS + "NanoMuse/NanoMuseDeviceReply.swift", "android/deps"]:
        git("diff", "--exit-code", UPSTREAM, "--", path)
    strings_path = IOS + "Localizable.xcstrings"
    official = json.loads(git("show", f"{UPSTREAM}:{strings_path}"))
    current = json.loads((ROOT / strings_path).read_text(encoding="utf-8"))
    for key, value in official["strings"].items():
        require(current["strings"].get(key) == value, f"Official localization changed: {key}")
    custom_keys = set(current["strings"]) - set(official["strings"])
    require(len(custom_keys) == 7, "Expected exactly seven personal header localization keys")
    locales = set(current["strings"]["Header Name"]["localizations"])
    for key in custom_keys:
        require(
            set(current["strings"][key]["localizations"]) == locales,
            f"Missing header locale: {key}",
        )
    config = (ROOT / "scripts/ios/Personal.xcconfig").read_text(encoding="utf-8")
    for setting in [
        "CODE_SIGNING_ALLOWED = NO",
        "CODE_SIGNING_REQUIRED = NO",
        "CODE_SIGN_ENTITLEMENTS =",
        "NANOMUSE_PERSONAL_BUILD = YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) NANOMUSE_PERSONAL",
    ]:
        require(setting in config, f"Personal build setting missing: {setting}")
    workflow = (ROOT / ".github/workflows/ios-personal.yml").read_text(encoding="utf-8")
    for token in [
        f"SOURCE_REVISION: {UPSTREAM}",
        "runs-on: macos-26-intel",
        "-configuration Release",
        "generic/platform=iOS",
        "CrashEvidenceChecks.swift",
        "AnthropicPromptChecks.swift",
        "DeviceConversationsChecks.swift",
        "ProviderCustomHeadersTests.swift",
        "prepare-rootfs-host.sh",
        "verify-personal-ipa.py",
        "test-verify-personal-ipa.py",
    ]:
        require(token in workflow, f"Workflow requirement missing: {token}")
    require(
        "restore-keys:" not in workflow and "|| true" not in workflow,
        "Unsafe cache or build fallback",
    )
    print(
        json.dumps(
            {
                "upstream": UPSTREAM,
                "protected_official_files": len(protected),
                "official_localizations": len(official["strings"]),
                "personal_localizations": len(custom_keys),
                "header_locales": sorted(locales),
                "result": "passed",
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
