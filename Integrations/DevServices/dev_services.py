"""按实际进程、端口和目录展示开发服务，并按已确认的进程范围清理。"""
from __future__ import annotations

import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

sys.dont_write_bytecode = True
import dev_services_manager as manager


class ServiceError(RuntimeError):
    pass


@dataclass(frozen=True)
class ProcessInfo:
    uid: int
    pid: int
    ppid: int
    pgid: int
    rss_kb: int
    cpu: float
    elapsed: str
    tty: str
    state: str
    started: str
    command: str

    @property
    def identity(self) -> str:
        value = f"{self.uid}\0{self.pid}\0{self.started}\0{self.command}"
        return hashlib.sha256(value.encode()).hexdigest()

    @property
    def key(self) -> str:
        return f"{self.pid}:{self.identity[:16]}"


@dataclass
class Observation:
    processes: dict[int, ProcessInfo]
    directories: dict[int, str]
    listeners: dict[int, set[str]]
    connected: set[int]
    managed: set[int]
    warnings: list[str]
    cleanup_available: bool = True


def read_command(arguments: list[str], *, empty_ok: bool = False) -> str:
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=15,
                                env={**os.environ, "LC_ALL": "C"})
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ServiceError(f"无法执行 {Path(arguments[0]).name}: {error}") from error
    if result.returncode and not (empty_ok and result.returncode == 1 and not result.stderr.strip()):
        raise ServiceError(f"无法读取 {Path(arguments[0]).name} 信息: {result.stderr.strip() or '权限不足或命令失败'}")
    if result.stderr.strip():
        raise ServiceError(f"{Path(arguments[0]).name} 返回了不完整的信息: {result.stderr.strip()}")
    return result.stdout


def parse_processes(output: str) -> dict[int, ProcessInfo]:
    processes = {}
    for line in output.splitlines():
        fields = line.split(None, 14)
        if len(fields) != 15:
            continue
        try:
            process = ProcessInfo(
                *map(int, fields[:5]), float(fields[5]), fields[6], fields[7], fields[8],
                " ".join(fields[9:14]), fields[14],
            )
        except ValueError:
            continue
        processes[process.pid] = process
    return processes


def read_processes() -> dict[int, ProcessInfo]:
    result = parse_processes(read_command([
        "/bin/ps", "-wwaxo", "uid=,pid=,ppid=,pgid=,rss=,pcpu=,etime=,tty=,state=,lstart=,command=",
    ]))
    if os.getpid() not in result:
        raise ServiceError("无法取得完整进程信息，已停止扫描。")
    return result


def parse_lsof(output: str) -> dict[int, set[str]]:
    result: dict[int, set[str]] = {}
    pid = None
    for line in output.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid = int(line[1:])
            result.setdefault(pid, set())
        elif line.startswith("n") and pid is not None:
            result[pid].add(line[1:])
    return result


def parse_managed(output: str) -> set[int]:
    managed = set()
    for line in output.splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and not fields[2].startswith("application."):
            managed.add(int(fields[0]))
    return managed


def runtime_name(command: str) -> str:
    first = command.split(" ", 1)[0]
    name = Path(first).name.lower()
    if re.fullmatch(r"python(?:\d+(?:\.\d+)*)?", name):
        return "python"
    return name


def is_launcher(command: str) -> bool:
    return re.search(r"(?:^|[/ ])zs-start(?:\.py)?\s+(?:fe|cloud:bff|zns:bff)(?:\s|$)", command) is not None


