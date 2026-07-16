#!/bin/bash
# qianwenyun · Nginx 纯静态托管（无后端反代）
# 该片段会被 generate_template.py 注入到 ECS UserData 头部。
# 占位符（generate_template.py 会替换）：
#   __FRONTEND_ARTIFACT_URL__  前端 dist 压缩包的 OSS 签名 URL（http GET）
set -euxo pipefail

LOG=/var/log/qianwenyun-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
echo "[$(date -u +%FT%TZ)] === qianwenyun nginx (static) bootstrap start ==="

# 1. 安装 Nginx
if ! command -v nginx >/dev/null 2>&1; then
  if command -v dnf >/dev/null 2>&1; then dnf install -y nginx
  elif command -v yum >/dev/null 2>&1; then yum install -y nginx
  elif command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y nginx
  else echo "no supported package manager"; exit 1
  fi
fi

# 2. 拉取前端构建产物（若有）
FRONTEND_URL='__FRONTEND_ARTIFACT_URL__'
mkdir -p /var/www/frontend
if [ -n "$FRONTEND_URL" ]; then
  curl -fsSL "$FRONTEND_URL" -o /tmp/frontend.tar.gz
  tar -xzf /tmp/frontend.tar.gz -C /var/www/frontend --strip-components=0
  rm -f /tmp/frontend.tar.gz
else
  cat > /var/www/frontend/index.html <<'HTML'
<!doctype html><meta charset=utf-8><title>qianwenyun</title>
<h1>ECS is up. Awaiting frontend artifact.</h1>
HTML
fi

# 3. 写站点配置：纯静态托管，无后端反代
cat > /etc/nginx/conf.d/qianwenyun.conf <<NGINX
server {
    listen 80 default_server;
    server_name _;
    root /var/www/frontend;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location = /healthz { return 200 "ok\n"; }
}
NGINX

# 移除默认 server（避免冲突）
[ -f /etc/nginx/conf.d/default.conf ] && mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak || true

nginx -t
systemctl enable nginx
systemctl restart nginx

echo "[$(date -u +%FT%TZ)] nginx (static) ready"
