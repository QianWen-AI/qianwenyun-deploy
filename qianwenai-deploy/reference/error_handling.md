# 错误处理与约束

## 错误速查

| 现象 | 原因 | 处理 |
|------|------|------|
| `check_env.sh` 退出码 2 | CLI 未装 / 版本过低 | `brew install aliyun-cli` |
| `check_env.sh` 退出码 3 | 凭证无效 | 独立终端 `aliyun configure` |
| `check_env.sh` 退出码 6 | AK 身份探测失败 | RAM 控制台检查 AK 状态 |
| `InvalidTemplate` | YAML 语法错 | 看 Message 修模板 |
| `InsufficientStock` | 库存不足 | 给 2-3 个替代方案（更大规格 / 换地域 / HA 退单机） |
| `InvalidParameter` | 密码不合格 | 重新生成强密码 |
| 栈回滚 `ROLLBACK_COMPLETE` | 资源创建失败 | `ListStackResources` 定位出错资源 |
| 探活失败但栈成功 | UserData 未跑完 / 应用未启动 | 查 `/var/log/qianwenai-bootstrap.log` |
| `/healthz` 通但 `/` 返回 502 | 后端崩了，Nginx 掩盖故障 | 查 `/var/log/qianwenai-app.log` |
| `DELETE_FAILED` | 资源被外部占用 | ROS 控制台手动清理 |
| 密码丢失 | `.local` 文件误删 | ECS/RDS 控制台重置密码 |
| RunCommand 超时 | 云助手未响应 | 检查 ECS 状态和 `DescribeCloudAssistantStatus` |
| RunCommand 权限不足 | 缺 `ecs:RunCommand` 权限 | 添加 `AliyunECSFullAccess` 或精确授权 |
| 热更新后应用未启动 | 新版本产物问题 | `ROLLBACK=1 bash scripts/update_app.sh` 回滚 |
| 云助手不可用 | 未安装或未启动 | `systemctl start aliyun.service` |
| 安全组未开放 80 | 规则缺失 | ECS 控制台添加入方向 TCP 80 |
| RDS `InvalidDBInstanceClass` | 规格不可用 | 检查 RDS 控制台可用规格 |
| RDS 可用区不支持 | ECS 有货但 RDS 没有 | 重跑 `check_stock.sh` 带 `DB_INSTANCE_CLASS` |
| `QuotaExceed.Instance` | 配额已满 | 清理闲置实例或提额 |

## 约束

**模板与 API**：
- ROS 必须用 `--TemplateURL`（`--TemplateBody` 被 WAF 拦截）
- 可用区必须从 `check_stock.sh` 获取
- SLB 不传 `VSwitchId`（否则强制内网类型）
- `DisableRollback=false` 和 `from=qianwenai` tag 必带
- 禁止跳过 `ValidateTemplate`

**产物与 OSS**：
- 产物 URL 必须用内网端点（HA 的 ECS 无公网 IP）
- 临时桶记录在 `.qianwenai-deploy` 中，`delete_stack.sh` 依赖它清理

**密码**：
- 特殊字符仅 `!@%^*+=_-`（`& # $ | ;` 会破坏 `db.env` source）
- ECS 与 RDS 密码分别生成、分别记录，不入聊天

**探活**：
- `/healthz` 只证明 Nginx 活着，不证明后端活着，探活必须两关
- 不猜 API 路由前缀

**RDS**：
- 仅 MySQL 8.0，不支持 PG/Redis/MongoDB
- 单 AZ，密码与 ECS 不复用
- `Fn::Sub` 内主脚本做 base64 编码注入，运行时解码 + source，避免 shell 变量与 Fn::Sub 冲突

## 当前限制

- 全栈按量付费，不支持包年包月
- 不支持 HTTPS（需自备域名+证书）
- 单 region
- 热更新回滚依赖签名 URL（24h 有效期）