def development_kind(command: str) -> str | None:
    if is_launcher(command):
        return "Cloud BFF" if "cloud:bff" in command else "ZNS BFF" if "zns:bff" in command else "ZStack 前端"
    if re.search(r"(?:^|[/ ])(?:tsc|tsgo|esbuild|cargo|swiftc)(?:[. /]|$)|fork-generate-dts\.js", command):
        return "构建任务"
    for marker, name in (("rsbuild", "Rsbuild"), ("vite", "Vite"), ("webpack", "Webpack"),
                         ("next dev", "Next.js"), ("nest", "Nest"), ("uvicorn", "Uvicorn"),
                         ("gunicorn", "Gunicorn"), ("manage.py runserver", "Django"),
                         ("http.server", "HTTP 服务"), ("start-broker.js", "模块联邦服务")):
        if re.search(r"(?:^|[/ ])" + re.escape(marker) + r"(?:[. /]|$)", command):
            return name
    if re.search(r"\b(?:npm|pnpm|yarn|bun)\b.*\b(?:dev|serve|start|watch|build)(?::[\w-]+)?\b", command):
        return "项目脚本"
    return None


def protected_reason(process: ProcessInfo, observation: Observation) -> str | None:
    if process.uid != os.getuid() or process.pid <= 1:
        return "其他用户或系统进程"
    command = process.command.lower()
    if not is_launcher(process.command):
        if any(name in command for name in ("dev_services.py", "dev_services_manager.py", "zs_start_manager.py")) or re.search(
            r"(?:^|[/ ])dev-services(?:\s|$)", command
        ) or re.search(
            r"(?:^|[/ ])zs-start(?:\.py)?\s+(?:services|clean|project|--help|--version)(?:\s|$)", command
        ):
            return "服务扫描或工具管理进程"
        if any(marker in command for marker in (
            "tsserver", "typingsinstaller", "language-server", "extensionhost", "extension-host",
            "/.vscode/", "/.vscode-server/", "/.codex/", "cua_node", "node_repl", "mcp-server", "mcp_server",
            "/mcp/", "mcp-", "nx/src/daemon", "nx/src/project-graph/plugins/isolation", "--lsp",
        )):
            return "编辑器或开发工具的后台进程"
        if ".app/contents/" in command and "/python.app/contents/" not in command:
            return "桌面应用进程"
    current = process
    seen = set()
    while current.pid not in seen:
        seen.add(current.pid)
        if current.pid in observation.managed:
            return "由系统服务管理器维护"
        parent = observation.processes.get(current.ppid)
        if parent is None or parent.pid <= 1:
            break
        current = parent
    return None


def project_directory(directory: str) -> str | None:
    current = Path(directory.removesuffix(" (deleted)"))
    fallback = None
    for _ in range(14):
        if (current / ".git").exists():
            return str(current)
        if fallback is None and any((current / name).is_file() for name in (
            "package.json", "pyproject.toml", "go.mod", "Cargo.toml", "Package.swift", "pom.xml", "Gemfile",
        )):
            fallback = str(current)
        if current.parent == current or current == Path.home():
            break
        current = current.parent
    return fallback


def collect_observation() -> Observation:
    processes = read_processes()
    warnings = []
    cleanup_available = True
    listeners: dict[int, set[str]] = {}
    connected: set[int] = set()
    managed: set[int] = set()
    for state in ("LISTEN", "ESTABLISHED"):
        try:
            values = parse_lsof(read_command([
                "/usr/sbin/lsof", "-nP", "-a", "-u", str(os.getuid()), "-iTCP", "-sTCP:" + state, "-Fpn",
            ], empty_ok=True))
            if state == "LISTEN":
                listeners = values
            else:
                connected = set(values)
        except ServiceError as error:
            warnings.append(str(error))
            cleanup_available = False
    try:
        managed = parse_managed(read_command(["/bin/launchctl", "list"]))
    except ServiceError as error:
        warnings.append(str(error))
        cleanup_available = False
    runtimes = {"node", "bun", "deno", "python", "ruby", "php", "java", "dotnet", "go", "cargo", "swift",
                "pnpm", "npm", "npx", "yarn", "uv", "tsc", "tsgo", "redis-server", "postgres", "mysqld"}
    candidates = [p.pid for p in processes.values() if p.uid == os.getuid() and (
        p.pid in listeners or runtime_name(p.command) in runtimes or development_kind(p.command)
    )]
    directories = {}
    if candidates:
        try:
            values = parse_lsof(read_command([
                "/usr/sbin/lsof", "-nP", "-a", "-p", ",".join(map(str, candidates)), "-d", "cwd", "-Fpn",
            ], empty_ok=True))
            directories = {pid: next(iter(paths)) for pid, paths in values.items() if paths}
        except ServiceError as error:
            warnings.append(str(error))
            cleanup_available = False
    return Observation(processes, directories, listeners, connected, managed, warnings, cleanup_available)


