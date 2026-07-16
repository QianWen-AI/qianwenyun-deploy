#!/usr/bin/env bash
# 探测当前 region 下由本工具创建（tag from=qianwenai）的存量 ROS 栈。
#
# 用途：
#   - 发现同项目已有部署 → 提供热更新/重新部署选项
#
# 用法：
#   ./check_existing.sh <region> [appName]
#
#   appName  可选；传入后区分「同项目」和「其他项目」的栈。
#
# stdout：JSON 对象，结构见脚本末尾的 Python 输出
# 退出码：
#   0  发现存量资源（stdout 有内容）
#   1  无存量资源
#   2  查询/解析失败
set -uo pipefail

usage() { echo "Usage: $0 <region> [appName]" >&2; exit 64; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
REGION="$1"
APP_NAME="${2:-}"

# --- 查询 ROS 栈 ---
STACKS_OUT=$(aliyun ros ListStacks --RegionId "$REGION" \
  --Tag.1.Key from --Tag.1.Value qianwenai 2>&1) || {
  echo "[existing] ListStacks 失败：$STACKS_OUT" >&2; exit 2; }

# --- 分析 ---
python3 - "$APP_NAME" <<'PY' "$STACKS_OUT"
import json, sys

app_name = sys.argv[1]
stacks_raw = sys.argv[2]

try:
    stacks_data = json.loads(stacks_raw)
except Exception as e:
    sys.stderr.write(f"解析 ListStacks 失败：{e}\n"); sys.exit(2)

all_stacks = []
same_app_stacks = []

for s in stacks_data.get("Stacks", []):
    if s.get("Status") == "DELETE_COMPLETE":
        continue
    tags = s.get("Tags", [])
    tag_app_name = ""
    for t in tags:
        key = t.get("Key") or t.get("TagKey") or ""
        val = t.get("Value") or t.get("TagValue") or ""
        if key == "qianwenai-appName":
            tag_app_name = val

    stack_info = {
        "stack_name": s.get("StackName", ""),
        "stack_id": s.get("StackId", ""),
        "status": s.get("Status", ""),
        "create_time": s.get("CreateTime", ""),
        "app_name": tag_app_name,
    }
    all_stacks.append(stack_info)

    if app_name and tag_app_name == app_name:
        same_app_stacks.append(stack_info)

result = {
    "stacks": all_stacks,
    "same_app_stacks": same_app_stacks,
}

if all_stacks:
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0)
else:
    sys.stderr.write("[existing] 未发现本工具创建的存量资源\n")
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(1)
PY
