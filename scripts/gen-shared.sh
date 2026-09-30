#!/bin/bash
# Generate Swift API client locally from shared's OpenAPI.yaml.
#
# 架构（家族同款）：shared 仓是纯契约源（TypeSpec → OpenAPI.yaml only），
# 语言产物在各消费仓本地生成（suite 硬规则 §4：API 面只认生成物，禁手写接口层）。
# 本脚本：先触发 shared emit，再跑 openapi-generator swift5 产 URLSession client，
# 产物拷进 Generated/（SPM 独立 target，禁手改）。
#
# 生成在任一有 Node+Java 的机器跑（Windows 本机 / home-mac）；产物 committed，
# 构建机（home-mac swift build/test）不需要装生成器。
set -euo pipefail

SHARED_DIR="$(cd "$(dirname "$0")/../../saas-identity-platform-shared" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[gen-shared] step 1/2 — shared: emit OpenAPI.yaml..."
(cd "$SHARED_DIR" && npm run emit:openapi)

OPENAPI="$SHARED_DIR/generated/openapi/openapi.yaml"
if [ ! -f "$OPENAPI" ]; then
  echo "[gen-shared] ERROR: missing $OPENAPI" >&2
  exit 1
fi

echo "[gen-shared] step 2/2 — swift: openapi-generator swift5 → Generated/..."
# hideGenerationTimestamp=true（5.70 教训）：不关则每次 regen 全量 diff 污染 commit。
# library=urlsession：无第三方依赖，Foundation-only，CoreKit 禁第三方库约定成立。
rm -rf "$ROOT/.openapi-tmp"
npx --yes @openapitools/openapi-generator-cli generate \
  -g swift5 \
  -i "$OPENAPI" \
  -o "$ROOT/.openapi-tmp/swift" \
  --library urlsession \
  --additional-properties=hideGenerationTimestamp=true,packageName=SaasSharedGenerated,useBacktickEscapes=true,nonPublicApi=false,useAnyCodable=false

# 只拷 Classes/OpenAPIs（APIs+Models+扩展源码）进 Generated/Sources，其余
# （docs/podspec/project/CHANGELOG）是生成器副产品，不入仓。
mkdir -p "$ROOT/Generated/Sources"
rm -rf "$ROOT/Generated/Sources"/*
cp -r "$ROOT"/.openapi-tmp/swift/*/Classes/OpenAPIs/. "$ROOT/Generated/Sources/"
rm -rf "$ROOT/.openapi-tmp"

# 生成器已知缺陷守卫（lab swift 修补①同源）：swift5 生成器对符号枚举值会产
# 非法标识符 case（`case  = "≥"` 形态）。saas 契约现状无此形态（首跑实证
# 2026-09-30），此处 fail-loud 兜住未来契约演进引入的同类缺陷。
if grep -rnE 'case +=' "$ROOT/Generated/Sources/Models/" >/dev/null 2>&1; then
  echo "gen-shared 守卫：Models/ 出现非法 case 标识符（生成器符号枚举缺陷），sed 改名后重跑" >&2
  grep -rnE 'case +=' "$ROOT/Generated/Sources/Models/" | head -5 >&2
  exit 3
fi

if [ ! -f "$ROOT/Generated/Sources/APIs/AuthAPI.swift" ] \
  || [ ! -f "$ROOT/Generated/Sources/Models/LoginResponse.swift" ]; then
  echo "[gen-shared] fail-loud：AuthAPI.swift / LoginResponse.swift 未生成（生成器输出结构漂移？）" >&2
  exit 3
fi

# ADR-0026 marker（同 sha 零写入，5.77）。
SHARED_SHA=$(cd "$SHARED_DIR" && git rev-parse HEAD)
MARKER="$ROOT/.state/last-gen-shared.json"
mkdir -p "$ROOT/.state"
python3 - "$MARKER" "$SHARED_SHA" <<'PYEOF' || echo "[gen-shared] WARN: marker 写失败（staleness 将报 UNKNOWN）" >&2
import datetime, json, sys

marker_path, shared_sha = sys.argv[1:3]
try:
    with open(marker_path, encoding="utf-8") as f:
        marker = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    marker = {}

if marker.get("api_synced_sha") == shared_sha:
    print("[marker] api_synced_sha unchanged - zero write (5.77)")
    sys.exit(0)

marker["api_synced_sha"] = shared_sha
marker["api_synced_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
marker["api_synced_cmd"] = "gen-shared.sh"
marker["shared_sha"] = shared_sha
marker["consumer_repo"] = "saas-identity-platform-swift"

with open(marker_path, "w", encoding="utf-8") as f:
    json.dump(marker, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYEOF

echo "[gen-shared] OK (shared HEAD ${SHARED_SHA:0:7})"
