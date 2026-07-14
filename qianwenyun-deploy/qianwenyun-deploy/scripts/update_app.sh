#!/usr/bin/env bash
# 应用热更新（免删栈）。
# 通过 Cloud Assistant RunCommand 在 ECS 上：停旧进程 → 拉新产物 → 启新进程。
# 不销毁/重建任何云资源，公网 IP 保持不变。
#
# 前置条件：
#   - 项目根目录存在 .qianwenyun-deploy 状态文件（由首次部署生成）
#   - 新产物已上传到 OSS（由 Agent 调用 upload_artifacts.py 完成后传入 URL）
#
# 必填环境变量：
#   BACKEND_URL   新后端产物的 OSS 签名 URL（或为空表示不更新后端）
# 可选环境变量：
#   FRONTEND_URL  新前端产物的 OSS 签名 URL（为空表示不更新前端）
#   PROJECT_ROOT  项目根目录（默认 .）
#   ROLLBACK      设为 1 时回滚到上一版本（从状态文件读 previous_artifact_urls）
#
# 用法：
#   BACKEND_URL="https://..." FRONTEND_URL="https://..." bash scripts/update_app.sh
#   ROLLBACK=1 bash scripts/update_app.sh
#
# stdout：JSON {"status":"success","updated_instances":["i-xxx"],"invoke_ids":["t-xxx"]}
# 退出码：0=成功 1=失败 2=状态文件异常 3=RunCommand 执行失败
set -uo pipefail

ROOT="${PROJECT_ROOT:-.}"
STATE="$ROOT/.qianwenyun-deploy"
ROLLBACK="${ROLLBACK:-0}"

[ -f "$STATE" ] || { echo "找不到 $STATE，请先完成首次部署" >&2; exit 2; }

# 解析状态文件
EVAL=$(python3 - "$STATE" <<'PY'
import json, shlex, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        d = json.load(f)
except Exception as e:
    sys.stderr.write(f"状态文件解析失败：{e}\n"); sys.exit(2)

def need(k):
    v = d.get(k)
    if not v:
        sys.stderr.write(f"状态文件缺少字段 '{k}'\n"); sys.exit(2)
    return v

region = need("region_id")
outputs = d.get("outputs") or {}
ecs_raw = outputs.get("ecs_instance_ids") or []
if isinstance(ecs_raw, str):
    ecs_raw = [x.strip() for x in ecs_raw.split(",") if x.strip()]
if not ecs_raw:
    sys.stderr.write("状态文件缺少 outputs.ecs_instance_ids\n"); sys.exit(2)

topology = d.get("topology") or "single"
app_type = d.get("app_type") or ""
nginx_mode = d.get("nginx_mode") or ""
bucket = d.get("artifact_bucket") or ""
public_ip = outputs.get("public_ip") or ""

prev = d.get("previous_artifact_urls") or {}

vals = {
    "REGION": region,
    "ECS_IDS": " ".join(ecs_raw),
    "ECS_COUNT": str(len(ecs_raw)),
    "TOPOLOGY": topology,
    "APP_TYPE": app_type,
    "NGINX_MODE": nginx_mode,
    "BUCKET": bucket,
    "PUBLIC_IP": public_ip,
    "PREV_BACKEND_URL": prev.get("backend_url") or "",
    "PREV_FRONTEND_URL": prev.get("frontend_url") or "",
}
for k, v in vals.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
) || { echo "[update] 读取状态文件失败" >&2; exit 2; }
eval "$EVAL"

# 回滚模式：从状态文件读取上一版本 URL
if [ "$ROLLBACK" = "1" ]; then
  if [ -z "$PREV_BACKEND_URL" ] && [ -z "$PREV_FRONTEND_URL" ]; then
    echo "[update] 无可回滚的版本（状态文件中没有 previous_artifact_urls）" >&2
    exit 1
  fi
  BACKEND_URL="${PREV_BACKEND_URL}"
  FRONTEND_URL="${PREV_FRONTEND_URL}"
  echo "[update] 回滚模式：使用上一版本产物" >&2
else
  BACKEND_URL="${BACKEND_URL:-}"
  FRONTEND_URL="${FRONTEND_URL:-}"
fi

