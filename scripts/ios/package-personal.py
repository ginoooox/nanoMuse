#!/usr/bin/env python3
"""Package a NANOMUSE_PERSONAL device build for local signing, without credentials."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import tempfile
import zipfile
from pathlib import Path


def package(
    app: Path, output: Path, bundle_id: str, revision: str, source_revision: str = ""
) -> dict[str, str]:
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise ValueError("Use a reverse-DNS bundle identifier without spaces or wildcards")
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("NanoMusePersonalBuild") not in (True, "YES", "true", "1"):
        raise ValueError("Refusing to package an app without the personal-build flag")
    if bundle_id == info["CFBundleIdentifier"]:
        raise ValueError("The personal app must have its own bundle identifier")
    executable = info["CFBundleExecutable"]
    if Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("The built app executable is missing")
    if output.exists():
        raise FileExistsError(output)
    output.parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="nanomuse-personal-", dir=output.parent) as temp:
        stage = Path(temp)
        target = stage / "Payload" / app.name
        shutil.copytree(app, target, symlinks=True)
        for name in ("PlugIns", "Watch", "AppClips"):
            path = target / name
            if path.is_symlink():
                path.unlink()
            elif path.exists():
                shutil.rmtree(path)
        for root, dirs, files in os.walk(target, followlinks=False):
            if "_CodeSignature" in dirs:
                signature = Path(root) / "_CodeSignature"
                if signature.is_symlink():
                    signature.unlink()
                else:
                    shutil.rmtree(signature)
                dirs.remove("_CodeSignature")
            if "embedded.mobileprovision" in files:
                (Path(root) / "embedded.mobileprovision").unlink()

        info["CFBundleIdentifier"] = bundle_id
        info["CFBundleDisplayName"] = "nanoMuse Personal"
        info["CFBundleName"] = "nanoMuse Personal"
        for entry in info.get("CFBundleURLTypes", []):
            replacements = {
                "nanomuse": "nanomuse-personal",
                "nanomuse-mcp": "nanomuse-personal-mcp",
            }
            entry["CFBundleURLSchemes"] = [
                replacements.get(scheme, scheme) for scheme in entry.get("CFBundleURLSchemes", [])
            ]
        # Leave the official app's bundled callback scheme registered to it.
        info["CFBundleURLTypes"] = [
            entry
            for entry in info.get("CFBundleURLTypes", [])
            if entry.get("CFBundleURLName") != "Claude OAuth Callback"
        ]
        with (target / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream, fmt=plistlib.FMT_BINARY)
        for strings in target.glob("*.lproj/InfoPlist.strings"):
            with strings.open("rb") as stream:
                localized = plistlib.load(stream)
            for key in ("CFBundleDisplayName", "CFBundleName"):
                if key in localized:
                    localized[key] = "nanoMuse Personal"
            with strings.open("wb") as stream:
                plistlib.dump(localized, stream, fmt=plistlib.FMT_BINARY)

        if list(target.rglob("*.appex")) or list(target.rglob("embedded.mobileprovision")):
            raise ValueError("An extension or provisioning profile remains in the personal app")
        # Keep executable permissions and framework symlinks in the IPA even
        # though the artifact will be downloaded and signed on Windows.
        staged_ipa = stage / "personal.ipa"
        with zipfile.ZipFile(staged_ipa, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted((stage / "Payload").rglob("*")):
                name = path.relative_to(stage).as_posix()
                if path.is_symlink():
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(entry, os.readlink(path))
                else:
                    archive.write(path, name)
        shutil.move(staged_ipa, output)

    with output.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    manifest = {
        "file": output.name,
        "sha256": digest,
        "revision": revision,
        "sourceRevision": source_revision,
        "version": str(info.get("CFBundleShortVersionString", "")),
        "buildNumber": str(info.get("CFBundleVersion", "")),
        "minimumOSVersion": str(info.get("MinimumOSVersion", "")),
        "bundleIdentifier": bundle_id,
        "configuration": "NANOMUSE_PERSONAL",
        "signing": "unsigned; sign locally with your own Apple account",
    }
    output.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    output.with_suffix(".sha256").write_text(f"{digest}  {output.name}\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--bundle-id", default="io.github.nanomuse.personal")
    parser.add_argument("--revision", default="local")
    parser.add_argument("--source-revision", default="")
    args = parser.parse_args()
    print(
        json.dumps(
            package(args.app, args.out, args.bundle_id, args.revision, args.source_revision),
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
