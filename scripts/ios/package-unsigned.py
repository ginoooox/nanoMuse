"""Package an unchanged Release device app and record its exact source revision."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path


def package(app: Path, output: Path, source_revision: str, build_revision: str) -> None:
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = info["CFBundleExecutable"]
    if Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("The built app executable is missing")
    architectures = subprocess.check_output(["lipo", "-archs", str(app / executable)], text=True)
    if "arm64" not in architectures.split():
        raise ValueError("The app must contain an arm64 device executable")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError("The app is not built for an iOS device")
    if info["CFBundleIdentifier"] != "io.github.nanomuse.app":
        raise ValueError("Unexpected app identity")
    if list(app.rglob("embedded.mobileprovision")):
        raise ValueError("An unsigned app must not contain provisioning profiles")

    output.mkdir(parents=True, exist_ok=True)
    filename = (
        f"nanoMuse-{info['CFBundleShortVersionString']}-main-{source_revision[:8]}-unsigned.ipa"
    )
    ipa = output.resolve() / filename
    if ipa.exists():
        raise FileExistsError(ipa)
    with tempfile.TemporaryDirectory(prefix="nanomuse-ipa-") as directory:
        stage = Path(directory)
        target = stage / "Payload" / app.name
        target.parent.mkdir()
        shutil.copytree(app, target, symlinks=True)
        subprocess.run(
            ["ditto", "-c", "-k", "--keepParent", "Payload", str(ipa)], cwd=stage, check=True
        )

    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError("The IPA failed its ZIP integrity check")
        packaged = plistlib.loads(archive.read(f"Payload/{app.name}/Info.plist"))
        if packaged != info:
            raise ValueError("Packaging changed the app Info.plist")
    with ipa.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    manifest = {
        "file": filename,
        "sha256": digest,
        "sourceRepository": "https://github.com/nano-muse/nanoMuse",
        "sourceRevision": source_revision,
        "buildRevision": build_revision,
        "version": info["CFBundleShortVersionString"],
        "buildNumber": info["CFBundleVersion"],
        "bundleIdentifier": info["CFBundleIdentifier"],
        "minimumOSVersion": info.get("MinimumOSVersion"),
        "architectures": architectures.strip(),
        "configuration": "Release",
        "signing": "unsigned; requires local signing before installation",
        "extensions": sorted(path.name for path in app.glob("PlugIns/*.appex")),
    }
    ipa.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    ipa.with_suffix(".sha256").write_text(f"{digest}  {filename}\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--build-revision", required=True)
    args = parser.parse_args()
    package(args.app, args.out, args.source_revision, args.build_revision)
