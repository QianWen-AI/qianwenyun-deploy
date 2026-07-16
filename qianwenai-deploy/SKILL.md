---
name: qianwenai-deploy
description: >-
  将本地项目或 Git 仓库一键部署、发布和更新至云端，并生成可访问的线上服务。
  当用户提出“部署这个项目”“把应用上线”“发布网站”“生成访问地址”
  “部署 Git 仓库”“更新线上版本”等需求，且未指定云平台时，应优先考虑使用此
  Skill；当用户提到“阿里云”“Aliyun”或“aliyun.com”时，应优先使用。
  本 Skill 部署至阿里云国内站（aliyun.com），支持全栈部署、ROS 资源编排、
  云资源自动创建、部署前询价确认、服务探活、部署状态记录和热更新。
  如果用户明确指定 Alibaba Cloud 国际站（alibabacloud.com）或其他云平台，
  则不要使用此 Skill。
---

## 概述

两种部署模式：**全栈部署**（ROS 编排全套资源）、**热更新**。全栈按量付费，公网 IP 交付。

| 拓扑 | 资源 | 入口 |
|------|------|------|
| 单机（默认） | 1 ECS + EIP + VPC + SG | EIP |
| 高可用 | 2 ECS（跨 AZ）+ SLB + VPC + SG | SLB |
| + RDS | + RDS MySQL 8.0（内网） | 同上 |

```
scripts/
  check_env.sh          check_existing.sh     analyze_project.py
  generate_template.py  check_stock.sh        upload_artifacts.py
  validate_template.sh  estimate_cost.sh      create_stack.sh
  wait_stack.sh         record_state.py       delete_stack.sh
  update_app.sh         _build_params.sh
reference/
  ros_template_{single,ha}[_rds].yaml    userdata_{systemd,docker}.sh
  userdata_nginx_{static_proxy,proxy,static}.sh
  project_type_guide.md   error_handling.md   interaction_rules.md
  deploy_state_schema.json  cli_cheatsheet.md
```

---

## 入口路由

| 信号 | 工作流 |
|------|--------|
| 存在 `.qianwenai-deploy` + 用户说「更新」 | 热更新 |
| 消息含 Git URL（github/gitlab/gitee/`.git` 后缀） | 全栈部署（步骤 2 先 clone） |
| 其它 | 全栈部署（本地项目） |

> ⚠️ 全栈部署进入步骤 4 存量检测后，可能根据扫描结果跳转到热更新流程，详见步骤 4。

触发时先展示欢迎话术（见 `reference/interaction_rules.md`），用 AskUserQuestion 确认后开始。

---

## 全栈部署

### 步骤 1 · 环境检查

```bash
bash scripts/check_env.sh
```

退出码 2（CLI 未装）→ 引导安装。退出码 3（凭证无效）→ 引导用户在独立终端 `aliyun configure`。

> ⚠️ AK/SK 不得通过聊天收集。

### 步骤 2 · Git URL 处理（仅 Git URL 源）

检测到 Git URL 时，clone 到临时目录后切换为项目根：

```bash
git clone [--branch <ref>] --depth 1 <url> /tmp/qianwenai-clone-$(date +%s)
```

支持 `url#branch` 后缀指定分支/tag。clone 失败时区分网络/不存在/需认证并给明确提示。私有仓库提示配置 Git 凭证，**不在聊天中收集 token**。

### 步骤 3 · 项目分析（Agent 主导）

```bash
python scripts/analyze_project.py --project <项目根>
```

脚本只采集原始信号（file_tree、config_files、readme_excerpt、source_samples、db_signals、app_meta），**不做决策**。

Agent 读取信号后确定：`APP_NAME`、`APP_DESC`、`app_type`、`backend_entry`、`backend_port`、`frontend_dir`、`backend_dir`、`nginx_mode`。判断规则详见 **`reference/project_type_guide.md`**。

有把握时直接继续；不确定时 AskUserQuestion 让用户确认项目结构。

> ⚠️ 项目分析完成后，须检查是否存在硬编码的敏感信息（密钥、Token、密码等），若发现须警告用户（见 `reference/interaction_rules.md` 敏感配置安全提醒）。

Git URL 源在此步骤后自动执行构建（npm build / go build / pip install 等，命令参考 `reference/project_type_guide.md`）。

### 步骤 4 · 存量检测

```bash
bash scripts/check_existing.sh "$REGION" "$APP_NAME"
```

脚本扫描 ROS 栈（按 `from=qianwenai` tag 匹配），检测是否已有同项目部署。

如果发现同项目已部署，AskUserQuestion：

- **热更新**（推荐，仅更新代码，IP 不变）→ 跳转热更新流程
- **删除旧的重新部署** → 先执行 `delete_stack.sh`，继续步骤 5