if [ -z "$BACKEND_URL" ] && [ -z "$FRONTEND_URL" ]; then
  echo "[update] BACKEND_URL 和 FRONTEND_URL 均为空，无内容可更新" >&2
  exit 1
fi

# 生成 ECS 上执行的更新脚本
# 改进：先下载验证+装依赖 → 再停服 → 原子替换 → 启动，最小化停机窗口
gen_update_script() {
  local script="#!/bin/bash
set -euxo pipefail
exec >> /var/log/qianwenyun-update.log 2>&1
echo \"[\$(date -u +%FT%TZ)] === qianwenyun update start ===\"

rollback_and_exit() {
  echo '[update] 更新失败，执行回滚'
  trap - ERR
  if [ -d /opt/qianwenyun.bak ]; then
    rm -rf /opt/qianwenyun
    mv /opt/qianwenyun.bak /opt/qianwenyun
  fi
  if [ -d /var/www/frontend.bak ]; then
    rm -rf /var/www/frontend
    mv /var/www/frontend.bak /var/www/frontend
    nginx -t && systemctl reload nginx || true
  fi
  systemctl restart qianwenyun-app || true
  rm -rf /opt/qianwenyun.staging /var/www/frontend.staging 2>/dev/null || true
  exit 1
}
"
  # 更新后端
  if [ -n "$BACKEND_URL" ]; then
    script+="
# === 阶段 1：预备——下载、解压、安装依赖（服务继续运行，不影响线上） ===
echo '[update] 阶段1：下载+验证新产物（服务不受影响）'

STAGING_DIR=/opt/qianwenyun.staging
rm -rf \"\$STAGING_DIR\"
mkdir -p \"\$STAGING_DIR\"

echo '[update] 拉取新后端产物到暂存区'
curl -fsSL '$BACKEND_URL' -o \"\$STAGING_DIR/backend.tar.gz\"
tar -tzf \"\$STAGING_DIR/backend.tar.gz\" >/dev/null
echo '[update] 产物完整性校验通过'
tar -xzf \"\$STAGING_DIR/backend.tar.gz\" -C \"\$STAGING_DIR\"
rm -f \"\$STAGING_DIR/backend.tar.gz\"
echo '[update] 新产物下载+解压成功'
"
    # 运行时依赖预安装（在 staging 目录完成，不影响线上服务）
    case "$APP_TYPE" in
      binary-python)
        script+="
cd \"\$STAGING_DIR\"
if [ -f requirements.txt ]; then
  echo '[update] 预下载 Python 依赖包（服务不受影响）'
  mkdir -p /tmp/qianwenyun-pip-cache
  python3 -m pip download -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com -d /tmp/qianwenyun-pip-cache -r requirements.txt
  echo '[update] Python 依赖预下载完成'
fi
"
        ;;
      binary-node)
        script+="
cd \"\$STAGING_DIR\"
if [ -f package.json ]; then
  echo '[update] 预安装 Node 依赖（暂存区，服务不受影响）'
  rm -rf node_modules
  yarn install --production --registry=https://registry.npmmirror.com
  echo '[update] Node 依赖安装完成'
fi
"
        ;;
    esac
    script+="
# === 阶段 2：原子切换——停服、替换、启动（停机窗口最小化） ===
echo '[update] 阶段2：新产物已就绪，执行原子切换'
echo '[update] 备份当前后端'
cp -a /opt/qianwenyun /opt/qianwenyun.bak
trap rollback_and_exit ERR

echo '[update] 停止后端服务'
systemctl stop qianwenyun-app || true

echo '[update] 原子替换后端目录'
rm -rf /opt/qianwenyun
mv \"\$STAGING_DIR\" /opt/qianwenyun
"
    # Python 需要在替换后用已缓存的包做快速离线安装
    case "$APP_TYPE" in
      binary-python)
        script+="
cd /opt/qianwenyun
if [ -f requirements.txt ] && [ -d /tmp/qianwenyun-pip-cache ]; then
  echo '[update] 离线安装 Python 依赖（使用预下载缓存）'
  python3 -m pip install --no-cache-dir --no-index --find-links /tmp/qianwenyun-pip-cache -r requirements.txt
  rm -rf /tmp/qianwenyun-pip-cache
fi
"
        ;;
    esac
    script+="
echo '[update] 启动后端服务'
systemctl restart qianwenyun-app

