#!/usr/bin/env python3
"""Provas de segregação dos uploads privados; nenhum serviço remoto é chamado."""

import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

import prepare_channels as prep


class PrepareChannelsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cura-prepare-channels-")
        self.root = Path(self.temp.name)
        self.commit = "a" * 40

    def tearDown(self):
        self.temp.cleanup()

    def package(self, channel, version="1.1.0", overrides=None):
        files = {
            "cura_ferramentas.rb": f"VERSION = '{version}'\n",
            prep.METADATA: json.dumps({"schema": 1, "product": prep.PRODUCT, "channel": channel}),
            "cura_ferramentas/core/shell.html": f"CURA_UI_VERSION = '{version}';",
            "cura_ferramentas/core/registry.rb": "# fixture aberta; não representa assinatura\n",
            "cura_ferramentas/core/access_policy.rb": "FREE_EXPIRES_AT = 1814324400\n",
        }
        if channel == "biblioteca":
            files[prep.UPDATER] = "# updater somente Biblioteca\n"
        files.update(overrides or {})
        path = self.root / (channel + ".rbz")
        with zipfile.ZipFile(path, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        return path

    def prepare(self, library, warehouse, destination=None):
        return prep.prepare(library, warehouse, self.commit, destination or self.root / "private")

    def test_preserves_bytes_and_never_claims_publication(self):
        library, warehouse = self.package("biblioteca"), self.package("warehouse")
        plan = self.prepare(library, warehouse)
        for channel, source in (("biblioteca", library), ("warehouse", warehouse)):
            entry = plan["packages"][channel]
            actual = self.root / "private" / entry["file"]
            self.assertEqual(source.read_bytes(), actual.read_bytes())
            self.assertEqual(hashlib.sha256(actual.read_bytes()).hexdigest(), entry["sha256"])
            self.assertFalse(entry["public_asset_allowed"])
        self.assertEqual("prepared", plan["github"]["state"])
        self.assertEqual("prepared", plan["warehouse"]["state"])
        self.assertIsNone(plan["warehouse"]["published_url"])
        self.assertFalse(plan["complete"])
        self.assertEqual(plan, json.loads((self.root / "private/release-plan.json").read_text()))

    def test_rejects_wrong_channel_and_own_warehouse_updater(self):
        library = self.package("biblioteca")
        warehouse = self.package("warehouse", overrides={prep.UPDATER: "# forbidden"})
        with self.assertRaisesRegex(ValueError, "updater próprio"):
            self.prepare(library, warehouse)
        with self.assertRaisesRegex(ValueError, "canal divergentes"):
            self.prepare(library, library)

    def test_rejects_version_ui_and_motor_differences(self):
        library = self.package("biblioteca")
        for overrides, version in [({}, "1.2.0"),
                                   ({"cura_ferramentas/core/shell.html": "CURA_UI_VERSION = '0.0.0';"}, "1.1.0"),
                                   ({"cura_ferramentas/core/access_policy.rb": "FREE_EXPIRES_AT = 1\n"}, "1.1.0")]:
            with self.subTest(overrides=overrides, version=version):
                with self.assertRaises(ValueError):
                    self.prepare(library, self.package("warehouse", version, overrides))
        self.assertFalse((self.root / "private").exists())

    def test_refuses_encrypted_upload_and_unsafe_zip(self):
        library = self.package("biblioteca")
        for name in ["cura_ferramentas/core/logic.rbe", "../source.rb", "cura_ferramentas.rb/extra.rb"]:
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    self.prepare(library, self.package("warehouse", overrides={name: "fixture"}))

    def test_refuses_existing_output_and_public_repo_destination(self):
        library, warehouse = self.package("biblioteca"), self.package("warehouse")
        existing = self.root / "keep"
        existing.mkdir()
        (existing / "proof.json").write_text("preserved")
        with self.assertRaises(FileExistsError):
            self.prepare(library, warehouse, existing)
        self.assertEqual("preserved", (existing / "proof.json").read_text())
        with self.assertRaisesRegex(ValueError, "fora do repositório público"):
            self.prepare(library, warehouse, prep.REPO / "payload/warehouse-upload")


if __name__ == "__main__":
    unittest.main()