def descendants(pid: int, processes: dict[int, ProcessInfo]) -> set[int]:
    result = {pid}
    pending = [pid]
    by_parent: dict[int, list[int]] = {}
    for process in processes.values():
        by_parent.setdefault(process.ppid, []).append(process.pid)
    while pending:
        for child in by_parent.get(pending.pop(), []):
            if child not in result:
                result.add(child)
                pending.append(child)
    return result


def elapsed_seconds(value: str) -> int:
    days, _, clock = value.rpartition("-")
    total = 0
    for component in clock.split(":"):
        total = total * 60 + int(component)
    return total + (int(days) * 86400 if days else 0)


def redacted_command(command: str) -> str:
    command = re.sub(r"(?i)((?:--?|\b)(?:password|passwd|token|api[-_]?key|secret|authorization)(?:=|\s+))(?:\"[^\"]*\"|'[^']*'|\S+)", r"\1<隐藏>", command)
    command = re.sub(r"(https?://)[^\s/@]+:[^\s/@]+@", r"\1<隐藏>@", command)
    return command


def service_rows(observation: Observation) -> list[dict]:
    processes = observation.processes
    excluded = {os.getpid()}
    current = processes.get(os.getpid())
    while current is not None and current.ppid not in excluded:
        excluded.add(current.ppid)
        current = processes.get(current.ppid)
    candidates: dict[int, tuple[str, str | None, str | None]] = {}
    runtime_scripts = {"node", "bun", "deno", "python", "ruby", "php", "java", "dotnet", "go", "cargo", "swift", "uv"}
    infrastructure = {"redis-server", "postgres", "mysqld", "mongod"}
    for process in processes.values():
        if process.uid != os.getuid() or process.pid in excluded:
            continue
        directory = observation.directories.get(process.pid)
        project = project_directory(directory) if directory else None
        kind = development_kind(process.command)
        runtime = runtime_name(process.command)
        protection = protected_reason(process, observation)
        if protection and runtime not in infrastructure:
            continue
        if not kind and runtime in runtime_scripts and project:
            kind = "开发服务" if process.pid in observation.listeners else "开发脚本"
        if not kind and runtime in infrastructure and process.pid in observation.listeners:
            kind = runtime
        if not kind and project and process.pid in observation.listeners:
            kind = "开发服务"
        if not kind and project and runtime in {"sh", "bash", "zsh"} and re.search(r"\.sh(?:\s|$)", process.command):
            kind = "Shell 脚本"
        if kind and (project or directory and process.pid in observation.listeners or is_launcher(process.command)):
            candidates[process.pid] = (kind, project, protection)

    roots = []
    for pid in candidates:
        parent = processes.get(processes[pid].ppid)
        seen = {pid}
        while parent and parent.pid not in seen and parent.pid not in excluded:
            if parent.pid in candidates:
                break
            seen.add(parent.pid)
            parent = processes.get(parent.ppid)
        else:
            roots.append(pid)
            continue
        if not parent or parent.pid not in candidates:
            roots.append(pid)

    rows = []
    for pid in roots:
        root = processes[pid]
        members = [processes[child] for child in sorted(descendants(pid, processes))]
        kind, project, protection = candidates[pid]
        if project is None:
            project = next((candidates[p.pid][1] for p in members if p.pid in candidates and candidates[p.pid][1]), None)
        reasons = [protected_reason(p, observation) for p in members]
        protection = protection or next((reason for reason in reasons if reason), None)
        ports = sorted({address for p in members for address in observation.listeners.get(p.pid, set())})
        connected = any(p.pid in observation.connected for p in members)
        suspected = root.ppid == 1 and root.tty == "??" and all(elapsed_seconds(p.elapsed) >= 300 for p in members) and sum(p.cpu for p in members) < 1 and not connected and not protection
        zombie = any("Z" in p.state for p in members)
        launcher_only = is_launcher(root.command) and len(members) == 1 and not ports
        can_stop = observation.cleanup_available and not protection and not zombie
        reason = protection or ("进程等待父进程回收，不能通过终止释放" if zombie else
            "原父进程已退出，且无终端、无活动 TCP 连接，CPU 占用低；需要确认是否仍在使用" if suspected else
            "仅检测到启动器进程，尚未检测到监听服务" if launcher_only else
            "当前有 TCP 连接" if connected else "根据启动命令和项目目录识别")
        if not observation.cleanup_available:
            reason = "进程信息不完整，当前仅展示"
        rows.append({
            "id": root.key, "pid": pid, "name": kind, "project": project or "未识别项目",
            "directory": observation.directories.get(pid, project or ""), "pids": [p.pid for p in members],
            "ports": ports, "rssMB": round(sum(p.rss_kb for p in members) / 1024, 1),
            "cpu": round(sum(p.cpu for p in members), 1), "elapsed": root.elapsed, "started": root.started,
            "command": redacted_command(root.command), "suspected": suspected, "canStop": can_stop,
            "status": "受保护" if protection else "待回收" if zombie else "疑似残留" if suspected else "启动入口" if launcher_only else "运行中",
            "reason": reason,
        })
    return sorted(rows, key=lambda row: (-row["rssMB"], row["pid"]))


