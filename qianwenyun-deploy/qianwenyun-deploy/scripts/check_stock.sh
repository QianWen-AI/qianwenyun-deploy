#!/usr/bin/env bash
# ECS（+ 可选 RDS）库存查询（按量付费）。v1 全栈 PostPaid。
# 用法：
#   ./check_stock.sh <region> <instance-type> [min-zones=1]
# 含 RDS 时设置环境变量（输出 ECS ∩ RDS 可用区交集，确保选出的区两者都支持）：
#   DB_INSTANCE_CLASS=mysql.n2.medium.1   必填（用于逐区校验 RDS 是否支持该规格）
#   DB_CATEGORY=Basic                     可选，默认 Basic（基础版/单节点）
#   DB_STORAGE_TYPE=cloud_essd            可选，默认 cloud_essd（须与模板一致）
#   DB_ENGINE_VERSION=8.0                 可选，默认 8.0（须与模板/规格一致）
# 退出码：
#   0  至少 min-zones 个 zone 有库存（含 RDS 时为交集）
#   1  库存不足
set -uo pipefail

usage() { echo "Usage: $0 <region> <instance-type> [min-zones=1]" >&2; exit 64; }
[ $# -ge 2 ] || usage
REGION="$1"; TYPE="$2"
MIN_ZONES="${3:-1}"

# --- ECS 可用区 ---
ECS_OUT=$(aliyun ecs DescribeAvailableResource \
  --RegionId "$REGION" \
  --DestinationResource InstanceType \
  --InstanceType "$TYPE" \
  --InstanceChargeType PostPaid 2>&1) || { echo "$ECS_OUT" >&2; exit 2; }

ECS_ZONES=$(echo "$ECS_OUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
zones = data.get('AvailableZones', {}).get('AvailableZone', [])
ok = [z['ZoneId'] for z in zones if z.get('Status') in ('Available','WithStock')]
print('\n'.join(ok))
")
echo "[stock] ECS 有库存可用区: $ECS_ZONES"

# --- RDS 逐区校验（可选）---
# DescribeAvailableZones 只到 storage type，拿不到实例规格；必须用 DescribeAvailableClasses
# 逐区查询该规格是否可售。只在 ECS 有货的区里筛，结果即 ECS ∩ RDS 交集。
if [ -n "${DB_INSTANCE_CLASS:-}" ]; then
  DB_CATEGORY="${DB_CATEGORY:-Basic}"
  DB_STORAGE_TYPE="${DB_STORAGE_TYPE:-cloud_essd}"
  DB_ENGINE_VERSION="${DB_ENGINE_VERSION:-8.0}"
  FINAL_ZONES=""
  for z in $ECS_ZONES; do
    CLS_OUT=$(aliyun rds DescribeAvailableClasses \
      --RegionId "$REGION" --ZoneId "$z" \
      --Engine MySQL --EngineVersion "$DB_ENGINE_VERSION" \
      --Category "$DB_CATEGORY" --DBInstanceStorageType "$DB_STORAGE_TYPE" \
      --CommodityCode bards --OrderType BUY 2>/dev/null) || continue
    if echo "$CLS_OUT" | grep -qF "\"$DB_INSTANCE_CLASS\""; then
      FINAL_ZONES="${FINAL_ZONES}${z}"$'\n'
    fi
  done
  FINAL_ZONES=$(printf '%s' "$FINAL_ZONES" | grep . || true)
  echo "[stock] RDS ($DB_INSTANCE_CLASS / $DB_CATEGORY / $DB_STORAGE_TYPE) ∩ ECS 可用区: $FINAL_ZONES"
else
  FINAL_ZONES="$ECS_ZONES"
fi

COUNT=$(echo "$FINAL_ZONES" | grep -c . || true)

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  echo "[stock] 解析库存数据失败（COUNT=$COUNT）" >&2
  exit 2
fi

echo "[stock] 可用区数量: $COUNT  (需要 >= $MIN_ZONES)"
echo "[stock] 可用区: $FINAL_ZONES"

if [ "$COUNT" -lt "$MIN_ZONES" ]; then
  echo "[stock] 库存不足。请更换实例规格或地域。" >&2
  exit 1
fi
exit 0
