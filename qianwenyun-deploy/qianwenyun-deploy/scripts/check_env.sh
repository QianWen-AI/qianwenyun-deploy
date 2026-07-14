#!/usr/bin/env bash
# 前置检查：aliyun CLI 是否安装、是否有 Valid profile、region 是否可识别、AK 身份探测。
#
# 用法：
#   bash check_env.sh
#
# 退出码：
#   0 通过
#   2 CLI 未装 / 版本过低
#   3 profile / AK-SK 无效
#   4 默认 region 未配置
#   5 ros / ecs / oss 子命令不可用
#   6 AK 身份探测失败

set -uo pipefail

err() { echo "[check_env] ERROR: $*" >&2; }
ok()  { echo "[check_env] OK: $*"; }

# 1) aliyun CLI
if ! command -v aliyun >/dev/null 2>&1; then
  err "未检测到 aliyun CLI。请先安装："
  err "  brew install aliyun-cli   # macOS"
  err "  或参考 https://help.aliyun.com/zh/cli/install-cli-on-macos"
  exit 2
fi
VERSION=$(aliyun version 2>/dev/null | head -1)
ok "aliyun CLI 已安装：$VERSION"
MAJOR=$(echo "$VERSION" | grep -oE '[0-9]+' | head -1)
if [ -n "$MAJOR" ] && [ "$MAJOR" -lt 3 ]; then
  err "aliyun CLI 版本过低（${VERSION}），需要 3.x+。请升级。"
  exit 2
fi

# 2) profile / AK-SK
LIST=$(aliyun configure list 2>&1) || {
  err "aliyun configure list 执行失败：$LIST"
  exit 3
}
if ! echo "$LIST" | grep -qE '\*'; then
  err "未找到默认 profile。请执行：aliyun configure --profile default"
  exit 3
fi
if ! echo "$LIST" | grep -qE 'Valid'; then
  err "默认 profile 凭证无效。请重新执行：aliyun configure --profile default"
  err "$LIST"
  exit 3
fi
ok "AK/SK profile 有效"

# 3) region（从 profile 默认 region 解析）
REGION=$(aliyun configure get region 2>/dev/null | tr -d '[:space:]')
if [ -z "$REGION" ]; then
  err "未配置默认 region。请：aliyun configure set --region cn-hangzhou"
  exit 4
fi
ok "默认 region：$REGION"

# 4) 探测 ROS / ECS / OSS 子命令可用
for prod in ros ecs oss; do
  if ! aliyun $prod help >/dev/null 2>&1; then
    err "aliyun $prod 子命令不可用，请重装 CLI 或安装 plugin"
    exit 5
  fi
done
ok "ros / ecs / oss 子命令可用"

# 5) 身份探测（必做） —— STS 是云上几乎所有 AK 都默认开通的，没有它通常说明 AK 已失效
IDENT=$(aliyun sts GetCallerIdentity 2>&1)
if [ $? -ne 0 ]; then
  err "AK 身份探测失败（aliyun sts GetCallerIdentity）："
  err "$IDENT"
  err "可能原因：AK/SK 已过期、被禁用，或被 RAM 策略明确 Deny 了 sts:GetCallerIdentity"
  exit 6
fi
ACCOUNT_ID=$(printf '%s' "$IDENT" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('AccountId',''))" 2>/dev/null)
ARN=$(printf '%s' "$IDENT" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('Arn',''))" 2>/dev/null)
if [ -z "$ARN" ] || [ -z "$ACCOUNT_ID" ]; then
  err "无法解析 GetCallerIdentity 返回（缺少 AccountId / Arn）："
  err "$IDENT"
  exit 6
fi
ok "AK 身份：${ARN}（账户 ${ACCOUNT_ID}）"

echo
echo "REGION=$REGION"
echo "ACCOUNT_ID=$ACCOUNT_ID"
echo "IDENTITY_ARN=$ARN"
exit 0
