#!/usr/bin/env python3
"""Exercise the independent IPA verifier with synthetic bundles, not a real iOS build."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("personal_package", SCRIPTS / "package-personal.py")
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)
REVISION = "a" * 40
SOURCE = "067384b7e5b3c47a7eeca217895be71493396518"


class PersonalIPAVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nanomuse-ipa-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        app = self.root / "Minis.app"
        app.mkdir()
        info = {
            "CFBundleIdentifier": "io.github.nanomuse.app",
            "CFBundleExecutable": "Minis",
            "NanoMusePersonalBuild": "YES",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "DTPlatformName": "iphoneos",
        }
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        # Minimal synthetic Mach-O header and LC_BUILD_VERSION, never an executable app.
        header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        command = struct.pack("<6I", 0x32, 24, 2, 0x100000, 0x1A0000, 0)
        (app / "Minis").write_bytes(header + command)
        self.ipa = self.root / "out" / "personal.ipa"
        PACKAGE.package(app, self.ipa, "io.github.nanomuse.personal", REVISION, SOURCE)

    def verify(self):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "verify-personal-ipa.py"),
                str(self.ipa),
                "--bundle-id",
                "io.github.nanomuse.personal",
                "--revision",
                REVISION,
                "--source-revision",
                SOURCE,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def rewrite(self, changes):
        with zipfile.ZipFile(self.ipa) as archive:
            files = {
                name: archive.read(name) for name in archive.namelist() if not name.endswith("/")
            }
        files.update(changes)
        with zipfile.ZipFile(self.ipa, "w") as archive:
            for name, content in files.items():
                archive.writestr(name, content)
        digest = hashlib.sha256(self.ipa.read_bytes()).hexdigest()
        manifest = json.loads(self.ipa.with_suffix(".json").read_text())
        manifest["sha256"] = digest
        self.ipa.with_suffix(".json").write_text(json.dumps(manifest))
        self.ipa.with_suffix(".sha256").write_text(f"{digest}  {self.ipa.name}\n")

    def test_packaged_personal_device_fixture_passes(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("arm64", result.stdout)

    def test_digest_mismatch_is_rejected(self):
        with self.ipa.open("ab") as stream:
            stream.write(b"changed after manifest")
        self.assertNotEqual(self.verify().returncode, 0)

    def test_extension_profile_signature_and_path_escape_are_rejected(self):
        clean_ipa = self.ipa.read_bytes()
        for name in [
            "Payload/Minis.app/PlugIns/Widget.appex/file",
            "Payload/Minis.app/embedded.mobileprovision",
            "Payload/Minis.app/_CodeSignature/CodeResources",
            "../outside",
        ]:
            with self.subTest(name=name):
                self.ipa.write_bytes(clean_ipa)
                self.rewrite({name: b"synthetic forbidden resource"})
                self.assertNotEqual(self.verify().returncode, 0)

    def test_wrong_platform_is_rejected(self):
        macho = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        macho += struct.pack("<6I", 0x32, 24, 7, 0x100000, 0x1A0000, 0)
        self.rewrite({"Payload/Minis.app/Minis": macho})
        self.assertNotEqual(self.verify().returncode, 0)

    def test_wrong_identity_is_rejected(self):
        with zipfile.ZipFile(self.ipa) as archive:
            info = plistlib.loads(archive.read("Payload/Minis.app/Info.plist"))
        info["CFBundleDisplayName"] = "not nano"
        self.rewrite({"Payload/Minis.app/Info.plist": plistlib.dumps(info)})
        self.assertNotEqual(self.verify().returncode, 0)

    def test_wrong_source_revision_is_rejected(self):
        manifest = json.loads(self.ipa.with_suffix(".json").read_text())
        manifest["sourceRevision"] = "b" * 40
        self.ipa.with_suffix(".json").write_text(json.dumps(manifest))
        self.assertNotEqual(self.verify().returncode, 0)


if __name__ == "__main__":
    unittest.main()
