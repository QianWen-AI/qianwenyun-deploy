#!/usr/bin/env bash
# 询价（按量付费）。v1 全栈 PostPaid，不再做包月对比。
# 模板里所有无默认值的 Parameter 都需通过环境变量传入：
#   APP_NAME, INSTANCE_TYPE, PASSWORD (必填)
#   SYSTEM_DISK_SIZE (默认 40), BACKEND_PORT (默认 8080)
# 含 RDS（WITH_RDS=1）时：必填 DB_PASSWORD；可选 DB_INSTANCE_CLASS / DB_INSTANCE_STORAGE / DB_NAME / DB_ACCOUNT
# 用法：
#   APP_NAME=myapp INSTANCE_TYPE=ecs.e-c1m2.large PASSWORD='Tmp_Pwd_For_Pricing!1' \
#     ./estimate_cost.sh <region> <template-url>
set -uo pipefail

usage() { echo "Usage: APP_NAME=... INSTANCE_TYPE=... PASSWORD=... $0 <region> <template-url>" >&2; exit 64; }
[ $# -eq 2 ] || usage
REGION="$1"; TPL_URL="$2"
: "${APP_NAME:?missing APP_NAME}"
: "${INSTANCE_TYPE:?missing INSTANCE_TYPE}"
: "${PASSWORD:?missing PASSWORD}"
DISK="${SYSTEM_DISK_SIZE:-40}"
PORT="${BACKEND_PORT:-8080}"

WITH_RDS="${WITH_RDS:-0}"
if [ "$WITH_RDS" = "1" ]; then
  : "${DB_PASSWORD:?missing DB_PASSWORD (WITH_RDS=1)}"
  DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-mysql.n2.medium.1}"
  DB_INSTANCE_STORAGE="${DB_INSTANCE_STORAGE:-20}"
  DB_NAME="${DB_NAME:-appdb}"
  DB_ACCOUNT="${DB_ACCOUNT:-appuser}"
fi

# 询价时 UserData 给个最小占位避免参数缺失（询价不关心脚本内容；含 RDS 模板无该参数）
USERDATA="${USERDATA:-#!/bin/bash}"

# 动态拼参数数组（共享逻辑）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_build_params.sh"

echo "[estimate] === PostPaid (按量付费) ===" >&2
build_ros_params
aliyun ros GetTemplateEstimateCost \
  --RegionId "$REGION" \
  --TemplateURL "$TPL_URL" \
  "${PARAMS[@]}"
echo >&2
