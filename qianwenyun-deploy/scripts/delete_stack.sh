#!/usr/bin/env bash
# 清理部署资源：整栈销毁（DeleteStack + 清 OSS + 清状态文件）
#
# 自动从项目根目录 .qianwenyun-deploy 读 stack_id / region_id / artifact_bucket。
# 删除完成后清理 .qianwenyun-deploy(.local)。
#
# 用法：
#   ./delete_stack.sh [--project-root .] [--yes]
#
# --yes：跳过命令行交互确认（Agent 应已通过 AskUserQuestion 让用户二次确认）
set -uo pipefail

ROOT="."
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project-root) ROOT="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    *) echo "未知参数 $1" >&2; exit 64 ;;
  esac
done

STATE="$ROOT/.qianwenyun-deploy"
[ -f "$STATE" ] || { echo "找不到 $STATE" >&2; exit 1; }

# 一次性解析状态文件，输出 shell 安全的变量赋值。
# 必需字段缺失或文件损坏时打印具体原因并以非 0 退出，避免后续出现空变量导致
# 删错资源或报“变量未定义”而被迫手动删除。
EVAL=$(python3 - "$STATE" <<'PY'
import json, shlex, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
except Exception as e:
    sys.stderr.write(f"状态文件 {path} 解析失败：{e}\n")
    sys.exit(3)

def need(k):
    v = d.get(k)
    if not v:
        sys.stderr.write(f"状态文件缺少必需字段 '{k}'，无法定位本次部署的资源。\n")
        sys.exit(3)
    return v

vals = {
    "REGION":    need("region_id"),
    "SID":       need("stack_id"),
    "NAME":      d.get("stack_name") or "",
    "BUCKET":    d.get("artifact_bucket") or "",
    "DB_ENGINE": d.get("db_engine") or "",
    "CREATED":   d.get("created_at") or "",
    "PUBLIC_IP": (d.get("outputs") or {}).get("public_ip") or "",
}

for k, v in vals.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
) || { echo "[delete] 读取部署状态失败，已中止（未删除任何资源）。" >&2; exit 3; }
eval "$EVAL"

echo "[delete] 释放本次部署创建的资源：栈 $NAME ($SID) @ $REGION"
[ -n "$PUBLIC_IP" ] && echo "[delete]   公网 IP ${PUBLIC_IP}，创建于 ${CREATED:-?}"
[ -n "$BUCKET" ]    && echo "[delete]   含临时 OSS 桶 $BUCKET"
[ -n "$DB_ENGINE" ] && echo "[delete]   含 RDS (${DB_ENGINE})，删除约 10-30 分钟"
echo "[delete] 仅删本栈资源，不影响账号其它资源；整栈销毁不可逆。"

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "继续？输入 'DELETE' 确认: " ANS
  [ "$ANS" = "DELETE" ] || { echo "已取消" >&2; exit 1; }
fi

# DeleteStack
  OUT=$(aliyun ros DeleteStack --RegionId "$REGION" --StackId "$SID" 2>&1)
  CODE=$?
  if [ $CODE -ne 0 ]; then
    if echo "$OUT" | grep -qiE 'StackNotFound|404'; then
      echo "[delete] Stack 已不存在"
    else
      echo "[delete] DeleteStack 失败：$OUT" >&2
      exit $CODE
    fi
  fi

  # 2) 轮询直到 404（含 RDS 时延长到 60 分钟）
  DELETE_TIMEOUT_MIN=30
  [ -n "$DB_ENGINE" ] && DELETE_TIMEOUT_MIN=60
  DEADLINE=$(( $(date +%s) + DELETE_TIMEOUT_MIN * 60 ))
  while :; do
    if [ $(date +%s) -gt $DEADLINE ]; then
      echo "[delete] 等待删除完成超时（${DELETE_TIMEOUT_MIN}m）。请到控制台检查。" >&2
      exit 2
    fi
    OUT=$(aliyun ros GetStack --RegionId "$REGION" --StackId "$SID" 2>&1)
    if echo "$OUT" | grep -qiE 'StackNotFound|404'; then
      echo "[delete] Stack DELETE_COMPLETE"
      break
    fi
    STATUS=$(echo "$OUT" | python3 -c "import json,sys;print(json.load(sys.stdin).get('Status',''))" 2>/dev/null || echo "?")
    echo "[delete] $(date -u +%H:%M:%S) Status=$STATUS"
    if [ "$STATUS" = "DELETE_COMPLETE" ]; then
      echo "[delete] Stack DELETE_COMPLETE"
      break
    fi
    if [ "$STATUS" = "DELETE_FAILED" ]; then
      echo "$OUT" >&2
      echo "[delete] DeleteStack 失败，请到控制台手动清理" >&2
      exit 2
    fi
    sleep 10
  done

# 3) 清理 OSS 临时桶
if [ -n "$BUCKET" ]; then
  echo "[delete] 清理 OSS 桶 $BUCKET"
  if ! aliyun oss rm "oss://$BUCKET" -r -f >/dev/null 2>&1 \
     || ! aliyun oss rm "oss://$BUCKET" -b -f >/dev/null 2>&1; then
    echo "[delete] 警告：OSS 桶 $BUCKET 未能完全清理。该桶设有 7 天自动过期 lifecycle，不会持续计费；" >&2
    echo "         如需立即删除，可在 OSS 控制台手动清理。" >&2
  fi
fi

# 4) 清理本地状态文件
rm -f "$STATE" "$ROOT/.qianwenyun-deploy.local"
echo "[delete] 完成。本地 .qianwenyun-deploy(.local) 已删除。"
