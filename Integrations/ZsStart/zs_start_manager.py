"""zs-start 的项目配置与 App 全局命令注册入口。"""
from __future__ import annotations

import base64
import fcntl
import json
import os
import plistlib
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path


TOOL_DIRECTORY = Path(__file__).resolve().parent
MANAGED_MARKER = "# Managed by RequirementTracker: zs-start"


class ManagerError(RuntimeError):
    pass


def data_directory() -> Path:
    return Path.home() / "Library/Application Support/RequirementTracker/DeveloperTools"


def config_path() -> Path:
    return data_directory() / "zs-start.json"


def read_config() -> dict:
    try:
        value = json.loads(config_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (ValueError, OSError) as error:
        raise ManagerError(f"无法读取项目配置: {config_path()}\n{error}") from error
    if not isinstance(value, dict):
        raise ManagerError(f"项目配置格式无效: {config_path()}")
    return value


def atomic_write(path: Path, content: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path: Path, value: dict) -> None:
    atomic_write(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode())


@contextmanager
def configuration_lock():
    data_directory().mkdir(parents=True, exist_ok=True)
    with (data_directory() / ".zs-start.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def git_output(path: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["/usr/bin/git", "-C", str(path), *arguments],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode:
        raise ManagerError(f"目录不是可用的 Git 项目: {path}")
    return result.stdout.strip()


def project_root(path: Path) -> Path:
    path = path.expanduser().resolve()
    root = Path(git_output(path, "rev-parse", "--show-toplevel")).resolve()
    fields = git_output(root, "worktree", "list", "--porcelain", "-z").split("\0")
    roots = [Path(field[9:]).resolve() for field in fields if field.startswith("worktree ")]
    if not roots or root not in roots:
        raise ManagerError(f"无法识别项目的主工作树: {path}")
    primary = roots[0]
    if not (primary / "scripts/start.ts").is_file() or not (primary / "package.json").is_file():
        raise ManagerError(f"目录缺少 ZStack 项目启动文件: {primary}")
    return primary


def discover_projects() -> list[Path]:
    roots = []
    for path in sorted((Path.home() / "workspace").glob("zstack-ui-next*")):
        try:
            root = project_root(path)
        except (ManagerError, OSError, subprocess.TimeoutExpired):
            continue
        if root not in roots:
            roots.append(root)
    return roots


def command_path(configuration: dict | None = None) -> Path:
    configuration = read_config() if configuration is None else configuration
    if configured := configuration.get("commandPath"):
        path = Path(configured).expanduser().absolute()
    else:
        current = shutil.which("zs-start")
        candidates = [Path(current)] if current else []
        candidates += [Path.home() / ".homebrew/bin/zs-start", Path.home() / ".local/bin/zs-start"]
        path = next((candidate for candidate in candidates if candidate.exists()), candidates[-1])
    if path.name != "zs-start" or not path.parent.resolve().is_relative_to(Path.home().resolve()):
        raise ManagerError(f"命令需要安装到当前用户的目录: {path}")
    return path


def legacy_project(path: Path) -> Path | None:
    if not path.is_file() or path.is_symlink():
        return None
    try:
        lines = path.read_text(encoding="utf-8").strip().splitlines()
    except UnicodeError:
        return None
    if len(lines) != 2 or lines[0] != "#!/bin/sh":
        return None
    try:
        arguments = shlex.split(lines[1])
    except ValueError:
        return None
    if len(arguments) != 4 or arguments[:2] != ["exec", "/usr/bin/python3"] or arguments[3] != "$@":
        return None
    script = Path(arguments[2])
    if script.name != "zs-start.py" or script.parent.name != "bin" or script.parent.parent.name != ".vscode":
        return None
    return script.parents[2]


def selected_project(configuration: dict | None = None) -> Path:
    configuration = read_config() if configuration is None else configuration
    if selected := configuration.get("primaryRoot"):
        return project_root(Path(selected))
    legacy = legacy_project(command_path(configuration))
    if legacy is not None:
        return project_root(legacy)
    projects = discover_projects()
    if len(projects) == 1:
        return projects[0]
    raise ManagerError("请先运行 zs-start project 选择项目目录。")


def select_project(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute() and len(path.parts) == 1 and not path.exists():
        path = Path.home() / "workspace" / path
    root = project_root(path)
    with configuration_lock():
        configuration = read_config()
        configuration["primaryRoot"] = str(root)
        write_json(config_path(), configuration)
    return root


def launcher_content() -> bytes:
    script = shlex.quote(str(TOOL_DIRECTORY / "zs-start.py"))
    return f'#!/bin/sh\n{MANAGED_MARKER}\nexec /usr/bin/python3 -B {script} "$@"\n'.encode()


def registration_state(path: Path) -> tuple[str, str]:
    if not path.exists() and not path.is_symlink():
        return "missing", "尚未注册全局命令"
    if path.is_symlink() or not path.is_file():
        return "conflict", "该位置已有其他命令，请先处理冲突"
    content = path.read_bytes()
    if content == launcher_content() and os.access(path, os.X_OK):
        return "installed", "已由需求记录 App 管理"
    if MANAGED_MARKER.encode() in content.splitlines():
        return "repair", "命令指向其他版本，点击修复以使用当前 App"
    try:
        legacy = legacy_project(path)
    except UnicodeError:
        legacy = None
    if legacy is not None:
        return "legacy", "正在使用项目内的旧脚本，可迁移到 App 管理"
    return "conflict", "该位置已有其他命令，请先处理冲突"


def install_command() -> None:
    with configuration_lock():
        configuration = read_config()
        path = command_path(configuration)
        state, detail = registration_state(path)
        if state == "conflict":
            raise ManagerError(f"{detail}: {path}")
        # 注册不依赖项目是否可用；迁移旧命令时保留原项目，其他项目选择交给终端。
        if not configuration.get("primaryRoot") and state == "legacy":
            configuration["primaryRoot"] = str(legacy_project(path))
        backup_path = data_directory() / "zs-start-command-backup.json"
        if state == "legacy":
            backup = {
                "path": str(path),
                "content": base64.b64encode(path.read_bytes()).decode(),
                "mode": stat.S_IMODE(path.stat().st_mode),
            }
            if backup_path.exists():
                if json.loads(backup_path.read_text(encoding="utf-8")) != backup:
                    raise ManagerError(f"存在其他命令的备份，请先确认: {backup_path}")
            else:
                write_json(backup_path, backup)
        configuration["commandPath"] = str(path)
        write_json(config_path(), configuration)
        atomic_write(path, launcher_content(), 0o755)


def uninstall_command() -> None:
    with configuration_lock():
        configuration = read_config()
        path = command_path(configuration)
        state, _ = registration_state(path)
        if state == "missing":
            return
        if state not in ("installed", "repair"):
            raise ManagerError("此命令未由需求记录 App 管理，已保留现有文件。")
        backup_path = data_directory() / "zs-start-command-backup.json"
        if backup_path.exists():
            backup = json.loads(backup_path.read_text(encoding="utf-8"))
            if backup["path"] != str(path):
                raise ManagerError("备份路径与命令不一致，已保留现有文件。")
            atomic_write(path, base64.b64decode(backup["content"]), backup["mode"])
            backup_path.unlink()
        else:
            path.unlink()


def tool_version() -> str:
    for path in (
        TOOL_DIRECTORY.parent.parent / "Info.plist",
        TOOL_DIRECTORY.parent.parent / "BundleSupport/RequirementTracker-Info.plist",
    ):
        if path.is_file():
            with path.open("rb") as source:
                return plistlib.load(source).get("CFBundleShortVersionString", "未知")
    return "未知"


def status(*, include_projects: bool = True) -> dict:
    configuration = read_config()
    path = command_path(configuration)
    state, detail = registration_state(path)
    result = {
        "toolVersion": tool_version(),
        "commandPath": str(path),
        "registrationState": state,
        "registrationDetail": detail,
    }
    if not include_projects:
        return result
    selected = None
    project_error = None
    try:
        selected = selected_project(configuration)
    except ManagerError as error:
        project_error = str(error)
    projects = discover_projects()
    if selected is not None and selected not in projects:
        projects.append(selected)
    result.update({
        "projectPath": str(selected) if selected else configuration.get("primaryRoot"),
        "projectError": project_error,
        "projects": [{"name": root.name, "path": str(root)} for root in projects],
    })
    return result


def main() -> int:
    try:
        arguments = sys.argv[1:]
        if arguments == ["install"]:
            install_command()
        elif arguments == ["uninstall"]:
            uninstall_command()
        elif len(arguments) == 2 and arguments[0] == "project":
            select_project(arguments[1])
        elif arguments not in (["status"], ["registration-status"]):
            raise ManagerError("用法: zs_start_manager.py registration-status|status|install|uninstall|project <目录>")
        print(json.dumps(status(include_projects=arguments[0] in ("status", "project")), ensure_ascii=False))
        return 0
    except (ManagerError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