def snapshot() -> dict:
    observation = collect_observation()
    rows = service_rows(observation)
    return {"services": rows, "warnings": observation.warnings, "scannedAt": time.time(),
            "totalRSSMB": round(sum(row["rssMB"] for row in rows), 1)}


def plan_directory() -> Path:
    return manager.data_directory() / "service-cleanup"


def create_plan(request: dict) -> dict:
    selected = request.get("selected", [])
    force = request.get("force", False)
    if not isinstance(selected, list) or not selected or not all(isinstance(value, str) for value in selected) or not isinstance(force, bool):
        raise ServiceError("请先选择需要停止的服务。")
    observation = collect_observation()
    rows = {row["id"]: row for row in service_rows(observation)}
    services = []
    for key in dict.fromkeys(selected):
        row = rows.get(key)
        if row is None:
            raise ServiceError("服务进程已变化，请刷新列表后重新选择。")
        if not row["canStop"]:
            raise ServiceError(f"无法停止 {row['name']}（{row['pid']}）：{row['reason']}")
        services.append(row)
    pids = sorted({pid for row in services for pid in row["pids"]})
    processes = [{"pid": pid, "identity": observation.processes[pid].identity,
                  "command": redacted_command(observation.processes[pid].command)} for pid in pids]
    plan = {"token": uuid.uuid4().hex, "createdAt": time.time(), "force": force,
            "services": services, "processes": processes,
            "rssMB": round(sum(observation.processes[pid].rss_kb for pid in pids) / 1024, 1)}
    # 预览仅保存本工具的短期清理计划，不修改项目文件或运行状态。
    for previous in plan_directory().glob("*.json"):
        if re.fullmatch(r"[a-f0-9]{32}\.json", previous.name) and time.time() - previous.stat().st_mtime > 86400:
            previous.unlink()
    manager.write_json(plan_directory() / f"{plan['token']}.json", plan)
    return plan


