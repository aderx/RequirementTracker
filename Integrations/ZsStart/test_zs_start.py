from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT_PATH = Path(__file__).with_name("zs-start.py")
SPEC = importlib.util.spec_from_file_location("zs_start", SCRIPT_PATH)
assert SPEC and SPEC.loader
zs_start = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = zs_start
SPEC.loader.exec_module(zs_start)


class TtyStringIO(io.StringIO):
    def isatty(self) -> bool:
        return True


class ZsStartTest(unittest.TestCase):
    def create_cloud_bff(self, root: Path) -> Path:
        cloud_bff_dir = root / zs_start.CLOUD_BFF_RELATIVE_DIR
        cloud_bff_dir.mkdir(parents=True)
        return cloud_bff_dir

    def create_frontend(self, root: Path, dependencies_ready: bool = False) -> Path:
        self.create_cloud_bff(root)
        start_script = root / "scripts/start.ts"
        start_script.parent.mkdir(parents=True, exist_ok=True)
        start_script.touch()
        if dependencies_ready:
            dependency_marker = root / "node_modules/.bin/nx"
            dependency_marker.parent.mkdir(parents=True, exist_ok=True)
            dependency_marker.touch()
        return root

    def create_workspace_package(
        self,
        root: Path,
        relative_path: str,
        name: str,
        *,
        dependencies: dict[str, str] | None = None,
        exports: object | None = None,
        build: bool = False,
    ) -> Path:
        package_dir = root / relative_path
        package_dir.mkdir(parents=True, exist_ok=True)
        payload: dict[str, object] = {"name": name}
        if dependencies:
            payload["dependencies"] = dependencies
        if exports is not None:
            payload["exports"] = exports
        if build:
            payload["scripts"] = {"build": "rslib build"}
        (package_dir / "package.json").write_text(
            json.dumps(payload),
            encoding="utf-8",
        )
        return package_dir

    def create_zns_bff(self, root: Path, dependencies_ready: bool = False) -> Path:
        self.create_cloud_bff(root)
        zns_bff_dir = root / "packages/products/zns/bff"
        zns_bff_dir.mkdir(parents=True, exist_ok=True)
        (zns_bff_dir / ".env.example").write_text(
            "PORT=7300\nZNS_API_BASE_URL=http://localhost:7278\n",
            encoding="utf-8",
        )
        if dependencies_ready:
            nest_cli = zns_bff_dir / "node_modules/.bin/nest"
            nest_cli.parent.mkdir(parents=True, exist_ok=True)
            nest_cli.touch()
        return zns_bff_dir

    def test_resolve_repo_context_uses_current_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = (temp_dir / "main").resolve()
            worktree_root = (temp_dir / "feature").resolve()
            common_dir = primary_root / ".git"
            self.create_cloud_bff(primary_root)
            self.create_cloud_bff(worktree_root)

            def top_level(path: Path) -> Path | None:
                resolved = path.resolve()
                if resolved == primary_root:
                    return primary_root
                if resolved == worktree_root:
                    return worktree_root
                return None

            with patch.object(zs_start, "git_top_level", side_effect=top_level), patch.object(
                zs_start, "git_common_dir", return_value=common_dir
            ), patch.object(zs_start, "git_branch", return_value="xfu-dev/5.5.38/zstac-1"):
                context = zs_start.resolve_repo_context(
                    cwd=worktree_root,
                    primary_hint=primary_root,
                )

            self.assertEqual(context.root, worktree_root)
            self.assertEqual(context.primary_root, primary_root)
            self.assertTrue(context.is_linked_worktree)
            self.assertEqual(context.branch, "xfu-dev/5.5.38/zstac-1")

    def test_resolve_repo_context_falls_back_to_primary_outside_project(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            foreign_root = temp_dir / "foreign"
            primary_common_dir = primary_root / ".git"
            foreign_common_dir = foreign_root / ".git"
            self.create_cloud_bff(primary_root)
            foreign_root.mkdir()

            with patch.object(
                zs_start,
                "git_top_level",
                side_effect=[primary_root, foreign_root],
            ), patch.object(
                zs_start,
                "git_common_dir",
                side_effect=[primary_common_dir, foreign_common_dir],
            ), patch.object(zs_start, "git_branch", return_value="5.5.38"):
                context = zs_start.resolve_repo_context(
                    cwd=foreign_root,
                    primary_hint=primary_root,
                )

            self.assertEqual(context.root, primary_root)
            self.assertFalse(context.is_linked_worktree)

    def test_resolve_repo_context_rejects_requested_foreign_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            foreign_root = temp_dir / "foreign"
            self.create_cloud_bff(primary_root)
            foreign_root.mkdir()

            with patch.object(
                zs_start,
                "git_top_level",
                side_effect=[primary_root, foreign_root],
            ), patch.object(
                zs_start,
                "git_common_dir",
                side_effect=[primary_root / ".git", foreign_root / ".git"],
            ):
                with self.assertRaisesRegex(zs_start.ZsStartError, "不是当前项目的 worktree"):
                    zs_start.resolve_repo_context(
                        requested_worktree=foreign_root,
                        primary_hint=primary_root,
                    )

    def test_parse_worktree_paths_reads_porcelain_zero_terminated_output(self) -> None:
        output = (
            "worktree /workspace/project\0HEAD abc123\0branch refs/heads/main\0\0"
            "worktree /workspace/feature one\0HEAD def456\0"
            "branch refs/heads/feature\0\0"
        )

        paths = zs_start.parse_worktree_paths(output)

        self.assertEqual(
            paths,
            [Path("/workspace/project"), Path("/workspace/feature one")],
        )

    def test_list_repo_contexts_uses_registered_worktrees(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            feature_root = temp_dir / "feature"
            primary_root.mkdir()
            feature_root.mkdir()
            current = zs_start.RepoContext(primary_root, primary_root, "main")
            primary = zs_start.RepoContext(primary_root, primary_root, "main")
            feature = zs_start.RepoContext(feature_root, primary_root, "feature")
            output = (
                f"worktree {primary_root}\0HEAD abc123\0\0"
                f"worktree {feature_root}\0HEAD def456\0\0"
            )

            with patch.object(zs_start, "git_output", return_value=output), patch.object(
                zs_start,
                "resolve_repo_context",
                side_effect=[primary, feature],
            ):
                contexts = zs_start.list_repo_contexts(current)

        self.assertEqual(contexts, [primary, feature])

    def test_terminal_session_key_is_stable_per_tab_and_isolated_between_tabs(self) -> None:
        build_key = getattr(zs_start, "build_terminal_session_key", None)
        self.assertTrue(callable(build_key))
        if not callable(build_key):
            return

        tab_a = build_key(
            {"TERM_SESSION_ID": "tab-a"},
            tty_path="/dev/ttys001",
            session_id=101,
        )
        same_tab = build_key(
            {"TERM_SESSION_ID": "tab-a"},
            tty_path="/dev/ttys001",
            session_id=101,
        )
        tab_b = build_key(
            {"TERM_SESSION_ID": "tab-b"},
            tty_path="/dev/ttys002",
            session_id=102,
        )

        self.assertEqual(tab_a, same_tab)
        self.assertNotEqual(tab_a, tab_b)

    def test_remembered_repo_context_is_scoped_to_terminal_tab(self) -> None:
        remember = getattr(zs_start, "remember_repo_context", None)
        restore = getattr(zs_start, "restore_repo_context", None)
        self.assertTrue(callable(remember))
        self.assertTrue(callable(restore))
        if not callable(remember) or not callable(restore):
            return

        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            feature_root = temp_dir / "feature"
            primary_root.mkdir()
            feature_root.mkdir()
            primary = zs_start.RepoContext(primary_root, primary_root, "main")
            feature = zs_start.RepoContext(feature_root, primary_root, "feature")

            remember(feature, session_key="tab-a", state_dir=temp_dir / "sessions")
            with patch.object(zs_start, "list_repo_contexts", return_value=[primary, feature]):
                same_tab = restore(
                    primary,
                    session_key="tab-a",
                    state_dir=temp_dir / "sessions",
                )
                other_tab = restore(
                    primary,
                    session_key="tab-b",
                    state_dir=temp_dir / "sessions",
                )

        self.assertEqual(same_tab, feature)
        self.assertEqual(other_tab, primary)

    def test_restore_repo_context_discards_unregistered_worktree(self) -> None:
        remember = getattr(zs_start, "remember_repo_context", None)
        restore = getattr(zs_start, "restore_repo_context", None)
        self.assertTrue(callable(remember))
        self.assertTrue(callable(restore))
        if not callable(remember) or not callable(restore):
            return

        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            feature_root = temp_dir / "feature"
            primary_root.mkdir()
            feature_root.mkdir()
            primary = zs_start.RepoContext(primary_root, primary_root, "main")
            feature = zs_start.RepoContext(feature_root, primary_root, "feature")
            state_dir = temp_dir / "sessions"

            remember(feature, session_key="tab-a", state_dir=state_dir)
            with patch.object(zs_start, "list_repo_contexts", return_value=[primary]):
                first_restore = restore(primary, session_key="tab-a", state_dir=state_dir)
            with patch.object(zs_start, "list_repo_contexts", return_value=[primary, feature]):
                second_restore = restore(primary, session_key="tab-a", state_dir=state_dir)

        self.assertEqual(first_restore, primary)
        self.assertEqual(second_restore, primary)

    def test_resolve_startup_repo_context_restores_tab_selection(self) -> None:
        resolver = getattr(zs_start, "resolve_startup_repo_context", None)
        self.assertTrue(callable(resolver))
        if not callable(resolver):
            return

        primary_root = Path("/workspace/project")
        feature_root = Path("/workspace/feature")
        primary = zs_start.RepoContext(primary_root, primary_root, "main")
        feature = zs_start.RepoContext(feature_root, primary_root, "feature")

        with patch.object(zs_start, "resolve_repo_context", return_value=primary), patch.object(
            zs_start,
            "restore_repo_context",
            return_value=feature,
            create=True,
        ) as restore, patch.object(
            zs_start,
            "remember_repo_context",
            create=True,
        ) as remember:
            resolved = resolver()

        self.assertEqual(resolved, feature)
        restore.assert_called_once_with(primary)
        remember.assert_called_once_with(feature)

    def test_resolve_startup_repo_context_explicit_worktree_overrides_tab_selection(self) -> None:
        resolver = getattr(zs_start, "resolve_startup_repo_context", None)
        self.assertTrue(callable(resolver))
        if not callable(resolver):
            return

        primary_root = Path("/workspace/project")
        feature_root = Path("/workspace/feature")
        feature = zs_start.RepoContext(feature_root, primary_root, "feature")

        with patch.object(zs_start, "resolve_repo_context", return_value=feature) as resolve, patch.object(
            zs_start,
            "restore_repo_context",
            create=True,
        ) as restore, patch.object(
            zs_start,
            "remember_repo_context",
            create=True,
        ) as remember:
            resolved = resolver(requested_worktree=feature_root)

        self.assertEqual(resolved, feature)
        resolve.assert_called_once_with(requested_worktree=feature_root)
        restore.assert_not_called()
        remember.assert_called_once_with(feature)

    def test_initialize_cloud_bff_env_copies_independent_worktree_config(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            primary_bff = self.create_cloud_bff(primary_root)
            self.create_cloud_bff(worktree_root)
            primary_env = primary_bff / ".env"
            primary_env.write_text("ZS_MN_SERVER=http://172.20.1.1:8080\n", encoding="utf-8")
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")

            with patch("sys.stdout", io.StringIO()):
                env_path = zs_start.initialize_cloud_bff_env(context)
            zs_start.write_env(["ZS_MN_SERVER=http://172.20.1.2:8080"], env_path)

            self.assertEqual(
                primary_env.read_text(encoding="utf-8"),
                "ZS_MN_SERVER=http://172.20.1.1:8080\n",
            )
            self.assertEqual(
                env_path.read_text(encoding="utf-8"),
                "ZS_MN_SERVER=http://172.20.1.2:8080\n",
            )

    def test_initialize_cloud_bff_env_preserves_existing_worktree_config(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            primary_bff = self.create_cloud_bff(primary_root)
            worktree_bff = self.create_cloud_bff(worktree_root)
            (primary_bff / ".env").write_text("SOURCE=main\n", encoding="utf-8")
            worktree_env = worktree_bff / ".env"
            worktree_env.write_text("SOURCE=feature\n", encoding="utf-8")
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")

            env_path = zs_start.initialize_cloud_bff_env(context)

            self.assertEqual(env_path, worktree_env)
            self.assertEqual(env_path.read_text(encoding="utf-8"), "SOURCE=feature\n")

    def test_ensure_cloud_bff_dependencies_runs_scoped_offline_install(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            self.create_cloud_bff(primary_root)
            worktree_bff = self.create_cloud_bff(worktree_root)
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")

            def run_install(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                nest_cli = worktree_bff / "node_modules/.bin/nest"
                nest_cli.parent.mkdir(parents=True)
                nest_cli.touch()
                return subprocess.CompletedProcess(command, 0)

            with patch.object(zs_start.shutil, "which", return_value="/opt/pnpm"), patch.object(
                zs_start.subprocess, "run", side_effect=run_install
            ) as run:
                zs_start.ensure_cloud_bff_dependencies(context, confirm=lambda _: True)

            run.assert_called_once_with(
                [
                    "pnpm",
                    "install",
                    "--offline",
                    "--frozen-lockfile",
                    "--filter=bff...",
                ],
                cwd=worktree_root,
                check=False,
            )

    def test_ensure_cloud_bff_dependencies_does_not_install_without_confirmation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            self.create_cloud_bff(primary_root)
            self.create_cloud_bff(worktree_root)
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")

            with patch.object(zs_start.subprocess, "run") as run:
                with self.assertRaisesRegex(zs_start.ZsStartError, "依赖尚未准备"):
                    zs_start.ensure_cloud_bff_dependencies(context, confirm=lambda _: False)

            run.assert_not_called()

    def test_prepare_cloud_bff_dependencies_builds_missing_runtime_outputs(
        self,
    ) -> None:
        prepare = getattr(zs_start, "prepare_cloud_bff_dependencies", None)
        self.assertTrue(callable(prepare))
        if not callable(prepare):
            return

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            (root / "node_modules/.pnpm").mkdir(parents=True)
            bff_dir = self.create_workspace_package(
                root,
                str(zs_start.CLOUD_BFF_RELATIVE_DIR),
                "bff",
                dependencies={"@zstack/constant-core": "workspace:*"},
            )
            constant_core_dir = self.create_workspace_package(
                root,
                "packages/products/cloud/shared/constant-core",
                "@zstack/constant-core",
                exports={".": {"require": "./dist/index.cjs"}},
                build=True,
            )
            link = bff_dir / "node_modules/@zstack/constant-core"
            link.parent.mkdir(parents=True)
            link.symlink_to(constant_core_dir, target_is_directory=True)
            context = zs_start.RepoContext(root, root, "feature")
            scope_json = json.dumps(
                [
                    {"name": "bff", "path": str(bff_dir)},
                    {
                        "name": "@zstack/constant-core",
                        "path": str(constant_core_dir),
                    },
                ]
            )

            def run_command(
                command: list[str],
                **kwargs: object,
            ) -> subprocess.CompletedProcess[str]:
                if "list" in command:
                    return subprocess.CompletedProcess(command, 0, stdout=scope_json)
                if "build" in command:
                    output = constant_core_dir / "dist/index.cjs"
                    output.parent.mkdir(parents=True)
                    output.touch()
                    return subprocess.CompletedProcess(command, 0)
                self.fail(f"unexpected command: {command}")

            with patch.object(
                zs_start.subprocess,
                "run",
                side_effect=run_command,
            ) as run, patch("sys.stdout", io.StringIO()):
                result = prepare(context)

            self.assertEqual(result.built_packages, ("@zstack/constant-core",))
            commands = [call.args[0] for call in run.call_args_list]
            self.assertIn("--filter=bff...", commands[0])
            build_command = next(command for command in commands if "build" in command)
            self.assertIn("--workspace-concurrency=1", build_command)
            self.assertIn("--filter=@zstack/constant-core", build_command)
            self.assertFalse(any("start" in command or "dev" in command for command in commands))

    def test_prepare_cloud_bff_dependencies_skips_build_when_outputs_exist(
        self,
    ) -> None:
        prepare = getattr(zs_start, "prepare_cloud_bff_dependencies", None)
        self.assertTrue(callable(prepare))
        if not callable(prepare):
            return

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            (root / "node_modules/.pnpm").mkdir(parents=True)
            bff_dir = self.create_workspace_package(
                root,
                str(zs_start.CLOUD_BFF_RELATIVE_DIR),
                "bff",
                dependencies={"@zstack/constant-core": "workspace:*"},
            )
            constant_core_dir = self.create_workspace_package(
                root,
                "packages/products/cloud/shared/constant-core",
                "@zstack/constant-core",
                exports={".": {"require": "./dist/index.cjs"}},
                build=True,
            )
            output = constant_core_dir / "dist/index.cjs"
            output.parent.mkdir(parents=True)
            output.touch()
            link = bff_dir / "node_modules/@zstack/constant-core"
            link.parent.mkdir(parents=True)
            link.symlink_to(constant_core_dir, target_is_directory=True)
            context = zs_start.RepoContext(root, root, "feature")
            scope_json = json.dumps(
                [
                    {"name": "bff", "path": str(bff_dir)},
                    {
                        "name": "@zstack/constant-core",
                        "path": str(constant_core_dir),
                    },
                ]
            )

            with patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    ["pnpm", "list"],
                    0,
                    stdout=scope_json,
                ),
            ) as run, patch("sys.stdout", io.StringIO()):
                result = prepare(context)

            self.assertFalse(result.installed)
            self.assertEqual(result.built_packages, ())
            self.assertEqual(len(run.call_args_list), 1)

    def test_prepare_cloud_bff_context_runs_runtime_preflight(self) -> None:
        root = Path("/workspace/feature")
        context = zs_start.RepoContext(root, root, "feature")
        env_path = root / zs_start.CLOUD_BFF_RELATIVE_DIR / ".env"

        with patch.object(Path, "is_dir", return_value=True), patch.object(
            zs_start,
            "render_repo_context",
        ), patch.object(zs_start, "ensure_cloud_bff_dependencies"), patch.object(
            zs_start,
            "prepare_cloud_bff_dependencies",
            create=True,
        ) as prepare, patch.object(
            zs_start,
            "initialize_cloud_bff_env",
            return_value=env_path,
        ):
            result = zs_start.prepare_cloud_bff_context(context)

        self.assertEqual(result, env_path)
        prepare.assert_called_once_with(context)

    def test_ensure_frontend_dependencies_runs_scoped_offline_bootstrap(self) -> None:
        ensure_dependencies = getattr(
            zs_start,
            "ensure_frontend_dependencies",
            None,
        )
        self.assertTrue(callable(ensure_dependencies))

        with tempfile.TemporaryDirectory() as directory:
            worktree_root = Path(directory) / "feature"
            self.create_frontend(worktree_root)
            context = zs_start.RepoContext(worktree_root, worktree_root, "feature")

            def run_install(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                dependency_marker = worktree_root / "node_modules/.bin/nx"
                dependency_marker.parent.mkdir(parents=True)
                dependency_marker.touch()
                return subprocess.CompletedProcess(command, 0)

            with patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start.subprocess,
                "run",
                side_effect=run_install,
            ) as run, patch.object(
                zs_start,
                "prepare_frontend_scope",
            ):
                ensure_dependencies(
                    context,
                    product="cloud",
                    confirm=lambda _: True,
                )

            run.assert_called_once_with(
                [
                    "pnpm",
                    "install",
                    "--offline",
                    "--frozen-lockfile",
                    "--ignore-scripts",
                    "--filter=core-shell...",
                ],
                cwd=worktree_root,
                check=False,
            )

    def test_ensure_frontend_dependencies_auto_installs_linked_worktree_bootstrap(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            self.create_frontend(primary_root, dependencies_ready=True)
            self.create_frontend(worktree_root)
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")

            def reject_confirmation(_: str) -> bool:
                self.fail("linked worktree bootstrap should not require confirmation")

            def run_install(
                command: list[str],
                **kwargs: object,
            ) -> subprocess.CompletedProcess[str]:
                dependency_marker = worktree_root / "node_modules/.bin/nx"
                dependency_marker.parent.mkdir(parents=True, exist_ok=True)
                dependency_marker.touch()
                return subprocess.CompletedProcess(command, 0)

            with patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start.subprocess,
                "run",
                side_effect=run_install,
            ) as run:
                zs_start.ensure_frontend_dependencies(
                    context,
                    product="cloud",
                    confirm=reject_confirmation,
                )

            self.assertIn("--offline", run.call_args.args[0])
            self.assertIn("--filter=core-shell...", run.call_args.args[0])

    def test_frontend_dependency_install_defaults_to_cloud_bootstrap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root)
            context = zs_start.RepoContext(root, root, "feature")

            command = zs_start.build_frontend_dependency_install_command(context)

        self.assertEqual(
            command,
            [
                "pnpm",
                "install",
                "--offline",
                "--frozen-lockfile",
                "--ignore-scripts",
                "--filter=core-shell...",
            ],
        )

    def test_frontend_dependency_install_uses_zns_shell_bootstrap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root)
            context = zs_start.RepoContext(root, root, "feature")

            command = zs_start.build_frontend_dependency_install_command(
                context,
                product="zns",
            )

        self.assertEqual(command[-1], "--filter=zns-shell...")

    def test_frontend_dependency_install_retries_online_with_same_scope(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root)
            context = zs_start.RepoContext(root, root, "feature")
            command = zs_start.build_frontend_dependency_install_command(
                context,
                product="cloud",
                apps=("core-shell", "physical-network"),
            )

            with patch.object(zs_start.shutil, "which", return_value="/opt/pnpm"), patch.object(
                zs_start.subprocess,
                "run",
                side_effect=(
                    subprocess.CompletedProcess(command, 1),
                    subprocess.CompletedProcess(command, 0),
                ),
            ) as run:
                zs_start.run_frontend_dependency_install(
                    context,
                    command,
                    confirm_online_retry=lambda _: True,
                )

        offline_command = run.call_args_list[0].args[0]
        online_command = run.call_args_list[1].args[0]
        self.assertIn("--offline", offline_command)
        self.assertNotIn("--offline", online_command)
        self.assertIn("--frozen-lockfile", online_command)
        self.assertIn("--ignore-scripts", online_command)
        self.assertIn("--filter=core-shell...", online_command)
        self.assertIn("--filter=physical-network...", online_command)

    def test_frontend_dependency_install_does_not_retry_online_without_confirmation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root)
            context = zs_start.RepoContext(root, root, "feature")
            command = zs_start.build_frontend_dependency_install_command(context)

            with patch.object(zs_start.shutil, "which", return_value="/opt/pnpm"), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(command, 1),
            ) as run:
                with self.assertRaisesRegex(
                    zs_start.ZsStartError,
                    "可在确认网络可用后执行",
                ):
                    zs_start.run_frontend_dependency_install(
                        context,
                        command,
                        confirm_online_retry=lambda _: False,
                    )

        run.assert_called_once()

    def test_frontend_runtime_output_issues_ignore_types_and_styles(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_dir = self.create_workspace_package(
                root,
                "packages/mf-runtime-plugin",
                "@zstack/mf-runtime-plugin",
                exports={
                    ".": {
                        "types": "./dist/index.d.ts",
                        "import": "./dist/index.js",
                    },
                    "./retry": "./dist/retry.js",
                    "./style.css": "./dist/style.css",
                },
                build=True,
            )

            issues = zs_start.frontend_runtime_output_issues(package_dir)

            self.assertEqual(
                issues,
                (
                    package_dir / "dist/index.js",
                    package_dir / "dist/retry.js",
                ),
            )

    def test_frontend_runtime_outputs_stale_when_source_is_newer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_dir = self.create_workspace_package(
                root,
                "packages/shared",
                "@example/shared",
                exports={
                    ".": {"import": "./dist/index.js"},
                    "./legacy": {"import": "./legacy.js"},
                },
                build=True,
            )
            source = package_dir / "src/index.ts"
            output = package_dir / "dist/index.js"
            legacy_output = package_dir / "legacy.js"
            source.parent.mkdir(parents=True)
            output.parent.mkdir(parents=True)
            source.touch()
            output.touch()
            legacy_output.touch()
            old_time = 1_700_000_000
            new_time = old_time + 60
            os.utime(package_dir / "package.json", (old_time, old_time))
            os.utime(source, (old_time, old_time))
            os.utime(output, (new_time, new_time))
            os.utime(legacy_output, (old_time - 60, old_time - 60))

            self.assertFalse(zs_start.frontend_runtime_outputs_stale(package_dir))

            os.utime(source, (new_time + 60, new_time + 60))

            self.assertTrue(zs_start.frontend_runtime_outputs_stale(package_dir))

    def test_frontend_dependency_build_command_is_sequential_and_scoped(self) -> None:
        command = zs_start.build_frontend_dependency_build_command(
            ("@zstack/mf-hub", "@zstack/mf-runtime-plugin"),
        )

        self.assertEqual(
            command,
            [
                "pnpm",
                "--workspace-concurrency=1",
                "--sort",
                "--if-present",
                "--filter=@zstack/mf-hub",
                "--filter=@zstack/mf-runtime-plugin",
                "run",
                "build",
            ],
        )

    def test_prepare_frontend_scope_installs_links_and_builds_only_missing_outputs(
        self,
    ) -> None:
        prepare = getattr(zs_start, "prepare_frontend_scope", None)
        self.assertTrue(callable(prepare))
        if not callable(prepare):
            return

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root, dependencies_ready=True)
            (root / "node_modules/.pnpm").mkdir(parents=True)
            app_dir = self.create_workspace_package(
                root,
                "packages/products/cloud/apps/core-shell",
                "core-shell",
                dependencies={"@zstack/mf-hub": "workspace:*"},
            )
            library_dir = self.create_workspace_package(
                root,
                "packages/products/cloud/shared/mf-hub",
                "@zstack/mf-hub",
                exports={".": "./dist/index.js"},
                build=True,
            )
            context = zs_start.RepoContext(root, root, "feature")
            scope_json = json.dumps(
                [
                    {"name": "core-shell", "path": str(app_dir)},
                    {"name": "@zstack/mf-hub", "path": str(library_dir)},
                ]
            )

            def run_command(
                command: list[str],
                **kwargs: object,
            ) -> subprocess.CompletedProcess[str]:
                if "list" in command:
                    return subprocess.CompletedProcess(command, 0, stdout=scope_json)
                if "install" in command:
                    link = app_dir / "node_modules/@zstack/mf-hub"
                    link.parent.mkdir(parents=True)
                    link.symlink_to(library_dir, target_is_directory=True)
                    return subprocess.CompletedProcess(command, 0)
                if "build" in command:
                    output = library_dir / "dist/index.js"
                    output.parent.mkdir(parents=True)
                    output.touch()
                    return subprocess.CompletedProcess(command, 0)
                self.fail(f"unexpected command: {command}")

            with patch.object(zs_start.shutil, "which", return_value="/opt/pnpm"), patch.object(
                zs_start.subprocess,
                "run",
                side_effect=run_command,
            ) as run, patch("sys.stdout", io.StringIO()):
                result = prepare(
                    context,
                    product="cloud",
                    apps=("core-shell",),
                )

            self.assertTrue(result.installed)
            self.assertEqual(result.built_packages, ("@zstack/mf-hub",))
            commands = [call.args[0] for call in run.call_args_list]
            install_command = next(command for command in commands if "install" in command)
            build_command = next(command for command in commands if "build" in command)
            self.assertIn("--offline", install_command)
            self.assertIn("--filter=core-shell...", install_command)
            self.assertIn("--workspace-concurrency=1", build_command)
            self.assertIn("--filter=@zstack/mf-hub", build_command)
            self.assertNotIn("core-shell", result.built_packages)
            self.assertFalse(any("dev" in command or "start" in command for command in commands))

    def test_prepare_frontend_scope_skips_install_and_build_when_scope_is_ready(
        self,
    ) -> None:
        prepare = getattr(zs_start, "prepare_frontend_scope", None)
        self.assertTrue(callable(prepare))
        if not callable(prepare):
            return

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root, dependencies_ready=True)
            (root / "node_modules/.pnpm").mkdir(parents=True)
            app_dir = self.create_workspace_package(
                root,
                "packages/products/cloud/apps/core-shell",
                "core-shell",
                dependencies={"@zstack/mf-hub": "workspace:*"},
            )
            library_dir = self.create_workspace_package(
                root,
                "packages/products/cloud/shared/mf-hub",
                "@zstack/mf-hub",
                exports={".": "./dist/index.js"},
                build=True,
            )
            link = app_dir / "node_modules/@zstack/mf-hub"
            link.parent.mkdir(parents=True)
            link.symlink_to(library_dir, target_is_directory=True)
            output = library_dir / "dist/index.js"
            output.parent.mkdir(parents=True)
            output.touch()
            context = zs_start.RepoContext(root, root, "feature")
            scope_json = json.dumps(
                [
                    {"name": "core-shell", "path": str(app_dir)},
                    {"name": "@zstack/mf-hub", "path": str(library_dir)},
                ]
            )

            with patch.object(zs_start.shutil, "which", return_value="/opt/pnpm"), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    ["pnpm", "list"],
                    0,
                    stdout=scope_json,
                ),
            ) as run, patch("sys.stdout", io.StringIO()):
                result = prepare(
                    context,
                    product="cloud",
                    apps=("core-shell",),
                )

            self.assertFalse(result.installed)
            self.assertEqual(result.built_packages, ())
            self.assertTrue(all("list" in call.args[0] for call in run.call_args_list))

    def test_ensure_frontend_dependencies_does_not_install_without_confirmation(
        self,
    ) -> None:
        ensure_dependencies = getattr(
            zs_start,
            "ensure_frontend_dependencies",
            None,
        )
        self.assertTrue(callable(ensure_dependencies))

        with tempfile.TemporaryDirectory() as directory:
            worktree_root = Path(directory) / "feature"
            self.create_frontend(worktree_root)
            context = zs_start.RepoContext(worktree_root, worktree_root, "feature")

            with patch.object(zs_start.subprocess, "run") as run:
                with self.assertRaisesRegex(zs_start.ZsStartError, "前端依赖尚未准备"):
                    ensure_dependencies(context, confirm=lambda _: False)

            run.assert_not_called()

    def test_ensure_frontend_dependencies_reports_partial_install_as_actionable_error(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            worktree_root = Path(directory) / "feature"
            self.create_frontend(worktree_root, dependencies_ready=True)
            postcss_config = worktree_root / zs_start.CORE_SHELL_POSTCSS_CONFIG
            postcss_config.parent.mkdir(parents=True)
            postcss_config.touch()
            context = zs_start.RepoContext(worktree_root, worktree_root, "feature")

            with self.assertRaisesRegex(
                zs_start.ZsStartError,
                "修复前端依赖",
            ):
                zs_start.ensure_frontend_dependencies(
                    context,
                    confirm=lambda _: False,
                )

    def test_ensure_frontend_dependencies_prepares_exact_selected_scope(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root, dependencies_ready=True)
            context = zs_start.RepoContext(root, root, "feature")

            with patch.object(
                zs_start,
                "validate_frontend_dependencies",
            ), patch.object(
                zs_start,
                "prepare_frontend_scope",
                create=True,
            ) as prepare:
                zs_start.ensure_frontend_dependencies(
                    context,
                    product="cloud",
                    apps=("core-shell", "settings"),
                )

            prepare.assert_called_once_with(
                context,
                product="cloud",
                apps=("core-shell", "settings"),
            )

    def test_install_frontend_dependencies_uses_primary_store_and_never_starts_service(
        self,
    ) -> None:
        installer = getattr(zs_start, "install_frontend_dependencies", None)
        self.assertTrue(callable(installer))
        if not callable(installer):
            return

        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            self.create_frontend(primary_root)
            self.create_frontend(worktree_root)
            modules_file = primary_root / "node_modules/.modules.yaml"
            modules_file.parent.mkdir(parents=True, exist_ok=True)
            modules_file.write_text(
                "storeDir: /cache/pnpm/store/v10\n",
                encoding="utf-8",
            )
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")

            def run_install(
                command: list[str],
                **kwargs: object,
            ) -> subprocess.CompletedProcess[str]:
                dependency_marker = worktree_root / "node_modules/.bin/nx"
                dependency_marker.parent.mkdir(parents=True)
                dependency_marker.touch()
                return subprocess.CompletedProcess(command, 0)

            with patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start.subprocess,
                "run",
                side_effect=run_install,
            ) as run, patch.object(
                zs_start,
                "prepare_frontend_scope",
            ) as prepare, patch("sys.stdout", io.StringIO()):
                result = installer(
                    context,
                    product="cloud",
                    apps=("core-shell", "settings", "virtual-orchestration"),
                    confirm=lambda _: True,
                )

            self.assertEqual(result, 0)
            prepare.assert_called_once_with(
                context,
                product="cloud",
                apps=("core-shell", "settings", "virtual-orchestration"),
            )
            run.assert_called_once_with(
                [
                    "pnpm",
                    "--store-dir",
                    "/cache/pnpm/store",
                    "install",
                    "--offline",
                    "--frozen-lockfile",
                    "--ignore-scripts",
                    "--filter=core-shell...",
                    "--filter=settings...",
                    "--filter=virtual-orchestration...",
                ],
                cwd=worktree_root,
                check=False,
            )

    def test_install_frontend_dependencies_stops_when_worktree_store_differs(
        self,
    ) -> None:
        installer = getattr(zs_start, "install_frontend_dependencies", None)
        self.assertTrue(callable(installer))
        if not callable(installer):
            return

        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            self.create_frontend(primary_root)
            self.create_frontend(worktree_root)
            primary_modules = primary_root / "node_modules/.modules.yaml"
            worktree_modules = worktree_root / "node_modules/.modules.yaml"
            primary_modules.parent.mkdir(parents=True, exist_ok=True)
            worktree_modules.parent.mkdir(parents=True, exist_ok=True)
            primary_modules.write_text(
                "storeDir: /cache/primary-store/v10\n",
                encoding="utf-8",
            )
            worktree_modules.write_text(
                "storeDir: /cache/worktree-store/v10\n",
                encoding="utf-8",
            )
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")

            with patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm"], 0),
            ) as run:
                with self.assertRaisesRegex(zs_start.ZsStartError, "store 不一致"):
                    installer(context, confirm=lambda _: True)

            run.assert_not_called()

    def test_ensure_frontend_dependencies_links_core_shell_postcss_plugin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            worktree_root = Path(directory) / "feature"
            self.create_frontend(worktree_root, dependencies_ready=True)
            postcss_config = (
                worktree_root
                / "packages/products/cloud/apps/core-shell/postcss.config.mjs"
            )
            postcss_config.parent.mkdir(parents=True)
            postcss_config.write_text(
                'export default { plugins: { "@tailwindcss/postcss": {} } };\n',
                encoding="utf-8",
            )
            plugin_source = (
                worktree_root
                / "node_modules/.pnpm/node_modules/@tailwindcss/postcss"
            )
            plugin_source.mkdir(parents=True)
            context = zs_start.RepoContext(worktree_root, worktree_root, "feature")

            with patch.object(zs_start.shutil, "which", return_value="/opt/tool"):
                zs_start.ensure_frontend_dependencies(context)

            plugin_link = (
                worktree_root
                / "packages/products/cloud/apps/core-shell/node_modules/@tailwindcss/postcss"
            )
            self.assertTrue(plugin_link.is_symlink())
            self.assertEqual(plugin_link.resolve(), plugin_source.resolve())

    def test_initialize_zns_bff_env_uses_worktree_example(self) -> None:
        initialize_env = getattr(zs_start, "initialize_zns_bff_env", None)
        self.assertTrue(callable(initialize_env))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "main"
            zns_bff_dir = self.create_zns_bff(root)
            context = zs_start.RepoContext(root, root, "main")

            with patch("sys.stdout", io.StringIO()):
                env_path = initialize_env(context)

            self.assertEqual(env_path, zns_bff_dir / ".env")
            self.assertEqual(
                env_path.read_text(encoding="utf-8"),
                "PORT=7300\nZNS_API_BASE_URL=http://localhost:7278\n",
            )

    def test_ensure_zns_bff_dependencies_runs_scoped_offline_install(self) -> None:
        ensure_dependencies = getattr(zs_start, "ensure_zns_bff_dependencies", None)
        self.assertTrue(callable(ensure_dependencies))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            zns_bff_dir = self.create_zns_bff(root)
            context = zs_start.RepoContext(root, root, "feature")

            def run_install(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
                nest_cli = zns_bff_dir / "node_modules/.bin/nest"
                nest_cli.parent.mkdir(parents=True)
                nest_cli.touch()
                return subprocess.CompletedProcess(command, 0)

            with patch.object(zs_start.shutil, "which", return_value="/opt/pnpm"), patch.object(
                zs_start.subprocess,
                "run",
                side_effect=run_install,
            ) as run:
                ensure_dependencies(context, confirm=lambda _: True)

            run.assert_called_once_with(
                [
                    "pnpm",
                    "install",
                    "--offline",
                    "--frozen-lockfile",
                    "--filter=zns-bff...",
                ],
                cwd=root,
                check=False,
            )

    def test_start_cloud_bff_runs_pnpm_from_selected_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            primary_bff = self.create_cloud_bff(primary_root)
            worktree_bff = self.create_cloud_bff(worktree_root)
            nest_cli = worktree_bff / "node_modules/.bin/nest"
            nest_cli.parent.mkdir(parents=True)
            nest_cli.touch()
            env_content = "ZS_MN_SERVER=http://172.20.1.1:8080\n"
            (primary_bff / ".env").write_text(
                env_content,
                encoding="utf-8",
            )
            (worktree_bff / ".env").write_text(
                env_content,
                encoding="utf-8",
            )
            context = zs_start.RepoContext(
                worktree_root,
                primary_root,
                "xfu-dev/5.5.38/zstac-1",
            )

            with patch.object(zs_start.sys.stdin, "isatty", return_value=False), patch.object(
                zs_start, "choose_with_numbers", return_value=("select", 0)
            ), patch.object(zs_start, "set_terminal_title"), patch.object(
                zs_start, "prepare_cloud_bff_dependencies"
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:dev"], 0),
            ) as run, patch("sys.stdout", io.StringIO()):
                result = zs_start.start_cloud_bff(context)

            self.assertEqual(result, 0)
            run.assert_called_once_with(["pnpm", "start:dev"], cwd=worktree_bff)

    def test_start_cloud_bff_install_shortcut_repairs_before_selection(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            bff_dir = self.create_cloud_bff(root)
            env_path = bff_dir / ".env"
            env_path.write_text(
                "ZS_MN_SERVER=http://172.20.1.1:8080\n",
                encoding="utf-8",
            )
            context = zs_start.RepoContext(root, root, "feature")

            with patch.object(
                zs_start,
                "prepare_cloud_bff_context",
                return_value=env_path,
            ), patch.object(
                zs_start.sys.stdin,
                "isatty",
                return_value=True,
            ), patch.object(
                zs_start,
                "choose_with_keys",
                side_effect=[("install", -1), ("select", 0)],
            ), patch.object(
                zs_start,
                "prepare_cloud_bff_dependencies",
            ) as prepare, patch.object(zs_start, "set_terminal_title"), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:dev"], 0),
            ) as run, patch("sys.stdout", io.StringIO()):
                result = zs_start.start_cloud_bff(context)

            self.assertEqual(result, 0)
            prepare.assert_called_once_with(context)
            run.assert_called_once_with(["pnpm", "start:dev"], cwd=bff_dir)

    def test_start_cloud_bff_uses_primary_targets_with_worktree_active_host(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            primary_bff = self.create_cloud_bff(primary_root)
            worktree_bff = self.create_cloud_bff(worktree_root)
            nest_cli = worktree_bff / "node_modules/.bin/nest"
            nest_cli.parent.mkdir(parents=True)
            nest_cli.touch()
            primary_env = primary_bff / ".env"
            primary_env.write_text(
                "# 主列表 A\n"
                "ZS_MN_SERVER=http://172.20.1.1:8080\n"
                "# 主列表 B\n"
                "# ZS_MN_SERVER=http://172.20.1.2:8080\n"
                "ZS_MYSQL_HOST=172.20.1.1\n"
                "ZOPS_SERVER=http://172.20.1.1:10010\n",
                encoding="utf-8",
            )
            primary_before = primary_env.read_text(encoding="utf-8")
            worktree_env = worktree_bff / ".env"
            worktree_env.write_text(
                "ZS_MN_SERVER=http://172.20.1.2:8080\n"
                "ZS_MYSQL_HOST=172.20.1.2\n"
                "ZOPS_SERVER=http://172.20.1.2:10010\n",
                encoding="utf-8",
            )
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")
            rendered_targets: list[list[tuple[str, bool]]] = []

            def choose(
                targets: list[zs_start.Target],
                _context: zs_start.RepoContext,
            ) -> tuple[str, int]:
                rendered_targets.append(
                    [(target.host, target.active) for target in targets]
                )
                return "select", 0

            with patch.object(zs_start.sys.stdin, "isatty", return_value=False), patch.object(
                zs_start,
                "choose_with_numbers",
                side_effect=choose,
            ), patch.object(zs_start, "set_terminal_title"), patch.object(
                zs_start, "prepare_cloud_bff_dependencies"
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:dev"], 0),
            ), patch("sys.stdout", io.StringIO()):
                result = zs_start.start_cloud_bff(context)

            self.assertEqual(result, 0)
            self.assertEqual(
                rendered_targets,
                [[("172.20.1.1", False), ("172.20.1.2", True)]],
            )
            self.assertEqual(primary_env.read_text(encoding="utf-8"), primary_before)
            self.assertEqual(
                worktree_env.read_text(encoding="utf-8"),
                "ZS_MN_SERVER=http://172.20.1.1:8080\n"
                "ZS_MYSQL_HOST=172.20.1.1\n"
                "ZOPS_SERVER=http://172.20.1.1:10010\n",
            )

    def test_start_cloud_bff_adds_worktree_candidate_to_primary_list(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            worktree_root = temp_dir / "feature"
            primary_bff = self.create_cloud_bff(primary_root)
            worktree_bff = self.create_cloud_bff(worktree_root)
            nest_cli = worktree_bff / "node_modules/.bin/nest"
            nest_cli.parent.mkdir(parents=True)
            nest_cli.touch()
            primary_env = primary_bff / ".env"
            primary_env.write_text(
                "# 主列表 A\n"
                "ZS_MN_SERVER=http://172.20.1.1:8080\n"
                "ZS_MYSQL_HOST=172.20.1.1\n"
                "ZOPS_SERVER=http://172.20.1.1:10010\n",
                encoding="utf-8",
            )
            worktree_env = worktree_bff / ".env"
            worktree_env.write_text(
                "ZS_MN_SERVER=http://172.20.1.1:8080\n"
                "ZS_MYSQL_HOST=172.20.1.1\n"
                "ZOPS_SERVER=http://172.20.1.1:10010\n",
                encoding="utf-8",
            )
            context = zs_start.RepoContext(worktree_root, primary_root, "feature")
            rendered_hosts: list[list[str]] = []

            def choose(
                targets: list[zs_start.Target],
                _context: zs_start.RepoContext,
            ) -> tuple[str, int]:
                rendered_hosts.append([target.host for target in targets])
                if len(rendered_hosts) == 1:
                    return "add", -1
                return "select", 1

            with patch.object(zs_start.sys.stdin, "isatty", return_value=False), patch.object(
                zs_start,
                "choose_with_numbers",
                side_effect=choose,
            ), patch.object(
                zs_start,
                "prompt_host_desc",
                return_value=("172.20.1.3", "共享新增"),
            ), patch.object(zs_start, "set_terminal_title"), patch.object(
                zs_start, "prepare_cloud_bff_dependencies"
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:dev"], 0),
            ), patch("sys.stdout", io.StringIO()):
                result = zs_start.start_cloud_bff(context)

            self.assertEqual(result, 0)
            self.assertEqual(
                rendered_hosts,
                [["172.20.1.1"], ["172.20.1.1", "172.20.1.3"]],
            )
            self.assertIn("# 共享新增", primary_env.read_text(encoding="utf-8"))
            self.assertIn(
                "# ZS_MN_SERVER=http://172.20.1.3:8080",
                primary_env.read_text(encoding="utf-8"),
            )
            worktree_content = worktree_env.read_text(encoding="utf-8")
            self.assertNotIn("共享新增", worktree_content)
            self.assertEqual(
                worktree_content,
                "ZS_MN_SERVER=http://172.20.1.3:8080\n"
                "ZS_MYSQL_HOST=172.20.1.3\n"
                "ZOPS_SERVER=http://172.20.1.3:10010\n",
            )

    def test_start_cloud_bff_can_switch_worktree_before_starting(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            feature_root = temp_dir / "feature"
            primary_bff = self.create_cloud_bff(primary_root)
            feature_bff = self.create_cloud_bff(feature_root)
            for cloud_bff, host in (
                (primary_bff, "172.20.1.1"),
                (feature_bff, "172.20.1.2"),
            ):
                nest_cli = cloud_bff / "node_modules/.bin/nest"
                nest_cli.parent.mkdir(parents=True)
                nest_cli.touch()
                (cloud_bff / ".env").write_text(
                    f"ZS_MN_SERVER=http://{host}:8080\n",
                    encoding="utf-8",
                )
            primary = zs_start.RepoContext(primary_root, primary_root, "main")
            feature = zs_start.RepoContext(feature_root, primary_root, "feature")

            with patch.object(zs_start.sys.stdin, "isatty", return_value=True), patch.object(
                zs_start,
                "choose_with_keys",
                side_effect=[("switch", -1), ("select", 0)],
            ), patch.object(
                zs_start,
                "choose_repo_context",
                return_value=feature,
            ), patch.object(zs_start, "set_terminal_title"), patch.object(
                zs_start, "prepare_cloud_bff_dependencies"
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:dev"], 0),
            ) as run, patch("sys.stdout", io.StringIO()):
                result = zs_start.start_cloud_bff(primary)

            self.assertEqual(result, 0)
            run.assert_called_once_with(["pnpm", "start:dev"], cwd=feature_bff)

    def test_start_frontend_preserves_default_pnpm_start_launcher(self) -> None:
        launcher = getattr(zs_start, "start_frontend", None)
        self.assertTrue(callable(launcher))

        with tempfile.TemporaryDirectory() as directory:
            worktree_root = Path(directory) / "feature"
            self.create_frontend(worktree_root, dependencies_ready=True)
            context = zs_start.RepoContext(
                worktree_root,
                worktree_root,
                "xfu-dev/5.5.38/zstac-1",
            )

            with patch.object(
                zs_start,
                "choose_frontend_action",
                return_value="default",
                create=True,
            ), patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start,
                "set_terminal_title",
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start"], 0),
            ) as run, patch.object(zs_start, "frontend_start_state_path", return_value=None), patch("sys.stdout", io.StringIO()):
                result = launcher(context)

            self.assertEqual(result, 0)
            run.assert_called_once_with(["pnpm", "start"], cwd=worktree_root)

    def test_start_frontend_uses_explicit_cloud_command(self) -> None:
        launcher = getattr(zs_start, "start_frontend", None)
        self.assertTrue(callable(launcher))

        with tempfile.TemporaryDirectory() as directory:
            worktree_root = Path(directory) / "feature"
            self.create_frontend(worktree_root, dependencies_ready=True)
            context = zs_start.RepoContext(worktree_root, worktree_root, "feature")

            with patch.object(
                zs_start,
                "choose_frontend_action",
                return_value="cloud",
                create=True,
            ), patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start,
                "set_terminal_title",
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:cloud"], 0),
            ) as run, patch.object(zs_start, "frontend_start_state_path", return_value=None), patch("sys.stdout", io.StringIO()):
                result = launcher(context)

            self.assertEqual(result, 0)
            run.assert_called_once_with(["pnpm", "start:cloud"], cwd=worktree_root)

    def test_start_frontend_can_switch_worktree_and_start_zns(self) -> None:
        launcher = getattr(zs_start, "start_frontend", None)
        self.assertTrue(callable(launcher))

        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            feature_root = temp_dir / "feature"
            self.create_frontend(primary_root, dependencies_ready=True)
            self.create_frontend(feature_root, dependencies_ready=True)
            primary = zs_start.RepoContext(primary_root, primary_root, "main")
            feature = zs_start.RepoContext(feature_root, primary_root, "feature")

            with patch.object(
                zs_start,
                "choose_frontend_action",
                side_effect=["switch", "zns"],
                create=True,
            ), patch.object(
                zs_start,
                "choose_repo_context",
                return_value=feature,
            ), patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start,
                "set_terminal_title",
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:zns"], 0),
            ) as run, patch.object(zs_start, "frontend_start_state_path", return_value=None), patch("sys.stdout", io.StringIO()):
                result = launcher(primary)

            self.assertEqual(result, 0)
            run.assert_called_once_with(["pnpm", "start:zns"], cwd=feature_root)

    def test_frontend_state_path_is_stable_per_tab_and_isolated_between_tabs(
        self,
    ) -> None:
        state_path = getattr(zs_start, "frontend_start_state_path", None)
        self.assertTrue(callable(state_path))

        context = zs_start.RepoContext(
            Path("/workspace/project"),
            Path("/workspace/project"),
            "main",
        )
        state_dir = Path("/tmp/zs-start-test-sessions")

        tab_a = state_path(context, session_key="tab-a", state_dir=state_dir)
        same_tab = state_path(context, session_key="tab-a", state_dir=state_dir)
        tab_b = state_path(context, session_key="tab-b", state_dir=state_dir)

        self.assertEqual(tab_a, same_tab)
        self.assertNotEqual(tab_a, tab_b)
        self.assertEqual(tab_a.parent, state_dir)
        self.assertEqual(tab_a.suffix, ".json")

    def test_frontend_state_loads_valid_state_and_rejects_invalid_payloads(
        self,
    ) -> None:
        state_path = getattr(zs_start, "frontend_start_state_path", None)
        load_state = getattr(zs_start, "load_frontend_start_state", None)
        build_command = getattr(zs_start, "build_frontend_start_command", None)
        self.assertTrue(callable(state_path))
        self.assertTrue(callable(load_state))
        self.assertTrue(callable(build_command))

        with tempfile.TemporaryDirectory() as directory:
            context = zs_start.RepoContext(
                Path(directory) / "project",
                Path(directory) / "project",
                "main",
            )
            state_dir = Path(directory) / "sessions"
            path = state_path(context, session_key="tab-a", state_dir=state_dir)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "product": "cloud",
                        "apps": ["core-shell", "network-service"],
                        "startProxy": False,
                    }
                ),
                encoding="utf-8",
            )

            loaded = load_state(context, session_key="tab-a", state_dir=state_dir)

            self.assertIsNotNone(loaded)
            self.assertEqual(loaded.product, "cloud")
            self.assertEqual(loaded.apps, ("core-shell", "network-service"))
            self.assertFalse(loaded.start_proxy)
            self.assertEqual(
                build_command(loaded),
                [
                    "pnpm",
                    "start:cloud",
                    "--apps",
                    "core-shell,network-service",
                    "--proxy=false",
                ],
            )

            invalid_cases: tuple[tuple[str, str | dict[str, object]], ...] = (
                ("bad json", "{"),
                (
                    "empty apps",
                    {
                        "version": 1,
                        "product": "cloud",
                        "apps": [],
                        "startProxy": False,
                    },
                ),
                (
                    "illegal product",
                    {
                        "version": 1,
                        "product": "portal",
                        "apps": ["core-shell"],
                        "startProxy": False,
                    },
                ),
            )
            for name, payload in invalid_cases:
                with self.subTest(name=name):
                    serialized = payload if isinstance(payload, str) else json.dumps(payload)
                    path.write_text(serialized, encoding="utf-8")
                    self.assertIsNone(
                        load_state(context, session_key="tab-a", state_dir=state_dir)
                    )

    def test_render_frontend_menu_highlights_last_start_as_final_item(self) -> None:
        state_cls = getattr(zs_start, "FrontendStartState", None)
        self.assertTrue(callable(state_cls))
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )
        last_state = state_cls(
            product="cloud",
            apps=("core-shell", "network-service"),
            start_proxy=False,
        )
        output = TtyStringIO()

        with patch.object(zs_start, "clear_screen"), patch("sys.stdout", output):
            zs_start.render_frontend_menu(context, 3, last_state=last_state)

        rendered = output.getvalue()
        self.assertIn("上一次启动", rendered)
        self.assertIn("\033[33;1m上一次启动", rendered)
        self.assertIn(
            "pnpm start:cloud --apps core-shell,network-service --proxy=false",
            rendered,
        )
        self.assertGreater(rendered.rfind("上一次启动"), rendered.rfind("ZNS"))

    def test_render_frontend_menu_exposes_install_shortcut_without_list_item(self) -> None:
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )
        output = io.StringIO()

        with patch.object(zs_start, "clear_screen"), patch("sys.stdout", output):
            zs_start.render_frontend_menu(context, 3)

        rendered = output.getvalue()
        self.assertIn("[i] 修复依赖", rendered)
        self.assertNotIn("修复前端依赖", rendered)
        self.assertNotIn(
            "pnpm install --offline --frozen-lockfile --ignore-scripts",
            rendered,
        )

    def test_render_cloud_bff_menu_exposes_install_shortcut(self) -> None:
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )
        target = zs_start.Target(
            1,
            "http://172.20.1.1:8080",
            "172.20.1.1",
            "当前",
            True,
        )
        output = io.StringIO()

        with patch.object(zs_start, "clear_screen"), patch("sys.stdout", output):
            zs_start.render_menu([target], 0, context)

        self.assertIn("[i] 修复依赖", output.getvalue())

    def test_choose_frontend_action_defaults_to_last_start(self) -> None:
        chooser = getattr(zs_start, "choose_frontend_action", None)
        state_cls = getattr(zs_start, "FrontendStartState", None)
        self.assertTrue(callable(chooser))
        self.assertTrue(callable(state_cls))
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )
        last_state = state_cls(
            product="cloud",
            apps=("core-shell", "network-service"),
            start_proxy=False,
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            return_value="enter",
        ):
            action = chooser(context, last_state=last_state)

        self.assertEqual(action, "last")

    def test_choose_frontend_action_cycles_down_from_last_start_to_default(self) -> None:
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )
        last_state = zs_start.FrontendStartState(
            product="cloud",
            apps=("core-shell", "network-service"),
            start_proxy=True,
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            side_effect=["down", "enter"],
        ):
            action = zs_start.choose_frontend_action(context, last_state=last_state)

        self.assertEqual(action, "default")

    def test_choose_frontend_action_supports_install_shortcut(self) -> None:
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            side_effect=["install", "enter"],
        ):
            action = zs_start.choose_frontend_action(context)

        self.assertEqual(action, "install:default")

    def test_choose_frontend_install_shortcut_targets_highlighted_product(self) -> None:
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            side_effect=["down", "install"],
        ):
            action = zs_start.choose_frontend_action(context)

        self.assertEqual(action, "install:cloud")

    def test_choose_frontend_install_shortcut_targets_last_started_apps(self) -> None:
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )
        last_state = zs_start.FrontendStartState(
            product="cloud",
            apps=("core-shell", "settings"),
            start_proxy=True,
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            return_value="install",
        ):
            action = zs_start.choose_frontend_action(context, last_state=last_state)

        self.assertEqual(action, "install:last")

    def test_choose_frontend_action_cycles_only_through_visible_start_items(self) -> None:
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            side_effect=["down", "down", "down", "enter"],
        ):
            action = zs_start.choose_frontend_action(context)

        self.assertEqual(action, "default")

    def test_start_frontend_install_action_prepares_dependencies_without_starting_service(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root, dependencies_ready=True)
            context = zs_start.RepoContext(root, root, "feature")

            with patch.object(
                zs_start,
                "choose_frontend_action",
                return_value="install:cloud",
            ), patch.object(
                zs_start,
                "install_frontend_dependencies",
                return_value=0,
                create=True,
            ) as install, patch.object(zs_start.subprocess, "run") as run:
                result = zs_start.start_frontend(context)

            self.assertEqual(result, 0)
            install.assert_called_once_with(context, product="cloud")
            run.assert_not_called()

    def test_start_frontend_keeps_dependency_error_visible_until_acknowledged(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root, dependencies_ready=True)
            context = zs_start.RepoContext(root, root, "feature")
            errors = io.StringIO()

            with patch.object(
                zs_start,
                "choose_frontend_action",
                return_value="cloud",
            ), patch.object(
                zs_start,
                "ensure_frontend_dependencies",
                side_effect=zs_start.ZsStartError("缺少 @tailwindcss/postcss"),
            ), patch.object(
                zs_start,
                "wait_for_frontend_acknowledgement",
                create=True,
            ) as wait, patch.object(zs_start.subprocess, "run") as run, patch(
                "sys.stderr",
                errors,
            ):
                try:
                    result = zs_start.start_frontend(context)
                except zs_start.ZsStartError:
                    result = None

            self.assertEqual(result, 1)
            self.assertIn("前端启动失败", errors.getvalue())
            self.assertIn("缺少 @tailwindcss/postcss", errors.getvalue())
            self.assertIn("修复前端依赖", errors.getvalue())
            wait.assert_called_once_with()
            run.assert_not_called()

    def test_start_frontend_injects_state_path_into_normal_launcher_env(self) -> None:
        launcher = getattr(zs_start, "start_frontend", None)
        self.assertTrue(callable(launcher))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root, dependencies_ready=True)
            state_path = Path(directory) / "sessions/frontend.json"
            context = zs_start.RepoContext(root, root, "feature")

            with patch.object(
                zs_start,
                "choose_frontend_action",
                return_value="cloud",
                create=True,
            ), patch.object(
                zs_start,
                "frontend_start_state_path",
                return_value=state_path,
                create=True,
            ), patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start,
                "set_terminal_title",
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:cloud"], 0),
            ) as run, patch.dict(zs_start.os.environ, {"EXISTING_ENV": "kept"}), patch(
                "sys.stdout",
                io.StringIO(),
            ):
                result = launcher(context)

            self.assertEqual(result, 0)
            run.assert_called_once()
            self.assertEqual(
                run.call_args.args[0],
                [
                    "bun",
                    "--preload",
                    str(zs_start.FRONTEND_MEMORY_PRELOAD),
                    "./scripts/start.ts",
                    "--product",
                    "cloud",
                ],
            )
            self.assertEqual(run.call_args.kwargs["cwd"], root)
            child_env = run.call_args.kwargs.get("env")
            self.assertIsNotNone(child_env)
            self.assertEqual(
                child_env["ZS_START_FRONTEND_STATE_PATH"],
                str(state_path),
            )
            self.assertEqual(
                child_env[zs_start.FRONTEND_AUTO_PREPARE_ENV_KEY],
                "1",
            )
            self.assertEqual(
                child_env[zs_start.FRONTEND_PREPARE_SCRIPT_ENV_KEY],
                str(zs_start.SCRIPT_PATH),
            )
            self.assertEqual(child_env["EXISTING_ENV"], "kept")
            self.assertEqual(child_env[zs_start.PROJECT_ROOT_ENV_KEY], str(context.primary_root))

    def test_frontend_memory_preload_records_modules_from_start_summary(self) -> None:
        preload = getattr(zs_start, "FRONTEND_MEMORY_PRELOAD", None)
        self.assertIsInstance(preload, Path)

        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            state_path = temp_dir / "sessions/frontend.json"
            fixture = temp_dir / "emit-start-summary.mjs"
            fixture.write_text(
                """
console.log("\\u001b[32m  ✓ MF Hub Proxy :3200\\u001b[0m");
console.log("  ✓ core-shell :3000");
console.log("  ✓ network-service :3021");
console.log("  All services started! 🚀");
""".strip(),
                encoding="utf-8",
            )
            child_env = os.environ.copy()
            child_env[zs_start.FRONTEND_STATE_ENV_KEY] = str(state_path)

            result = subprocess.run(
                [
                    "bun",
                    "--preload",
                    str(preload),
                    str(fixture),
                    "--product",
                    "cloud",
                ],
                cwd=temp_dir,
                env=child_env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(state_path.read_text(encoding="utf-8")),
                {
                    "version": 1,
                    "product": "cloud",
                    "apps": ["core-shell", "network-service"],
                    "startProxy": True,
                },
            )

    def test_frontend_preload_prepares_selected_apps_before_services_start(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            state_path = temp_dir / "sessions/frontend.json"
            prepared_path = temp_dir / "prepared.json"
            prepare_script = temp_dir / "prepare.py"
            prepare_script.write_text(
                """
import json
import os
import sys
from pathlib import Path

Path(os.environ["PREPARED_PATH"]).write_text(
    json.dumps(sys.argv[1:]),
    encoding="utf-8",
)
""".strip(),
                encoding="utf-8",
            )
            fixture = temp_dir / "emit-before-start.mjs"
            fixture.write_text(
                """
import { existsSync } from "node:fs";

console.log("  🚀 Starting 3 service(s)...");
console.log("  ────────────────────────────────");
console.log("  ✓ MF Hub Proxy :3200");
console.log("  ✓ core-shell :3000");
console.log("  ✓ settings :7003");
console.log("  ────────────────────────────────");
console.log(`PREPARED_BEFORE_START=${existsSync(process.env.PREPARED_PATH)}`);
console.log("  Starting: core-shell");
console.log("  All services started! 🚀");
""".strip(),
                encoding="utf-8",
            )
            child_env = os.environ.copy()
            child_env[zs_start.FRONTEND_STATE_ENV_KEY] = str(state_path)
            child_env[zs_start.FRONTEND_AUTO_PREPARE_ENV_KEY] = "1"
            child_env[zs_start.FRONTEND_PREPARE_SCRIPT_ENV_KEY] = str(prepare_script)
            child_env["PREPARED_PATH"] = str(prepared_path)

            result = subprocess.run(
                [
                    "bun",
                    "--preload",
                    str(zs_start.FRONTEND_MEMORY_PRELOAD),
                    str(fixture),
                    "--product",
                    "cloud",
                ],
                cwd=temp_dir,
                env=child_env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("PREPARED_BEFORE_START=true", result.stdout)
            self.assertEqual(
                json.loads(prepared_path.read_text(encoding="utf-8")),
                [
                    zs_start.FRONTEND_PREPARE_COMMAND,
                    "--product",
                    "cloud",
                    "--apps",
                    "core-shell,settings",
                ],
            )

    def test_start_frontend_last_command_uses_recorded_apps_without_native_selector(
        self,
    ) -> None:
        launcher = getattr(zs_start, "start_frontend", None)
        self.assertTrue(callable(launcher))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            self.create_frontend(root, dependencies_ready=True)
            state_path = Path(directory) / "sessions/frontend.json"
            state_path.parent.mkdir(parents=True)
            state_path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "product": "cloud",
                        "apps": ["core-shell", "network-service"],
                        "startProxy": False,
                    }
                ),
                encoding="utf-8",
            )
            context = zs_start.RepoContext(root, root, "feature")
            output = io.StringIO()

            with patch.object(
                zs_start,
                "choose_frontend_action",
                return_value="last",
                create=True,
            ), patch.object(
                zs_start,
                "frontend_start_state_path",
                return_value=state_path,
                create=True,
            ), patch.object(zs_start.shutil, "which", return_value="/opt/tool"), patch.object(
                zs_start,
                "ensure_frontend_dependencies",
            ) as ensure, patch.object(
                zs_start,
                "set_terminal_title",
            ), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    [
                        "pnpm",
                        "start:cloud",
                        "--apps",
                        "core-shell,network-service",
                        "--proxy=false",
                    ],
                    0,
                ),
            ) as run, patch("sys.stdout", output):
                result = launcher(context)

            self.assertEqual(result, 0)
            ensure.assert_called_once_with(
                context,
                product="cloud",
                apps=("core-shell", "network-service"),
            )
            run.assert_called_once_with(
                [
                    "pnpm",
                    "start:cloud",
                    "--apps",
                    "core-shell,network-service",
                    "--proxy=false",
                ],
                cwd=root,
                env=unittest.mock.ANY,
            )
            self.assertNotIn("原生选择器", output.getvalue())

    def test_start_zns_bff_runs_from_selected_worktree(self) -> None:
        launcher = getattr(zs_start, "start_zns_bff", None)
        self.assertTrue(callable(launcher))

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "feature"
            zns_bff_dir = self.create_zns_bff(root, dependencies_ready=True)
            context = zs_start.RepoContext(root, root, "feature")

            with patch.object(
                zs_start,
                "choose_zns_bff_action",
                return_value="start",
                create=True,
            ), patch.object(zs_start, "set_terminal_title"), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:dev"], 0),
            ) as run, patch("sys.stdout", io.StringIO()):
                result = launcher(context)

            self.assertEqual(result, 0)
            self.assertTrue((zns_bff_dir / ".env").exists())
            run.assert_called_once_with(["pnpm", "start:dev"], cwd=zns_bff_dir)

    def test_start_zns_bff_can_switch_worktree_before_starting(self) -> None:
        launcher = getattr(zs_start, "start_zns_bff", None)
        self.assertTrue(callable(launcher))

        with tempfile.TemporaryDirectory() as directory:
            temp_dir = Path(directory)
            primary_root = temp_dir / "main"
            feature_root = temp_dir / "feature"
            self.create_zns_bff(primary_root, dependencies_ready=True)
            feature_bff = self.create_zns_bff(feature_root, dependencies_ready=True)
            primary = zs_start.RepoContext(primary_root, primary_root, "main")
            feature = zs_start.RepoContext(feature_root, primary_root, "feature")

            with patch.object(
                zs_start,
                "choose_zns_bff_action",
                side_effect=["switch", "start"],
                create=True,
            ), patch.object(
                zs_start,
                "choose_repo_context",
                return_value=feature,
            ), patch.object(zs_start, "set_terminal_title"), patch.object(
                zs_start.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(["pnpm", "start:dev"], 0),
            ) as run, patch("sys.stdout", io.StringIO()):
                result = launcher(primary)

            self.assertEqual(result, 0)
            run.assert_called_once_with(["pnpm", "start:dev"], cwd=feature_bff)

    def test_parse_worktree_arg_resolves_relative_path_from_current_directory(self) -> None:
        cwd = Path("/workspace/project")

        worktree = zs_start.parse_worktree_arg(
            ["cloud:bff", "--worktree", ".worktrees/feature"],
            cwd=cwd,
        )

        self.assertEqual(worktree, Path("/workspace/project/.worktrees/feature"))

    def test_parse_worktree_arg_supports_fe_and_zns_bff(self) -> None:
        cwd = Path("/workspace/project")
        expected = Path("/workspace/project/.worktrees/feature")

        for command in ("fe", "zns:bff"):
            with self.subTest(command=command):
                try:
                    worktree = zs_start.parse_worktree_arg(
                        [command, "--worktree", ".worktrees/feature"],
                        cwd=cwd,
                    )
                except zs_start.ZsStartError:
                    worktree = None

                self.assertEqual(worktree, expected)

    def test_main_dispatches_fe_command(self) -> None:
        root = Path("/workspace/project")
        context = zs_start.RepoContext(root, root, "main")

        with patch.object(
            zs_start.sys,
            "argv",
            ["zs-start", "fe"],
        ), patch.object(
            zs_start,
            "resolve_repo_context",
            return_value=context,
        ), patch.object(
            zs_start,
            "start_frontend",
            return_value=0,
            create=True,
        ) as start_frontend, patch.object(zs_start, "start_cloud_bff") as start_bff:
            result = zs_start.main()

        self.assertEqual(result, 0)
        start_frontend.assert_called_once_with(context)
        start_bff.assert_not_called()

    def test_main_dispatches_internal_frontend_prepare_command(self) -> None:
        root = Path("/workspace/project")
        context = zs_start.RepoContext(root, root, "main")

        with patch.object(
            zs_start.sys,
            "argv",
            [
                "zs-start",
                zs_start.FRONTEND_PREPARE_COMMAND,
                "--product",
                "cloud",
                "--apps",
                "core-shell,settings",
            ],
        ), patch.object(zs_start.Path, "cwd", return_value=root), patch.object(
            zs_start,
            "resolve_repo_context",
            return_value=context,
        ) as resolve, patch.object(
            zs_start,
            "prepare_frontend_scope",
            create=True,
        ) as prepare:
            result = zs_start.main()

        self.assertEqual(result, 0)
        resolve.assert_called_once_with(requested_worktree=root)
        prepare.assert_called_once_with(
            context,
            product="cloud",
            apps=("core-shell", "settings"),
        )

    def test_main_dispatches_zns_bff_command(self) -> None:
        root = Path("/workspace/project")
        context = zs_start.RepoContext(root, root, "main")

        with patch.object(
            zs_start.sys,
            "argv",
            ["zs-start", "zns:bff"],
        ), patch.object(
            zs_start,
            "resolve_repo_context",
            return_value=context,
        ), patch.object(
            zs_start,
            "start_zns_bff",
            return_value=0,
            create=True,
        ) as start_zns_bff, patch.object(zs_start, "start_cloud_bff") as start_cloud_bff:
            result = zs_start.main()

        self.assertEqual(result, 0)
        start_zns_bff.assert_called_once_with(context)
        start_cloud_bff.assert_not_called()

    def test_main_without_arguments_prints_help_and_returns_success(self) -> None:
        output = io.StringIO()

        with patch.object(zs_start.sys, "argv", ["zs-start"]), patch.object(
            zs_start.sys.stdin,
            "isatty",
            return_value=False,
        ), patch.object(
            zs_start,
            "resolve_repo_context",
        ) as resolve_context, patch("sys.stdout", output):
            result = zs_start.main()

        self.assertEqual(result, 0)
        self.assertIn("ZStack 本地开发服务启动器", output.getvalue())
        resolve_context.assert_not_called()

    def test_main_without_arguments_dispatches_selected_command_on_tty(self) -> None:
        root = Path("/workspace/project")
        context = zs_start.RepoContext(root, root, "main")

        with patch.object(zs_start.sys, "argv", ["zs-start"]), patch.object(
            zs_start.sys.stdin,
            "isatty",
            return_value=True,
        ), patch.object(
            zs_start,
            "choose_command_from_help",
            return_value="zns:bff",
            create=True,
        ) as choose_command, patch.object(
            zs_start,
            "resolve_repo_context",
            return_value=context,
        ), patch.object(
            zs_start,
            "start_zns_bff",
            return_value=0,
        ) as start_zns_bff, patch.object(zs_start, "start_cloud_bff") as start_cloud_bff:
            result = zs_start.main()

        self.assertEqual(result, 0)
        choose_command.assert_called_once_with()
        start_zns_bff.assert_called_once_with(context)
        start_cloud_bff.assert_not_called()

    def test_main_help_flag_prints_help_without_resolving_repository(self) -> None:
        output = io.StringIO()

        with patch.object(zs_start.sys, "argv", ["zs-start", "--help"]), patch.object(
            zs_start,
            "choose_command_from_help",
            create=True,
        ) as choose_command, patch.object(
            zs_start,
            "resolve_repo_context",
        ) as resolve_context, patch("sys.stdout", output):
            result = zs_start.main()

        self.assertEqual(result, 0)
        self.assertIn("fe", output.getvalue())
        choose_command.assert_not_called()
        resolve_context.assert_not_called()

    def test_invalid_arguments_print_error_and_help(self) -> None:
        output = io.StringIO()
        errors = io.StringIO()

        with patch.object(zs_start.sys, "argv", ["zs-start", "unknown"]), patch(
            "sys.stdout",
            output,
        ), patch("sys.stderr", errors):
            result = zs_start.main()

        self.assertEqual(result, 2)
        self.assertIn("无法识别的参数", errors.getvalue())
        self.assertIn("可用命令", output.getvalue())

    def test_usage_renders_documented_help_sections(self) -> None:
        output = io.StringIO()

        with patch("sys.stdout", output):
            zs_start.usage()

        rendered = output.getvalue()
        for expected in (
            "ZStack 本地开发服务启动器",
            "用法",
            "可用命令",
            "fe",
            "选择默认入口或 Cloud/ZNS 产品并启动前端模块",
            "cloud:bff",
            "选择管理节点并启动 Cloud BFF",
            "zns:bff",
            "启动 ZNS BFF",
            "通用选项",
            "-w, --worktree <path>",
            "-h, --help",
            "示例",
            "zs-start fe -w .worktrees/zstac-12345",
        ):
            self.assertIn(expected, rendered)
        self.assertNotIn("交互提示", rendered)

    def test_selected_help_command_keeps_plain_layout_without_extra_hint(self) -> None:
        static_output = io.StringIO()
        selected_output = io.StringIO()

        with patch.object(zs_start, "color_enabled", return_value=True), patch(
            "sys.stdout",
            static_output,
        ):
            zs_start.print_help()
        with patch.object(zs_start, "color_enabled", return_value=True), patch(
            "sys.stdout",
            selected_output,
        ):
            try:
                zs_start.print_help("cloud:bff")
            except TypeError:
                pass

        ansi_pattern = re.compile(r"\x1b\[[0-9;]*m")
        selected = selected_output.getvalue()
        self.assertEqual(
            ansi_pattern.sub("", selected),
            ansi_pattern.sub("", static_output.getvalue()),
        )
        self.assertIn("\x1b[7;1mcloud:bff", selected)
        self.assertNotIn("↑/↓", selected)
        self.assertNotIn("Enter", selected)

    def test_choose_command_from_help_moves_down_and_selects_command(self) -> None:
        chooser = getattr(zs_start, "choose_command_from_help", None)
        self.assertTrue(callable(chooser))

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "print_help",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            side_effect=["down", "enter"],
        ), patch(
            "sys.stdout",
            TtyStringIO(),
        ):
            command = chooser()

        self.assertEqual(command, "cloud:bff")

    def test_choose_command_from_help_redraws_only_its_output_region(self) -> None:
        output = TtyStringIO()

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "read_key",
            side_effect=["down", "enter"],
        ), patch.object(zs_start, "clear_screen") as clear_screen, patch(
            "sys.stdout",
            output,
        ):
            command = zs_start.choose_command_from_help()

        self.assertEqual(command, "cloud:bff")
        clear_screen.assert_not_called()
        rendered = output.getvalue()
        self.assertEqual(rendered.count("\x1b[s"), 1)
        self.assertEqual(rendered.count("\x1b[u\x1b[J"), 2)
        self.assertNotIn("\x1b[2J\x1b[H", rendered)

    def test_choose_command_from_help_escape_returns_without_command(self) -> None:
        chooser = getattr(zs_start, "choose_command_from_help", None)
        self.assertTrue(callable(chooser))

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "print_help",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            return_value="escape",
        ), patch(
            "sys.stdout",
            TtyStringIO(),
        ):
            command = chooser()

        self.assertIsNone(command)

    def test_read_key_maps_right_arrow_and_ignores_removed_shortcuts(self) -> None:
        with patch.object(zs_start.os, "read", return_value=b"\x1b"), patch.object(
            zs_start, "read_escape_tail", return_value="C"
        ):
            self.assertEqual(zs_start.read_key(), "right")

        with patch.object(zs_start.os, "read", return_value=b"o"):
            self.assertEqual(zs_start.read_key(), "")

        with patch.object(zs_start.os, "read", return_value=b"v"):
            self.assertEqual(zs_start.read_key(), "")

        with patch.object(zs_start.os, "read", return_value=b"w"):
            self.assertEqual(zs_start.read_key(), "switch")

        with patch.object(zs_start.os, "read", return_value=b"i"):
            self.assertEqual(zs_start.read_key(), "install")

    def test_render_frontend_menu_lists_default_cloud_and_zns_commands(self) -> None:
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )
        output = io.StringIO()

        with patch.object(zs_start, "clear_screen"), patch("sys.stdout", output):
            zs_start.render_frontend_menu(context, 0)

        rendered = output.getvalue()
        for expected in (
            "选择方式",
            "默认启动器",
            "pnpm start",
            "Cloud",
            "pnpm start:cloud",
            "ZNS",
            "pnpm start:zns",
        ):
            self.assertIn(expected, rendered)
        self.assertNotIn("pnpm start 当前默认进入 Cloud", rendered)

    def test_choose_frontend_action_selects_cloud_with_keyboard(self) -> None:
        chooser = getattr(zs_start, "choose_frontend_action", None)
        self.assertTrue(callable(chooser))
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            side_effect=["down", "enter"],
        ):
            action = chooser(context)

        self.assertEqual(action, "cloud")

    def test_choose_frontend_action_selects_zns_with_keyboard(self) -> None:
        chooser = getattr(zs_start, "choose_frontend_action", None)
        self.assertTrue(callable(chooser))
        context = zs_start.RepoContext(
            Path("/workspace/feature"),
            Path("/workspace/project"),
            "feature",
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            side_effect=["down", "down", "enter"],
        ):
            action = chooser(context)

        self.assertEqual(action, "zns")

    def test_choose_frontend_action_can_open_worktree_switcher(self) -> None:
        chooser = getattr(zs_start, "choose_frontend_action", None)
        self.assertTrue(callable(chooser))
        context = zs_start.RepoContext(
            Path("/workspace/project"),
            Path("/workspace/project"),
            "main",
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_frontend_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            return_value="switch",
        ):
            action = chooser(context)

        self.assertEqual(action, "switch")

    def test_choose_zns_bff_action_supports_start_and_worktree_switch(self) -> None:
        chooser = getattr(zs_start, "choose_zns_bff_action", None)
        self.assertTrue(callable(chooser))
        context = zs_start.RepoContext(
            Path("/workspace/project"),
            Path("/workspace/project"),
            "main",
        )

        for key, expected in (("enter", "start"), ("switch", "switch")):
            with self.subTest(key=key), patch.object(
                zs_start.termios,
                "tcgetattr",
                return_value=[],
            ), patch.object(zs_start.termios, "tcsetattr"), patch.object(
                zs_start.tty,
                "setcbreak",
            ), patch.object(zs_start, "render_zns_bff_menu"), patch.object(
                zs_start,
                "clear_screen",
            ), patch.object(zs_start, "read_key", return_value=key):
                action = chooser(context)

            self.assertEqual(action, expected)

    def test_choose_with_keys_opens_browser_after_double_right(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="开发机",
            active=True,
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios, "tcsetattr"
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start, "render_menu"
        ), patch.object(
            zs_start, "clear_screen"
        ), patch.object(
            zs_start, "read_key", side_effect=["right", "right", "escape"]
        ), patch.object(
            zs_start.time, "monotonic", side_effect=[1.0, 1.2]
        ), patch.object(zs_start.webbrowser, "open") as open_browser:
            with self.assertRaises(KeyboardInterrupt):
                zs_start.choose_with_keys([target])

        open_browser.assert_called_once_with("http://172.26.1.4:5000")

    def test_choose_with_keys_supports_install_shortcut(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="开发机",
            active=True,
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios,
            "tcsetattr",
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start,
            "render_menu",
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start,
            "read_key",
            return_value="install",
        ):
            action = zs_start.choose_with_keys([target])

        self.assertEqual(action, ("install", -1))

    def test_main_menu_delete_is_ignored_and_edit_opens_target_editor(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="开发机",
            active=True,
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios, "tcsetattr"
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start, "render_menu"
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start, "read_key", side_effect=["delete", "edit"]
        ):
            action = zs_start.choose_with_keys([target])

        self.assertEqual(action, ("edit", 0))

    def test_main_menu_up_from_first_target_wraps_to_add_item(self) -> None:
        root = Path("/workspace/project")
        context = zs_start.RepoContext(root, root, "main")
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="开发机",
            active=True,
        )

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios, "tcsetattr"
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start, "render_menu"
        ) as render, patch.object(zs_start, "clear_screen"), patch.object(
            zs_start, "read_key", side_effect=["up", "enter"]
        ):
            action = zs_start.choose_with_keys([target], context=context)

        self.assertEqual(action, ("add", -1))
        self.assertEqual(render.call_args_list[-1].args[1], 1)

    def test_main_menu_w_opens_worktree_switcher(self) -> None:
        root = Path("/workspace/project")
        context = zs_start.RepoContext(root, root, "main")
        target = zs_start.Target(1, "http://172.20.1.1:8080", "172.20.1.1", "当前", True)

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios, "tcsetattr"
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start, "render_menu"
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start, "read_key", return_value="switch"
        ):
            action = zs_start.choose_with_keys([target], context=context)

        self.assertEqual(action, ("switch", -1))

    def test_main_menu_keeps_active_target_as_initial_selection(self) -> None:
        root = Path("/workspace/project")
        context = zs_start.RepoContext(root, root, "main")
        targets = [
            zs_start.Target(1, "http://172.20.1.1:8080", "172.20.1.1", "候选", False),
            zs_start.Target(3, "http://172.20.1.2:8080", "172.20.1.2", "当前", True),
        ]

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios, "tcsetattr"
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start, "render_menu"
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start, "read_key", return_value="enter"
        ):
            action = zs_start.choose_with_keys(targets, context=context)

        self.assertEqual(action, ("select", 1))

    def test_choose_repo_context_defaults_to_current_worktree(self) -> None:
        primary_root = Path("/workspace/project")
        feature_root = Path("/workspace/feature")
        primary = zs_start.RepoContext(primary_root, primary_root, "main")
        feature = zs_start.RepoContext(feature_root, primary_root, "feature")

        with patch.object(zs_start, "list_repo_contexts", return_value=[primary, feature]), patch.object(
            zs_start.termios, "tcgetattr", return_value=[]
        ), patch.object(zs_start.termios, "tcsetattr"), patch.object(
            zs_start.tty, "setcbreak"
        ), patch.object(zs_start, "render_worktree_menu") as render, patch.object(
            zs_start, "clear_screen"
        ), patch.object(zs_start, "read_key", return_value="enter"), patch.object(
            zs_start, "remember_repo_context", create=True
        ) as remember:
            selected = zs_start.choose_repo_context(feature)

        self.assertEqual(selected, feature)
        render.assert_called_once_with([primary, feature], 1, feature_root)
        remember.assert_called_once_with(feature)

    def test_choose_edit_field_navigates_between_host_and_description(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="开发机",
            active=True,
        )
        draft = zs_start.EditDraft(host=target.host, desc=target.desc)

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios, "tcsetattr"
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start, "render_target_editor"
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start, "read_key", side_effect=["down", "enter"]
        ):
            action = zs_start.choose_edit_field(target, draft)

        self.assertEqual(action, ("edit", 1))

    def test_choose_edit_field_supports_delete_inside_editor(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="开发机",
            active=True,
        )
        draft = zs_start.EditDraft(host=target.host, desc=target.desc)

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios, "tcsetattr"
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start, "render_target_editor"
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start, "read_key", return_value="delete"
        ):
            action = zs_start.choose_edit_field(target, draft, initial=1)

        self.assertEqual(action, ("delete", 1))

    def test_choose_edit_field_confirms_from_last_row(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="开发机",
            active=True,
        )
        draft = zs_start.EditDraft(host="172.20.1.159", desc=target.desc)

        with patch.object(zs_start.termios, "tcgetattr", return_value=[]), patch.object(
            zs_start.termios, "tcsetattr"
        ), patch.object(zs_start.tty, "setcbreak"), patch.object(
            zs_start, "render_target_editor"
        ), patch.object(zs_start, "clear_screen"), patch.object(
            zs_start, "read_key", side_effect=["down", "down", "enter"]
        ):
            action = zs_start.choose_edit_field(target, draft)

        self.assertEqual(action, ("confirm", 2))

    def test_double_right_expires_after_timeout(self) -> None:
        self.assertFalse(
            zs_start.is_double_right(1.0, 1.0 + zs_start.DOUBLE_RIGHT_TIMEOUT + 0.01)
        )

    def test_render_menu_shows_linked_worktree_context_with_section_spacing(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="开发机",
            active=True,
        )
        context = zs_start.RepoContext(
            root=Path("/workspace/project/.worktrees/zstac-1"),
            primary_root=Path("/workspace/project"),
            branch="xfu-dev/5.5.38/zstac-1",
        )

        output = io.StringIO()
        with patch("sys.stdout", output), patch(
            "shutil.get_terminal_size", return_value=(120, 40)
        ):
            zs_start.render_menu([target], 0, context)

        rendered = output.getvalue()
        self.assertIn("╭──", rendered)
        self.assertIn("│ 运行位置  Worktree · zstac-1", rendered)
        self.assertIn("│ 当前分支  xfu-dev/5.5.38/zstac-1", rendered)
        self.assertIn("│ 项目目录  /workspace/project/.worktrees/zstac-1", rendered)
        self.assertNotIn("[ 切换环境 ]", rendered)
        self.assertIn("╯\n\n[↑/↓] 选择", rendered)
        self.assertLess(rendered.index("[e] 编辑"), rendered.index("[Esc] 退出"))
        self.assertLess(rendered.index("[Esc] 退出"), rendered.index("[w] 切换工作树"))
        self.assertLess(rendered.index("[w] 切换工作树"), rendered.index("[→→] 浏览器访问"))
        self.assertLess(rendered.index("[Esc] 退出"), rendered.index("[→→] 浏览器访问"))
        self.assertNotIn("[v] 查看", rendered)
        self.assertNotIn("[Delete] 删除", rendered)
        self.assertNotIn(":5000", rendered)
        self.assertNotIn("运行环境", rendered)
        self.assertNotIn("Cloud BFF 启动", rendered)
        self.assertNotIn("选择后端地址", rendered)

    def test_render_menu_identifies_primary_worktree(self) -> None:
        root = Path("/workspace/project")
        context = zs_start.RepoContext(root=root, primary_root=root, branch="5.5.38")

        output = io.StringIO()
        with patch("sys.stdout", output), patch(
            "shutil.get_terminal_size", return_value=(100, 40)
        ):
            zs_start.render_menu([], 0, context)

        self.assertIn("│ 运行位置  主工作树", output.getvalue())

    def test_render_worktree_menu_marks_actual_current_context(self) -> None:
        primary_root = Path("/workspace/project")
        feature_root = Path("/workspace/project/.worktrees/zstac-87040-d2")
        primary = zs_start.RepoContext(primary_root, primary_root, "main")
        branch = "xfu-dev/feature-5.5.38-policy-rule-scheduler/zstac-87040-d2"
        feature = zs_start.RepoContext(feature_root, primary_root, branch)
        output = io.StringIO()

        with patch("sys.stdout", output), patch(
            "shutil.get_terminal_size", return_value=(160, 40)
        ):
            zs_start.render_worktree_menu([primary, feature], 1, feature_root)

        rendered = output.getvalue()
        self.assertIn("切换工作树", rendered)
        self.assertIn("主工作树", rendered)
        self.assertIn("zstac-87040-d2", rendered)
        self.assertIn(branch, rendered)
        self.assertIn(str(feature_root), rendered)
        self.assertIn("选中项", rendered)
        self.assertNotIn("...", rendered)

    def test_worktree_display_name_compacts_codex_worktree(self) -> None:
        root = Path("/Users/xfu-work/.codex/worktrees/9c8b/zstack-ui-next-dev")
        context = zs_start.RepoContext(root, Path("/workspace/project"), "detached@03589f1181")

        self.assertEqual(zs_start.worktree_display_name(context), "Codex · 9c8b")

    def test_wrap_text_to_width_preserves_long_content_without_ellipsis(self) -> None:
        text = "/workspace/project/.worktrees/zstac-87040-d2"

        lines = zs_start.wrap_text_to_width(text, 16)

        self.assertEqual("".join(lines), text)
        self.assertTrue(all(zs_start.display_width(line) <= 16 for line in lines))

    def test_color_ignores_global_no_color_for_zs_start(self) -> None:
        output = TtyStringIO()
        with patch("sys.stdout", output), patch.dict(
            zs_start.os.environ,
            {"NO_COLOR": "1"},
            clear=False,
        ):
            zs_start.os.environ.pop("ZS_START_NO_COLOR", None)
            rendered = zs_start.color("重点", "36;1")

        self.assertEqual(rendered, "\033[36;1m重点\033[0m")

    def test_zs_start_specific_no_color_disables_color(self) -> None:
        output = TtyStringIO()
        with patch("sys.stdout", output), patch.dict(
            zs_start.os.environ,
            {"ZS_START_NO_COLOR": "1"},
            clear=False,
        ):
            rendered = zs_start.color("重点", "36;1")

        self.assertEqual(rendered, "重点")

    def test_render_menu_keeps_full_description_when_terminal_is_wide(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="admin-ADMIN@test-qa｜开发机",
            active=False,
        )
        output = io.StringIO()
        with patch("sys.stdout", output), patch(
            "shutil.get_terminal_size", return_value=(120, 40)
        ):
            zs_start.render_menu([target], 0)

        self.assertIn("admin-ADMIN@test-qa｜开发机", output.getvalue())

    def test_render_menu_rows_do_not_exceed_terminal_width(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="admin-ADMIN@test-qa｜开发机",
            active=False,
        )

        output = io.StringIO()
        with patch("sys.stdout", output), patch(
            "shutil.get_terminal_size", return_value=(80, 40)
        ):
            zs_start.render_menu([target], 0)

        row = next(line for line in output.getvalue().splitlines() if "172.26.1.4" in line)
        self.assertLessEqual(zs_start.display_width(row), 78)

    def test_delete_target_removes_description_and_server_line(self) -> None:
        lines = [
            "# 开发机",
            "ZS_MN_SERVER=http://172.25.15.205:8080",
            "# admin-ADMIN@test-qa｜开发机",
            "# ZS_MN_SERVER=http://172.26.1.4:8080",
            "ZS_MYSQL_HOST=172.25.15.205",
        ]
        targets = zs_start.parse_targets(lines)

        next_cursor, updated = zs_start.delete_target(lines, targets, targets[1])

        self.assertEqual(next_cursor, 0)
        self.assertNotIn("# admin-ADMIN@test-qa｜开发机", updated)
        self.assertNotIn("# ZS_MN_SERVER=http://172.26.1.4:8080", updated)
        self.assertIn("ZS_MN_SERVER=http://172.25.15.205:8080", updated)

    def test_delete_active_target_selects_next_available_target(self) -> None:
        lines = [
            "# 开发机",
            "ZS_MN_SERVER=http://172.25.15.205:8080",
            "# 开发机",
            "# ZS_MN_SERVER=http://172.20.1.164:8080",
            "ZS_MYSQL_HOST=172.25.15.205",
            "ZOPS_SERVER=http://172.25.15.205:10010 # comment",
        ]
        targets = zs_start.parse_targets(lines)

        next_cursor, updated = zs_start.delete_target(lines, targets, targets[0])

        self.assertEqual(next_cursor, 0)
        self.assertNotIn("172.25.15.205:8080", "\n".join(updated))
        self.assertIn("ZS_MN_SERVER=http://172.20.1.164:8080", updated)
        self.assertIn("ZS_MYSQL_HOST=172.20.1.164", updated)
        self.assertIn(
            "ZOPS_SERVER=http://172.20.1.164:10010 # comment",
            updated,
        )

    def test_edit_target_writes_once_only_after_confirmation(self) -> None:
        lines = [
            "# 旧描述",
            "ZS_MN_SERVER=http://172.25.15.205:8080",
            "ZS_MYSQL_HOST=172.25.15.205",
            "ZOPS_SERVER=http://172.25.15.205:10010",
        ]
        with tempfile.TemporaryDirectory() as directory:
            env_path = Path(directory) / ".env"
            with patch.object(
                zs_start,
                "choose_edit_field",
                side_effect=[("edit", 0), ("edit", 1), ("confirm", 2)],
            ) as choose, patch.object(
                zs_start,
                "prompt_host_value",
                return_value="172.20.1.159",
            ), patch.object(
                zs_start,
                "prompt_desc_value",
                return_value="新描述",
            ), patch.object(zs_start, "write_env", wraps=zs_start.write_env) as write:
                cursor = zs_start.edit_target(lines, 0, env_path)

            updated = env_path.read_text(encoding="utf-8")

        self.assertEqual(cursor, 0)
        self.assertEqual(choose.call_count, 3)
        self.assertEqual(write.call_count, 1)
        self.assertIn("# 新描述", updated)
        self.assertIn("ZS_MN_SERVER=http://172.20.1.159:8080", updated)
        self.assertIn("ZS_MYSQL_HOST=172.20.1.159", updated)
        self.assertIn("ZOPS_SERVER=http://172.20.1.159:10010", updated)

    def test_edit_target_discards_draft_when_returning_without_confirmation(self) -> None:
        lines = [
            "# 原描述",
            "ZS_MN_SERVER=http://172.25.15.205:8080",
            "ZS_MYSQL_HOST=172.25.15.205",
        ]
        original = "\n".join(lines) + "\n"
        with tempfile.TemporaryDirectory() as directory:
            env_path = Path(directory) / ".env"
            env_path.write_text(original, encoding="utf-8")
            with patch.object(
                zs_start,
                "choose_edit_field",
                side_effect=[("edit", 0), ("back", 0)],
            ), patch.object(
                zs_start,
                "prompt_host_value",
                return_value="172.20.1.159",
            ), patch.object(zs_start, "write_env", wraps=zs_start.write_env) as write:
                cursor = zs_start.edit_target(lines, 0, env_path)

            current = env_path.read_text(encoding="utf-8")

        self.assertEqual(cursor, 0)
        self.assertEqual(write.call_count, 0)
        self.assertEqual(current, original)

    def test_edit_target_deletes_only_after_editor_confirmation(self) -> None:
        lines = [
            "# 当前地址",
            "ZS_MN_SERVER=http://172.25.15.205:8080",
            "# 待删除",
            "# ZS_MN_SERVER=http://172.20.1.159:8080",
            "ZS_MYSQL_HOST=172.25.15.205",
        ]
        with tempfile.TemporaryDirectory() as directory:
            env_path = Path(directory) / ".env"
            with patch.object(
                zs_start,
                "choose_edit_field",
                return_value=("delete", 0),
            ), patch.object(zs_start, "confirm_delete", return_value=True):
                cursor = zs_start.edit_target(lines, 1, env_path)

            updated = env_path.read_text(encoding="utf-8")

        self.assertEqual(cursor, 0)
        self.assertNotIn("待删除", updated)
        self.assertNotIn("172.20.1.159", updated)
        self.assertIn("ZS_MN_SERVER=http://172.25.15.205:8080", updated)

    def test_render_target_editor_shows_fields_and_editor_only_delete(self) -> None:
        target = zs_start.Target(
            line_index=1,
            value="http://172.26.1.4:8080",
            host="172.26.1.4",
            desc="admin-ADMIN@test-qa｜开发机",
            active=False,
        )
        draft = zs_start.EditDraft(host="172.20.1.159", desc=target.desc)

        output = io.StringIO()
        with patch("sys.stdout", output), patch(
            "shutil.get_terminal_size", return_value=(120, 40)
        ):
            zs_start.render_target_editor(target, draft, selected=2)

        rendered = output.getvalue()
        self.assertIn("编辑后端地址", rendered)
        self.assertIn("[↑/↓] 选择字段", rendered)
        self.assertIn("[Delete] 删除地址", rendered)
        self.assertIn("Host/IP", rendered)
        self.assertIn("172.20.1.159", rendered)
        self.assertIn("已修改", rendered)
        self.assertIn("[ 确认修改 ]", rendered)
        self.assertIn("admin-ADMIN@test-qa｜开发机", rendered)


if __name__ == "__main__":
    unittest.main()
