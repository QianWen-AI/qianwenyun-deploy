#!/usr/bin/env python3
"""
组装最终 ROS 模板：基于 reference/ros_template_{single,ha}[_rds].yaml 骨架，
按 app_type 注入 reference/userdata_*.sh 片段（含占位符替换）。

无 RDS 路径：
  - 模板写出原样（UserData 走 Parameter 传入）
  - UserData 拼好写到独立文件，由 create_stack.sh 作为 UserDataScript 参数传

含 RDS 路径（--with-rds）：
  - 选 *_rds.yaml 模板（ECS UserData 字段是 Fn::Sub 块，含 __USERDATA_BODY__ 占位）
  - 拼好 UserData body 后做 base64 编码，注入到模板 __USERDATA_BODY__ 位置。
    运行时先写 db.env（RDS 变量由 Fn::Sub 替换），再解码 + source 主脚本。
    这样 Fn::Sub 完全不接触 shell 变量，避免 ${!VAR} 不可靠的问题。
  - --userdata-output 在 --with-rds 时不再写出独立文件（UserData 已 inline 到模板）

用法示例：
  # 无 RDS（产物 URL 直接读 upload_artifacts.py 的 JSON 输出，无需手动粘贴）
  python upload_artifacts.py --region cn-hangzhou --frontend-dir dist \\
    --backend-mode binary --backend-dir backend > /tmp/artifacts.json
  python generate_template.py --topology single --app-type binary-go \\
    --backend-port 8080 --backend-entry ./server \\
    --artifacts-json /tmp/artifacts.json \\
    --output /tmp/tpl.yaml --userdata-output /tmp/userdata.sh
  # 或直接管道：upload_artifacts.py ... | generate_template.py ... --artifacts-json -

  # 含 RDS（密码经环境变量 DB_PASSWORD 传入，不走命令行）
  DB_PASSWORD='Strong_P@ss1' python generate_template.py --topology single --app-type binary-go \\
    --backend-port 8080 --backend-entry ./server \\
    --frontend-artifact-url "https://..." --backend-artifact-url "https://..." \\
    --with-rds --db-name appdb --db-account appuser \\
    --output /tmp/tpl.yaml --userdata-output /tmp/userdata.sh
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from pathlib import Path


REF_DIR = Path(__file__).resolve().parent.parent / "reference"


def load_skeleton(topology: str, with_rds: bool) -> str:
    if with_rds:
        fname = f"ros_template_{topology}_rds.yaml"
    else:
        fname = f"ros_template_{topology}.yaml"
    return (REF_DIR / fname).read_text(encoding="utf-8")


def build_userdata(app_type: str, args) -> str:
    parts = ["#!/bin/bash", "set -euxo pipefail", "exec >> /var/log/qianwenai-bootstrap.log 2>&1"]

    nginx_mode = getattr(args, "nginx_mode", "static-proxy")

    if nginx_mode == "proxy":
        nginx = (REF_DIR / "userdata_nginx_proxy.sh").read_text(encoding="utf-8")
        nginx = nginx.replace("__BACKEND_PORT__", str(args.backend_port))
        parts.append("# --- nginx: proxy (server-rendered) ---")
        parts.append(nginx)
    elif nginx_mode == "static":
        nginx = (REF_DIR / "userdata_nginx_static.sh").read_text(encoding="utf-8")
        nginx = nginx.replace("__FRONTEND_ARTIFACT_URL__", args.frontend_artifact_url or "")
        parts.append("# --- nginx: static (no backend) ---")
        parts.append(nginx)
    else:
        nginx = (REF_DIR / "userdata_nginx_static_proxy.sh").read_text(encoding="utf-8")
        nginx = nginx.replace("__FRONTEND_ARTIFACT_URL__", args.frontend_artifact_url or "")
        nginx = nginx.replace("__BACKEND_PORT__", str(args.backend_port))
        parts.append("# --- nginx: static-proxy (frontend + api) ---")
        parts.append(nginx)

    # 后端片段
    if app_type == "frontend-only":
        pass
    elif app_type == "docker":
        backend = (REF_DIR / "userdata_docker.sh").read_text(encoding="utf-8")
        backend = backend.replace("__BACKEND_ARTIFACT_URL__", args.backend_artifact_url or "")
        backend = backend.replace("__BACKEND_MODE__", args.backend_mode or "docker-image")
        backend = backend.replace("__BACKEND_PORT__", str(args.backend_port))
        backend = backend.replace("__BACKEND_IMAGE_NAME__", args.backend_image_name or "qianwenai-app:latest")
        parts.append("# --- backend: docker ---")
        parts.append(backend)
    elif app_type.startswith("binary-"):
        runtime = {"binary-go": "binary", "binary-java": "java", "binary-node": "node", "binary-python": "python"}[app_type]
        backend = (REF_DIR / "userdata_systemd.sh").read_text(encoding="utf-8")
        backend = backend.replace("__BACKEND_ARTIFACT_URL__", args.backend_artifact_url or "")
        backend = backend.replace("__BACKEND_RUNTIME__", runtime)
        backend = backend.replace("__BACKEND_ENTRY__", args.backend_entry or "./server")
        backend = backend.replace("__BACKEND_PORT__", str(args.backend_port))
        parts.append(f"# --- backend: {app_type} ---")
        parts.append(backend)
    else:
        print(f"unknown app_type: {app_type}", file=sys.stderr)
        sys.exit(2)

    return "\n".join(parts) + "\n"


def inject_userdata_body(template_text: str, userdata_body: str) -> str:
    """把 userdata_body 做 base64 编码后注入模板的 __USERDATA_BODY__ 占位。

    不再尝试逐个转义 shell 变量（${!VAR} 不可靠，且 $VAR / ${VAR#pattern} 也会被
    ROS Fn::Sub 解析报错）。改用 base64 编码方案：Fn::Sub 完全看不到 shell 变量，
    运行时解码后 source 执行，继承 db.env 环境变量。
    """
    marker = "__USERDATA_BODY__"
    if marker not in template_text:
        print(f"模板中找不到 {marker} 占位符", file=sys.stderr)
        sys.exit(2)

    encoded = base64.b64encode(userdata_body.encode("utf-8")).decode("ascii")

    loader = (
        f"echo '{encoded}' | base64 -d > /tmp/qianwenai-main.sh\n"
        f"chmod +x /tmp/qianwenai-main.sh\n"
        f". /tmp/qianwenai-main.sh"
    )

    for line in template_text.splitlines():
        if marker in line:
            indent = line[: len(line) - len(line.lstrip())]
            break

    indented_lines = []
    for ln in loader.splitlines():
        if ln.strip():
            indented_lines.append(indent + ln)
        else:
            indented_lines.append("")
    indented_body = "\n".join(indented_lines)

    full_marker_line = indent + marker
    return template_text.replace(full_marker_line, indented_body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", choices=["single", "ha"], required=True)
    ap.add_argument("--app-type", required=True,
                    choices=["frontend-only", "docker", "binary-go", "binary-java", "binary-node", "binary-python"])
    ap.add_argument("--backend-port", type=int, default=8080)
    ap.add_argument("--frontend-artifact-url", default="")
    ap.add_argument("--backend-artifact-url", default="")
    ap.add_argument("--artifacts-json", default=None,
                    help="upload_artifacts.py 的 JSON 输出（文件路径，或 - 表示从 stdin 读）；"
                         "自动取其中的 frontend_url / backend_url，免去手动粘贴长签名 URL。"
                         "显式的 --frontend-artifact-url / --backend-artifact-url 优先。")
    ap.add_argument("--backend-mode", default="docker-image", choices=["docker-image", "docker-compose"])
    ap.add_argument("--backend-image-name", default="")
    ap.add_argument("--backend-entry", default="",
                    help="完整启动命令（相对 /opt/qianwenai），如 ./server / "
                         "\"python3 app.py\" / \"java -jar app.jar\" / \"node server.js\" / "
                         "\"gunicorn -b :8080 app:app\"。脚本不再自动补解释器前缀，"
                         "命令以此为唯一来源。")
    ap.add_argument("--nginx-mode", default="static-proxy", choices=["static-proxy", "proxy", "static"],
                    help="static-proxy: 静态前端 + /api/ 反代（默认）；proxy: 全量反代到后端（Flask/Django 等）；static: 纯静态托管")
    ap.add_argument("--output", required=True)
    ap.add_argument("--userdata-output", required=True,
                    help="无 RDS 时写出 UserData 到该文件；含 RDS 时该路径仅写一个 placeholder 注释")
    # RDS-related
    ap.add_argument("--with-rds", action="store_true",
                    help="选用 *_rds.yaml 模板，并把 UserData inline 进模板（Fn::Sub 嵌入 RDS 内网地址）")
    ap.add_argument("--db-name", default="appdb")
    ap.add_argument("--db-account", default="appuser")
    ap.add_argument("--db-instance-class", default="mysql.n2.medium.1")
    ap.add_argument("--db-instance-storage", type=int, default=20)
    args = ap.parse_args()

    # RDS 密码经环境变量 DB_PASSWORD 校验存在性（真正注入由 create_stack.sh 走 ROS Parameter）；
    # 不走命令行参数，避免在 ps 进程列表泄露明文。
    if args.with_rds and not os.environ.get("DB_PASSWORD"):
        print("--with-rds 需要设置环境变量 DB_PASSWORD", file=sys.stderr)
        sys.exit(64)

    # 直接消费 upload_artifacts.py 的 JSON 输出，把签名 URL 管道传入（免手动粘贴）。
    # 显式 --frontend-artifact-url / --backend-artifact-url 非空时优先。
    if args.artifacts_json:
        raw = sys.stdin.read() if args.artifacts_json == "-" \
            else Path(args.artifacts_json).read_text(encoding="utf-8")
        try:
            art = json.loads(raw)
        except Exception as e:
            print(f"--artifacts-json 解析失败：{e}", file=sys.stderr)
            sys.exit(64)
        if not args.frontend_artifact_url:
            args.frontend_artifact_url = art.get("frontend_url") or ""
        if not args.backend_artifact_url:
            args.backend_artifact_url = art.get("backend_url") or ""

    skeleton = load_skeleton(args.topology, args.with_rds)
    userdata = build_userdata(args.app_type, args)

    if args.with_rds:
        # UserData 内嵌到模板，--userdata-output 仅写一个备查文件（未转义、未缩进的原始版本）
        final_template = inject_userdata_body(skeleton, userdata)
        Path(args.output).write_text(final_template, encoding="utf-8")
        Path(args.userdata_output).write_text(
            "# NOTE: --with-rds 路径下 UserData 已 inline 到模板，无需作为 ROS Parameter 传入。\n"
            "# 以下为转义前的原始 body（仅供 diff 调试）：\n\n" + userdata,
            encoding="utf-8")
    else:
        # 原有路径：模板原样写出，UserData 走独立文件
        Path(args.output).write_text(skeleton, encoding="utf-8")
        Path(args.userdata_output).write_text(userdata, encoding="utf-8")

    print(json.dumps({"template": args.output, "userdata": args.userdata_output, "with_rds": args.with_rds},
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
