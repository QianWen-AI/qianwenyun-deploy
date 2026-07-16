#!/usr/bin/env bash
# 共享参数构建逻辑，被 create_stack.sh 和 estimate_cost.sh source。
# 调用前须设置环境变量：APP_NAME, INSTANCE_TYPE, PASSWORD, DISK, PORT
# 含 RDS（WITH_RDS=1）时还需：DB_INSTANCE_CLASS, DB_INSTANCE_STORAGE, DB_NAME, DB_ACCOUNT, DB_PASSWORD
# 可选：ZONE_ID, ZONE_ID_A, ZONE_ID_B, USERDATA（仅 estimate_cost 用占位符）
#
# 输出：PARAMS 数组

PARAMS=()
_add_param() {
  local n="$1" k="$2" v="$3"
  PARAMS+=("--Parameters.${n}.ParameterKey" "$k" "--Parameters.${n}.ParameterValue" "$v")
}

build_ros_params() {
  local n=0
  n=$((n+1)); _add_param "$n" AppName            "$APP_NAME"
  n=$((n+1)); _add_param "$n" InstanceType       "$INSTANCE_TYPE"
  n=$((n+1)); _add_param "$n" Password           "$PASSWORD"
  n=$((n+1)); _add_param "$n" SystemDiskSize     "$DISK"
  n=$((n+1)); _add_param "$n" BackendPort        "$PORT"

  # ZoneId: 单机用 ZONE_ID, HA 用 ZONE_ID_A + ZONE_ID_B
  if [ -n "${ZONE_ID_A:-}" ] && [ -n "${ZONE_ID_B:-}" ]; then
    n=$((n+1)); _add_param "$n" ZoneIdA          "$ZONE_ID_A"
    n=$((n+1)); _add_param "$n" ZoneIdB          "$ZONE_ID_B"
  elif [ -n "${ZONE_ID:-}" ]; then
    n=$((n+1)); _add_param "$n" ZoneId           "$ZONE_ID"
  fi

  if [ "${WITH_RDS:-0}" = "1" ]; then
    n=$((n+1)); _add_param "$n" DbInstanceClass   "$DB_INSTANCE_CLASS"
    n=$((n+1)); _add_param "$n" DbInstanceStorage "$DB_INSTANCE_STORAGE"
    n=$((n+1)); _add_param "$n" DbName            "$DB_NAME"
    n=$((n+1)); _add_param "$n" DbAccount         "$DB_ACCOUNT"
    n=$((n+1)); _add_param "$n" DbPassword        "$DB_PASSWORD"
  else
    n=$((n+1)); _add_param "$n" UserDataScript    "${USERDATA:?missing USERDATA}"
  fi
}
