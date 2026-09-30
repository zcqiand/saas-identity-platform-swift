#!/usr/bin/env python3
"""trace_cmd：扫 Tests/ 源码 `// fn: <功能ID>` 字面 → 产出 .state/trace.json（REQ-2026-002 T-1）。

契约（suite harness.py 契约二）：
    {"schema": 1, "tests": [{"test": "...", "fns": ["M03.F01.I01"], "inert": false}]}

机制（REQ-2026-002 Q2 人裁）：Swift XCTest 没有 pytest marker 生态，走源码字面扫描——
同 contract-test SSOT 解析器思路（只扫源码字面）。纪律与各家栈相同：
扫描只证明「存在一个声称覆盖该 ID 的测试」，不证明真执行到；挂 ID = 人审 diff。

硬规则：
- trace.json 禁手写——本脚本每次全量重写；手改的内容重跑即被覆盖（AC-8）。
- inert 测试（skip）必须不挂 ID：本扫描是静态的，测不出 skip；挂在 `func testXxx() throws` 上的
  ID 一律 inert=false。skip 的测试**不写 fn 字面**（写了也会被当成在覆盖，属于违规，人审拦截）。

用法（.harness/stack.json trace_cmd 调用，cwd = 仓根）：
    python scripts/trace_cmd.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = ROOT / "Tests"
OUT = ROOT / ".state" / "trace.json"

# 与 suite harness.py FUNCTION_ID_RE 同语法的统一 ID 正则（M / M.F / M.F.I 三级）。
FN_ID_RE = re.compile(r"\bM\d{2}(?:\.F\d{2}(?:\.I\d{2})?)?\b")
# XCTest 测试方法：func testXxx(...)——非 test 前缀的方法不收集（helper 不挂 ID）。
FUNC_RE = re.compile(r"\bfunc\s+(test\w+)\s*\(")
# XCTest 类声明（test 前缀限定，避免吸进 ViewModel 名）。
CLASS_RE = re.compile(r"\bclass\s+(\w+Tests)\b")

# trace 条目里的 test 名 = 相对路径::类.方法（与 trace.json 契约示例同风格）。
_test_name = "{}::{}.{}"


def _scan_file(path: Path) -> tuple[list[dict], list[str]]:
    """返回 (该文件的 trace 条目, 该文件里锚定失败的 fn 字面描述列表)。"""
    entries: list[dict] = []
    dangling: list[str] = []
    cls = ""
    func = ""
    fns: list[str] = []
    order: list[str] = []  # 保序去重：一个测试挂多个 ID 时按源码出现顺序

    def flush() -> None:
        nonlocal func, fns, order
        if func and order:
            entries.append(
                {
                    "test": _test_name.format(path.relative_to(ROOT).as_posix(), cls, func),
                    "fns": order,
                    "inert": False,
                }
            )
        func, fns, order = "", [], []

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if m := CLASS_RE.search(raw):
            cls = m.group(1)
        if m := FUNC_RE.search(raw):
            flush()
            func = m.group(1)
        if "// fn:" in raw:
            ids = FN_ID_RE.findall(raw)
            if not ids:
                dangling.append(f"{path.name}: `{raw.strip()}`（fn 注释里没有合法功能 ID）")
            elif not func:
                dangling.append(f"{path.name}: `{raw.strip()}`（不在任何 func testXxx 内）")
            else:
                for fid in ids:
                    if fid not in order:
                        order.append(fid)
    flush()
    return entries, dangling


def main() -> int:
    if not TESTS_DIR.is_dir():
        print(f"trace_cmd: {TESTS_DIR} 不存在", file=sys.stderr)
        return 1
    entries: list[dict] = []
    dangling: list[str] = []
    for path in sorted(TESTS_DIR.rglob("*.swift")):
        file_entries, file_dangling = _scan_file(path)
        entries.extend(file_entries)
        dangling.extend(file_dangling)

    if dangling:
        print("trace_cmd: fn 字面锚定失败（挂 ID 是承诺，位置错了必须停下修）：", file=sys.stderr)
        for d in dangling:
            print(f"  - {d}", file=sys.stderr)
        return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(
        json.dumps({"schema": 1, "tests": entries}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    ids = sorted({fid for e in entries for fid in e["fns"]})
    print(f"trace_cmd: {len(entries)} 个测试挂 {len(ids)} 个功能 ID → .state/trace.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
