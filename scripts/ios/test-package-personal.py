#!/usr/bin/env python3
"""Exercise packaging boundaries without Xcode or signing credentials."""

import importlib.util
import json
import os
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "personal_package", Path(__file__).with_name("package-personal.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PersonalPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Minis.app"
        self.app.mkdir()
        self.info = {
            "CFBundleIdentifier": "io.github.nanomuse.app",
            "CFBundleExecutable": "Minis",
            "NanoMusePersonalBuild": "YES",
            "CFBundleURLTypes": [
                {"CFBundleURLName": "nanoMuse Share", "CFBundleURLSchemes": ["nanomuse"]},
                {"CFBundleURLName": "MCP OAuth Callback", "CFBundleURLSchemes": ["nanomuse-mcp"]},
                {
                    "CFBundleURLName": "Claude OAuth Callback",
                    "CFBundleURLSchemes": ["io.github.nanomuse.app"],
                },
            ],
        }
        self.save_info()
        executable = self.app / "Minis"
        executable.write_bytes(b"test executable")
        executable.chmod(0o755)
        self.output = self.root / "output" / "personal.ipa"

    def save_info(self):
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream)

    def test_separate_identity_no_extensions_source_unchanged(self):
        extension = self.app / "PlugIns" / "Files.appex"
        extension.mkdir(parents=True)
        (extension / "embedded.mobileprovision").write_bytes(b"profile")
        signature = self.app / "Frameworks" / "Library.framework" / "_CodeSignature"
        signature.mkdir(parents=True)
        (signature / "CodeResources").write_bytes(b"signature")
        localized = self.app / "zh-Hans.lproj" / "InfoPlist.strings"
        localized.parent.mkdir()
        with localized.open("wb") as stream:
            plistlib.dump({"CFBundleDisplayName": "nanoMuse", "Other": "keep"}, stream)
        manifest = module.package(self.app, self.output, "io.github.nanomuse.personal", "revision")
        with zipfile.ZipFile(self.output) as archive:
            names = archive.namelist()
            self.assertFalse(any(".appex" in name or "_CodeSignature" in name for name in names))
            info = plistlib.loads(archive.read("Payload/Minis.app/Info.plist"))
            self.assertEqual(info["CFBundleIdentifier"], "io.github.nanomuse.personal")
            self.assertEqual(info["CFBundleDisplayName"], "nanoMuse Personal")
            schemes = [
                scheme
                for entry in info["CFBundleURLTypes"]
                for scheme in entry["CFBundleURLSchemes"]
            ]
            self.assertEqual(schemes, ["nanomuse-personal", "nanomuse-personal-mcp"])
            strings = plistlib.loads(
                archive.read("Payload/Minis.app/zh-Hans.lproj/InfoPlist.strings")
            )
            self.assertEqual(strings, {"CFBundleDisplayName": "nanoMuse Personal", "Other": "keep"})
            if os.name != "nt":
                self.assertTrue(
                    archive.getinfo("Payload/Minis.app/Minis").external_attr >> 16 & 0o111
                )
        self.assertTrue(extension.exists())
        self.assertTrue(signature.exists())
        with (self.app / "Info.plist").open("rb") as stream:
            self.assertEqual(plistlib.load(stream), self.info)
        self.assertEqual(json.loads(self.output.with_suffix(".json").read_text()), manifest)

    def test_official_binary_and_original_identity_are_rejected(self):
        self.info.pop("NanoMusePersonalBuild")
        self.save_info()
        with self.assertRaisesRegex(ValueError, "personal-build flag"):
            module.package(self.app, self.output, "io.github.nanomuse.personal", "revision")
        for flag in ("", "$(NANOMUSE_PERSONAL_BUILD)", "NO", False):
            with self.subTest(flag=flag):
                self.info["NanoMusePersonalBuild"] = flag
                self.save_info()
                with self.assertRaisesRegex(ValueError, "personal-build flag"):
                    module.package(self.app, self.output, "io.github.nanomuse.personal", "revision")
        self.info["NanoMusePersonalBuild"] = True
        self.save_info()
        with self.assertRaisesRegex(ValueError, "own bundle"):
            module.package(self.app, self.output, "io.github.nanomuse.app", "revision")
        self.assertFalse(self.output.exists())

    def test_invalid_identifier_or_missing_executable_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "bundle identifier"):
            module.package(self.app, self.output, "bad id", "revision")
        (self.app / "Minis").unlink()
        with self.assertRaisesRegex(ValueError, "executable is missing"):
            module.package(self.app, self.output, "io.github.nanomuse.personal", "revision")


if __name__ == "__main__":
    unittest.main()
