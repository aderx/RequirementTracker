from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import zs_start_manager as manager
from test_zs_start import zs_start


class ManagedLauncherTest(unittest.TestCase):
    def test_zs_start_no_longer_exposes_service_management(self):
        output = io.StringIO()
        with patch("sys.stdout", output):
            zs_start.print_help()
        self.assertNotIn("services", output.getvalue())
        self.assertNotIn("clean", zs_start.MENU_COMMANDS)
        for command in ("services", "clean"):
            with patch("sys.argv", ["zs-start", command]), patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()), patch.object(zs_start, "resolve_startup_repo_context") as resolve:
                self.assertNotEqual(zs_start.main(), 0)
                resolve.assert_not_called()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zs-start-managed-")
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name).resolve() / "user with spaces"
        self.home.mkdir()
        self.home_patch = patch.object(Path, "home", return_value=self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        self.which_patch = patch.object(manager.shutil, "which", return_value=None)
        self.which_patch.start()
        self.addCleanup(self.which_patch.stop)
        self.env_patch = patch.dict(os.environ, {zs_start.PROJECT_ROOT_ENV_KEY: ""})
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        self.primary = self.create_project("zstack-ui-next-dev")
        self.other = self.create_project("zstack-ui-next")
        self.command = self.home / ".homebrew/bin/zs-start"
        self.command.parent.mkdir(parents=True)
        self.legacy = f'#!/bin/sh\nexec /usr/bin/python3 "{self.primary}/.vscode/bin/zs-start.py" "$@"\n'.encode()
        self.command.write_bytes(self.legacy)
        self.command.chmod(0o755)

    def git(self, root, *arguments):
        return subprocess.run(
            ["/usr/bin/git", "-C", str(root), *arguments],
            check=True, capture_output=True, text=True,
        )

    def create_project(self, name):
        root = self.home / "workspace" / name
        (root / "scripts").mkdir(parents=True)
        (root / "scripts/start.ts").write_text("// fixture\n")
        (root / "package.json").write_text("{}\n")
        self.git(root, "init", "-q")
        self.git(root, "add", "scripts/start.ts", "package.json")
        self.git(root, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")
        return root.resolve()

    def test_read_only_status_preserves_legacy_default_and_discovers_workspace(self):
        result = manager.status()
        self.assertEqual(result["projectPath"], str(self.primary))
        self.assertEqual(result["registrationState"], "legacy")
        self.assertEqual({p["path"] for p in result["projects"]}, {str(self.primary), str(self.other)})
        self.assertFalse(manager.config_path().exists())
        self.assertEqual(self.command.read_bytes(), self.legacy)

    def test_switch_by_name_is_persisted_and_drives_startup_outside_repository(self):
        with patch.object(zs_start, "remember_repo_context") as remember, patch("sys.stdout", io.StringIO()):
            self.assertEqual(zs_start.switch_project(["zstack-ui-next"]), 0)
        self.assertEqual(manager.status()["projectPath"], str(self.other))
        context = zs_start.resolve_repo_context(cwd=self.home)
        self.assertEqual(context.primary_root, self.other)
        self.assertEqual(context.root, self.other)
        self.assertEqual(remember.call_args.args[0].root, self.other)

    def test_persisted_switch_is_read_by_cli_and_current_is_read_only(self):
        manager.select_project(str(self.other))
        before = manager.config_path().read_bytes()
        output = io.StringIO()
        with patch("sys.stdout", output):
            self.assertEqual(zs_start.switch_project(["--current"]), 0)
        self.assertEqual(output.getvalue().strip(), str(self.other))
        self.assertEqual(manager.config_path().read_bytes(), before)

    def test_switch_accepts_worktree_path_and_resolves_its_primary_repository(self):
        worktree = self.home / "feature with spaces"
        self.git(self.other, "worktree", "add", "-qb", "feature", str(worktree))
        manager.select_project(str(worktree))
        self.assertEqual(manager.selected_project(), self.other)
        context = zs_start.resolve_repo_context(requested_worktree=worktree)
        self.assertEqual(context.root, worktree)
        self.assertEqual(context.primary_root, self.other)
        with self.assertRaisesRegex(zs_start.ZsStartError, "不是当前项目"):
            zs_start.resolve_repo_context(requested_worktree=self.primary)

    def test_failed_switch_preserves_configuration(self):
        manager.select_project(str(self.primary))
        before = manager.config_path().read_bytes()
        with self.assertRaises(manager.ManagerError):
            manager.select_project(str(self.home / "missing"))
        self.assertEqual(manager.config_path().read_bytes(), before)

    def test_missing_selected_repository_does_not_silently_fall_back(self):
        manager.select_project(str(self.other))
        shutil.rmtree(self.other)
        with self.assertRaises(manager.ManagerError):
            manager.selected_project()
        result = manager.status()
        self.assertEqual(result["projectPath"], str(self.other))
        self.assertIsNotNone(result["projectError"])
        manager.select_project(str(self.primary))
        self.assertIsNone(manager.status()["projectError"])

    def test_legacy_install_repair_and_uninstall_restores_exact_original_command(self):
        manager.install_command()
        self.assertEqual(manager.status()["registrationState"], "installed")
        self.assertIn(b"-B", self.command.read_bytes())
        self.assertTrue(os.access(self.command, os.X_OK))
        self.assertEqual(manager.selected_project(), self.primary)
        backup = manager.data_directory() / "zs-start-command-backup.json"
        before = backup.read_bytes()
        manager.install_command()
        self.assertEqual(backup.read_bytes(), before)
        manager.uninstall_command()
        self.assertEqual(self.command.read_bytes(), self.legacy)
        self.assertEqual(self.command.stat().st_mode & 0o777, 0o755)
        self.assertFalse(backup.exists())
        self.assertEqual(manager.selected_project(), self.primary)

    def test_new_install_and_uninstall_keeps_project_configuration(self):
        self.command.unlink()
        manager.select_project(str(self.other))
        manager.install_command()
        installed = manager.command_path()
        self.assertTrue(installed.is_file())
        manager.uninstall_command()
        self.assertFalse(installed.exists())
        self.assertEqual(manager.selected_project(), self.other)

    def test_registration_without_selected_project_allows_subsequent_cli_selection(self):
        self.command.unlink()
        manager.install_command()
        installed = manager.command_path()
        self.assertTrue(installed.is_file())
        self.assertNotIn("primaryRoot", manager.read_config())
        with self.assertRaisesRegex(manager.ManagerError, "zs-start project"):
            manager.selected_project()
        with patch.object(zs_start, "remember_repo_context"), patch("sys.stdout", io.StringIO()):
            self.assertEqual(zs_start.switch_project(["zstack-ui-next"]), 0)
        self.assertEqual(manager.selected_project(), self.other)
        manager.uninstall_command()
        self.assertFalse(installed.exists())
        self.assertEqual(manager.selected_project(), self.other)

    def test_repair_keeps_missing_project_and_does_not_require_git_discovery(self):
        manager.install_command()
        configuration = manager.read_config()
        configuration["primaryRoot"] = str(self.home / "missing-project")
        manager.write_json(manager.config_path(), configuration)
        self.command.write_bytes(b"#!/bin/sh\n" + manager.MANAGED_MARKER.encode() + b"\n# old app\n")
        with patch.object(manager, "project_root", side_effect=AssertionError("unexpected Git lookup")), patch.object(manager, "discover_projects", side_effect=AssertionError("unexpected discovery")):
            manager.install_command()
            output = io.StringIO()
            with patch.object(sys, "argv", ["zs_start_manager.py", "registration-status"]), patch("sys.stdout", output):
                self.assertEqual(manager.main(), 0)
            self.assertEqual(json.loads(output.getvalue())["registrationState"], "installed")
        self.assertEqual(manager.read_config(), configuration)

    def test_corrupt_configuration_prevents_registration_without_overwriting_command(self):
        manager.config_path().parent.mkdir(parents=True)
        manager.config_path().write_text("invalid json")
        with self.assertRaises(manager.ManagerError):
            manager.install_command()
        self.assertEqual(self.command.read_bytes(), self.legacy)
        self.assertEqual(manager.config_path().read_text(), "invalid json")

    def test_unknown_command_and_symlink_are_never_overwritten(self):
        self.command.write_bytes(b"#!/bin/sh\necho other-command\n")
        before = self.command.read_bytes()
        with self.assertRaises(manager.ManagerError):
            manager.install_command()
        self.assertEqual(self.command.read_bytes(), before)
        target = self.command.with_name("real-command")
        self.command.rename(target)
        self.command.symlink_to(target)
        with self.assertRaises(manager.ManagerError):
            manager.install_command()
        self.assertEqual(target.read_bytes(), before)

    def test_install_retry_after_command_write_failure_reuses_original_backup(self):
        atomic_write = manager.atomic_write
        def fail_command(path, content, mode=0o600):
            if path == self.command:
                raise PermissionError("fixture")
            atomic_write(path, content, mode)
        with patch.object(manager, "atomic_write", side_effect=fail_command):
            with self.assertRaises(PermissionError):
                manager.install_command()
        self.assertEqual(self.command.read_bytes(), self.legacy)
        manager.install_command()
        manager.uninstall_command()
        self.assertEqual(self.command.read_bytes(), self.legacy)

    def test_signed_bundle_launcher_quotes_paths_and_generates_no_python_cache(self):
        bundle = self.home / "需求记录.app/Contents/Resources/ZsStart"
        bundle.mkdir(parents=True)
        script = bundle / "zs-start.py"
        script.write_text("import helper\nimport sys\nprint(sys.argv[1])\n")
        (bundle / "helper.py").write_text("value = 1\n")
        with patch.object(manager, "TOOL_DIRECTORY", bundle):
            manager.install_command()
        result = subprocess.run([str(self.command), "argument with spaces"], check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout.strip(), "argument with spaces")
        self.assertFalse((bundle / "__pycache__").exists())

    def test_frontend_subprocess_keeps_project_if_another_terminal_switches_default(self):
        manager.select_project(str(self.other))
        with patch.dict(os.environ, {zs_start.PROJECT_ROOT_ENV_KEY: str(self.primary)}):
            context = zs_start.resolve_repo_context(requested_worktree=self.primary)
        self.assertEqual(context.primary_root, self.primary)
        self.assertEqual(manager.selected_project(), self.other)

    def test_project_menu_escape_does_not_write_and_enter_switches(self):
        with patch("sys.stdin.isatty", return_value=True), patch("sys.stdout", io.StringIO()), patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(zs_start.termios, "tcsetattr"), patch.object(zs_start.tty, "setcbreak"), patch.object(zs_start, "clear_screen"), patch.object(zs_start, "read_key", return_value="escape"):
            self.assertEqual(zs_start.switch_project([]), 0)
        self.assertFalse(manager.config_path().exists())
        with patch("sys.stdin.isatty", return_value=True), patch("sys.stdout", io.StringIO()), patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(zs_start.termios, "tcsetattr"), patch.object(zs_start.tty, "setcbreak"), patch.object(zs_start, "clear_screen"), patch.object(zs_start, "read_key", side_effect=["up", "enter"]), patch.object(zs_start, "remember_repo_context"):
            self.assertEqual(zs_start.switch_project([]), 0)
        self.assertEqual(manager.selected_project(), self.other)


if __name__ == "__main__":
    unittest.main()