echo '[update] 健康检查...'
APP_PORT=\$(sed -n 's/^Environment=PORT=//p' /etc/systemd/system/qianwenyun-app.service 2>/dev/null | head -1)
APP_PORT=\${APP_PORT:-8080}
sleep 3
HEALTHY=0
for _i in $(seq 1 15); do
  if curl -sf -o /dev/null --max-time 5 \"http://localhost:\${APP_PORT}/\"; then
    HEALTHY=1
    break
  fi
  sleep 2
done
if [ \"\$HEALTHY\" -eq 0 ]; then
  echo '[update] 健康检查失败，触发回滚'
  rollback_and_exit
fi
echo '[update] 健康检查通过'
"
  fi

  # 更新前端
  if [ -n "$FRONTEND_URL" ]; then
    script+="
# === 前端更新：先下载到暂存区验证，再原子替换（Nginx reload 无停机） ===
echo '[update] 下载新前端产物到暂存区'
FRONTEND_STAGING=/var/www/frontend.staging
rm -rf \"\$FRONTEND_STAGING\"
mkdir -p \"\$FRONTEND_STAGING\"
curl -fsSL '$FRONTEND_URL' -o /tmp/frontend.tar.gz
tar -tzf /tmp/frontend.tar.gz >/dev/null
echo '[update] 前端产物完整性校验通过'
tar -xzf /tmp/frontend.tar.gz -C \"\$FRONTEND_STAGING\" --strip-components=0
rm -f /tmp/frontend.tar.gz
echo '[update] 前端产物下载+解压成功'

echo '[update] 原子替换前端目录'
if [ -d /var/www/frontend ]; then
  cp -a /var/www/frontend /var/www/frontend.bak
fi
trap rollback_and_exit ERR
rm -rf /var/www/frontend
mv \"\$FRONTEND_STAGING\" /var/www/frontend
nginx -t && systemctl reload nginx
echo '[update] 前端更新完成'
"
  fi

  script+="
trap - ERR
rm -rf /opt/qianwenyun.bak /var/www/frontend.bak /opt/qianwenyun.staging /var/www/frontend.staging /tmp/qianwenyun-pip-cache 2>/dev/null || true
echo \"[\$(date -u +%FT%TZ)] === qianwenyun update complete ===\"
"
  echo "$script"
}

UPDATE_SCRIPT=$(gen_update_script)

# 执行 RunCommand
run_on_instance() {
  local instance_id="$1"
  echo "[update] 下发更新命令到 $instance_id ..." >&2

  local out
  out=$(PAGER=cat aliyun ecs RunCommand \
    --RegionId "$REGION" \
    --InstanceId.1 "$instance_id" \
    --Type RunShellScript \
    --CommandContent "$UPDATE_SCRIPT" \
    --Timeout 300 2>&1)
  local code=$?
  if [ $code -ne 0 ]; then
    echo "[update] RunCommand 失败：$out" >&2
    return 3
  fi

  local invoke_id
  invoke_id=$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin).get('InvokeId',''))" 2>/dev/null)
  if [ -z "$invoke_id" ]; then
    echo "[update] 无法解析 InvokeId：$out" >&2
    return 3
  fi
  echo "[update] InvokeId=${invoke_id}，等待执行完成..." >&2

  # 轮询执行状态（最多 5 分钟）
  local deadline=$(( $(date +%s) + 300 ))
  local status=""
  while [ $(date +%s) -lt $deadline ]; do
    sleep 5
    local inv_out
    inv_out=$(PAGER=cat aliyun ecs DescribeInvocations \
      --RegionId "$REGION" \
      --InvokeId "$invoke_id" 2>&1) || continue

    status=$(echo "$inv_out" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    invs = d.get('Invocations', {}).get('Invocation', [])
    if invs:
        instances = invs[0].get('InvokeInstances', {}).get('InvokeInstance', [])
        if instances:
            print(instances[0].get('InvocationStatus', ''))
except: pass
" 2>/dev/null)

    case "$status" in
      Finished|Success)
        echo "[update] $instance_id 更新完成" >&2
        # 取输出日志
        local result_out
        result_out=$(PAGER=cat aliyun ecs DescribeInvocationResults \
          --RegionId "$REGION" \
          --InvokeId "$invoke_id" 2>&1)
        local output_b64
        output_b64=$(echo "$result_out" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    items = d.get('Invocation', {}).get('InvocationResults', {}).get('InvocationResult', [])
    if items: print(items[0].get('Output', ''))
except: pass
" 2>/dev/null)
        if [ -n "$output_b64" ]; then
          echo "[update] === 远程输出 ===" >&2
          echo "$output_b64" | base64 -d 2>/dev/null >&2 || true
          echo "[update] === 远程输出结束 ===" >&2
        fi
        echo "$invoke_id"
        return 0
        ;;
      Failed)
        echo "[update] $instance_id 执行失败" >&2
        # 取错误输出
        local err_out
        err_out=$(PAGER=cat aliyun ecs DescribeInvocationResults \
          --RegionId "$REGION" \
          --InvokeId "$invoke_id" 2>&1)
        local err_b64
        err_b64=$(echo "$err_out" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    items = d.get('Invocation', {}).get('InvocationResults', {}).get('InvocationResult', [])
    if items: print(items[0].get('Output', ''))
except: pass
" 2>/dev/null)
        if [ -n "$err_b64" ]; then
          echo "[update] === 错误输出 ===" >&2
          echo "$err_b64" | base64 -d 2>/dev/null >&2 || true
        fi
        return 3
        ;;
      *)
        echo "[update] $(date -u +%H:%M:%S) $instance_id status=$status" >&2
        ;;
    esac
  done

  echo "[update] $instance_id 执行超时（5 分钟）" >&2
  return 3
}

