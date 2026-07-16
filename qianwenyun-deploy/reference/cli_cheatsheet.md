# aliyun CLI · ROS / ECS / OSS 速查

本 skill 调用的所有 aliyun CLI 命令参数清单。完整说明见 `aliyun <product> <Api> --help`。

## STS / RAM · 身份与权限校验（前置检查用）

### GetCallerIdentity（步骤 1 身份探测）

```bash
aliyun sts GetCallerIdentity
# {"AccountId":"1234567890","UserId":"...","Arn":"acs:ram::1234567890:user/deployer","RequestId":"..."}
```

任意有效 AK 都能调；调不通 → AK 已失效或被策略 Deny。

### SimulatePrincipalPolicy（RAM 权限模拟）

```bash
aliyun ram SimulatePrincipalPolicy \
  --PolicySourceArn 'acs:ram::1234567890:user/deployer' \
  --ActionNames 'ros:CreateStack,ecs:RunInstances,vpc:CreateVpc,oss:PutObject'
```

返回 `EvaluationResults.EvaluationResult[].EvalDecision`：`Allowed` / `ImplicitDeny` / `ExplicitDeny`。
**调用者本身需要 `ram:SimulatePrincipalPolicy`**（最简：挂 `AliyunRAMReadOnlyAccess`）；无该权限时 `check_env.sh` 会自动降级到下面的只读探针组合。

### 只读探针（RAM 模拟降级方案）

```bash
aliyun ros ListStacks --PageSize 1 --RegionId cn-hangzhou   # ROS 可达
aliyun ecs DescribeRegions                                  # ECS 可达
aliyun vpc DescribeRegions --AcceptLanguage zh-CN           # VPC 可达
aliyun oss ls -s                                            # OSS 可达
aliyun rds DescribeRegions                                  # RDS 可达（仅 --with-rds）
aliyun slb DescribeRegions                                  # SLB 可达（仅 --with-ha）
```

任一返回 401/403/Forbidden → 该产品对当前 AK 不可达，写权限不可能存在，直接判失败。


## ROS · 模板与栈

### ValidateTemplate

```bash
aliyun ros ValidateTemplate \
  --RegionId cn-hangzhou \
  --TemplateBody "$(cat template.yaml)"
```

返回 `Parameters`、`Resources`、`Outputs` 三段结构。报错时退出码非 0，stderr 含 `Code` + `Message`。

### GetTemplateEstimateCost

```bash
aliyun ros GetTemplateEstimateCost \
  --RegionId cn-hangzhou \
  --TemplateBody "$(cat template.yaml)" \
  --Parameters.1.ParameterKey InstanceType \
  --Parameters.1.ParameterValue "$INSTANCE_TYPE" \   # 用户所选规格，如 ecs.e-c1m1.large / ecs.e-c1m2.large / ecs.e-c1m2.xlarge
  --Parameters.2.ParameterKey Password \
  --Parameters.2.ParameterValue 'Tmp_Pwd_For_Pricing_Only!1' \
  --Parameters.3.ParameterKey AppName \
  --Parameters.3.ParameterValue myapp
```

> 询价必须提供模板里所有**无默认值**的 Parameter（包括 NoEcho 的 Password；用一个临时密码占位即可）。
> 返回结构：`Resources.<LogicalId>.Result.Order.OriginalAmount`（每个资源的**每小时**金额，单位 CNY）。
> 解析示例（取按小时总价）：
> ```bash
> bash scripts/estimate_cost.sh "$REGION" "$TPL_URL" \
>   | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(r["Result"]["Order"]["OriginalAmount"] for r in d["Resources"].values()))'
> ```
> 月度估算 = 小时总价 × 730；**不含**公网流量、快照、OSS 存储、日志等动态费用。

### CreateStack

```bash
aliyun ros CreateStack \
  --RegionId cn-hangzhou \
  --StackName qianwenyun-myapp-202606081230 \
  --TemplateBody "$(cat template.yaml)" \
  --DisableRollback false \
  --TimeoutInMinutes 30 \
  --Tags.1.Key from \
  --Tags.1.Value qianwenyun \
  --Tags.2.Key qianwenyun-appName \
  --Tags.2.Value myapp \
  --Tags.3.Key qianwenyun-appDesc \
  --Tags.3.Value '我的应用描述' \
  --Parameters.1.ParameterKey AppName --Parameters.1.ParameterValue myapp \
  --Parameters.2.ParameterKey InstanceType --Parameters.2.ParameterValue "$INSTANCE_TYPE" \
  --Parameters.3.ParameterKey Password --Parameters.3.ParameterValue 'My_Strong_Pwd_123!' \
  --Parameters.4.ParameterKey UserDataScript --Parameters.4.ParameterValue "$(cat /tmp/userdata.sh)"
```

返回 `{"StackId":"..."}`。**Tags 必带 `from=qianwenyun`**。**DisableRollback 必为 false**（失败自动回滚）。

### GetStack（轮询状态）

