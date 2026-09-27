#!/usr/bin/env python3
"""远程门禁：把本仓工作树同步到构建机 home-mac 的 staging 目录，再跑 swift build / swift test。

用法（.harness/stack.json L2/L4 调用）:
    python scripts/remote_gate.py build   # L2：远程 swift build
    python scripts/remote_gate.py test    # L4：远程 swift test

设计约束（suite 铁律）:
- 构建机与 staging 路径是常量，不是 env 兜底 —— 目标漂移宁可红，不静默换地方测。
- 每次全量打包本机工作树（排除 .git/.build）再同步，gate 测的永远是本机当前代码，
  不测构建机上可能陈旧的克隆。
- ssh 一律 BatchMode：key 认证失败立刻红，绝不挂住门禁等密码。
- exit code 唯一真相：swift 子进程的返回码原样透传。
"""

import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

HOST = "home-mac"  # ~/.ssh/config 免密别名；与 version-lock.json 的 build_host 同源
STAGING_ROOT = "swift-builds"  # 构建机上的 staging 根目录：~/swift-builds/<仓名>
EXCLUDE_PREFIXES = ("./.git", "./.build")


def _sync(root: Path, staging: str) -> None:
    with tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False) as fh:
        archive = Path(fh.name)
    try:
        with tarfile.open(archive, "w:gz") as tar:
            tar.add(
                root,
                arcname=".",
                filter=lambda ti: None
                if ti.name.startswith(EXCLUDE_PREFIXES)
                else ti,
            )
        subprocess.run(
            ["ssh", "-o", "BatchMode=yes", HOST, f"mkdir -p ~/{staging}"],
            check=True,
        )
        with archive.open("rb") as fh:
            subprocess.run(
                ["ssh", "-o", "BatchMode=yes", HOST, f"tar -xzf - -C ~/{staging}"],
                stdin=fh,
                check=True,
            )
    finally:
        archive.unlink(missing_ok=True)


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"build", "test"}:
        print("用法: python scripts/remote_gate.py build|test", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    root = Path(__file__).resolve().parent.parent
    staging = f"{STAGING_ROOT}/{root.name}"

    _sync(root, staging)
    result = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", HOST, f"cd ~/{staging} && swift {mode}"]
    )
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
