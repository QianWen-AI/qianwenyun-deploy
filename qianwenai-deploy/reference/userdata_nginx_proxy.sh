#!/bin/bash
# qianwenai · Nginx 全量反代后端（适用于 Flask/Django/Express SSR 等服务端渲染应用）
# 该片段会被 generate_template.py 注入到 ECS UserData 头部。
# 占位符（generate_template.py 会替换）：
#   __BACKEND_PORT__           后端服务监听端口（如 5000）
set -euxo pipefail

LOG=/var/log/qianwenai-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date -u +%FT%TZ)] === qianwenai nginx (proxy) bootstrap start ==="

# 1. 安装 Nginx
if ! command -v nginx >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then dnf install -y nginx
  elif command -v yum >/dev/null 2>&1; then yum install -y nginx
  elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y nginx
  else echo "no supported package manager"; exit 1
  fi
fi

# 2. 写站点配置：所有请求反代到后端
cat > /etc/nginx/conf.d/qianwenai.conf <<NGINX
server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:__BACKEND_PORT__;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
    }

    location = /healthz { return 200 "ok\n"; }
}
NGINX

# 移除默认 server（避免冲突）
[ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak || true

nginx -t
systemctl enable nginx
systemctl restart nginx

echo "[$(date -u +%FT%TZ)] nginx (proxy) ready"