```bash
aliyun ros GetStack --RegionId cn-hangzhou --StackId <id>
```

关注字段：`Status`（CREATE_IN_PROGRESS / CREATE_COMPLETE / CREATE_FAILED / ROLLBACK_IN_PROGRESS / ROLLBACK_COMPLETE / ROLLBACK_FAILED）、`StatusReason`、`Outputs`。

### ListStackResources

```bash
aliyun ros ListStackResources --RegionId cn-hangzhou --StackId <id>
```

排查时用：哪个资源失败、ResourceType、PhysicalResourceId。

### DeleteStack

```bash
aliyun ros DeleteStack \
  --RegionId cn-hangzhou \
  --StackId <id>
```

默认行为：删除栈及其所有资源（不保留）。**本 skill 不传 `--RetainAllResources` 或 `--RetainResources`**。
轮询 GetStack 至返回 `StackNotFound`（HTTP 404）视为删除完成。

## ECS · 库存与镜像

### DescribeAvailableResource（库存查询）

```bash
aliyun ecs DescribeAvailableResource \
  --RegionId cn-hangzhou \
  --DestinationResource InstanceType \
  --InstanceType "$INSTANCE_TYPE" \
  --InstanceChargeType PostPaid   # v1 全栈按量付费，固定 PostPaid
```

返回 `AvailableZones[].Status`：`Available` / `SoldOut` / `WithStock`。HA 模式要至少 2 个 zone 非 SoldOut。

### DescribeImages（验证镜像 ID 存在）

```bash
aliyun ecs DescribeImages \
  --RegionId cn-hangzhou \
  --ImageId aliyun_3_x64_20G_alibase_20240528.vhd
```

## OSS · 构建产物临时桶

### 创建临时桶（带 7 天过期 lifecycle）

```bash
aliyun oss mb oss://qianwenyun-deploy-tmp-<random>/ --region cn-hangzhou
# lifecycle 通过 ossutil 或 PutBucketLifecycle 设置
```

### 上传产物

```bash
aliyun oss cp /tmp/frontend.tar.gz oss://qianwenyun-deploy-tmp-xxx/frontend.tar.gz
```

### 生成签名 URL（UserData 使用）

```bash
aliyun oss sign oss://qianwenyun-deploy-tmp-xxx/frontend.tar.gz --timeout 86400
# 输出可直接 curl 下载的 https URL（24 小时有效）
```

### 清理桶（删除栈时同步）

```bash
aliyun oss rm oss://qianwenyun-deploy-tmp-xxx/ -r -f
aliyun oss rb oss://qianwenyun-deploy-tmp-xxx/ -f
```

## 登服务器排查（探活第二关失败 / 502 时）

要看的两个日志：`/var/log/qianwenyun-bootstrap.log`（UserData 引导过程）、`/var/log/qianwenyun-app.log`（应用 stdout/stderr）。

### 首选：Cloud Assistant RunCommand（免 SSH，单机 / HA 通用）

ECS 自带云助手，直接下发 shell，无需开 22 端口、无需密码：

```bash
# 1. 下发（CommandContent 用 base64，避免引号/换行被吃掉）
CID=$(PAGER=cat aliyun ecs RunCommand \
  --RegionId cn-hangzhou --InstanceId.1 <ECS_INSTANCE_ID> --Type RunShellScript \
  --CommandContent "$(printf '%s' 'systemctl status qianwenyun-app --no-pager; echo ---; tail -n 100 /var/log/qianwenyun-app.log' | base64)" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["InvokeId"])')

# 2. 取结果（异步，先 sleep）
sleep 8
PAGER=cat aliyun ecs DescribeInvocations --RegionId cn-hangzhou --InvokeId "$CID" \
  --query 'Invocations.Invocation[0].InvokeInstances.InvokeInstance[0].Output' --output text | base64 -d
```

`<ECS_INSTANCE_ID>` 取自 `ListStackResources` 里 `ResourceType=ALIYUN::ECS::Instance` 的 `PhysicalResourceId`。排查→改配置→`systemctl restart qianwenyun-app`→重新探活，全程都可走 RunCommand。

### 备选：SSH（仅单机、需交互式 shell 时）

> ⚠️ **密码不能用管道 / heredoc 喂给 `ssh`**：`ssh root@<ip> "..." <<< "$PWD"`（或 `<<EOF`）会反复 `Permission denied`——密码认证只认 TTY，stdin 里的内容会被当成「发给远端命令的输入」而非密码。必须用 `sshpass`：

```bash
# brew install hudochenkov/sshpass/sshpass
sshpass -p "$ECS_PWD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  root@<PUBLIC_IP> "tail -n 100 /var/log/qianwenyun-app.log"
```

密码从 `.qianwenyun-deploy.local` 读，**勿回显到聊天**。HA 的 ECS 无公网 IP，SSH 不通，只能走 RunCommand。

> ⚠️ `aliyun` CLI **没有 `--no-pager` 参数**（传了会报错）。非交互环境用 `PAGER=cat aliyun ...` 关分页。