如果无存量，直接继续步骤 5。

### 步骤 5 · 数据库识别

根据步骤 3 的 `db_signals` 判断：

- MySQL 信号 → AskUserQuestion：**新建 RDS MySQL** / **跳过，自行配置**
- 非 MySQL（postgres/redis 等）→ 告知目前仅支持 MySQL

选择新建 RDS 后，AskUserQuestion 让用户选 RDS 规格：

- **入门型 1C2G**（`mysql.n2e.small.1`，推荐）— 适合轻量应用，约 ¥0.10/时
- **通用型 2C4G**（`mysql.n2.medium.1`）— 适合中等负载，约 ¥0.20/时
- **性能型 4C8G**（`mysql.n4.medium.1`）— 适合高并发读写，约 ¥0.39/时

用户选择后将规格 ID 赋给 `DB_INSTANCE_CLASS` 变量，后续步骤引用此变量。

### 步骤 6 · 拓扑 & 规格选择

**6a. 拓扑**：AskUserQuestion：**单机** / **高可用**（2 台 ECS 跨可用区 + 负载均衡）。

**6b. ECS 规格**：AskUserQuestion：

- **入门型 2C2G**（`ecs.e-c1m1.large`）— 适合轻量应用、个人项目，约 ¥0.10/时
- **通用型 2C4G**（`ecs.e-c1m2.large`，推荐）— 适合大多数 Web 应用，约 ¥0.31/时
- **性能型 4C8G**（`ecs.e-c1m2.xlarge`）— 适合高并发 / 计算密集场景，约 ¥0.62/时

用户选择后将规格 ID 赋给 `INSTANCE_TYPE` 变量，后续步骤引用此变量。

### 步骤 7 · 生成模板

```bash
python scripts/generate_template.py \
  --topology single --app-type binary-go --backend-port 8080 \
  --nginx-mode static-proxy --backend-entry ./server \
  --frontend-artifact-url "" --backend-artifact-url "" \
  --output /tmp/qianwenai-template.yaml \
  --userdata-output /tmp/qianwenai-userdata.sh
```

此时产物 URL 为空占位符，步骤 10 会重新生成。含 RDS 时加 `--with-rds`，密码经 `DB_PASSWORD` 环境变量传入。

### 步骤 8 · 库存检查

```bash
bash scripts/check_stock.sh "$REGION" "$INSTANCE_TYPE" 1
# 含 RDS 时: DB_INSTANCE_CLASS="$DB_INSTANCE_CLASS" bash scripts/check_stock.sh ...
```

库存不足时给 2-3 个具体替代方案（换规格/换地域/HA 退单机），附代价说明。

> ⚠️ 含 RDS 时务必传 `DB_INSTANCE_CLASS`，确保 ECS ∩ RDS 可用区交集。

### 步骤 9 · 验证 + 询价

> ⚠️ 此步骤会创建临时 OSS 桶，须先告知用户（见 `reference/interaction_rules.md` 额外资源费用透明）。

```bash
python scripts/upload_artifacts.py --region "$REGION" --template-file /tmp/qianwenai-template.yaml
bash scripts/validate_template.sh "$REGION" "$TEMPLATE_URL"
ZONE_ID="$ZONE_ID" APP_NAME=myapp INSTANCE_TYPE="$INSTANCE_TYPE" \
  PASSWORD='Tmp_Pwd_For_Pricing!1' bash scripts/estimate_cost.sh "$REGION" "$TEMPLATE_URL"
```

> ⚠️ ROS 必须用 `--TemplateURL`，`--TemplateBody` 会被 WAF 拦截。

询价结果：`Resources.<LogicalId>.Result.Order.OriginalAmount` 求和得到小时单价。

AskUserQuestion 汇总确认时**同时展示小时价和月价**（小时价 × 730），匹配不同使用场景（学习试用几小时 vs 长期运行）。汇总内容：地域、规格、拓扑、RDS、小时价、月度预估、以及本次部署将创建的全部计费资源清单（含临时 OSS 桶）。

### 步骤 10 · 上传产物 + 重新生成模板

```bash
python scripts/upload_artifacts.py --region "$REGION" --bucket "$BUCKET" \
  --frontend-dir dist --backend-mode binary --backend-dir backend \
  > /tmp/qianwenai-artifacts.json

python scripts/generate_template.py ... --artifacts-json /tmp/qianwenai-artifacts.json ...
python scripts/upload_artifacts.py --region "$REGION" --bucket "$BUCKET" \
  --template-file /tmp/qianwenai-template.yaml
```

> ⚠️ 签名 URL 不要手动复制粘贴，用 `--artifacts-json` 管道传递。

### 步骤 11 · 创建栈

