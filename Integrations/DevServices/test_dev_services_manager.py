from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import dev_services_manager as manager


class RegistrationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dev-services-registration-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve() / "user with spaces"
        (self.home / ".homebrew/bin").mkdir(parents=True)
        home_patch = patch.object(Path, "home", return_value=self.home)
        home_patch.start()
        self.addCleanup(home_patch.stop)
        which_patch = patch.object(manager.shutil, "which", return_value=None)
        which_patch.start()
        self.addCleanup(which_patch.stop)
        self.command = self.home / ".homebrew/bin/dev-services"

    def test_status_is_read_only_and_does_not_need_zstack_configuration(self):
        result = manager.status()
        self.assertEqual(result["registrationState"], "missing")
        self.assertEqual(result["commandPath"], str(self.command))
        self.assertFalse(manager.data_directory().exists())

    def test_install_repair_uninstall_preserves_zs_start_and_other_data(self):
        zs_command = self.command.with_name("zs-start")
        zs_command.write_bytes(b"original ZStack command")
        zs_config = manager.data_directory().parent / "zs-start.json"
        zs_config.parent.mkdir(parents=True)
        zs_config.write_bytes(b"invalid ZStack config must not affect dev-services")
        manager.install_command()
        self.assertEqual(manager.status()["registrationState"], "installed")
        self.assertTrue(os.access(self.command, os.X_OK))
        self.command.write_bytes((manager.MANAGED_MARKER + "\nold app\n").encode())
        self.assertEqual(manager.status()["registrationState"], "repair")
        manager.install_command()
        self.assertEqual(self.command.read_bytes(), manager.launcher_content())
        manager.uninstall_command()
        self.assertFalse(self.command.exists())
        self.assertEqual(zs_command.read_bytes(), b"original ZStack command")
        self.assertEqual(zs_config.read_bytes(), b"invalid ZStack config must not affect dev-services")

    def test_unknown_command_or_symlink_is_never_replaced_or_removed(self):
        self.command.write_bytes(b"#!/bin/sh\necho another tool\n")
        for operation in (manager.install_command, manager.uninstall_command):
            with self.assertRaises(manager.ManagerError):
                operation()
        original = self.command.read_bytes()
        target = self.command.with_name("another-tool")
        self.command.rename(target)
        self.command.symlink_to(target)
        for operation in (manager.install_command, manager.uninstall_command):
            with self.assertRaises(manager.ManagerError):
                operation()
        self.assertEqual(target.read_bytes(), original)

    def test_corrupt_configuration_and_foreign_paths_are_not_overwritten(self):
        manager.config_path().parent.mkdir(parents=True)
        manager.config_path().write_text("invalid json")
        with self.assertRaises(manager.ManagerError):
            manager.install_command()
        self.assertEqual(manager.config_path().read_text(), "invalid json")
        for path in ("/usr/local/bin/dev-services", str(self.command.with_name("zs-start"))):
            manager.config_path().write_text(json.dumps({"commandPath": path}))
            with self.assertRaises(manager.ManagerError):
                manager.install_command()
        self.assertFalse(self.command.exists())

    def test_packaged_command_runs_with_only_its_own_resources_and_no_python_cache(self):
        bundle = self.home / "需求记录.app/Contents/Resources/DevServices"
        bundle.mkdir(parents=True)
        for name in ("dev_services.py", "dev_services_manager.py"):
            shutil.copyfile(Path(__file__).with_name(name), bundle / name)
        with patch.object(manager, "TOOL_DIRECTORY", bundle):
            manager.install_command()
        result = subprocess.run([str(self.command), "--help"], capture_output=True, text=True, check=True, cwd=self.home,
                                env={key: value for key, value in os.environ.items() if key != "PYTHONPATH"})
        self.assertIn("dev-services clean", result.stdout)
        self.assertNotIn("zs-start", result.stdout)
        self.assertFalse((bundle / "__pycache__").exists())


if __name__ == "__main__":
    unittest.main()
