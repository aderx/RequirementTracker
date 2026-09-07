#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import re
import select
import shutil
import subprocess
import sys
import termios
import time
import tty
import unicodedata
import webbrowser
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping
from urllib.parse import urlsplit

# 工具位于已签名 App 内，运行时不在资源目录生成 Python 缓存。
sys.dont_write_bytecode = True
import zs_start_manager


SCRIPT_PATH = Path(__file__).resolve()
PROJECT_ROOT_ENV_KEY = "ZS_START_PROJECT_ROOT"
CLOUD_BFF_RELATIVE_DIR = Path("packages/products/cloud/bff")
ZNS_BFF_RELATIVE_DIR = Path("packages/products/zns/bff")
FRONTEND_START_SCRIPT = Path("scripts/start.ts")
CORE_SHELL_POSTCSS_CONFIG = Path(
    "packages/products/cloud/apps/core-shell/postcss.config.mjs"
)
CORE_SHELL_POSTCSS_PLUGIN = Path(
    "packages/products/cloud/apps/core-shell/node_modules/@tailwindcss/postcss"
)
PNPM_POSTCSS_PLUGIN = Path(
    "node_modules/.pnpm/node_modules/@tailwindcss/postcss"
)
FRONTEND_MEMORY_PRELOAD = Path(__file__).with_name("zs-start-fe-memory.mjs")
SUPPORTED_COMMANDS = ("fe", "cloud:bff", "zns:bff")
MENU_COMMANDS = (*SUPPORTED_COMMANDS, "project")
FRONTEND_PRODUCTS = (
    ("default", "默认启动器", "pnpm start"),
    ("cloud", "Cloud", "pnpm start:cloud"),
    ("zns", "ZNS", "pnpm start:zns"),
)
FRONTEND_INSTALL_ACTION = "install"
FRONTEND_INSTALL_LABEL = "修复前端依赖"
FRONTEND_STATE_ENV_KEY = "ZS_START_FRONTEND_STATE_PATH"
FRONTEND_AUTO_PREPARE_ENV_KEY = "ZS_START_FRONTEND_AUTO_PREPARE"
FRONTEND_PREPARE_SCRIPT_ENV_KEY = "ZS_START_FRONTEND_PREPARE_SCRIPT"
FRONTEND_PREPARE_COMMAND = "__prepare-frontend"
FRONTEND_APP_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
FRONTEND_RUNTIME_SUFFIXES = frozenset((".js", ".mjs", ".cjs"))
SERVER_KEY = "ZS_MN_SERVER"
MYSQL_HOST_KEY = "ZS_MYSQL_HOST"
ZOPS_KEY = "ZOPS_SERVER"
SERVER_PORT = 8080
ZOPS_PORT = 10010
UI_PORT = 5000
DEFAULT_DESC = "暂无说明"
ESC_SEQUENCE_TIMEOUT = 0.5
DOUBLE_RIGHT_TIMEOUT = 0.6
RESET = "\033[0m"
TERMINAL_SESSION_ENV_KEYS = (
    "TERM_SESSION_ID",
    "ITERM_SESSION_ID",
    "TMUX_PANE",
    "WEZTERM_PANE",
    "KITTY_WINDOW_ID",
    "WT_SESSION",
)


@dataclass
class Target:
    line_index: int
    value: str
    host: str
    desc: str
    active: bool


@dataclass
class EditDraft:
    host: str
    desc: str

    def has_changes(self, target: Target) -> bool:
        return self.host != target.host or self.desc != target.desc


@dataclass(frozen=True)
class RepoContext:
    root: Path
    primary_root: Path
    branch: str

    @property
    def is_linked_worktree(self) -> bool:
        return self.root != self.primary_root

    @property
    def cloud_bff_dir(self) -> Path:
        return self.root / CLOUD_BFF_RELATIVE_DIR

    @property
    def cloud_bff_env(self) -> Path:
        return self.cloud_bff_dir / ".env"

    @property
    def primary_cloud_bff_env(self) -> Path:
        return self.primary_root / CLOUD_BFF_RELATIVE_DIR / ".env"

    @property
    def zns_bff_dir(self) -> Path:
        return self.root / ZNS_BFF_RELATIVE_DIR

    @property
    def zns_bff_env(self) -> Path:
        return self.zns_bff_dir / ".env"

    @property
    def zns_bff_env_example(self) -> Path:
        return self.zns_bff_dir / ".env.example"


@dataclass(frozen=True)
class FrontendStartState:
    product: str
    apps: tuple[str, ...]
    start_proxy: bool


@dataclass(frozen=True)
class FrontendWorkspacePackage:
    name: str
    path: Path
    manifest: dict[str, object]


@dataclass(frozen=True)
class FrontendPrepareResult:
    installed: bool
    built_packages: tuple[str, ...]


class ZsStartError(RuntimeError):
    pass


class FrontendDependenciesMissing(ZsStartError):
    pass


def print_help(selected_command: str | None = None) -> None:
    print(color("ZStack 本地开发服务启动器", "1"))
    print()
    print(color("用法", "1"))
    print("  zs-start <命令> [选项]")
    print()
    print(color("可用命令", "1"))
    descriptions = {
        "fe": "选择默认入口或 Cloud/ZNS 产品并启动前端模块",
        "cloud:bff": "选择管理节点并启动 Cloud BFF",
        "zns:bff": "启动 ZNS BFF",
        "project": "选择或切换默认项目目录",
    }
    for command in MENU_COMMANDS:
        command_code = "7;1" if command == selected_command else "36;1"
        print(f"  {color(command.ljust(16), command_code)} {descriptions[command]}")
    print()
    print(color("通用选项", "1"))
    print("  -w, --worktree <path>  使用指定工作树")
    print("  -h, --help             显示帮助文档")
    print("  --version              显示工具版本")
    print("  project [目录或名称]    选择项目；省略目录时打开列表")
    print("  project --current      显示当前项目目录")
    print("  project --list         列出 workspace 下的 ZStack 项目")
    print()
    print(color("示例", "1"))
    print("  zs-start fe")
    print("  zs-start fe -w .worktrees/zstac-12345")
    print("  zs-start cloud:bff --worktree /path/to/worktree")
    print("  zs-start zns:bff")
    print("  zs-start project zstack-ui-next")
    print("  zs-start project ~/workspace/zstack-ui-next-dev")


def usage() -> int:
    print_help()
    return 2