def validate_plan(plan: dict, observation: Observation) -> dict[int, str]:
    if not observation.cleanup_available:
        raise ServiceError("无法完整核对当前进程状态，请刷新后重试。")
    if not 0 <= time.time() - plan["createdAt"] <= 300:
        raise ServiceError("清理预览已过期，请重新选择服务。")
    identities = {item["pid"]: item["identity"] for item in plan["processes"]}
    own_chain = set()
    current = observation.processes.get(os.getpid())
    while current and current.pid not in own_chain:
        own_chain.add(current.pid)
        current = observation.processes.get(current.ppid)
    for pid, identity in identities.items():
        process = observation.processes.get(pid)
        if process is None:
            continue
        if process.identity != identity:
            raise ServiceError(f"PID {pid} 已对应其他进程，请重新预览。")
        if pid in own_chain or protected_reason(process, observation):
            raise ServiceError(f"PID {pid} 当前不允许清理，请重新预览。")
        if descendants(pid, observation.processes) - identities.keys():
            raise ServiceError("服务产生了新的子进程，请重新预览完整范围。")
    return identities


def execute_plan(token: str) -> dict:
    if re.fullmatch(r"[a-f0-9]{32}", token) is None:
        raise ServiceError("清理预览标识无效。")
    path = plan_directory() / f"{token}.json"
    try:
        plan = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ServiceError("清理预览已使用或不存在，请重新选择服务。") from error
    observation = collect_observation()
    identities = validate_plan(plan, observation)
    path.unlink()
    errors = []
    changed = []
    signum = signal.SIGKILL if plan["force"] else signal.SIGTERM
    roots = [row["pid"] for row in plan["services"]]
    order = list(dict.fromkeys(roots + list(identities)))
    # 每个信号只针对预览中核实的 PID，进程组里可能还有终端和其他服务。
    for pid in order:
        process = read_processes().get(pid)
        if process is None or "Z" in process.state:
            continue
        if process.identity != identities[pid]:
            changed.append(pid)
            continue
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass
        except PermissionError:
            errors.append(f"没有权限停止 PID {pid}")
    deadline = time.monotonic() + 4
    while True:
        processes = read_processes()
        remaining = [pid for pid, identity in identities.items() if pid in processes
                     and processes[pid].identity == identity and "Z" not in processes[pid].state]
        if not remaining or time.monotonic() >= deadline:
            break
        time.sleep(0.2)
    expected_ports = {port for service in plan["services"] for port in service["ports"]}
    remaining_ports = []
    if expected_ports:
        try:
            listeners = parse_lsof(read_command([
                "/usr/sbin/lsof", "-nP", "-a", "-u", str(os.getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpn",
            ], empty_ok=True))
            current_ports = {port for ports in listeners.values() for port in ports}
            remaining_ports = sorted(expected_ports & current_ports)
        except ServiceError as error:
            errors.append(str(error))
    stopped = [pid for pid in identities if pid not in remaining and pid not in changed]
    return {"stoppedPids": stopped, "remainingPids": remaining, "changedPids": changed,
            "remainingPorts": remaining_ports, "errors": errors, "rssBeforeMB": plan["rssMB"]}


def render_services(rows: list[dict]) -> None:
    print("本地开发服务 · 内存为进程 RSS 合计\n")
    if not rows:
        print("当前未发现匹配的开发服务或脚本。")
        return
    for index, row in enumerate(rows, 1):
        ports = ", ".join(row["ports"]) or "无 TCP 监听"
        print(f"{index}. [{row['status']}] {row['name']}  PID {row['pid']}  {row['rssMB']:.1f} MB  CPU {row['cpu']:.1f}%  运行 {row['elapsed']}")
        print(f"   目录: {row['directory']}\n   端口: {ports}\n   {row['reason']}")


def confirm_and_stop(rows: list[dict], *, force: bool = False) -> int:
    plan = create_plan({"selected": [row["id"] for row in rows], "force": force})
    render_services(plan["services"])
    print("\n将停止这些服务及以下子进程:")
    for item in plan["processes"]:
        print(f"  PID {item['pid']}  {item['command']}")
    print(f"当前占用合计约 {plan['rssMB']:.1f} MB；实际可回收内存由系统决定。")
    if not sys.stdin.isatty():
        raise ServiceError("请在交互终端确认清理操作。")
    label = "强制停止" if force else "停止"
    if input(f"确认{label}以上 {len(plan['processes'])} 个进程？[y/N]: ").strip().lower() not in ("y", "yes"):
        print("已取消")
        return 0
    result = execute_plan(plan["token"])
    print(f"已结束 {len(result['stoppedPids'])} 个原进程。")
    if result["remainingPids"]:
        print("仍在运行的 PID: " + ", ".join(map(str, result["remainingPids"])))
        print("可刷新后使用 dev-services stop <PID> --force 重新预览并强制停止。")
    if result["changedPids"]:
        print("已跳过身份变化的 PID: " + ", ".join(map(str, result["changedPids"])))
    if result["remainingPorts"]:
        print("仍被占用的端口: " + ", ".join(result["remainingPorts"]))
    for error in result["errors"]:
        print(error, file=sys.stderr)
    return 1 if result["remainingPids"] or result["changedPids"] or result["errors"] or result["remainingPorts"] else 0


def cli(arguments: list[str], *, residual_only: bool = False) -> int:
    if arguments in (["--help"], ["-h"]):
        print("dev-services [--list | --json | stop <PID>... [--force]]\ndev-services clean [--list | --json]  查看或选择清理疑似残留\ndev-services --version  查看版本")
        return 0
    if arguments and arguments not in (["--list"], ["--json"]) and arguments[0] != "stop":
        raise ServiceError("用法: dev-services [--list | --json | clean | stop <PID>... [--force]]")
    while True:
        data = snapshot()
        rows = [row for row in data["services"] if row["suspected"] or not residual_only]
        if arguments == ["--json"]:
            print(json.dumps({**data, "services": rows, "totalRSSMB": round(sum(row["rssMB"] for row in rows), 1)}, ensure_ascii=False))
            return 0
        for warning in data["warnings"]:
            print(warning, file=sys.stderr)
        if arguments and arguments[0] == "stop":
            values = arguments[1:]
            force = "--force" in values
            values = [value for value in values if value != "--force"]
            if not values or not all(value.isdecimal() for value in values):
                raise ServiceError("请填写要停止的 PID，例如 dev-services stop 12345。")
            selected = [row for row in rows if set(map(int, values)) & set(row["pids"])]
            found = {pid for row in selected for pid in row["pids"]}
            if not set(map(int, values)).issubset(found):
                raise ServiceError("部分 PID 不在当前开发服务列表中，请刷新后重试。")
            return confirm_and_stop(selected, force=force)
        render_services(rows)
        if not rows or arguments == ["--list"] or not sys.stdin.isatty():
            return 0
        value = input("\n输入要停止的序号（逗号分隔），r 刷新，q 退出: ").strip().lower()
        if value in ("", "q"):
            return 0
        if value == "r":
            continue
        indices = value.split(",")
        if not all(item.strip().isdecimal() and 1 <= int(item) <= len(rows) for item in indices):
            print("序号无效。")
            continue
        return confirm_and_stop([rows[int(item) - 1] for item in dict.fromkeys(indices)])


def main() -> int:
    try:
        arguments = sys.argv[1:]
        if arguments == ["--version"]:
            print(f"dev-services {manager.tool_version()} · 需求记录")
            return 0
        if arguments and arguments[0] == "clean":
            return cli(arguments[1:], residual_only=True)
        return cli(arguments)
    except KeyboardInterrupt:
        print("\n已取消")
        return 130
    except (ServiceError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
