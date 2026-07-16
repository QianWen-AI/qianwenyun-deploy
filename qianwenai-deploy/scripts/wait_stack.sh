#!/usr/bin/env bash
# 轮询 GetStack 至终态。
# 用法：./wait_stack.sh <region> <stack-id> [interval=10] [max-min=40]
# 终态：CREATE_COMPLETE | CREATE_FAILED | ROLLBACK_COMPLETE | ROLLBACK_FAILED | DELETE_FAILED
# stdout：最终 GetStack 的完整 JSON
# 退出码：0 = CREATE_COMPLETE；2 = 任何 *FAILED / ROLLBACK；3 = 超时
set -uo pipefail

usage() { echo "Usage: $0 <region> <stack-id> [interval=10] [max-min=40]" >&2; exit 64; }
[ $# -ge 2 ] || usage
REGION="$1"; SID="$2"; INTERVAL="${3:-10}"; MAX_MIN="${4:-40}"

DEADLINE=$(( $(date +%s) + MAX_MIN * 60 ))
LAST=""
TERMINAL_OK="CREATE_COMPLETE UPDATE_COMPLETE"
TERMINAL_BAD="CREATE_FAILED CREATE_ROLLBACK_COMPLETE CREATE_ROLLBACK_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED DELETE_FAILED"

while :; do
  if [ $(date +%s) -gt $DEADLINE ]; then
    echo "[wait] 超时 ${MAX_MIN}m" >&2
    [ -n "$LAST" ] && echo "$LAST"
    exit 3
  fi
  OUT=$(aliyun ros GetStack --RegionId "$REGION" --StackId "$SID" 2>&1)
  CODE=$?
  if [ $CODE -ne 0 ]; then
    if echo "$OUT" | grep -qiE 'StackNotFound|404'; then
      echo "[wait] Stack 已不存在（DELETE_COMPLETE）" >&2
      exit 0
    fi
    echo "[wait] GetStack 失败：$OUT" >&2
    sleep "$INTERVAL"; continue
  fi
  LAST="$OUT"
  STATUS=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('Status',''))")
  REASON=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('StatusReason',''))")
  echo "[wait] $(date -u +%H:%M:%S) Status=$STATUS  Reason=$REASON" >&2

  for ok in $TERMINAL_OK; do
    if [ "$STATUS" = "$ok" ]; then
      echo "$OUT"
      exit 0
    fi
  done
  for bad in $TERMINAL_BAD; do
    if [ "$STATUS" = "$bad" ]; then
      echo "$OUT"
      exit 2
    fi
  done
  sleep "$INTERVAL"
done
