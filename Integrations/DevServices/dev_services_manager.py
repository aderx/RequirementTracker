"""独立管理 dev-services 的命令注册与短期清理计划，不读取 ZStack 项目配置。"""
from __future__ import annotations

import fcntl
import json
import os
import plistlib
import shlex
import shutil
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

TOOL_DIRECTORY = Path(__file__).resolve().parent
COMMAND_NAME = "dev-services"
MANAGED_MARKER = "# Managed by RequirementTracker: dev-services"


class ManagerError(RuntimeError):
    pass


def data_directory() -> Path:
    return Path.home() / "Library/Application Support/RequirementTracker/DeveloperTools/DevServices"


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


def config_path() -> Path:
    return data_directory() / "command.json"


def read_config() -> dict:
    try:
        value = json.loads(config_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (ValueError, OSError) as error:
        raise ManagerError(f"无法读取 dev-services 命令配置: {error}") from error
    if not isinstance(value, dict):
        raise ManagerError("dev-services 命令配置格式无效。")
    return value


@contextmanager
def configuration_lock():
    data_directory().mkdir(parents=True, exist_ok=True)
    with (data_directory() / ".command.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def command_path(configuration: dict) -> Path:
    configured = configuration.get("commandPath")
    if configured:
        path = Path(configured).expanduser().absolute()
    elif current := shutil.which(COMMAND_NAME):
        path = Path(current).absolute()
    else:
        candidates = [Path.home() / ".homebrew/bin", Path.home() / ".local/bin"]
        directory = next((candidate for candidate in candidates if candidate.is_dir()), candidates[-1])
        path = directory / COMMAND_NAME
    if path.name != COMMAND_NAME or not path.parent.resolve().is_relative_to(Path.home().resolve()):
        raise ManagerError(f"命令需要安装到当前用户的目录: {path}")
    return path


def launcher_content() -> bytes:
    script = shlex.quote(str(TOOL_DIRECTORY / "dev_services.py"))
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
    return "conflict", "该位置已有其他命令，请先处理冲突"


def install_command() -> None:
    with configuration_lock():
        configuration = read_config()
        path = command_path(configuration)
        state, detail = registration_state(path)
        if state == "conflict":
            raise ManagerError(f"{detail}: {path}")
        configuration["commandPath"] = str(path)
        write_json(config_path(), configuration)
        atomic_write(path, launcher_content(), 0o755)


def uninstall_command() -> None:
    with configuration_lock():
        path = command_path(read_config())
        state, _ = registration_state(path)
        if state == "missing":
            return
        if state not in ("installed", "repair"):
            raise ManagerError("此命令未由需求记录 App 管理，已保留现有文件。")
        path.unlink()


def tool_version() -> str:
    for path in (TOOL_DIRECTORY.parent.parent / "Info.plist",
                 TOOL_DIRECTORY.parent.parent / "BundleSupport/RequirementTracker-Info.plist"):
        if path.is_file():
            with path.open("rb") as source:
                return plistlib.load(source).get("CFBundleShortVersionString", "未知")
    return "未知"


def status() -> dict:
    path = command_path(read_config())
    state, detail = registration_state(path)
    return {"toolVersion": tool_version(), "commandPath": str(path),
            "registrationState": state, "registrationDetail": detail}


def main() -> int:
    try:
        arguments = sys.argv[1:]
        if arguments == ["install"]:
            install_command()
        elif arguments == ["uninstall"]:
            uninstall_command()
        elif arguments != ["registration-status"]:
            raise ManagerError("用法: dev_services_manager.py registration-status|install|uninstall")
        print(json.dumps(status(), ensure_ascii=False))
        return 0
    except (ManagerError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
