#!/usr/bin/env bash
# 创建 ROS 栈。带 from=qianwenai / qianwenai-appName / qianwenai-appDesc tag；失败自动回滚（DisableRollback=false）。
# 全栈按量付费（PostPaid），不支持包年包月。
# 必填环境变量：APP_NAME, INSTANCE_TYPE, PASSWORD, USERDATA_FILE
# 必填环境变量（续）：APP_DESC（应用描述）
# 可选：SYSTEM_DISK_SIZE=40, BACKEND_PORT=8080, TIMEOUT_MIN=30（含 RDS 时默认 60）
# 含 RDS 时（WITH_RDS=1）：
#   必填：DB_PASSWORD
#   可选：DB_INSTANCE_CLASS=mysql.n2.medium.1, DB_INSTANCE_STORAGE=20,
#         DB_NAME=appdb, DB_ACCOUNT=appuser
#   注意：含 RDS 的模板里 UserData 已 inline，不再作为 Parameter 传入；USERDATA_FILE 仅供 debug 备查
# 用法：
#   ./create_stack.sh <region> <template-url> <stack-name>
# stdout：仅 StackId（一行）
set -uo pipefail

usage() {
  echo "Usage: APP_NAME=... APP_DESC=... INSTANCE_TYPE=... PASSWORD=... USERDATA_FILE=... $0 <region> <template-url> <stack-name>" >&2
  exit 64
}
[ $# -eq 3 ] || usage
REGION="$1"; TPL_URL="$2"; NAME="$3"
: "${APP_NAME:?missing APP_NAME}"
: "${INSTANCE_TYPE:?missing INSTANCE_TYPE}"
: "${PASSWORD:?missing PASSWORD}"
: "${USERDATA_FILE:?missing USERDATA_FILE}"
: "${ZONE_ID:=${ZONE_ID_A:-}}"
[ -f "$USERDATA_FILE" ] || { echo "USERDATA_FILE not found: $USERDATA_FILE" >&2; exit 1; }
: "${APP_DESC:?missing APP_DESC}"
DISK="${SYSTEM_DISK_SIZE:-40}"
PORT="${BACKEND_PORT:-8080}"
PROJECT_ROOT="${PROJECT_ROOT:-.}"   # 临时状态文件写到此目录（默认当前项目根）

WITH_RDS="${WITH_RDS:-0}"
if [ "$WITH_RDS" = "1" ]; then
  : "${DB_PASSWORD:?missing DB_PASSWORD (WITH_RDS=1)}"
  DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-mysql.n2.medium.1}"
  DB_INSTANCE_STORAGE="${DB_INSTANCE_STORAGE:-20}"
  DB_NAME="${DB_NAME:-appdb}"
  DB_ACCOUNT="${DB_ACCOUNT:-appuser}"
  TIMEOUT="${TIMEOUT_MIN:-60}"
else
  TIMEOUT="${TIMEOUT_MIN:-30}"
fi

USERDATA="$(cat "$USERDATA_FILE")"

# 动态拼参数数组（共享逻辑）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_build_params.sh"
build_ros_params

OUT=$(aliyun ros CreateStack \
  --RegionId "$REGION" \
  --StackName "$NAME" \
  --TemplateURL "$TPL_URL" \
  --DisableRollback false \
  --TimeoutInMinutes "$TIMEOUT" \
  --Tags.1.Key from                --Tags.1.Value qianwenai \
  --Tags.2.Key qianwenai-appName  --Tags.2.Value "$APP_NAME" \
  --Tags.3.Key qianwenai-appDesc  --Tags.3.Value "$APP_DESC" \
  "${PARAMS[@]}" 2>&1)
CODE=$?
if [ $CODE -ne 0 ]; then
  echo "$OUT" >&2
  exit $CODE
fi

STACK_ID=$(echo "$OUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin)['StackId'])
except Exception: pass")
[ -z "$STACK_ID" ] && { echo "无法解析 StackId（CreateStack 返回非预期内容）" >&2; echo "$OUT" >&2; exit 1; }

# 拿到 StackId 立即落「临时状态文件」：即便后续等待终态阶段被中断（关终端 / 断网），
# delete_stack.sh 也能据此清理，避免留下持续计费的孤儿栈。record_state.py 成功后会覆盖为完整状态。
DB_ENGINE_HINT=""
[ "$WITH_RDS" = "1" ] && DB_ENGINE_HINT="mysql"
python3 - "$PROJECT_ROOT" "$STACK_ID" "$NAME" "$REGION" "$DB_ENGINE_HINT" <<'PY' || true
import datetime, json, os, sys
root, sid, name, region, db = sys.argv[1:6]
state = {
    "version": 1,
    "stack_id": sid,
    "stack_name": name,
    "region_id": region,
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "tags": [{"Key": "from", "Value": "qianwenai"}, {"Key": "qianwenai-appName", "Value": os.environ.get("APP_NAME", "")}, {"Key": "qianwenai-appDesc", "Value": os.environ.get("APP_DESC", "")}],
    "provisional": True,
    "notes": "CreateStack 已提交，等待终态中；成功后由 record_state.py 覆盖为完整状态。",
}
if db:
    state["db_engine"] = db
path = os.path.join(root, ".qianwenai-deploy")
with open(path, "w", encoding="utf-8") as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
sys.stderr.write(f"[create] 已写入临时状态文件 {path}（含 stack_id，中断后仍可清理）\n")
PY

echo "$STACK_ID"
