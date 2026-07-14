#!/bin/bash
# qianwenyun · 原生二进制后端 + systemd
# 占位符：
#   __BACKEND_ARTIFACT_URL__   后端产物 tar.gz 的 OSS 签名 URL
#   __BACKEND_RUNTIME__        binary | java | node | python
#   __BACKEND_ENTRY__          完整启动命令（相对 /opt/qianwenyun），如
#                              ./server / "python3 app.py" / "java -jar app.jar" /
#                              "node server.js" / "gunicorn -b :8080 app:app"
#   __BACKEND_PORT__           后端监听端口
set -euxo pipefail

LOG=/var/log/qianwenyun-bootstrap.log
exec >> "$LOG" 2>&1
echo "[$(date -u +%FT%TZ)] === qianwenyun systemd bootstrap start ==="

BACKEND_URL="__BACKEND_ARTIFACT_URL__"
RUNTIME="__BACKEND_RUNTIME__"
ENTRY="__BACKEND_ENTRY__"
PORT="__BACKEND_PORT__"

# 1. 安装运行时
case "$RUNTIME" in
  java)
    if ! command -v java >/dev/null 2>&1; then
      if command -v dnf >/dev/null 2>&1; then dnf install -y java-17-openjdk-headless
      else yum install -y java-17-openjdk-headless; fi
    fi
    ;;
  node)
    if ! command -v node >/dev/null 2>&1; then
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      yum install -y nodejs
    fi
    if ! command -v yarn >/dev/null 2>&1; then
      npm install -g yarn --registry=https://registry.npmmirror.com
    fi
    ;;
  python)
    if ! command -v python3 >/dev/null 2>&1; then
      yum install -y python3 python3-pip
    fi
    ;;
  binary)
    : # 静态链接二进制无需运行时
    ;;
  *)
    echo "unknown runtime: $RUNTIME"; exit 1
    ;;
esac

# 2. 拉产物
mkdir -p /opt/qianwenyun
cd /opt/qianwenyun
curl -fsSL "$BACKEND_URL" -o backend.tar.gz
tar -xzf backend.tar.gz
rm -f backend.tar.gz

# python: 安装依赖
if [ "$RUNTIME" = "python" ] && [ -f requirements.txt ]; then
  python3 -m pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ --trusted-host mirrors.aliyun.com -r requirements.txt
fi
# node: 安装依赖（产物已包含 package.json 时）
if [ "$RUNTIME" = "node" ] && [ -f package.json ]; then
  yarn install --production --registry=https://registry.npmmirror.com
fi

# 3. 解析启动命令
# ENTRY 即「完整启动命令」，是命令的唯一来源；脚本不按 runtime 注入任何解释器，
# 只把首个 token（argv[0]）解析成绝对路径——systemd ExecStart 要求 argv[0] 为绝对路径。
# 这样无论 ./server / "python3 run.py" / "java -jar app.jar" / "gunicorn app:app"
# 都按用户给定的命令原样运行，不存在「自动前缀」与「用户前缀」相撞的问题。
set -- $ENTRY
ARGV0="$1"; shift || true
case "$ARGV0" in
  /*)
    : ;;                                    # 已是绝对路径，原样使用
  */*)
    # 含 / 的相对路径（./server、subdir/app）→ 拼绝对路径；不能走 command -v，它会原样返回相对路径
    ARGV0="/opt/qianwenyun/${ARGV0#./}"
    chmod +x "$ARGV0" 2>/dev/null || true
    ;;
  *)
    if command -v "$ARGV0" >/dev/null 2>&1; then
      ARGV0="$(command -v "$ARGV0")"        # PATH 上的解释器/工具（python3 / node / java / gunicorn …）
    else
      ARGV0="/opt/qianwenyun/$ARGV0"         # 产物里的可执行文件（裸文件名，如 server）
      chmod +x "$ARGV0" 2>/dev/null || true
    fi ;;
esac
EXEC="$ARGV0 $*"

# 4. 写 systemd unit
cat > /etc/systemd/system/qianwenyun-app.service <<UNIT
[Unit]
Description=qianwenyun app
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/qianwenyun
Environment=PORT=${PORT}
EnvironmentFile=-/etc/qianwenyun/db.env
ExecStart=${EXEC}
Restart=always
RestartSec=3
StandardOutput=append:/var/log/qianwenyun-app.log
StandardError=append:/var/log/qianwenyun-app.log

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable qianwenyun-app
systemctl restart qianwenyun-app

echo "[$(date -u +%FT%TZ)] systemd backend up"
