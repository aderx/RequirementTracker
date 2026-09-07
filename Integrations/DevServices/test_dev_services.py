from __future__ import annotations

import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

import dev_services as services


class ServiceManagementTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dev-services-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.project = self.directory / "project with spaces"
        (self.project / ".git").mkdir(parents=True)
        self.home_patch = patch.object(services.manager, "data_directory", return_value=self.directory / "tool-data")
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)

    def process(self, pid=1100, ppid=1090, command="node ./node_modules/vite/bin/vite.js", **changes):
        original = services.ProcessInfo(os.getuid(), pid, ppid, 1090, 102400, 0, "01:00:00", "ttys001", "S", "Sun Sep 6 10:00:00 2026", command)
        return replace(original, **changes)

    def observation(self, *processes, **changes):
        values = {p.pid: p for p in processes}
        return services.Observation(values, changes.get("directories", {p.pid: str(self.project) for p in processes}),
                                    changes.get("listeners", {}), changes.get("connected", set()),
                                    changes.get("managed", set()), changes.get("warnings", []),
                                    changes.get("cleanup_available", True))

    def plan(self, observation, selected=None, force=False):
        rows = services.service_rows(observation)
        with patch.object(services, "collect_observation", return_value=observation):
            return services.create_plan({"selected": selected or [rows[0]["id"]], "force": force})

    def test_ps_parser_retains_full_command_and_start_identity(self):
        output = f"{os.getuid()} 1100 1090 1090 102400 2.5 01:00:00 ttys001 S Sun Sep  6 10:00:00 2026 node /project with spaces/server.js\n"
        process = services.parse_processes(output)[1100]
        self.assertEqual(process.command, "node /project with spaces/server.js")
        self.assertEqual(process.started, "Sun Sep 6 10:00:00 2026")
        self.assertNotEqual(process.identity, replace(process, started="Mon Sep 7 10:00:00 2026").identity)

    def test_lsof_parser_handles_ipv6_and_cwd_spaces(self):
        result = services.parse_lsof("p1100\nf5\nn[::1]:3000\nf6\nn127.0.0.1:3000\np1101\nfcwd\nn/path with spaces\n")
        self.assertEqual(result[1100], {"[::1]:3000", "127.0.0.1:3000"})
        self.assertEqual(result[1101], {"/path with spaces"})

    def test_launchctl_parser_separates_gui_app_and_managed_service(self):
        self.assertEqual(services.parse_managed("PID Status Label\n1100 0 homebrew.mxcl.redis\n1101 0 application.com.apple.Terminal.1\n- 0 idle.job\n"), {1100})

    def test_service_groups_child_processes_and_aggregates_memory_and_ports(self):
        root, child = self.process(), self.process(1101, 1100, command="node worker.js", rss_kb=51200)
        rows = services.service_rows(self.observation(root, child, listeners={1101: {"*:3000"}}))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["pids"], [1100, 1101])
        self.assertEqual(rows[0]["rssMB"], 150)
        self.assertEqual(rows[0]["ports"], ["*:3000"])

    def test_all_local_projects_are_included_without_zstack_configuration(self):
        other = self.directory / "other-python-project"
        (other / "pyproject.toml").parent.mkdir()
        (other / "pyproject.toml").write_text("[project]\nname='fixture'\n")
        rows = services.service_rows(self.observation(self.process(), self.process(1200, command="python app.py"),
            directories={1100: str(self.project), 1200: str(other)}))
        self.assertEqual({row["project"] for row in rows}, {str(self.project), str(other)})

    def test_native_compiled_development_server_is_detected_by_project_and_port(self):
        row = services.service_rows(self.observation(self.process(command="./target/debug/api"), listeners={1100: {"*:8080"}}))[0]
        self.assertEqual(row["name"], "开发服务")

    def test_old_orphan_without_terminal_connection_or_cpu_is_only_suspected(self):
        row = services.service_rows(self.observation(self.process(ppid=1, tty="??")))[0]
        self.assertTrue(row["suspected"])
        self.assertEqual(row["status"], "疑似残留")
        self.assertIn("需要确认", row["reason"])

    def test_waiting_zs_start_launcher_is_distinct_from_a_running_listener(self):
        root = self.process(command="python /project/.vscode/bin/zs-start.py cloud:bff")
        row = services.service_rows(self.observation(root))[0]
        self.assertEqual(row["status"], "启动入口")
        self.assertFalse(row["suspected"])
        self.assertIn("尚未检测到监听服务", row["reason"])

    def test_active_connection_terminal_recent_child_and_busy_process_are_not_residual(self):
        orphan = self.process(ppid=1, tty="??")
        observations = [
            self.observation(orphan, connected={1100}),
            self.observation(replace(orphan, tty="ttys001")),
            self.observation(replace(orphan, elapsed="00:20")),
            self.observation(orphan, self.process(1101, 1100, elapsed="00:20")),
            self.observation(replace(orphan, cpu=45)),
        ]
        for observation in observations:
            with self.subTest(observation=observation):
                self.assertFalse(services.service_rows(observation)[0]["suspected"])

    def test_managed_redis_is_visible_but_cannot_be_stopped(self):
        observation = self.observation(self.process(command="redis-server 127.0.0.1:6379", ppid=1, tty="??"), managed={1100}, listeners={1100: {"127.0.0.1:6379"}})
        row = services.service_rows(observation)[0]
        self.assertFalse(row["canStop"])
        self.assertFalse(row["suspected"])
        with self.assertRaises(services.ServiceError):
            self.plan(observation)

    def test_desktop_editor_mcp_and_nx_workers_are_excluded(self):
        commands = ["/Applications/Code.app/Contents/MacOS/Electron", "node /project/typescript/lib/tsserver.js",
                    "node ./mcp/server.mjs", "node /mcp-lanhu/dist/server.js", "node node_modules/nx/src/daemon/server/start.js"]
        for command in commands:
            with self.subTest(command=command):
                self.assertEqual(services.service_rows(self.observation(self.process(command=command))), [])

    def test_another_service_scanner_or_management_command_is_excluded(self):
        for command in ("python /app/dev_services.py --list", "python /app/dev_services_manager.py registration-status", "dev-services", "dev-services clean", "python /app/zs_start_manager.py status"):
            self.assertEqual(services.service_rows(self.observation(self.process(command=command))), [])

    def test_other_users_and_zombies_cannot_be_cleaned(self):
        self.assertEqual(services.service_rows(self.observation(self.process(uid=os.getuid() + 1))), [])
        row = services.service_rows(self.observation(self.process(state="Z", rss_kb=0)))[0]
        self.assertFalse(row["canStop"])

    def test_incomplete_observation_disables_cleanup(self):
        row = services.service_rows(self.observation(self.process(), cleanup_available=False))[0]
        self.assertFalse(row["canStop"])

    def test_plan_scopes_descendants_without_terminal_or_other_service_in_same_group(self):
        shell = self.process(1090, 1, "/bin/zsh")
        root, child, unrelated = self.process(), self.process(1101, 1100, "node worker.js"), self.process(1200)
        observation = self.observation(shell, root, child, unrelated)
        plan = self.plan(observation, [root.key])
        self.assertEqual({p["pid"] for p in plan["processes"]}, {1100, 1101})
        self.assertEqual(plan["rssMB"], 200)
        path = services.plan_directory() / (plan["token"] + ".json")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_reused_pid_start_time_or_command_changes_invalidate_entire_plan(self):
        original = self.process()
        plan = self.plan(self.observation(original))
        for process in (replace(original, started="another start"), replace(original, command="node another.js")):
            with patch.object(services, "collect_observation", return_value=self.observation(process)), patch.object(services.os, "kill") as kill:
                with self.assertRaisesRegex(services.ServiceError, "其他进程"):
                    services.execute_plan(plan["token"])
                kill.assert_not_called()

    def test_new_descendant_requires_another_preview(self):
        plan = self.plan(self.observation(self.process()))
        changed = self.observation(self.process(), self.process(1101, 1100, "node worker.js"))
        with patch.object(services, "collect_observation", return_value=changed), patch.object(services.os, "kill") as kill:
            with self.assertRaisesRegex(services.ServiceError, "新的子进程"):
                services.execute_plan(plan["token"])
            kill.assert_not_called()

    def test_expired_plan_and_newly_protected_process_are_rejected(self):
        observation = self.observation(self.process())
        plan = self.plan(observation)
        with self.assertRaisesRegex(services.ServiceError, "过期"):
            services.validate_plan({**plan, "createdAt": time.time() - 301}, observation)
        with self.assertRaises(services.ServiceError):
            services.validate_plan(plan, self.observation(self.process(), managed={1100}))

    def test_normal_stop_signals_only_exact_approved_pids_and_consumes_plan(self):
        root, child, unrelated = self.process(), self.process(1101, 1100, "node worker.js"), self.process(1200)
        observation = self.observation(root, child, unrelated)
        plan = self.plan(observation, [root.key])
        running = observation.processes.copy()
        def signal_process(pid, signum):
            self.assertEqual(signum, signal.SIGTERM)
            running.pop(pid)
        with patch.object(services, "collect_observation", return_value=observation), patch.object(services, "read_processes", side_effect=lambda: running.copy()), patch.object(services.os, "kill", side_effect=signal_process) as kill, patch.object(services.os, "killpg") as killpg:
            result = services.execute_plan(plan["token"])
        self.assertEqual({call.args[0] for call in kill.call_args_list}, {1100, 1101})
        killpg.assert_not_called()
        self.assertEqual(result["remainingPids"], [])
        self.assertEqual(result["stoppedPids"], [1100, 1101])
        self.assertIn(1200, running)
        with self.assertRaises(services.ServiceError):
            services.execute_plan(plan["token"])

    def test_stop_timeout_reports_survivors_without_automatic_force(self):
        observation = self.observation(self.process())
        plan = self.plan(observation)
        with patch.object(services, "collect_observation", return_value=observation), patch.object(services, "read_processes", return_value=observation.processes), patch.object(services.os, "kill") as kill, patch.object(services.time, "monotonic", side_effect=[0, 10]):
            result = services.execute_plan(plan["token"])
        kill.assert_called_once_with(1100, signal.SIGTERM)
        self.assertEqual(result["remainingPids"], [1100])
        self.assertEqual(result["stoppedPids"], [])

    def test_force_is_only_used_in_explicit_force_plan(self):
        observation = self.observation(self.process())
        plan = self.plan(observation, force=True)
        with patch.object(services, "collect_observation", return_value=observation), patch.object(services, "read_processes", side_effect=[observation.processes, {}]), patch.object(services.os, "kill") as kill:
            services.execute_plan(plan["token"])
        kill.assert_called_once_with(1100, signal.SIGKILL)

    def test_cancelled_confirmation_and_noninteractive_cleanup_never_signal(self):
        observation = self.observation(self.process())
        rows = services.service_rows(observation)
        with patch.object(services, "collect_observation", return_value=observation), patch("sys.stdout", io.StringIO()), patch("sys.stdin.isatty", return_value=True), patch("builtins.input", return_value="n"), patch.object(services.os, "kill") as kill:
            self.assertEqual(services.confirm_and_stop(rows), 0)
            kill.assert_not_called()
        with patch.object(services, "collect_observation", return_value=observation), patch("sys.stdout", io.StringIO()), patch("sys.stdin.isatty", return_value=False), patch.object(services.os, "kill") as kill:
            with self.assertRaises(services.ServiceError):
                services.confirm_and_stop(rows)
            kill.assert_not_called()

    def test_services_command_does_not_depend_on_selected_zstack_repository(self):
        with patch.object(services, "cli", return_value=0) as cli, patch("sys.argv", ["dev-services", "--list"]):
            self.assertEqual(services.main(), 0)
        cli.assert_called_once_with(["--list"])

    def test_clean_entry_filters_json_and_does_not_stop_processes(self):
        rows = services.service_rows(self.observation(self.process(ppid=1, tty="??"), self.process(1200)))
        output = io.StringIO()
        with patch.object(services, "snapshot", return_value={"services": rows, "warnings": [], "totalRSSMB": 200}), patch("sys.argv", ["dev-services", "clean", "--json"]), patch("sys.stdout", output), patch.object(services.os, "kill") as kill:
            self.assertEqual(services.main(), 0)
            kill.assert_not_called()
        result = json.loads(output.getvalue())
        self.assertEqual([row["pid"] for row in result["services"]], [1100])
        self.assertEqual(result["totalRSSMB"], 100)

    def test_stop_entry_requires_pid_selection_and_confirmation(self):
        rows = services.service_rows(self.observation(self.process()))
        with patch.object(services, "snapshot", return_value={"services": rows, "warnings": []}), patch.object(services, "confirm_and_stop", return_value=0) as confirm, patch("sys.argv", ["dev-services", "stop", "1100", "--force"]):
            self.assertEqual(services.main(), 0)
        confirm.assert_called_once_with(rows, force=True)

    def test_help_version_and_invalid_arguments_do_not_scan_or_signal(self):
        for arguments, expected in ((["--help"], 0), (["--version"], 0), (["unknown"], 1)):
            with self.subTest(arguments=arguments), patch("sys.argv", ["dev-services"] + arguments), patch("sys.stdout", io.StringIO()), patch("sys.stderr", io.StringIO()), patch.object(services, "snapshot") as scan, patch.object(services.os, "kill") as kill:
                self.assertEqual(services.main(), expected)
                scan.assert_not_called()
                kill.assert_not_called()

    def test_unknown_selected_pid_is_not_accepted(self):
        with patch.object(services, "snapshot", return_value={"services": [], "warnings": []}), patch.object(services.os, "kill") as kill:
            with self.assertRaises(services.ServiceError):
                services.cli(["stop", "9999"])
            kill.assert_not_called()

    def test_plan_token_cannot_reference_other_files(self):
        with self.assertRaises(services.ServiceError):
            services.execute_plan("../../settings")

    def test_common_credentials_are_hidden_in_displayed_commands(self):
        result = services.redacted_command("node app.js --token secret-value --password='private value' https://user:password@example.test")
        self.assertNotIn("secret-value", result)
        self.assertNotIn("private value", result)
        self.assertNotIn("user:password", result)

    def test_real_cleanup_only_terminates_owned_non_listening_fixture_tree(self):
        child_file = self.project / "child.pid"
        code = "import subprocess,time,pathlib,signal,sys; p=subprocess.Popen(['/bin/sleep','60']); signal.signal(signal.SIGTERM, lambda *_: (p.terminate(), p.wait(), sys.exit(0))); pathlib.Path('child.pid').write_text(str(p.pid)); time.sleep(60)"
        fixture = subprocess.Popen([sys.executable, "-B", "-c", code], cwd=self.project, start_new_session=True)
        child_pid = None
        try:
            for _ in range(100):
                if child_file.exists():
                    child_pid = int(child_file.read_text())
                    break
                time.sleep(0.02)
            self.assertIsNotNone(child_pid)
            processes = services.read_processes()
            owned = {pid: processes[pid] for pid in (fixture.pid, child_pid)}
            observation = services.Observation(owned, {fixture.pid: str(self.project)}, {}, set(), set(), [])
            with patch.object(services, "collect_observation", return_value=observation):
                rows = services.service_rows(observation)
                self.assertEqual({pid for row in rows for pid in row["pids"]}, {fixture.pid, child_pid})
                plan = services.create_plan({"selected": [rows[0]["id"]]})
                result = services.execute_plan(plan["token"])
            fixture.wait(timeout=5)
            self.assertEqual(result["remainingPids"], [])
            self.assertEqual(set(result["stoppedPids"]), {fixture.pid, child_pid})
        finally:
            if fixture.poll() is None:
                fixture.terminate()
                fixture.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