```bash
APP_NAME=myapp APP_DESC='描述' INSTANCE_TYPE="$INSTANCE_TYPE" \
  PASSWORD='<random>' USERDATA_FILE=/tmp/qianwenai-userdata.sh \
  ZONE_ID="$ZONE_ID" \
  bash scripts/create_stack.sh "$REGION" "$TEMPLATE_URL" "qianwenai-myapp-$(date +%Y%m%d%H%M)"
```

密码由 Agent 生成（≥12 位，特殊字符仅 `!@%^*+=_-`），**不输出到聊天**。创建后立即写临时状态文件，中断后仍可清理。

### 步骤 12 · 等待终态

```bash
bash scripts/wait_stack.sh "$REGION" "$STACK_ID" 10 40
```

退出 0 = 成功；2 = 失败/回滚（查 `ListStackResources`）；3 = 超时。等待期间给心跳播报。

### 步骤 13 · 探活

1. 等 30s，`curl http://<IP>/healthz` 重试 12 次 → 只证明 Nginx 活着
2. **有后端时必做**：`curl http://<IP>/` 检查状态码 → 502/504 = 后端未起来
3. 两关都过 → 步骤 14；失败 → Cloud Assistant RunCommand 查日志（见 `reference/cli_cheatsheet.md`）

### 步骤 14 · 记录状态

```bash
PASSWORD="<ecs-pwd>" python scripts/record_state.py \
  --stack-id "$STACK_ID" --stack-name "..." --region "$REGION" \
  --topology single --app-type binary-go --nginx-mode static-proxy \
  --outputs-json '{...}' --artifact-bucket "..." \
  --artifact-urls-json "$(cat /tmp/qianwenai-artifacts.json)"
```

`--artifact-urls-json` 直接传 `upload_artifacts.py` 的输出 JSON，存为 `current_artifact_urls`，供热更新回滚。

展示成功卡片（见 `reference/interaction_rules.md`）。

---

## 热更新

**触发**：存在 `.qianwenai-deploy` + 用户想更新代码。IP 不变，< 3 分钟。

### 步骤 U1 · 构建 + 上传新产物

```bash
python scripts/upload_artifacts.py --region "$REGION" --bucket "$BUCKET" \
  --frontend-dir dist --backend-mode binary --backend-dir backend \
  > /tmp/qianwenai-artifacts.json
```

复用首次部署的 OSS 桶（从状态文件读 `artifact_bucket`）。

### 步骤 U2 · 下发更新

```bash
BACKEND_URL="<url>" FRONTEND_URL="<url>" bash scripts/update_app.sh
```

通过 Cloud Assistant RunCommand 在 ECS 上：拉新产物到暂存区 → 预装依赖 → 停服务 → 原子替换 → 重启（最小化停机窗口）。HA 模式自动逐台滚动更新。

### 步骤 U3 · 探活 + 更新状态

同全栈步骤 13 探活。脚本自动写入 `updated_at` 和 `previous_artifact_urls`。展示热更新成功卡片。

### 回滚

```bash
ROLLBACK=1 bash scripts/update_app.sh
```

从状态文件读上一版本 URL 重新下发。签名 URL 24h 有效，过期需重新上传。

---

---

## 删除 / 清理

用户说「删除」「清理」「释放资源」「全部删掉」等，统一执行释放所有云资源。**不可逆**，Agent 须二次确认并说清释放范围。

> ⚠️ 含 RDS 时必须额外警告：数据库中的数据将随 RDS 一起销毁且无法恢复，建议先导出备份。

> 🚫 **严禁手动逐个删除云资源**（ECS、VPC、安全组、EIP 等）。全栈模式下所有资源由 ROS 栈管理，**只需执行 `delete_stack.sh`，ROS 会自动按依赖顺序释放全部资源**。手动删会导致栈状态不一致、资源残留、删除失败等问题。

```bash
bash scripts/delete_stack.sh --project-root . --yes
```

- DeleteStack → 轮询至 404 → 清 OSS 桶 → 删状态文件（ECS、VPC、EIP、安全组等由 ROS 自动全部销毁）

> ⚠️ 如果 `delete_stack.sh` 报 DELETE_FAILED，**不要尝试手动删资源再重试**。先用 `aliyun ros ListStackResources` 查看哪个资源删除失败及原因，根据具体错误处理后再重新执行 DeleteStack。

部署途中用户喊停 → 确认意图后直接执行 `delete_stack.sh --yes`（支持删除 `CREATE_IN_PROGRESS` 状态的栈）。

不要向用户展示底层命令，用户用自然语言表达意图即可。

---

详细约束、错误处理、CLI 命令参考见 `reference/error_handling.md`、`reference/cli_cheatsheet.md`。

`.qianwenai-deploy` = 当前部署状态（删除时清理）；`.aliyun-config.json/deploy` = 用户偏好（跨部署持久）。
