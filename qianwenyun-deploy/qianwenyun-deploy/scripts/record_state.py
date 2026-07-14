#!/usr/bin/env python3
"""
写入 .qianwenyun-deploy 状态文件（项目根目录）。
schema 见 reference/deploy_state_schema.json。

用法（全栈部署）：
  python record_state.py \
    --stack-id <id> --stack-name <name> --region cn-hangzhou \
    --topology single --app-type docker \
    --outputs-json '{"PublicIp":"47.x.x.x","EcsInstanceIds":"i-xxx,i-yyy","SlbId":"lb-xxx",
                     "DbInstanceId":"rm-xxx","DbConnectionAddress":"rm-xxx.mysql.rds.aliyuncs.com",
                     "DbPort":"3306","DbAccount":"appuser"}' \
    [--artifact-bucket qianwenyun-deploy-tmp-xxx] \
    [--frontend-dir dist] [--backend-dir backend] \
    [--with-rds] [--db-engine mysql]

密码通过环境变量传入（不走命令行，避免在 `ps` 进程列表泄露明文）：
  PASSWORD      ECS 登录密码 → 写入 .qianwenyun-deploy.local
  DB_PASSWORD   RDS 账号密码 → 写入 .qianwenyun-deploy.local（含 RDS 时）

输出：.qianwenyun-deploy 路径
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stack-id", required=True,
                    help="ROS Stack ID")
    ap.add_argument("--stack-name", required=True,
                    help="ROS Stack Name")
    ap.add_argument("--region", required=True)
    ap.add_argument("--topology", required=True, choices=["single", "ha"])
    ap.add_argument("--app-type", required=True)
    ap.add_argument("--outputs-json", required=True,
                    help='ROS GetStack 的 Outputs 序列化为 {"Key": "Value"} 的 JSON')
    ap.add_argument("--artifact-bucket", default=None)
    ap.add_argument("--frontend-dir", default=None)
    ap.add_argument("--backend-dir", default=None)
    ap.add_argument("--nginx-mode", default=None, choices=["static-proxy", "proxy", "static"])
    ap.add_argument("--with-rds", action="store_true")
    ap.add_argument("--db-engine", default=None, choices=["mysql"])
    ap.add_argument("--artifact-urls-json", default=None,
                    help='产物签名 URL（upload_artifacts.py 的输出 JSON），存入 current_artifact_urls 供热更新回滚')
    ap.add_argument("--notes", default="")
    ap.add_argument("--project-root", default=".")
    args = ap.parse_args()

    deploy_mode = "full-stack"

    # 密码从环境变量读取，不经命令行（避免 ps 泄露）
    ecs_password = os.environ.get("PASSWORD") or None
    db_password = os.environ.get("DB_PASSWORD") or None

    outputs = json.loads(args.outputs_json)
    public_ip = outputs.get("PublicIp") or outputs.get("public_ip")
    ecs_ids_raw = outputs.get("EcsInstanceIds") or outputs.get("ecs_instance_ids") or ""
    if isinstance(ecs_ids_raw, list):
        ecs_ids = [str(x) for x in ecs_ids_raw]
    else:
        ecs_ids = [x.strip() for x in str(ecs_ids_raw).split(",") if x.strip()]
    slb_id = outputs.get("SlbId") or outputs.get("slb_id")

    db_instance_id = outputs.get("DbInstanceId") or outputs.get("db_instance_id")
    db_conn = outputs.get("DbConnectionAddress") or outputs.get("db_connection_address")
    db_port_raw = outputs.get("DbPort") or outputs.get("db_port")
    db_port = int(db_port_raw) if db_port_raw not in (None, "") else None
    db_account = outputs.get("DbAccount") or outputs.get("db_account")

    state = {
        "version": 1,
        "deploy_mode": deploy_mode,
        "region_id": args.region,
        "topology": args.topology,
        "app_type": args.app_type,
        "frontend_dir": args.frontend_dir,
        "backend_dir": args.backend_dir,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "tags": [{"Key": "from", "Value": "qianwenyun"}],
        "outputs": {
            "public_ip": public_ip,
            "ecs_instance_ids": ecs_ids,
            "slb_id": slb_id,
            "db_instance_id": db_instance_id,
            "db_connection_address": db_conn,
            "db_port": db_port,
            "db_account": db_account,
        },
        "nginx_mode": args.nginx_mode,
        "artifact_bucket": args.artifact_bucket,
        "notes": args.notes,
    }
    if args.stack_id:
        state["stack_id"] = args.stack_id
    if args.stack_name:
        state["stack_name"] = args.stack_name
    if args.with_rds or db_instance_id:
        state["db_engine"] = args.db_engine or "mysql"

    if args.artifact_urls_json:
        urls = json.loads(args.artifact_urls_json)
        current = {k: v for k, v in urls.items() if v and k.endswith("_url") and k not in ("template_url",)}
        if current:
            state["current_artifact_urls"] = current

    root = Path(args.project_root).resolve()
    state_path = root / ".qianwenyun-deploy"
    state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")

    if ecs_password or db_password:
        local_path = root / ".qianwenyun-deploy.local"
        local_data = {"stack_id": args.stack_id,
                      "warning": "本文件含密码，请勿提交版本库"}
        if ecs_password:
            local_data["ecs_password"] = ecs_password
        if db_password:
            local_data["db_password"] = db_password
        local_path.write_text(json.dumps(local_data, ensure_ascii=False, indent=2),
                              encoding="utf-8")
        os.chmod(local_path, 0o600)

        # 追加到 .gitignore
        gi = root / ".gitignore"
        existing = gi.read_text(encoding="utf-8") if gi.exists() else ""
        lines = existing.splitlines()
        changed = False
        for entry in (".qianwenyun-deploy.local",):
            if entry not in lines:
                lines.append(entry)
                changed = True
        if changed:
            content = "\n".join(lines)
            if not content.endswith("\n"):
                content += "\n"
            gi.write_text(content, encoding="utf-8")
    # 若两个密码都没传，保留旧行为：不写 .local，不动 .gitignore

    print(str(state_path))


if __name__ == "__main__":
    main()
