#!/usr/bin/env python3
"""Verify a packaged personal IPA and its provenance without Apple credentials."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path, PurePosixPath


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def verify_macho(data: bytes) -> None:
    require(len(data) >= 32, "Missing Mach-O header")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    require(
        magic == 0xFEEDFACF and cpu == 0x0100000C and kind == 2,
        "Expected a thin arm64 Mach-O executable",
    )
    require(32 + size <= len(data), "Truncated Mach-O load commands")
    offset = 32
    platforms = []
    for _ in range(count):
        require(offset + 8 <= 32 + size, "Truncated Mach-O command")
        command, length = struct.unpack_from("<2I", data, offset)
        require(length >= 8 and offset + length <= 32 + size, "Invalid Mach-O command size")
        if command == 0x32:  # LC_BUILD_VERSION
            require(length >= 24, "Invalid LC_BUILD_VERSION")
            platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
        offset += length
    require(
        offset == 32 + size and platforms == [2],
        "Expected the physical iOS platform, not simulator",
    )


def verify(ipa: Path, bundle_id: str, revision: str, source_revision: str) -> dict[str, str]:
    manifest = json.loads(ipa.with_suffix(".json").read_text(encoding="utf-8"))
    with ipa.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    require(
        ipa.with_suffix(".sha256").read_text(encoding="utf-8").strip() == f"{digest}  {ipa.name}",
        "Checksum sidecar mismatch",
    )
    for key, value in {
        "file": ipa.name,
        "sha256": digest,
        "revision": revision,
        "sourceRevision": source_revision,
        "bundleIdentifier": bundle_id,
        "displayName": "nano",
        "configuration": "NANOMUSE_PERSONAL",
    }.items():
        require(manifest.get(key) == value, f"Manifest mismatch: {key}")
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, "ZIP CRC mismatch")
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate ZIP paths")
        for name in names:
            path = PurePosixPath(name)
            require(
                not path.is_absolute()
                and ".." not in path.parts
                and "\\" not in name
                and bool(path.parts)
                and path.parts[0] == "Payload",
                "Unsafe ZIP path",
            )
            require(
                not any(
                    part.endswith(".appex")
                    or part
                    in {
                        "PlugIns",
                        "Watch",
                        "AppClips",
                        "_CodeSignature",
                        "embedded.mobileprovision",
                    }
                    for part in path.parts
                ),
                "Extension, profile or signature resource remains",
            )
        infos = [
            name
            for name in names
            if len(PurePosixPath(name).parts) == 3 and name.endswith(".app/Info.plist")
        ]
        require(len(infos) == 1, "Expected one main app")
        prefix = infos[0].removesuffix("Info.plist")
        info = plistlib.loads(archive.read(infos[0]))
        require(info.get("CFBundleIdentifier") == bundle_id, "Wrong bundle identifier")
        require(
            info.get("CFBundleDisplayName") == "nano" and info.get("CFBundleName") == "nano",
            "Wrong personal app name",
        )
        require(
            info.get("NanoMusePersonalBuild") in (True, "YES", "true", "1"),
            "Missing personal build flag",
        )
        require(
            info.get("DTPlatformName") == "iphoneos"
            and info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
            "Wrong platform metadata",
        )
        executable = info.get("CFBundleExecutable", "")
        require(
            bool(executable) and PurePosixPath(executable).name == executable,
            "Invalid executable path",
        )
        verify_macho(archive.read(prefix + executable))
        schemes = [
            scheme
            for entry in info.get("CFBundleURLTypes", [])
            for scheme in entry.get("CFBundleURLSchemes", [])
        ]
        require(
            not {"nanomuse", "nanomuse-mcp", "io.github.nanomuse.app"}.intersection(schemes),
            "Official app callback scheme remains",
        )
        for name in names:
            if name.startswith(prefix) and name.endswith(".lproj/InfoPlist.strings"):
                localized = plistlib.loads(archive.read(name))
                require(
                    all(
                        localized.get(key, "nano") == "nano"
                        for key in ("CFBundleName", "CFBundleDisplayName")
                    ),
                    "Localized name mismatch",
                )
    return {
        "file": ipa.name,
        "sha256": digest,
        "bundleIdentifier": bundle_id,
        "architecture": "arm64",
        "platform": "iOS device",
        "displayName": "nano",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--bundle-id", default="io.github.nanomuse.personal")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--source-revision", required=True)
    args = parser.parse_args()
    print(
        json.dumps(verify(args.ipa, args.bundle_id, args.revision, args.source_revision), indent=2)
    )


if __name__ == "__main__":
    main()