# 执行更新
UPDATED_INSTANCES=()
INVOKE_IDS=()
FAILED=0

IFS=' ' read -r -a ECS_ARRAY <<< "$ECS_IDS"

if [ "$TOPOLOGY" = "ha" ] && [ "$ECS_COUNT" -gt 1 ]; then
  # HA 滚动更新：逐台更新
  for i in "${!ECS_ARRAY[@]}"; do
    ecs="${ECS_ARRAY[$i]}"
    echo "[update] HA 滚动更新 ($((i+1))/$ECS_COUNT): $ecs" >&2
    invoke_id=$(run_on_instance "$ecs") || { FAILED=1; break; }
    UPDATED_INSTANCES+=("$ecs")
    INVOKE_IDS+=("$invoke_id")
    echo "[update] $ecs 更新成功" >&2
  done
else
  # 单机更新
  ecs="${ECS_ARRAY[0]}"
  invoke_id=$(run_on_instance "$ecs") || FAILED=1
  if [ $FAILED -eq 0 ]; then
    UPDATED_INSTANCES+=("$ecs")
    INVOKE_IDS+=("$invoke_id")
  fi
fi

if [ $FAILED -ne 0 ]; then
  echo "[update] 更新失败" >&2
  exit 3
fi

# 更新状态文件：追加 updated_at 和 previous_artifact_urls
python3 - "$STATE" "$BACKEND_URL" "$FRONTEND_URL" "$ROLLBACK" <<'PY'
import json, sys
from datetime import datetime, timezone

path, new_backend, new_frontend, is_rollback = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    state = json.load(f)

if is_rollback != "1":
    current = state.get("current_artifact_urls") or {}
    state["previous_artifact_urls"] = {}
    if current.get("backend_url"):
        state["previous_artifact_urls"]["backend_url"] = current["backend_url"]
    if current.get("frontend_url"):
        state["previous_artifact_urls"]["frontend_url"] = current["frontend_url"]

state["current_artifact_urls"] = {}
if new_backend:
    state["current_artifact_urls"]["backend_url"] = new_backend
if new_frontend:
    state["current_artifact_urls"]["frontend_url"] = new_frontend

state["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

with open(path, "w", encoding="utf-8") as f:
    json.dump(state, f, ensure_ascii=False, indent=2)
sys.stderr.write(f"[update] 状态文件已更新 updated_at\n")
PY

# 输出结果 JSON
python3 - "${UPDATED_INSTANCES[@]}" -- "${INVOKE_IDS[@]}" <<'PY'
import json, sys
args = sys.argv[1:]
sep = args.index("--")
instances = args[:sep]
invoke_ids = args[sep+1:]
print(json.dumps({
    "status": "success",
    "updated_instances": instances,
    "invoke_ids": invoke_ids,
}, ensure_ascii=False))
PY