def git_output(path: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(path), *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def git_top_level(path: Path) -> Path | None:
    value = git_output(path, "rev-parse", "--show-toplevel")
    return Path(value).resolve() if value else None


def git_common_dir(repo_root: Path) -> Path | None:
    value = git_output(repo_root, "rev-parse", "--git-common-dir")
    if not value:
        return None
    path = Path(value)
    if not path.is_absolute():
        path = repo_root / path
    return path.resolve()


def git_branch(repo_root: Path) -> str:
    branch = git_output(repo_root, "branch", "--show-current")
    if branch:
        return branch
    commit = git_output(repo_root, "rev-parse", "--short", "HEAD")
    return f"detached@{commit}" if commit else "未知"


def parse_worktree_paths(output: str) -> list[Path]:
    """解析 `git worktree list --porcelain -z` 中登记的工作树路径。"""
    prefix = "worktree "
    return [
        Path(field[len(prefix) :]).resolve()
        for field in output.split("\0")
        if field.startswith(prefix)
    ]


def resolve_repo_context(
    cwd: Path | None = None,
    requested_worktree: Path | None = None,
    primary_hint: Path | None = None,
) -> RepoContext:
    """使用当前/指定 worktree；仓库外调用时保持原有的主工作树行为。"""
    if primary_hint is None:
        try:
            runtime_root = os.environ.get(PROJECT_ROOT_ENV_KEY)
            primary_hint = Path(runtime_root) if runtime_root else zs_start_manager.selected_project()
        except zs_start_manager.ManagerError as error:
            raise ZsStartError(str(error)) from error
    primary_root = git_top_level(primary_hint)
    if not primary_root:
        raise ZsStartError(f"无法识别主工作树: {primary_hint}")
    primary_common_dir = git_common_dir(primary_root)
    if not primary_common_dir:
        raise ZsStartError(f"无法识别 Git 仓库: {primary_root}")

    current_dir = (cwd or Path.cwd()).resolve()
    selected_path = requested_worktree or current_dir
    if requested_worktree and not selected_path.exists():
        raise ZsStartError(f"worktree 路径不存在: {selected_path}")

    selected_root = git_top_level(selected_path)
    selected_common_dir = git_common_dir(selected_root) if selected_root else None
    belongs_to_repo = selected_common_dir == primary_common_dir

    if requested_worktree and not belongs_to_repo:
        raise ZsStartError(f"指定路径不是当前项目的 worktree: {selected_path}")

    root = selected_root if belongs_to_repo and selected_root else primary_root
    return RepoContext(root=root, primary_root=primary_root, branch=git_branch(root))


def list_repo_contexts(context: RepoContext) -> list[RepoContext]:
    """列出当前 Git 仓库中已登记且路径仍存在的 worktree。"""
    output = git_output(context.primary_root, "worktree", "list", "--porcelain", "-z")
    if not output:
        return [context]

    contexts: list[RepoContext] = []
    seen_roots: set[Path] = set()
    for root in parse_worktree_paths(output):
        if root in seen_roots or not root.exists():
            continue
        try:
            candidate = resolve_repo_context(
                requested_worktree=root,
                primary_hint=context.primary_root,
            )
        except ZsStartError:
            continue
        seen_roots.add(candidate.root)
        contexts.append(candidate)

    if context.root not in seen_roots:
        contexts.append(context)
    return contexts


def build_terminal_session_key(
    environ: Mapping[str, str],
    *,
    tty_path: str | None,
    session_id: int | None,
) -> str | None:
    """用终端会话与 TTY 共同标识当前 TAB；不依赖跨进程修改 Shell 环境。"""
    parts = [
        f"{key}={value}"
        for key in TERMINAL_SESSION_ENV_KEYS
        if (value := environ.get(key))
    ]
    if tty_path:
        parts.append(f"tty={tty_path}")
    if session_id is not None:
        parts.append(f"sid={session_id}")
    return "\0".join(parts) if parts else None


def terminal_session_key() -> str | None:
    if not sys.stdin.isatty():
        return None
    try:
        tty_path = os.ttyname(sys.stdin.fileno())
    except (AttributeError, OSError, ValueError):
        tty_path = None
    try:
        session_id = os.getsid(0)
    except OSError:
        session_id = None
    return build_terminal_session_key(
        os.environ,
        tty_path=tty_path,
        session_id=session_id,
    )


def default_session_state_dir(environ: Mapping[str, str] | None = None) -> Path:
    environment = environ or os.environ
    temp_root = Path(environment.get("TMPDIR") or "/tmp")
    return temp_root / f"zs-start-{os.getuid()}" / "sessions"


def repo_context_state_path(
    context: RepoContext,
    *,
    session_key: str | None = None,
    state_dir: Path | None = None,
) -> Path | None:
    active_session_key = session_key or terminal_session_key()
    if not active_session_key:
        return None
    repository_key = str(context.primary_root.resolve())
    digest = hashlib.sha256(
        f"{active_session_key}\0{repository_key}".encode("utf-8")
    ).hexdigest()
    return (state_dir or default_session_state_dir()) / f"{digest}.json"


def frontend_start_state_path(
    context: RepoContext,
    *,
    session_key: str | None = None,
    state_dir: Path | None = None,
) -> Path | None:
    active_session_key = session_key or terminal_session_key()
    if not active_session_key:
        return None
    repository_key = str(context.primary_root.resolve())
    digest = hashlib.sha256(
        f"{active_session_key}\0{repository_key}".encode("utf-8")
    ).hexdigest()
    return (state_dir or default_session_state_dir()) / f"frontend-{digest}.json"


def load_frontend_start_state(
    context: RepoContext,
    *,
    session_key: str | None = None,
    state_dir: Path | None = None,
) -> FrontendStartState | None:
    state_path = frontend_start_state_path(
        context,
        session_key=session_key,
        state_dir=state_dir,
    )
    if state_path is None or not state_path.exists():
        return None
    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None

    product = payload.get("product")
    apps = payload.get("apps")
    start_proxy = payload.get("startProxy")
    if (
        type(payload.get("version")) is not int
        or payload.get("version") != 1
        or product not in ("cloud", "zns")
        or not isinstance(apps, list)
        or not apps
        or not all(
            isinstance(app, str) and FRONTEND_APP_NAME_PATTERN.fullmatch(app)
            for app in apps
        )
        or not isinstance(start_proxy, bool)
    ):
        return None
    return FrontendStartState(
        product=product,
        apps=tuple(apps),
        start_proxy=start_proxy,
    )


def build_frontend_start_command(state: FrontendStartState) -> list[str]:
    command = [
        "pnpm",
        f"start:{state.product}",
        "--apps",
        ",".join(state.apps),
    ]
    if not state.start_proxy:
        command.append("--proxy=false")
    return command


def build_frontend_memory_command(product: str) -> list[str]:
    command = [
        "bun",
        "--preload",
        str(FRONTEND_MEMORY_PRELOAD),
        f"./{FRONTEND_START_SCRIPT}",
    ]
    if product != "default":
        command.extend(("--product", product))
    return command


def discard_repo_context_state(state_path: Path) -> None:
    try:
        state_path.unlink(missing_ok=True)
    except OSError:
        pass


def remember_repo_context(
    context: RepoContext,
    *,
    session_key: str | None = None,
    state_dir: Path | None = None,
) -> None:
    state_path = repo_context_state_path(
        context,
        session_key=session_key,
        state_dir=state_dir,
    )
    if state_path is None:
        return

    temp_path = state_path.with_name(f".{state_path.name}.{os.getpid()}.tmp")
    payload = {
        "version": 1,
        "primary_root": str(context.primary_root.resolve()),
        "worktree": str(context.root.resolve()),
    }
    try:
        state_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temp_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        temp_path.chmod(0o600)
        temp_path.replace(state_path)
    except OSError:
        discard_repo_context_state(temp_path)


def restore_repo_context(
    current: RepoContext,
    *,
    session_key: str | None = None,
    state_dir: Path | None = None,
) -> RepoContext:
    state_path = repo_context_state_path(
        current,
        session_key=session_key,
        state_dir=state_dir,
    )
    if state_path is None or not state_path.exists():
        return current

    try:
        payload = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        discard_repo_context_state(state_path)
        return current
    if not isinstance(payload, dict):
        discard_repo_context_state(state_path)
        return current

    primary_root = payload.get("primary_root")
    worktree = payload.get("worktree")
    if (
        not isinstance(primary_root, str)
        or not isinstance(worktree, str)
        or Path(primary_root).resolve() != current.primary_root.resolve()
    ):
        discard_repo_context_state(state_path)
        return current

    remembered_root = Path(worktree).resolve()
    remembered = next(
        (
            context
            for context in list_repo_contexts(current)
            if context.root.resolve() == remembered_root
        ),
        None,
    )
    if remembered is None:
        discard_repo_context_state(state_path)
        return current
    return remembered


def resolve_startup_repo_context(
    requested_worktree: Path | None = None,
) -> RepoContext:
    context = resolve_repo_context(requested_worktree=requested_worktree)
    if requested_worktree is None:
        context = restore_repo_context(context)
    remember_repo_context(context)
    return context


def parse_worktree_arg(args: list[str], cwd: Path | None = None) -> Path | None:
    if len(args) == 1 and args[0] in SUPPORTED_COMMANDS:
        return None
    if len(args) == 3 and args[0] in SUPPORTED_COMMANDS and args[1] in (
        "--worktree",
        "-w",
    ):
        path = Path(args[2]).expanduser()
        if not path.is_absolute():
            path = (cwd or Path.cwd()) / path
        return path.resolve()
    rendered = " ".join(args) if args else "<空>"
    raise ZsStartError(f"无法识别的参数: {rendered}")


def is_server_line(line: str) -> bool:
    return re.match(r"^\s*#?\s*ZS_MN_SERVER\s*=", line) is not None


def parse_server_line(line: str) -> tuple[bool, str] | None:
    match = re.match(r"^\s*(#\s*)?ZS_MN_SERVER\s*=\s*(.*?)\s*$", line)
    if not match:
        return None
    return match.group(1) is None, match.group(2)


def previous_desc(lines: list[str], index: int) -> str:
    if index <= 0:
        return ""
    previous = lines[index - 1].strip()
    if not previous.startswith("#"):
        return ""
    content = previous[1:].strip()
    if not content or is_server_line(previous):
        return ""
    if content.startswith(("改成", "这里改成")):
        return ""
    return content


def clip_text(text: str, length: int) -> str:
    if len(text) <= length:
        return text
    return f"{text[: max(0, length - 3)]}..."


def fit_text_to_width(text: str, width: int) -> str:
    if width <= 0:
        return ""
    if display_width(text) <= width:
        return text

    ellipsis = "..."
    if width <= len(ellipsis):
        return "." * width

    limit = width - len(ellipsis)
    result: list[str] = []
    current_width = 0
    for char in text:
        char_width = display_width(char)
        if current_width + char_width > limit:
            break
        result.append(char)
        current_width += char_width
    return f"{''.join(result)}{ellipsis}"


def pad_text_to_width(text: str, width: int) -> str:
    fitted = fit_text_to_width(text, width)
    return f"{fitted}{' ' * max(0, width - display_width(fitted))}"


def color_enabled() -> bool:
    return sys.stdout.isatty() and not os.environ.get("ZS_START_NO_COLOR")


def color(text: str, code: str) -> str:
    if not color_enabled():
        return text
    return f"\033[{code}m{text}{RESET}"


def set_terminal_title(title: str) -> None:
    if not sys.stdout.isatty():
        return
    safe_title = title.replace("\033", "").replace("\a", "")
    sys.stdout.write(f"\033]0;{safe_title}\a")
    sys.stdout.flush()


def extract_host(text: str) -> str:
    raw = text.strip()
    if not raw:
        return ""

    candidate = raw
    if "://" in raw:
        parsed = urlsplit(raw)
        candidate = parsed.hostname or parsed.netloc
    else:
        candidate = raw.split("/", 1)[0]
        if candidate.startswith("[") and "]" in candidate:
            candidate = candidate[1 : candidate.index("]")]
        elif candidate.count(":") == 1:
            host_part, port_part = candidate.rsplit(":", 1)
            if port_part.isdigit():
                candidate = host_part

    return candidate.strip("[] \t")


def host_url(host: str, port: int) -> str:
    if ":" in host and not host.startswith("["):
        return f"http://[{host}]:{port}"
    return f"http://{host}:{port}"


def server_url(host: str) -> str:
    return host_url(host, SERVER_PORT)


def read_env(env_path: Path) -> list[str]:
    if not env_path.exists():
        raise ZsStartError(f"缺少 Cloud BFF 配置: {env_path}")
    return env_path.read_text(encoding="utf-8").splitlines()


def initialize_cloud_bff_env(context: RepoContext) -> Path:
    """为支线复制独立配置，避免切换测试地址时改动主工作树。"""
    env_path = context.cloud_bff_env
    if env_path.exists():
        return env_path

    primary_env = context.primary_cloud_bff_env
    if not context.is_linked_worktree or not primary_env.exists():
        raise ZsStartError(
            f"缺少 Cloud BFF 配置: {env_path}\n"
            f"请先创建该文件，或在主工作树准备模板: {primary_env}"
        )

    temp_path = env_path.parent / ".env.zs-start.tmp"
    shutil.copy2(primary_env, temp_path)
    os.replace(temp_path, env_path)
    print(f"已初始化 worktree 配置: {env_path}")
    print(f"配置来源: {primary_env}")
    return env_path


def initialize_zns_bff_env(context: RepoContext) -> Path:
    """从所选 worktree 的示例创建独立 ZNS BFF 配置。"""
    env_path = context.zns_bff_env
    if env_path.exists():
        return env_path
    if not context.zns_bff_dir.is_dir():
        raise ZsStartError(f"worktree 中不存在 ZNS BFF: {context.zns_bff_dir}")

    source = context.zns_bff_env_example
    if not source.exists() and context.is_linked_worktree:
        primary_env = context.primary_root / ZNS_BFF_RELATIVE_DIR / ".env"
        if primary_env.exists():
            source = primary_env
    if not source.exists():
        raise ZsStartError(
            f"缺少 ZNS BFF 配置模板: {context.zns_bff_env_example}\n"
            f"请手动创建配置: {env_path}"
        )

    temp_path = env_path.parent / ".env.zs-start.tmp"
    shutil.copy2(source, temp_path)
    os.replace(temp_path, env_path)
    print(f"已初始化 worktree 配置: {env_path}")
    print(f"配置来源: {source}")
    return env_path


def default_confirm_dependency_install(command: str) -> bool:
    if not sys.stdin.isatty():
        return False
    print("当前 worktree 尚未准备 Cloud BFF 依赖。")
    print(f"一次性准备命令: {command}")
    value = input("是否现在执行？[y/N]: ").strip().lower()
    return value in ("y", "yes")


def default_confirm_frontend_dependency_install(command: str) -> bool:
    if not sys.stdin.isatty():
        return False
    print("当前 worktree 尚未准备前端依赖。")
    print(f"一次性准备命令: {command}")
    value = input("是否现在执行？[y/N]: ").strip().lower()
    return value in ("y", "yes")


def default_confirm_frontend_online_retry(command: str) -> bool:
    if not sys.stdin.isatty():
        return False
    print("\n离线依赖安装失败。")
    print("若上方错误为 ERR_PNPM_NO_OFFLINE_TARBALL，可按原范围联网补齐。")
    print(f"联网重试命令: {command}")
    value = input("是否现在联网重试？[y/N]: ").strip().lower()
    return value in ("y", "yes")


def read_pnpm_store_dir(modules_file: Path) -> Path | None:
    try:
        content = modules_file.read_text(encoding="utf-8")
    except OSError:
        return None

    match = re.search(r"^storeDir:\s*(.+?)\s*$", content, re.MULTILINE)
    if not match:
        return None
    raw_path = match.group(1).strip().strip("'\"")
    if not raw_path:
        return None

    store_dir = Path(raw_path).expanduser()
    if not store_dir.is_absolute():
        store_dir = (modules_file.parent / store_dir).resolve()
    if re.fullmatch(r"v\d+", store_dir.name):
        store_dir = store_dir.parent
    return store_dir


def frontend_pnpm_store_dir(context: RepoContext) -> Path | None:
    primary_modules = context.primary_root / "node_modules/.modules.yaml"
    worktree_modules = context.root / "node_modules/.modules.yaml"
    primary_store = read_pnpm_store_dir(primary_modules)
    worktree_store = read_pnpm_store_dir(worktree_modules)
    if primary_store and worktree_store and primary_store != worktree_store:
        raise ZsStartError(
            "主工作树与当前 worktree 的 pnpm store 不一致，已停止安装。\n"
            f"主工作树: {primary_store}\n"
            f"当前 worktree: {worktree_store}"
        )
    return primary_store or worktree_store


def frontend_dependency_filter_args(
    product: str,
    apps: tuple[str, ...] = (),
) -> list[str]:
    selected_apps = apps or frontend_bootstrap_apps(product)
    unique_apps = tuple(dict.fromkeys(selected_apps))
    invalid_apps = [
        app for app in unique_apps if not FRONTEND_APP_NAME_PATTERN.fullmatch(app)
    ]
    if invalid_apps:
        raise ZsStartError(f"无法为非法前端模块安装依赖: {', '.join(invalid_apps)}")
    return [f"--filter={app}..." for app in unique_apps]


def frontend_bootstrap_apps(product: str) -> tuple[str, ...]:
    bootstrap_apps = {
        "default": ("core-shell",),
        "cloud": ("core-shell",),
        "zns": ("zns-shell",),
    }
    apps = bootstrap_apps.get(product)
    if apps is None:
        raise ZsStartError(f"不支持为此前端产品准备依赖: {product}")
    return apps


def build_frontend_dependency_install_command(
    context: RepoContext,
    product: str = "default",
    apps: tuple[str, ...] = (),
) -> list[str]:
    command = ["pnpm"]
    store_dir = frontend_pnpm_store_dir(context)
    if store_dir:
        command.extend(("--store-dir", str(store_dir)))
    command.extend(
        (
            "install",
            "--offline",
            "--frozen-lockfile",
            "--ignore-scripts",
        )
    )
    command.extend(frontend_dependency_filter_args(product, apps))
    return command


def build_frontend_scope_list_command(
    product: str,
    apps: tuple[str, ...],
) -> list[str]:
    return [
        "pnpm",
        *frontend_dependency_filter_args(product, apps),
        "list",
        "--depth",
        "-1",
        "--json",
    ]


def read_frontend_package_manifest(package_dir: Path) -> dict[str, object]:
    manifest_path = package_dir / "package.json"
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ZsStartError(f"无法读取 workspace 包配置: {manifest_path}: {error}") from error
    if not isinstance(payload, dict):
        raise ZsStartError(f"workspace 包配置不是 JSON 对象: {manifest_path}")
    return payload


def list_frontend_scope_packages(
    context: RepoContext,
    product: str,
    apps: tuple[str, ...],
    subject: str = "前端",
) -> tuple[FrontendWorkspacePackage, ...]:
    command = build_frontend_scope_list_command(product, apps)
    result = subprocess.run(
        command,
        cwd=context.root,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ZsStartError(
            f"无法解析{subject}模块依赖闭包（退出码 {result.returncode}）。\n{detail}"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ZsStartError(f"pnpm 未返回有效的{subject}依赖闭包 JSON") from error
    if not isinstance(payload, list):
        raise ZsStartError(f"pnpm 返回的{subject}依赖闭包格式无效")

    root = context.root.resolve()
    packages: list[FrontendWorkspacePackage] = []
    seen_paths: set[Path] = set()
    for item in payload:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        raw_path = item.get("path")
        if not isinstance(name, str) or not isinstance(raw_path, str):
            continue
        package_path = Path(raw_path).resolve()
        try:
            package_path.relative_to(root)
        except ValueError as error:
            raise ZsStartError(f"依赖闭包包含当前 worktree 之外的包: {package_path}") from error
        if package_path in seen_paths:
            continue
        seen_paths.add(package_path)
        packages.append(
            FrontendWorkspacePackage(
                name=name,
                path=package_path,
                manifest=read_frontend_package_manifest(package_path),
            )
        )
    if not packages:
        raise ZsStartError("没有找到待启动模块的 workspace 依赖闭包")
    return tuple(packages)


def frontend_package_dependency_names(manifest: dict[str, object]) -> tuple[str, ...]:
    names: list[str] = []
    for section_name in ("dependencies", "devDependencies"):
        section = manifest.get(section_name)
        if not isinstance(section, dict):
            continue
        names.extend(name for name in section if isinstance(name, str))
    return tuple(dict.fromkeys(names))


def frontend_scope_install_issues(
    context: RepoContext,
    packages: tuple[FrontendWorkspacePackage, ...],
) -> tuple[Path, ...]:
    issues: list[Path] = []
    if not (context.root / "node_modules/.pnpm").is_dir():
        issues.append(context.root / "node_modules/.pnpm")

    workspace_packages = {package.name: package.path.resolve() for package in packages}
    for package in packages:
        for dependency in frontend_package_dependency_names(package.manifest):
            dependency_path = package.path / "node_modules" / dependency
            if not dependency_path.exists():
                issues.append(dependency_path)
                continue
            expected_workspace_path = workspace_packages.get(dependency)
            if expected_workspace_path is None:
                continue
            try:
                actual_path = dependency_path.resolve(strict=True)
            except OSError:
                issues.append(dependency_path)
                continue
            if actual_path != expected_workspace_path:
                issues.append(dependency_path)
    return tuple(dict.fromkeys(issues))


def collect_frontend_runtime_targets(value: object) -> tuple[str, ...]:
    targets: list[str] = []
    if isinstance(value, str):
        if (
            value.startswith("./")
            and "*" not in value
            and Path(value).suffix in FRONTEND_RUNTIME_SUFFIXES
        ):
            targets.append(value)
    elif isinstance(value, dict):
        for nested in value.values():
            targets.extend(collect_frontend_runtime_targets(nested))
    elif isinstance(value, list):
        for nested in value:
            targets.extend(collect_frontend_runtime_targets(nested))
    return tuple(dict.fromkeys(targets))


def frontend_runtime_output_issues(package_dir: Path) -> tuple[Path, ...]:
    manifest = read_frontend_package_manifest(package_dir)
    targets = list(collect_frontend_runtime_targets(manifest.get("exports")))
    for key in ("main", "module"):
        targets.extend(collect_frontend_runtime_targets(manifest.get(key)))
    unique_targets = tuple(dict.fromkeys(targets))
    return tuple(
        package_dir / target.removeprefix("./")
        for target in unique_targets
        if not (package_dir / target.removeprefix("./")).is_file()
    )


def frontend_runtime_outputs_stale(package_dir: Path) -> bool:
    manifest = read_frontend_package_manifest(package_dir)
    targets = list(collect_frontend_runtime_targets(manifest.get("exports")))
    for key in ("main", "module"):
        targets.extend(collect_frontend_runtime_targets(manifest.get(key)))
    output_paths = tuple(
        package_dir / target.removeprefix("./")
        for target in dict.fromkeys(targets)
    )
    if not output_paths or any(not path.is_file() for path in output_paths):
        return False

    input_paths = [package_dir / "package.json"]
    source_dir = package_dir / "src"
    if source_dir.is_dir():
        input_paths.extend(path for path in source_dir.rglob("*") if path.is_file())
    latest_input = max(path.stat().st_mtime_ns for path in input_paths)
    newest_output = max(path.stat().st_mtime_ns for path in output_paths)
    return latest_input > newest_output


def frontend_packages_missing_runtime_outputs(
    packages: tuple[FrontendWorkspacePackage, ...],
    excluded_names: tuple[str, ...],
) -> tuple[FrontendWorkspacePackage, ...]:
    missing: list[FrontendWorkspacePackage] = []
    unbuildable: list[str] = []
    excluded = set(excluded_names)
    for package in packages:
        needs_build = bool(frontend_runtime_output_issues(package.path)) or (
            frontend_runtime_outputs_stale(package.path)
        )
        if package.name in excluded or not needs_build:
            continue
        scripts = package.manifest.get("scripts")
        build_script = scripts.get("build") if isinstance(scripts, dict) else None
        if not isinstance(build_script, str) or not build_script.strip():
            unbuildable.append(package.name)
            continue
        missing.append(package)
    if unbuildable:
        raise ZsStartError(
            "以下 workspace 包缺少运行时产物且没有 build 脚本: "
            + ", ".join(unbuildable)
        )
    return tuple(missing)


def build_frontend_dependency_build_command(
    package_names: tuple[str, ...],
) -> list[str]:
    unique_names = tuple(dict.fromkeys(package_names))
    return [
        "pnpm",
        "--workspace-concurrency=1",
        "--sort",
        "--if-present",
        *(f"--filter={name}" for name in unique_names),
        "run",
        "build",
    ]


def frontend_dependency_issues(context: RepoContext) -> list[Path]:
    issues: list[Path] = []
    dependency_marker = context.root / "node_modules/.bin/nx"
    if not dependency_marker.exists():
        issues.append(dependency_marker)

    postcss_config = context.root / CORE_SHELL_POSTCSS_CONFIG
    postcss_plugin = context.root / PNPM_POSTCSS_PLUGIN
    if postcss_config.is_file() and not postcss_plugin.exists():
        issues.append(postcss_plugin)
    return issues


def validate_frontend_dependencies(context: RepoContext) -> None:
    start_script = context.root / FRONTEND_START_SCRIPT
    if not start_script.is_file():
        raise ZsStartError(f"worktree 中不存在前端启动脚本: {start_script}")

    issues = frontend_dependency_issues(context)
    if issues:
        rendered_issues = "\n".join(f"- {path}" for path in issues)
        raise FrontendDependenciesMissing(
            f"当前 worktree 的前端依赖尚未准备完整:\n{rendered_issues}\n"
            f"请在 zs-start fe 中选择「{FRONTEND_INSTALL_LABEL}」"
            "（快捷键 i）。"
        )

    ensure_core_shell_postcss_plugin(context)
    if not shutil.which("pnpm"):
        raise ZsStartError("未找到 pnpm，无法启动前端")
    if not shutil.which("bun"):
        raise ZsStartError("未找到 bun，无法运行前端启动脚本")


def run_frontend_dependency_install(
    context: RepoContext,
    command: list[str],
    subject: str = "前端",
    confirm_online_retry: Callable[[str], bool] = default_confirm_frontend_online_retry,
) -> None:
    if not shutil.which("pnpm"):
        raise ZsStartError(f"未找到 pnpm，无法准备{subject}依赖")
    result = subprocess.run(command, cwd=context.root, check=False)
    if result.returncode == 0:
        return

    online_command = [argument for argument in command if argument != "--offline"]
    online_command_text = " ".join(online_command)
    if "--offline" not in command or not confirm_online_retry(online_command_text):
        raise ZsStartError(
            f"{subject}依赖安装失败（退出码 {result.returncode}）。\n"
            "请检查上方 pnpm 输出；若离线 store 缺包，可在确认网络可用后执行:\n"
            f"{online_command_text}"
        )

    print(f"\n联网补齐{subject}依赖: {online_command_text}\n")
    online_result = subprocess.run(online_command, cwd=context.root, check=False)
    if online_result.returncode != 0:
        raise ZsStartError(
            f"{subject}依赖联网重试失败（退出码 {online_result.returncode}）。\n"
            "请检查上方 pnpm 输出中的网络、registry 或依赖错误。"
        )


def run_frontend_dependency_build(
    context: RepoContext,
    package_names: tuple[str, ...],
    subject: str = "前端",
) -> None:
    command = build_frontend_dependency_build_command(package_names)
    result = subprocess.run(command, cwd=context.root, check=False)
    if result.returncode != 0:
        raise ZsStartError(
            f"{subject} workspace 包构建失败（退出码 {result.returncode}）。\n"
            "请检查上方构建输出。"
        )


def render_frontend_prepare_issues(issues: tuple[Path, ...]) -> str:
    visible = issues[:8]
    rendered = "\n".join(f"- {path}" for path in visible)
    if len(issues) > len(visible):
        rendered += f"\n- 其余 {len(issues) - len(visible)} 项已省略"
    return rendered


def prepare_frontend_scope(
    context: RepoContext,
    product: str,
    apps: tuple[str, ...],
    *,
    subject: str = "前端",
    completion: str = "继续启动所选模块。",
) -> FrontendPrepareResult:
    selected_apps = apps or frontend_bootstrap_apps(product)
    packages = list_frontend_scope_packages(
        context,
        product,
        selected_apps,
        subject=subject,
    )
    install_issues = frontend_scope_install_issues(context, packages)
    installed = False
    if install_issues:
        command = build_frontend_dependency_install_command(
            context,
            product,
            selected_apps,
        )
        print("\n检测到当前模块依赖链接不完整，正在离线补齐:")
        print(render_frontend_prepare_issues(install_issues))
        print(f"\n执行: {' '.join(command)}\n")
        run_frontend_dependency_install(context, command, subject=subject)
        installed = True
        packages = list_frontend_scope_packages(
            context,
            product,
            selected_apps,
            subject=subject,
        )
        remaining_install_issues = frontend_scope_install_issues(context, packages)
        if remaining_install_issues:
            raise ZsStartError(
                "离线安装完成后仍有依赖链接缺失:\n"
                + render_frontend_prepare_issues(remaining_install_issues)
            )

    missing_packages = frontend_packages_missing_runtime_outputs(
        packages,
        excluded_names=selected_apps,
    )
    built_packages = tuple(package.name for package in missing_packages)
    if built_packages:
        print("\n检测到缺失或过期的 workspace 运行时产物:")
        print("\n".join(f"- {name}" for name in built_packages))
        print("\n正在按依赖顺序构建（单并发）...\n")
        run_frontend_dependency_build(context, built_packages, subject=subject)
        remaining_runtime_issues = tuple(
            issue
            for package in missing_packages
            for issue in frontend_runtime_output_issues(package.path)
        )
        if remaining_runtime_issues:
            raise ZsStartError(
                "构建完成后仍有运行时产物缺失:\n"
                + render_frontend_prepare_issues(remaining_runtime_issues)
            )
        stale_packages = tuple(
            package.name
            for package in missing_packages
            if frontend_runtime_outputs_stale(package.path)
        )
        if stale_packages:
            raise ZsStartError(
                "构建完成后运行时产物仍早于源码: " + ", ".join(stale_packages)
            )

    if installed or built_packages:
        print(f"\n{subject}依赖准备完成，{completion}\n")
    return FrontendPrepareResult(
        installed=installed,
        built_packages=built_packages,
    )


def prepare_cloud_bff_dependencies(context: RepoContext) -> FrontendPrepareResult:
    return prepare_frontend_scope(
        context,
        product="cloud",
        apps=("bff",),
        subject="Cloud BFF",
        completion="可以继续选择管理节点并启动。",
    )


def install_frontend_dependencies(
    context: RepoContext,
    product: str = "default",
    apps: tuple[str, ...] = (),
    confirm: Callable[[str], bool] = default_confirm_frontend_dependency_install,
) -> int:
    command = build_frontend_dependency_install_command(context, product, apps)
    command_text = " ".join(command)
    if not confirm(command_text):
        print("已取消安装前端依赖。")
        return 0

    print(f"工作树: {context.root}")
    print(f"修复: {command_text}\n")
    run_frontend_dependency_install(context, command)
    validate_frontend_dependencies(context)
    prepare_frontend_scope(context, product=product, apps=apps)
    print("\n前端依赖修复完成，可重新运行 zs-start fe 启动服务。")
    return 0


def default_confirm_zns_bff_dependency_install(command: str) -> bool:
    if not sys.stdin.isatty():
        return False
    print("当前 worktree 尚未准备 ZNS BFF 依赖。")
    print(f"一次性准备命令: {command}")
    value = input("是否现在执行？[y/N]: ").strip().lower()
    return value in ("y", "yes")


def ensure_core_shell_postcss_plugin(context: RepoContext) -> None:
    if not (context.root / CORE_SHELL_POSTCSS_CONFIG).is_file():
        return

    plugin_source = context.root / PNPM_POSTCSS_PLUGIN
    if not plugin_source.exists():
        raise ZsStartError(
            "当前 worktree 缺少 @tailwindcss/postcss，无法启动 core-shell。\n"
            "请先在该 worktree 完成前端依赖初始化。"
        )

    plugin_link = context.root / CORE_SHELL_POSTCSS_PLUGIN
    if plugin_link.is_symlink():
        if plugin_link.resolve() == plugin_source.resolve():
            return
        plugin_link.unlink()
    elif plugin_link.exists():
        return

    plugin_link.parent.mkdir(parents=True, exist_ok=True)
    relative_source = os.path.relpath(plugin_source, start=plugin_link.parent)
    plugin_link.symlink_to(relative_source, target_is_directory=True)


def ensure_frontend_dependencies(
    context: RepoContext,
    product: str = "default",
    apps: tuple[str, ...] = (),
    confirm: Callable[[str], bool] = default_confirm_frontend_dependency_install,
) -> None:
    try:
        validate_frontend_dependencies(context)
    except FrontendDependenciesMissing:
        command = build_frontend_dependency_install_command(context, product, apps)
        command_text = " ".join(command)
        if context.is_linked_worktree:
            print("当前 worktree 首次启动，正在自动准备前端基础依赖。")
            print(f"执行: {command_text}\n")
        elif not confirm(command_text):
            raise

        run_frontend_dependency_install(context, command)
        validate_frontend_dependencies(context)

    if apps:
        prepare_frontend_scope(context, product=product, apps=apps)


def ensure_cloud_bff_dependencies(
    context: RepoContext,
    confirm: Callable[[str], bool] = default_confirm_dependency_install,
) -> None:
    nest_cli = context.cloud_bff_dir / "node_modules/.bin/nest"
    if nest_cli.exists():
        return

    command = [
        "pnpm",
        "install",
        "--offline",
        "--frozen-lockfile",
        "--filter=bff...",
    ]
    command_text = " ".join(command)
    if not confirm(command_text):
        raise ZsStartError(
            f"Cloud BFF 依赖尚未准备: {nest_cli}\n"
            f"可在 worktree 根目录执行: {command_text}"
        )
    if not shutil.which("pnpm"):
        raise ZsStartError("未找到 pnpm，无法准备 Cloud BFF 依赖")

    result = subprocess.run(command, cwd=context.root, check=False)
    if result.returncode != 0:
        raise ZsStartError(
            "Cloud BFF 依赖准备失败；离线缓存可能不完整。\n"
            "请在网络可用时于 worktree 根目录执行: "
            "pnpm install --frozen-lockfile --filter=bff..."
        )
    if not nest_cli.exists():
        raise ZsStartError(f"依赖命令执行完成，但仍未找到 Nest CLI: {nest_cli}")


def ensure_zns_bff_dependencies(
    context: RepoContext,
    confirm: Callable[[str], bool] = default_confirm_zns_bff_dependency_install,
) -> None:
    if not context.zns_bff_dir.is_dir():
        raise ZsStartError(f"worktree 中不存在 ZNS BFF: {context.zns_bff_dir}")

    nest_cli = context.zns_bff_dir / "node_modules/.bin/nest"
    if nest_cli.exists():
        return

    command = [
        "pnpm",
        "install",
        "--offline",
        "--frozen-lockfile",
        "--filter=zns-bff...",
    ]
    command_text = " ".join(command)
    if not confirm(command_text):
        raise ZsStartError(
            f"ZNS BFF 依赖尚未准备: {nest_cli}\n"
            f"可在 worktree 根目录执行: {command_text}"
        )
    if not shutil.which("pnpm"):
        raise ZsStartError("未找到 pnpm，无法准备 ZNS BFF 依赖")

    result = subprocess.run(command, cwd=context.root, check=False)
    if result.returncode != 0:
        raise ZsStartError(
            "ZNS BFF 依赖准备失败；离线缓存可能不完整。\n"
            "请在网络可用时于 worktree 根目录执行: "
            "pnpm install --frozen-lockfile --filter=zns-bff..."
        )
    if not nest_cli.exists():
        raise ZsStartError(f"依赖命令执行完成，但仍未找到 Nest CLI: {nest_cli}")


def parse_targets(lines: list[str]) -> list[Target]:
    targets: list[Target] = []
    for index, line in enumerate(lines):
        parsed = parse_server_line(line)
        if not parsed:
            continue
        active, value = parsed
        host = extract_host(value)
        if not host:
            continue
        targets.append(
            Target(
                line_index=index,
                value=server_url(host),
                host=host,
                desc=previous_desc(lines, index) or DEFAULT_DESC,
                active=active,
            )
        )

    if not any(target.active for target in targets):
        mysql_host = current_mysql_host(lines)
        for target in targets:
            if target.host == mysql_host:
                target.active = True
    return targets


def current_mysql_host(lines: list[str]) -> str:
    pattern = re.compile(rf"^\s*{re.escape(MYSQL_HOST_KEY)}\s*=\s*(.*?)\s*$")
    for line in lines:
        match = pattern.match(line)
        if match:
            return extract_host(match.group(1))
    return ""


def current_server_host(lines: list[str]) -> str:
    for line in lines:
        parsed = parse_server_line(line)
        if parsed and parsed[0]:
            return extract_host(parsed[1])
    return current_mysql_host(lines)


def selectable_cloud_bff_targets(
    candidate_lines: list[str],
    runtime_lines: list[str],
) -> list[Target]:
    """候选地址统一来自主工作树，但当前状态属于实际启动的 worktree。"""
    active_host = current_server_host(runtime_lines)
    targets = parse_targets(candidate_lines)
    for target in targets:
        target.active = target.host == active_host
    return targets


def clear_screen() -> None:
    sys.stdout.write("\033[2J\033[H")


def repo_location_label(context: RepoContext) -> str:
    if context.is_linked_worktree:
        return f"Worktree · {context.root.name}"
    return "主工作树"


def context_box_width(context: RepoContext, terminal_width: int) -> int:
    values = (repo_location_label(context), context.branch, str(context.root))
    label_width = display_width("运行位置")
    content_width = 1 + label_width + 2 + max(display_width(value) for value in values) + 1
    preferred_width = content_width + 2
    available_width = max(20, terminal_width - 2)
    return min(max(28, min(preferred_width, 108)), available_width)


def render_context_row(label: str, value: str, box_width: int, value_code: str = "") -> None:
    border = color("│", "36;1")
    label_width = display_width("运行位置")
    padded_label = pad_text_to_width(label, label_width)
    prefix = f" {padded_label}  "
    value_width = max(1, box_width - 2 - display_width(prefix) - 1)
    padded_value = pad_text_to_width(value, value_width)
    rendered_value = color(padded_value, value_code) if value_code else padded_value
    print(f"{border}{color(prefix, '2')}{rendered_value} {border}")


def render_repo_context(context: RepoContext, terminal_width: int) -> None:
    box_width = context_box_width(context, terminal_width)
    print(color(f"╭{'─' * (box_width - 2)}╮", "36;1"))
    render_context_row("运行位置", repo_location_label(context), box_width, "36;1")
    render_context_row("当前分支", context.branch, box_width, "36")
    render_context_row("项目目录", str(context.root), box_width, "2")
    print(color(f"╰{'─' * (box_width - 2)}╯", "36;1"))


def keycap(text: str) -> str:
    if not color_enabled():
        return f"[{text}]"
    return color(f" {text} ", "7;1")


def render_shortcut_items(shortcuts: tuple[tuple[str, str], ...], terminal_width: int) -> None:
    line_parts: list[str] = []
    line_width = 0
    max_width = max(20, terminal_width - 2)
    for key, action in shortcuts:
        plain = f"[{key}] {action}"
        rendered = f"{keycap(key)} {action}"
        separator = "   " if line_parts else ""
        part_width = display_width(separator + plain)
        if line_parts and line_width + part_width > max_width:
            print("".join(line_parts))
            line_parts = []
            line_width = 0
            separator = ""
            part_width = display_width(plain)
        line_parts.append(f"{separator}{rendered}")
        line_width += part_width
    if line_parts:
        print("".join(line_parts))


def render_shortcuts(terminal_width: int) -> None:
    render_shortcut_items(
        (
            ("↑/↓", "选择"),
            ("Enter", "启动"),
            ("i", "修复依赖"),
            ("e", "编辑"),
            ("Esc", "退出"),
            ("w", "切换工作树"),
            ("→→", "浏览器访问"),
        ),
        terminal_width,
    )


def render_edit_shortcuts(terminal_width: int) -> None:
    render_shortcut_items(
        (
            ("↑/↓", "选择字段"),
            ("Enter", "编辑/确认"),
            ("Delete", "删除地址"),
            ("Esc", "放弃返回"),
        ),
        terminal_width,
    )


def render_frontend_menu(
    context: RepoContext,
    selected: int,
    last_state: FrontendStartState | None = None,
) -> None:
    terminal_width = shutil.get_terminal_size((100, 24))[0]
    clear_screen()
    render_repo_context(context, terminal_width)
    print()
    print(color("启动前端服务", "1"))
    print()
    render_shortcut_items(
        (
            ("↑/↓", "选择方式"),
            ("Enter", "继续"),
            ("i", "修复依赖"),
            ("w", "切换工作树"),
            ("Esc", "退出"),
        ),
        terminal_width,
    )
    print()
    print(color("  启动方式     后续命令", "1"))
    for index, (_, label, command) in enumerate(FRONTEND_PRODUCTS):
        is_selected = index == selected
        pointer = color(">", "36;1") if is_selected else " "
        padded_label = pad_text_to_width(label, 12)
        rendered_label = color(padded_label, "36;1") if is_selected else padded_label
        rendered_command = color(command, "36") if is_selected else command
        print(f"{pointer} {rendered_label} {rendered_command}")

    if last_state is not None:
        index = len(FRONTEND_PRODUCTS)
        is_selected = index == selected
        pointer = color(">", "36;1") if is_selected else " "
        padded_label = pad_text_to_width("上一次启动", 12)
        rendered_label = color(padded_label, "33;1")
        command = " ".join(build_frontend_start_command(last_state))
        rendered_command = color(command, "36") if is_selected else command
        print(f"{pointer} {rendered_label} {rendered_command}")
    print()


def render_zns_bff_menu(context: RepoContext) -> None:
    terminal_width = shutil.get_terminal_size((100, 24))[0]
    clear_screen()
    render_repo_context(context, terminal_width)
    print()
    print(color("启动 ZNS BFF", "1"))
    print()
    render_shortcut_items(
        (("Enter", "启动"), ("w", "切换工作树"), ("Esc", "退出")),
        terminal_width,
    )
    print()
    print(f"  启动命令  {color('pnpm start:dev', '36;1')}")
    print(f"  服务目录  {color(str(context.zns_bff_dir), '2')}")
    print()


def render_menu(
    targets: list[Target],
    selected: int,
    context: RepoContext | None = None,
) -> None:
    terminal_width = shutil.get_terminal_size((100, 24))[0]
    status_width = 6
    host_width = 24
    wrap_safe_width = max(20, terminal_width - 2)
    row_fixed_width = display_width("> ") + status_width + 1 + host_width + 1
    desc_width = max(12, wrap_safe_width - row_fixed_width)

    clear_screen()
    if context:
        render_repo_context(context, terminal_width)
        print()
    render_shortcuts(terminal_width)
    print()
    print(color(f"  {'状态':<6} {'Host/IP':<24} 描述", "1"))

    items = targets + [Target(-1, "", "", "+ 新增地址", False)]
    for index, target in enumerate(items):
        pointer = color(">", "36;1") if index == selected else " "
        if target.line_index == -1:
            print(f"{pointer} {pad_text_to_width('操作', status_width)} {color(target.desc, '33;1')}")
        else:
            status_text = "* 当前" if target.active else "候选"
            padded_status = pad_text_to_width(status_text, status_width)
            status = color(padded_status, "32;1") if target.active else color(padded_status, "2")
            desc_text = fit_text_to_width(target.desc, desc_width)
            desc = color(desc_text, "36;1") if index == selected else desc_text
            host_text = pad_text_to_width(target.host, host_width)
            host = color(host_text, "36") if index == selected else host_text
            print(f"{pointer} {status} {host} {desc}")
    print()


def worktree_display_name(context: RepoContext) -> str:
    if not context.is_linked_worktree:
        return "主工作树"
    parent = context.root.parent
    if parent.parent.name == "worktrees" and parent.parent.parent.name == ".codex":
        return f"Codex · {parent.name}"
    return context.root.name


def wrap_text_to_width(text: str, width: int) -> list[str]:
    """按终端显示宽度换行；路径优先在 `/` 后断行并保留全部内容。"""
    if not text:
        return [""]

    lines: list[str] = []
    remaining = text
    safe_width = max(1, width)
    while remaining:
        used_width = 0
        hard_break = 0
        for index, char in enumerate(remaining):
            char_width = display_width(char)
            if hard_break and used_width + char_width > safe_width:
                break
            used_width += char_width
            hard_break = index + 1
        if hard_break >= len(remaining):
            lines.append(remaining)
            break

        slash_break = remaining.rfind("/", 1, hard_break)
        break_at = slash_break + 1 if slash_break > 0 else hard_break
        lines.append(remaining[:break_at])
        remaining = remaining[break_at:]
    return lines


def render_worktree_detail(context: RepoContext, box_width: int) -> None:
    border = color("│", "36;1")
    label_width = display_width("分支")
    value_width = max(8, box_width - 2 - 1 - label_width - 2 - 1)
    rows = (("分支", context.branch, "36"), ("路径", str(context.root), "2"))
    for label, value, value_code in rows:
        value_lines = wrap_text_to_width(value, value_width)
        for index, line in enumerate(value_lines):
            row_label = label if index == 0 else ""
            prefix = f" {pad_text_to_width(row_label, label_width)}  "
            padded_value = pad_text_to_width(line, value_width)
            print(f"{border}{color(prefix, '2')}{color(padded_value, value_code)} {border}")


def render_worktree_menu(
    contexts: list[RepoContext],
    selected: int,
    current_root: Path,
) -> None:
    terminal_width = shutil.get_terminal_size((100, 24))[0]
    available_width = max(20, terminal_width - 2)

    clear_screen()
    print(color("切换工作树", "1"))
    print()
    render_shortcut_items(
        (("↑/↓", "选择"), ("Enter", "切换"), ("Esc", "返回")),
        terminal_width,
    )
    print()
    print(color("  工作树", "1"))
    for index, context in enumerate(contexts):
        is_selected = index == selected
        is_current = context.root == current_root
        pointer = color(">", "36;1") if is_selected else " "
        marker = color("*", "32;1") if is_current else " "
        current_label = color("  当前", "32;1") if is_current else ""
        current_label_width = display_width("  当前") if is_current else 0
        name_width = max(8, available_width - 4 - current_label_width)
        name_lines = wrap_text_to_width(worktree_display_name(context), name_width)
        name_code = "36;1" if is_selected else ""
        rendered_name = color(name_lines[0], name_code) if name_code else name_lines[0]
        print(f"{pointer} {marker} {rendered_name}{current_label}")
        for line in name_lines[1:]:
            rendered_line = color(line, name_code) if name_code else line
            print(f"    {rendered_line}")

    print()
    print(color("选中项", "1"))
    selected_context = contexts[selected]
    detail_width = max(
        display_width(selected_context.branch),
        display_width(str(selected_context.root)),
    )
    box_width = min(120, available_width, max(32, detail_width + 10))
    print(color(f"╭{'─' * (box_width - 2)}╮", "36;1"))
    render_worktree_detail(selected_context, box_width)
    print(color(f"╰{'─' * (box_width - 2)}╯", "36;1"))
    print()


def render_target_editor(target: Target, draft: EditDraft, selected: int) -> None:
    terminal_width = shutil.get_terminal_size((100, 24))[0]
    fields = (
        ("Host/IP", draft.host, draft.host != target.host),
        ("描述", draft.desc, draft.desc != target.desc),
    )
    label_width = max(display_width(label) for label, _, _ in fields)
    value_width = max(12, terminal_width - label_width - 5)

    clear_screen()
    print(color("编辑后端地址", "1"))
    print()
    render_edit_shortcuts(terminal_width)
    print()
    status = color("* 当前", "32;1") if target.active else color("候选", "2")
    print(f"  {pad_text_to_width('状态', label_width)}  {status}")
    for index, (label, value, changed) in enumerate(fields):
        is_selected = index == selected
        pointer = color(">", "36;1") if is_selected else " "
        padded_label = pad_text_to_width(label, label_width)
        rendered_label = color(padded_label, "36;1") if is_selected else padded_label
        marker = "  已修改" if changed else ""
        fitted_value = fit_text_to_width(value, max(8, value_width - display_width(marker)))
        value_code = "36;1" if is_selected else "33" if changed else ""
        rendered_value = color(fitted_value, value_code) if value_code else fitted_value
        rendered_marker = color(marker, "33;1") if marker else ""
        print(f"{pointer} {rendered_label}  {rendered_value}{rendered_marker}")

    is_confirm_selected = selected == 2
    pointer = color(">", "36;1") if is_confirm_selected else " "
    button = "[ 确认修改 ]"
    if is_confirm_selected:
        rendered_button = color(button, "7;1")
    elif draft.has_changes(target):
        rendered_button = color(button, "32;1")
    else:
        rendered_button = color(button, "2")
    print(f"{pointer} {rendered_button}")
    print()


def display_width(text: str) -> int:
    return sum(2 if unicodedata.east_asian_width(char) in ("W", "F") else 1 for char in text)


def read_char(fd: int) -> str:
    first = os.read(fd, 1)
    if not first:
        return ""
    lead = first[0]
    if lead < 0x80:
        return first.decode("ascii", "replace")
    length = 2 if lead < 0xE0 else 3 if lead < 0xF0 else 4
    data = first
    while len(data) < length:
        chunk = os.read(fd, length - len(data))
        if not chunk:
            break
        data += chunk
    return data.decode("utf-8", "replace")


def read_escape_tail(fd: int) -> str:
    if not select.select([fd], [], [], ESC_SEQUENCE_TIMEOUT)[0]:
        return ""
    lead = os.read(fd, 1)
    if lead not in (b"[", b"O"):
        return ""
    sequence = b""
    while select.select([fd], [], [], ESC_SEQUENCE_TIMEOUT)[0]:
        byte = os.read(fd, 1)
        if not byte:
            break
        sequence += byte
        if 0x40 <= byte[0] <= 0x7E:
            break
    return sequence.decode("ascii", "replace")


def edit_line(prompt: str, initial: str = "") -> str | None:
    """自绘行编辑器：整行重绘保证显示与数据一致，按字符（而非字节）移动光标。

    替代 readline——macOS libedit 对中文宽字符的回显/光标处理有缺陷，
    会出现删不掉的残影和左右移动后乱序。Esc 取消返回 None。
    """
    fd = sys.stdin.fileno()
    chars = list(initial)
    cursor = len(chars)
    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(fd)
        while True:
            tail_width = display_width("".join(chars[cursor:]))
            sys.stdout.write(f"\r\033[K{prompt}{''.join(chars)}")
            if tail_width:
                sys.stdout.write(f"\033[{tail_width}D")
            sys.stdout.flush()

            char = read_char(fd)
            if not char or char in ("\r", "\n"):
                sys.stdout.write("\n")
                return "".join(chars)
            if char == "\x03":
                raise KeyboardInterrupt
            if char == "\x1b":
                tail = read_escape_tail(fd)
                if not tail:
                    sys.stdout.write("\n")
                    return None
                if tail == "D":
                    cursor = max(0, cursor - 1)
                elif tail == "C":
                    cursor = min(len(chars), cursor + 1)
                elif tail == "H":
                    cursor = 0
                elif tail == "F":
                    cursor = len(chars)
                elif tail == "3~" and cursor < len(chars):
                    del chars[cursor]
            elif char in ("\x7f", "\x08"):
                if cursor > 0:
                    cursor -= 1
                    del chars[cursor]
            elif char == "\x01":
                cursor = 0
            elif char == "\x05":
                cursor = len(chars)
            elif char == "\x15":
                chars = []
                cursor = 0
            elif char >= " ":
                chars.insert(cursor, char)
                cursor += 1
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)


def read_input(prompt: str, initial: str = "") -> str | None:
    if not sys.stdin.isatty():
        try:
            return input(prompt)
        except EOFError:
            return None
    return edit_line(prompt, initial)


def read_key() -> str:
    fd = sys.stdin.fileno()
    char = os.read(fd, 1)
    if char == b"\x03":
        raise KeyboardInterrupt
    if char in (b"\r", b"\n"):
        return "enter"
    if char in (b"e", b"E"):
        return "edit"
    if char in (b"w", b"W"):
        return "switch"
    if char in (b"i", b"I"):
        return "install"
    if char == b"\x1b":
        tail = read_escape_tail(fd)
        if not tail:
            return "escape"
        if tail == "A":
            return "up"
        if tail == "B":
            return "down"
        if tail == "C":
            return "right"
        if tail == "3~":
            return "delete"
    return ""


def choose_command_from_help() -> str | None:
    selected = 0
    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        sys.stdout.write("\x1b[s")
        sys.stdout.flush()
        while True:
            sys.stdout.write("\x1b[u\x1b[J")
            print_help(MENU_COMMANDS[selected])
            sys.stdout.flush()
            key = read_key()
            if key == "up":
                selected = (selected - 1) % len(MENU_COMMANDS)
            elif key == "down":
                selected = (selected + 1) % len(MENU_COMMANDS)
            elif key == "enter":
                return MENU_COMMANDS[selected]
            elif key == "escape":
                return None
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)


def is_double_right(previous_at: float | None, current_at: float) -> bool:
    return previous_at is not None and 0 <= current_at - previous_at <= DOUBLE_RIGHT_TIMEOUT


def choose_with_keys(
    targets: list[Target],
    initial: int | None = None,
    context: RepoContext | None = None,
) -> tuple[str, int]:
    if initial is None:
        initial = next((index for index, target in enumerate(targets) if target.active), 0)
    item_count = len(targets) + 1
    selected = min(max(initial, 0), item_count - 1)
    previous_right_at: float | None = None
    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        while True:
            render_menu(targets, selected, context)
            key = read_key()
            if key == "switch" and context:
                return "switch", -1
            if key == "install":
                return "install", -1
            if key == "right":
                current_at = time.monotonic()
                if is_double_right(previous_right_at, current_at):
                    if 0 <= selected < len(targets):
                        webbrowser.open(host_url(targets[selected].host, UI_PORT))
                    previous_right_at = None
                else:
                    previous_right_at = current_at
                continue

            previous_right_at = None
            if key == "up":
                selected = (selected - 1) % item_count
            elif key == "down":
                selected = (selected + 1) % item_count
            elif key == "enter":
                return ("add", -1) if selected == len(targets) else ("select", selected)
            elif key == "edit" and 0 <= selected < len(targets):
                return ("edit", selected)
            elif key == "escape":
                raise KeyboardInterrupt
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        clear_screen()


def choose_repo_context(current: RepoContext) -> RepoContext | None:
    contexts = list_repo_contexts(current)
    selected = next(
        (index for index, context in enumerate(contexts) if context.root == current.root),
        0,
    )
    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        while True:
            render_worktree_menu(contexts, selected, current.root)
            key = read_key()
            if key == "up":
                selected = (selected - 1) % len(contexts)
            elif key == "down":
                selected = (selected + 1) % len(contexts)
            elif key == "enter":
                selected_context = contexts[selected]
                remember_repo_context(selected_context)
                return selected_context
            elif key == "escape":
                return None
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        clear_screen()


def switch_project(arguments: list[str]) -> int:
    if arguments == ["--current"]:
        print(zs_start_manager.selected_project())
        return 0
    if len(arguments) > 1 or (arguments and arguments[0].startswith("-") and arguments != ["--list"]):
        raise ZsStartError("用法: zs-start project [目录或名称 | --current | --list]")
    if arguments and arguments != ["--list"]:
        selected = zs_start_manager.select_project(arguments[0])
    else:
        projects = zs_start_manager.discover_projects()
        try:
            current = zs_start_manager.selected_project()
        except zs_start_manager.ManagerError:
            current = None
        if current is not None and current not in projects:
            projects.append(current)
        if not projects:
            raise ZsStartError("workspace 下未找到 ZStack 项目，请运行 zs-start project <完整目录>。")
        if arguments == ["--list"] or not sys.stdin.isatty():
            for project in projects:
                marker = "*" if project == current else " "
                print(f"{marker} {project.name}  {project}")
            return 0
        selected_index = projects.index(current) if current in projects else 0
        old_settings = termios.tcgetattr(sys.stdin)
        try:
            tty.setcbreak(sys.stdin.fileno())
            while True:
                clear_screen()
                print(color("切换默认项目", "1"))
                print("↑/↓ 选择 · Enter 切换 · Esc 取消\n")
                for index, project in enumerate(projects):
                    pointer = ">" if index == selected_index else " "
                    marker = " · 当前" if project == current else ""
                    print(color(f"{pointer} {project.name}{marker}", "36;1" if index == selected_index else "2"))
                    print(f"    {project}\n")
                key = read_key()
                if key == "up":
                    selected_index = (selected_index - 1) % len(projects)
                elif key == "down":
                    selected_index = (selected_index + 1) % len(projects)
                elif key == "enter":
                    break
                elif key == "escape":
                    return 0
        finally:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
            clear_screen()
        selected = zs_start_manager.select_project(str(projects[selected_index]))
    context = resolve_repo_context(requested_worktree=selected, primary_hint=selected)
    remember_repo_context(context)
    print(f"默认项目已切换: {selected}")
    print("后续 zs-start 命令使用此项目；当前终端目录保持不变。")
    return 0


def choose_frontend_action(
    context: RepoContext,
    last_state: FrontendStartState | None = None,
) -> str:
    actions = [product[0] for product in FRONTEND_PRODUCTS]
    if last_state is not None:
        actions.append("last")
    selected = len(actions) - 1 if last_state is not None else 0
    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        while True:
            render_frontend_menu(context, selected, last_state=last_state)
            key = read_key()
            if key == "up":
                selected = (selected - 1) % len(actions)
            elif key == "down":
                selected = (selected + 1) % len(actions)
            elif key == "enter":
                return actions[selected]
            elif key == "install":
                return f"{FRONTEND_INSTALL_ACTION}:{actions[selected]}"
            elif key == "switch":
                return "switch"
            elif key == "escape":
                raise KeyboardInterrupt
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        clear_screen()


def choose_zns_bff_action(context: RepoContext) -> str:
    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        while True:
            render_zns_bff_menu(context)
            key = read_key()
            if key == "enter":
                return "start"
            if key == "switch":
                return "switch"
            if key == "escape":
                raise KeyboardInterrupt
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        clear_screen()


def choose_edit_field(target: Target, draft: EditDraft, initial: int = 0) -> tuple[str, int]:
    selected = min(max(initial, 0), 2)
    old_settings = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        while True:
            render_target_editor(target, draft, selected)
            key = read_key()
            if key == "up":
                selected = (selected - 1) % 3
            elif key == "down":
                selected = (selected + 1) % 3
            elif key == "enter":
                return ("confirm" if selected == 2 else "edit"), selected
            elif key == "delete":
                return "delete", selected
            elif key == "escape":
                return "back", selected
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        clear_screen()


def choose_with_numbers(
    targets: list[Target],
    context: RepoContext | None = None,
) -> tuple[str, int]:
    if context:
        render_repo_context(context, shutil.get_terminal_size((100, 24))[0])
        print()
    print(f"   {'状态':<6} {'Host/IP':<24} 描述")
    for index, target in enumerate(targets, start=1):
        active = "* 当前" if target.active else "候选"
        print(f"{index}. {active:<6} {clip_text(target.host, 24):<24} {clip_text(target.desc, 22)}")
    print(f"{len(targets) + 1}. 操作   + 新增地址")
    print()

    while True:
        value = input("选择序号: ").strip()
        if value.isdigit() and 1 <= int(value) <= len(targets) + 1:
            index = int(value) - 1
            return ("add", -1) if index == len(targets) else ("select", index)
        print("请输入有效序号")


def prompt_host_desc(initial_host: str = "", initial_desc: str = "") -> tuple[str, str] | None:
    if sys.stdin.isatty():
        clear_screen()
        print(color("录入地址（Enter 确认，Esc 返回列表）", "1"))

    while True:
        raw_host = read_input("Host/IP: ", initial_host)
        if raw_host is None:
            return None
        host = extract_host(raw_host)
        if host:
            break
        print("Host/IP 不能为空")
        initial_host = raw_host

    desc = read_input("描述: ", initial_desc)
    if desc is None:
        return None
    return host, desc.strip() or DEFAULT_DESC


def prompt_host_value(initial_host: str) -> str | None:
    if sys.stdin.isatty():
        clear_screen()
        print(color("编辑 Host/IP（Enter 确认，Esc 取消）", "1"))
        print()
    while True:
        raw_host = read_input("Host/IP: ", initial_host)
        if raw_host is None:
            return None
        host = extract_host(raw_host)
        if host:
            return host
        print("Host/IP 不能为空")
        initial_host = raw_host


def prompt_desc_value(initial_desc: str) -> str | None:
    if sys.stdin.isatty():
        clear_screen()
        print(color("编辑描述（Enter 确认，Esc 取消）", "1"))
        print()
    desc = read_input("描述: ", initial_desc)
    if desc is None:
        return None
    return desc.strip() or DEFAULT_DESC


def replace_or_append_key(lines: list[str], key: str, value: str) -> list[str]:
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for index, line in enumerate(lines):
        if pattern.match(line):
            lines[index] = f"{key}={value}"
            return lines

    if lines and lines[-1].strip():
        lines.append("")
    lines.append(f"{key}={value}")
    return lines


def replace_zops_host(lines: list[str], host: str) -> list[str]:
    """只替换 ZOPS_SERVER 值里的 host，保留原端口和行内注释。"""
    pattern = re.compile(rf"^(\s*{re.escape(ZOPS_KEY)}\s*=\s*)(\S*)(.*)$")
    for index, line in enumerate(lines):
        match = pattern.match(line)
        if match:
            try:
                port = urlsplit(match.group(2)).port or ZOPS_PORT
            except ValueError:
                port = ZOPS_PORT
            lines[index] = f"{match.group(1)}{host_url(host, port)}{match.group(3)}"
            return lines
    return lines


def append_candidate(lines: list[str], host: str, desc: str) -> tuple[list[str], int]:
    server_lines = [index for index, line in enumerate(lines) if parse_server_line(line)]
    insert_at = max(server_lines) + 1 if server_lines else len(lines)
    lines[insert_at:insert_at] = [f"# {desc}", f"# {SERVER_KEY}={server_url(host)}"]
    return lines, insert_at + 1


def apply_host_edit(lines: list[str], target: Target, host: str) -> tuple[list[str], int]:
    index = target.line_index
    prefix = "" if target.active else "# "
    lines[index] = f"{prefix}{SERVER_KEY}={server_url(host)}"
    if target.active:
        lines = replace_or_append_key(lines, MYSQL_HOST_KEY, host)
        lines = replace_zops_host(lines, host)
    return lines, index


def apply_desc_edit(lines: list[str], target: Target, desc: str) -> tuple[list[str], int]:
    index = target.line_index
    if previous_desc(lines, index):
        lines[index - 1] = f"# {desc}"
    else:
        lines[index:index] = [f"# {desc}"]
        index += 1
    return lines, index


def apply_target(lines: list[str], targets: list[Target], selected: Target) -> list[str]:
    for target in targets:
        lines[target.line_index] = f"# {SERVER_KEY}={server_url(target.host)}"
    lines[selected.line_index] = f"{SERVER_KEY}={server_url(selected.host)}"

    lines = replace_or_append_key(lines, MYSQL_HOST_KEY, selected.host)
    return replace_zops_host(lines, selected.host)


def apply_runtime_target(lines: list[str], selected: Target) -> list[str]:
    lines = replace_or_append_key(lines, SERVER_KEY, selected.value)
    lines = replace_or_append_key(lines, MYSQL_HOST_KEY, selected.host)
    return replace_zops_host(lines, selected.host)


def delete_target(lines: list[str], targets: list[Target], target: Target) -> tuple[int, list[str]]:
    target_position = next(
        (index for index, item in enumerate(targets) if item.line_index == target.line_index),
        0,
    )
    start = target.line_index - 1 if previous_desc(lines, target.line_index) else target.line_index
    updated = lines[:start] + lines[target.line_index + 1 :]
    remaining_targets = parse_targets(updated)

    if target.active and remaining_targets:
        replacement_index = min(target_position, len(remaining_targets) - 1)
        updated = apply_target(updated, remaining_targets, remaining_targets[replacement_index])
        return replacement_index, updated

    if remaining_targets:
        return min(target_position, len(remaining_targets) - 1), updated
    return 0, updated


def confirm_delete(target: Target) -> bool:
    if sys.stdin.isatty():
        clear_screen()
        print(color("确认删除 Cloud BFF 后端地址", "1"))
        print(f"IP: {target.host}")
        print(f"描述: {target.desc}\n")

    value = read_input("输入 y 确认删除，其他内容取消: ")
    return value is not None and value.strip().lower() in ("y", "yes")


def write_env(lines: list[str], env_path: Path) -> None:
    temp_path = env_path.parent / ".env.tmp"
    temp_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(temp_path, env_path)


def cursor_for_line(targets: list[Target], line_index: int) -> int | None:
    for index, target in enumerate(targets):
        if target.line_index == line_index:
            return index
    return None


def edit_target(lines: list[str], target_index: int, env_path: Path) -> int:
    selected_field = 0
    targets = parse_targets(lines)
    target = targets[target_index]
    draft = EditDraft(host=target.host, desc=target.desc)
    while True:
        action, selected_field = choose_edit_field(target, draft, selected_field)

        if action == "back":
            return target_index
        if action == "delete":
            if not confirm_delete(target):
                continue
            cursor, lines = delete_target(lines, targets, target)
            write_env(lines, env_path)
            return cursor

        if action == "confirm":
            if not draft.has_changes(target):
                return target_index
            server_line = target.line_index
            if draft.host != target.host:
                lines, server_line = apply_host_edit(lines, target, draft.host)
            if draft.desc != target.desc:
                lines, server_line = apply_desc_edit(lines, target, draft.desc)
            write_env(lines, env_path)
            updated_index = cursor_for_line(parse_targets(lines), server_line)
            if updated_index is None:
                raise ZsStartError("确认修改后无法重新定位 Cloud BFF 地址")
            return updated_index

        if selected_field == 0:
            host = prompt_host_value(draft.host)
            if host is None:
                continue
            draft.host = host
        else:
            initial_desc = "" if draft.desc == DEFAULT_DESC else draft.desc
            desc = prompt_desc_value(initial_desc)
            if desc is None:
                continue
            draft.desc = desc


def prepare_cloud_bff_context(context: RepoContext) -> Path:
    if not context.cloud_bff_dir.is_dir():
        raise ZsStartError(f"worktree 中不存在 Cloud BFF: {context.cloud_bff_dir}")
    render_repo_context(context, shutil.get_terminal_size((100, 24))[0])
    print()
    ensure_cloud_bff_dependencies(context)
    prepare_cloud_bff_dependencies(context)
    return initialize_cloud_bff_env(context)


def start_cloud_bff(context: RepoContext) -> int:
    env_path = prepare_cloud_bff_context(context)

    cursor: int | None = None
    while True:
        runtime_lines = read_env(env_path)
        candidate_env_path = context.primary_cloud_bff_env
        candidate_lines = read_env(candidate_env_path)
        targets = selectable_cloud_bff_targets(candidate_lines, runtime_lines)
        if sys.stdin.isatty():
            action, index = choose_with_keys(targets, cursor, context)
        else:
            action, index = choose_with_numbers(targets, context)

        if action == "switch":
            next_context = choose_repo_context(context)
            if next_context is None or next_context.root == context.root:
                continue
            next_env_path = prepare_cloud_bff_context(next_context)
            context = next_context
            env_path = next_env_path
            cursor = None
            continue

        if action == "install":
            prepare_cloud_bff_dependencies(context)
            continue

        if action == "select":
            selected = targets[index]
            if context.is_linked_worktree:
                write_env(apply_runtime_target(runtime_lines, selected), env_path)
            else:
                write_env(
                    apply_target(candidate_lines, targets, selected),
                    candidate_env_path,
                )
            break

        if action == "add":
            entry = prompt_host_desc()
            if entry is None:
                cursor = len(targets)
                continue
            host, desc = entry
            candidate_lines, server_line = append_candidate(candidate_lines, host, desc)
            write_env(candidate_lines, candidate_env_path)
            cursor = cursor_for_line(parse_targets(candidate_lines), server_line)
        elif action == "edit":
            cursor = edit_target(candidate_lines, index, candidate_env_path)

    print(f"已选择: {selected.host}({selected.desc})")
    print(f"已更新: {env_path}")
    print("启动: pnpm start:dev\n")

    branch_name = context.branch.rsplit("/", 1)[-1]
    set_terminal_title(f"BFF:{branch_name}:{selected.host}")
    try:
        return subprocess.run(["pnpm", "start:dev"], cwd=context.cloud_bff_dir).returncode
    except KeyboardInterrupt:
        return 130
    finally:
        set_terminal_title("BFF")


def report_frontend_error(error: ZsStartError) -> None:
    print(file=sys.stderr)
    print(color("前端启动失败", "31;1"), file=sys.stderr)
    print(f"错误: {error}", file=sys.stderr)
    print(
        f"处理方式: 重新运行 zs-start fe，选择「{FRONTEND_INSTALL_LABEL}」"
        "（快捷键 i）。",
        file=sys.stderr,
    )


def wait_for_frontend_acknowledgement() -> None:
    if not sys.stdin.isatty():
        return
    try:
        input("\n按 Enter 退出...")
    except (EOFError, OSError):
        return


def finish_frontend_error(error: ZsStartError) -> int:
    report_frontend_error(error)
    wait_for_frontend_acknowledgement()
    return 1


def resolve_frontend_dependency_scope(
    action: str,
    last_state: FrontendStartState | None,
) -> tuple[str, tuple[str, ...]]:
    if action == "last":
        if last_state is None:
            raise ZsStartError("没有可用于安装依赖的上一次启动记录")
        return last_state.product, last_state.apps
    if action in {product[0] for product in FRONTEND_PRODUCTS}:
        return action, ()
    raise ZsStartError(f"无法识别前端依赖安装范围: {action}")


def parse_frontend_prepare_args(args: list[str]) -> tuple[str, tuple[str, ...]]:
    if (
        len(args) != 5
        or args[0] != FRONTEND_PREPARE_COMMAND
        or args[1] != "--product"
        or args[3] != "--apps"
    ):
        raise ZsStartError("内部前端准备命令参数无效")
    product = args[2]
    if product not in ("cloud", "zns"):
        raise ZsStartError(f"不支持为此前端产品准备依赖: {product}")
    apps = tuple(dict.fromkeys(app.strip() for app in args[4].split(",") if app.strip()))
    if not apps:
        raise ZsStartError("内部前端准备命令缺少模块")
    frontend_dependency_filter_args(product, apps)
    return product, apps


def start_frontend(context: RepoContext) -> int:
    while True:
        state_path = frontend_start_state_path(context)
        last_state = load_frontend_start_state(context)
        action = choose_frontend_action(context, last_state=last_state)
        if action != "switch":
            break
        next_context = choose_repo_context(context)
        if next_context is not None:
            context = next_context

    install_prefix = f"{FRONTEND_INSTALL_ACTION}:"
    if action.startswith(install_prefix):
        try:
            target = action.removeprefix(install_prefix)
            product, apps = resolve_frontend_dependency_scope(target, last_state)
            if apps:
                return install_frontend_dependencies(
                    context,
                    product=product,
                    apps=apps,
                )
            return install_frontend_dependencies(context, product=product)
        except ZsStartError as error:
            return finish_frontend_error(error)

    try:
        product, apps = resolve_frontend_dependency_scope(action, last_state)
        ensure_frontend_dependencies(context, product=product, apps=apps)
    except ZsStartError as error:
        return finish_frontend_error(error)

    if action == "last" and last_state is not None:
        command = build_frontend_start_command(last_state)
        runtime_command = command
        product_label = "Cloud" if last_state.product == "cloud" else "ZNS"
    elif action == "default":
        command = ["pnpm", "start"]
        runtime_command = build_frontend_memory_command(action)
        product_label = "默认启动器"
    elif action == "cloud":
        command = ["pnpm", "start:cloud"]
        runtime_command = build_frontend_memory_command(action)
        product_label = "Cloud"
    else:
        command = ["pnpm", "start:zns"]
        runtime_command = build_frontend_memory_command(action)
        product_label = "ZNS"
    print(f"已选择: {product_label}")
    print(f"工作树: {context.root}")
    print(f"启动: {' '.join(command)}")
    if action != "last":
        print("接下来请在项目原生选择器中选择前端模块。\n")

    branch_name = context.branch.rsplit("/", 1)[-1]
    set_terminal_title(f"FE:{product_label}:{branch_name}")
    try:
        if state_path is None:
            return subprocess.run(command, cwd=context.root).returncode
        if action != "last" and not FRONTEND_MEMORY_PRELOAD.is_file():
            raise ZsStartError(f"缺少前端启动记忆脚本: {FRONTEND_MEMORY_PRELOAD}")
        child_env = os.environ.copy()
        child_env[FRONTEND_STATE_ENV_KEY] = str(state_path)
        child_env[FRONTEND_AUTO_PREPARE_ENV_KEY] = "1"
        child_env[FRONTEND_PREPARE_SCRIPT_ENV_KEY] = str(SCRIPT_PATH)
        # 模块选择期间其他终端可能切换默认项目，子进程仍使用本次启动的项目。
        child_env[PROJECT_ROOT_ENV_KEY] = str(context.primary_root)
        return subprocess.run(
            runtime_command,
            cwd=context.root,
            env=child_env,
        ).returncode
    except KeyboardInterrupt:
        return 130
    finally:
        set_terminal_title("FE")


def start_zns_bff(context: RepoContext) -> int:
    while True:
        action = choose_zns_bff_action(context)
        if action == "start":
            break
        next_context = choose_repo_context(context)
        if next_context is not None:
            context = next_context

    ensure_zns_bff_dependencies(context)
    env_path = initialize_zns_bff_env(context)
    print(f"工作树: {context.root}")
    print(f"配置: {env_path}")
    print("启动: pnpm start:dev\n")

    branch_name = context.branch.rsplit("/", 1)[-1]
    set_terminal_title(f"ZNS-BFF:{branch_name}")
    try:
        return subprocess.run(["pnpm", "start:dev"], cwd=context.zns_bff_dir).returncode
    except KeyboardInterrupt:
        return 130
    finally:
        set_terminal_title("ZNS-BFF")


def main() -> int:
    args = sys.argv[1:]
    if args == ["--version"]:
        print(f"zs-start {zs_start_manager.tool_version()} · 需求记录")
        return 0
    if args and args[0] == FRONTEND_PREPARE_COMMAND:
        try:
            product, apps = parse_frontend_prepare_args(args)
            context = resolve_repo_context(requested_worktree=Path.cwd())
            prepare_frontend_scope(context, product=product, apps=apps)
            return 0
        except (OSError, ZsStartError) as error:
            print(f"错误: {error}", file=sys.stderr)
            return 1

    if not args:
        if not sys.stdin.isatty():
            print_help()
            return 0
        try:
            command = choose_command_from_help()
        except KeyboardInterrupt:
            print("\n已取消")
            return 130
        if command is None:
            return 0
        args = [command]
    elif args in (["--help"], ["-h"]):
        print_help()
        return 0

    if args and args[0] == "project":
        try:
            return switch_project(args[1:])
        except KeyboardInterrupt:
            print("\n已取消")
            return 130
        except (OSError, ZsStartError, zs_start_manager.ManagerError, subprocess.TimeoutExpired) as error:
            print(f"错误: {error}", file=sys.stderr)
            return 1

    try:
        requested_worktree = parse_worktree_arg(args)
    except ZsStartError as error:
        print(f"错误: {error}", file=sys.stderr)
        return usage()
    try:
        context = resolve_startup_repo_context(requested_worktree=requested_worktree)
        command = args[0]
        if command == "fe":
            return start_frontend(context)
        if command == "zns:bff":
            return start_zns_bff(context)
        return start_cloud_bff(context)
    except KeyboardInterrupt:
        print("\n已取消")
        return 130
    except (OSError, ZsStartError) as error:
        print(f"错误: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
