#!/bin/bash
# qianwenai · Docker 后端 bootstrap
# 占位符：
#   __BACKEND_ARTIFACT_URL__   后端镜像 tar.gz（docker save 的产物）或 docker-compose.yml + 构建上下文 tar.gz 的 OSS 签名 URL
#   __BACKEND_MODE__           docker-image | docker-compose
#   __BACKEND_PORT__           后端容器监听端口（被 Nginx 反代）
#   __BACKEND_IMAGE_NAME__     docker-image 模式下 docker load 后的镜像名:tag（如 myapp:latest）
set -euxo pipefail

LOG=/var/log/qianwenai-bootstrap.log
exec >> "$LOG" 2>&1
echo "[$(date -u +%FT%TZ)] === qianwenai docker bootstrap start ==="

# 1. 安装 Docker
if ! command -v docker >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y docker
  elif command -v yum >/dev/null 2>&1; then
    yum install -y docker
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y docker.io
  fi
fi
systemctl enable docker
systemctl start docker

BACKEND_URL="__BACKEND_ARTIFACT_URL__"
BACKEND_MODE="__BACKEND_MODE__"
BACKEND_PORT="__BACKEND_PORT__"
IMAGE_NAME="__BACKEND_IMAGE_NAME__"

mkdir -p /opt/qianwenai
cd /opt/qianwenai
curl -fsSL "$BACKEND_URL" -o backend.tar.gz

# 若 RDS bootstrap 写了 db.env，docker 启动时挂进容器
DB_ENV_OPT=""
[ -f /etc/qianwenai/db.env ] && DB_ENV_OPT="--env-file /etc/qianwenai/db.env"

if [ "$BACKEND_MODE" = "docker-image" ]; then
  # 解压并 docker load
  tar -xzf backend.tar.gz
  docker load -i image.tar
  # 写 systemd unit 持久托管
  cat > /etc/systemd/system/qianwenai-app.service <<UNIT
[Unit]
Description=qianwenai app container
After=docker.service
Requires=docker.service

[Service]
Restart=always
ExecStartPre=-/usr/bin/docker rm -f qianwenai-app
ExecStart=/usr/bin/docker run --rm --name qianwenai-app -p ${BACKEND_PORT}:${BACKEND_PORT} ${DB_ENV_OPT} ${IMAGE_NAME}
ExecStop=/usr/bin/docker stop qianwenai-app

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable qianwenai-app
  systemctl restart qianwenai-app

elif [ "$BACKEND_MODE" = "docker-compose" ]; then
  # 解压（包含 docker-compose.yml 和构建上下文 或 已 build 的镜像 tar）
  tar -xzf backend.tar.gz
  # 安装 docker compose plugin（若未自带）
  if ! docker compose version >/dev/null 2>&1; then
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -fsSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  fi
  # compose 会自动加载同目录下的 .env；如有 RDS env 则导出到 .env
  if [ -f /etc/qianwenai/db.env ]; then
    cp /etc/qianwenai/db.env ./.env
  fi
  docker compose -f docker-compose.yml up -d
fi

echo "[$(date -u +%FT%TZ)] docker backend up"
