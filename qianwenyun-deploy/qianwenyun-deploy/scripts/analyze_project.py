#!/usr/bin/env python3
"""
项目信号采集器。在项目根目录运行，输出原始信号 JSON 到 stdout。

本脚本**不做决策**（不输出 app_type、backend_entry、backend_port 等判断结论），
只采集文件结构、配置文件内容、依赖信息、数据库信号等原始事实，
由 AI Agent 读取后结合语义理解做最终判断。

输出结构：
{
  "file_tree": ["package.json", "src/", "Dockerfile", ...],
  "config_files": {
    "package.json": {...},              // JSON 文件解析为对象
    "go.mod": "module ...\n...",        // 非 JSON 文件保留原文
    "requirements.txt": "flask==3.0\n...",
    ...
  },
  "readme_excerpt": "# My App\n...(前 80 行)",
  "source_samples": {
    "app.py": "from fastapi import ...(前 30 行)",
    "main.go": "package main\n...(前 30 行)",
    ...
  },
  "env_files": {
    ".env.example": "PORT=8080\n..."
  },
  "db_signals": {
    "mysql": ["requirements.txt:pymysql", ...],
    "postgres": ["go.mod:gorm.io/driver/postgres", ...],
    "redis": [],
    "mongodb": []
  },
  "app_meta": {
    "app_name": "my-app",
    "app_desc": "A FastAPI application"
  }
}
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path


# --- 配置 ---

SKIP_DIRS = {
    "node_modules", ".git", "__pycache__", ".venv", "venv",
    ".pytest_cache", ".mypy_cache", ".tox", ".next",
    ".idea", ".vscode", ".claude",
    "target", "build", "dist", "out",
}

CONFIG_FILE_NAMES = [
    "package.json", "go.mod", "go.sum",
    "pom.xml", "build.gradle", "build.gradle.kts",
    "requirements.txt", "pyproject.toml", "setup.py", "setup.cfg", "Pipfile",
    "Cargo.toml",
    "Gemfile", "composer.json",
    "Dockerfile", "docker-compose.yml", "docker-compose.yaml",
    "compose.yml", "compose.yaml",
    "Makefile", "CMakeLists.txt", "Taskfile.yml",
    "tsconfig.json", "vite.config.ts", "vite.config.js",
    "next.config.js", "next.config.mjs", "nuxt.config.ts",
    "webpack.config.js", "rollup.config.js",
    ".env.example", ".env.sample", ".env.template",
    "Procfile", "app.yaml", "fly.toml", "render.yaml",
    "supervisord.conf", "uwsgi.ini", "gunicorn.conf.py",
]

SOURCE_ENTRY_CANDIDATES = [
    "app.py", "main.py", "server.py", "wsgi.py", "asgi.py", "manage.py",
    "main.go", "cmd/main.go", "cmd/server/main.go",
    "server.js", "index.js", "app.js", "src/index.ts", "src/main.ts", "src/server.ts",
    "src/main.rs", "src/lib.rs",
    "Program.cs", "Startup.cs",
    "index.php", "artisan",
    "config/application.rb", "app.rb",
    "gradio_app.py", "streamlit_app.py",
]

README_NAMES = ["README.md", "README.rst", "README.txt", "README", "readme.md"]

ENV_FILE_NAMES = [".env.example", ".env.sample", ".env.template", ".env.development"]

CONFIG_MAX_SIZE = 50_000
SOURCE_SAMPLE_LINES = 30
README_LINES = 80
FILE_TREE_MAX_DEPTH = 3


# --- 信号采集 ---

def _read_text(p: Path, max_size: int = CONFIG_MAX_SIZE) -> str | None:
    try:
        if p.stat().st_size > max_size:
            return p.read_text(encoding="utf-8", errors="ignore")[:max_size] + "\n... (truncated)"
        return p.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return None


def _read_lines(p: Path, n: int) -> str | None:
    try:
        lines = []
        with open(p, encoding="utf-8", errors="ignore") as f:
            for i, line in enumerate(f):
                if i >= n:
                    break
                lines.append(line)
        return "".join(lines) if lines else None
    except Exception:
        return None


def scan_file_tree(root: Path, max_depth: int = FILE_TREE_MAX_DEPTH) -> list[str]:
    entries = []
    root_len = len(root.parts)
    for dirpath, dirnames, filenames in os.walk(root):
        depth = len(Path(dirpath).parts) - root_len
        if depth >= max_depth:
            dirnames[:] = []
            continue
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and not d.startswith("."))
        rel_dir = str(Path(dirpath).relative_to(root))
        if rel_dir == ".":
            rel_dir = ""
        for d in dirnames:
            entries.append(os.path.join(rel_dir, d, "") if rel_dir else d + "/")
        for f in sorted(filenames):
            if f.startswith(".") and f not in (".env.example", ".env.sample", ".env.template"):
                continue
            entries.append(os.path.join(rel_dir, f) if rel_dir else f)
    return entries


def scan_config_files(root: Path) -> dict:
    configs = {}
    for name in CONFIG_FILE_NAMES:
        p = root / name
        if not p.is_file():
            continue
        content = _read_text(p)
        if content is None:
            continue
        if name.endswith(".json"):
            try:
                configs[name] = json.loads(content)
            except Exception:
                configs[name] = content
        else:
            configs[name] = content

    # 也扫一层子目录（frontend/, backend/, server/, api/, cmd/ 等）
    for sub in ("frontend", "client", "web", "backend", "server", "api", "app", "cmd", "src"):
        sub_dir = root / sub
        if not sub_dir.is_dir():
            continue
        for name in CONFIG_FILE_NAMES:
            p = sub_dir / name
            if not p.is_file():
                continue
            key = f"{sub}/{name}"
            content = _read_text(p)
            if content is None:
                continue
            if name.endswith(".json"):
                try:
                    configs[key] = json.loads(content)
                except Exception:
                    configs[key] = content
            else:
                configs[key] = content

    return configs


def scan_readme(root: Path) -> str | None:
    for name in README_NAMES:
        p = root / name
        if p.is_file():
            return _read_lines(p, README_LINES)
    return None


def scan_source_samples(root: Path) -> dict:
    samples = {}
    for name in SOURCE_ENTRY_CANDIDATES:
        p = root / name
        if p.is_file():
            content = _read_lines(p, SOURCE_SAMPLE_LINES)
            if content:
                samples[name] = content
    # 也扫子目录
    for sub in ("backend", "server", "api", "app", "src", "cmd"):
        sub_dir = root / sub
        if not sub_dir.is_dir():
            continue
        for name in SOURCE_ENTRY_CANDIDATES:
            fname = Path(name).name
            p = sub_dir / fname
            if p.is_file():
                key = f"{sub}/{fname}"
                if key not in samples:
                    content = _read_lines(p, SOURCE_SAMPLE_LINES)
                    if content:
                        samples[key] = content
    return samples


def scan_env_files(root: Path) -> dict:
    envs = {}
    for name in ENV_FILE_NAMES:
        p = root / name
        if p.is_file():
            content = _read_text(p, max_size=5000)
            if content:
                envs[name] = content
    return envs


# --- 数据库信号检测（保留规则匹配，作为信号传给 Agent） ---

MYSQL_DEP_PATTERNS = {
    "go.mod": [
        r"github\.com/go-sql-driver/mysql",
        r"gorm\.io/driver/mysql",
        r"github\.com/jinzhu/gorm",
    ],
    "pom.xml": [
        r"mysql-connector-j",
        r"mysql-connector-java",
        r"<artifactId>mysql</artifactId>",
    ],
    "build.gradle": [
        r"mysql-connector-j",
        r"mysql-connector-java",
        r"runtimeOnly\s+['\"]mysql:mysql-connector",
    ],
    "requirements.txt": [
        r"^pymysql\b",
        r"^mysqlclient\b",
        r"^mysql-connector-python\b",
        r"^aiomysql\b",
    ],
    "package.json": [
        r'"mysql"\s*:',
        r'"mysql2"\s*:',
        r'"sequelize"\s*:',
        r'"prisma"\s*:',
        r'"@prisma/client"\s*:',
        r'"typeorm"\s*:',
    ],
}

OTHER_ENGINE_PATTERNS = {
    "postgres": [
        r"github\.com/lib/pq",
        r"gorm\.io/driver/postgres",
        r"psycopg2", r"psycopg\b", r"asyncpg",
        r"postgresql-connector", r"postgresql-jdbc",
        r'"pg"\s*:', r'"@types/pg"\s*:',
    ],
    "redis": [
        r"go-redis/redis",
        r"^redis\b",
        r'"redis"\s*:', r'"ioredis"\s*:',
        r"jedis", r"lettuce",
    ],
    "mongodb": [
        r"go\.mongodb\.org/mongo-driver",
        r"^pymongo\b",
        r'"mongoose"\s*:', r'"mongodb"\s*:',
        r"spring-boot-starter-data-mongodb",
    ],
}

SOURCE_GREP_PATTERNS = {
    "mysql": [
        r"jdbc:mysql://",
        r"mysql\+pymysql://",
        r"mysql\+mysqlconnector://",
        r"\bspring\.datasource\.url\b.*mysql",
        r"\bDATABASE_URL\b\s*=\s*['\"]?mysql://",
    ],
}

SOURCE_EXTS = (".go", ".java", ".py", ".js", ".ts", ".env", ".properties", ".yaml", ".yml", ".xml")
SOURCE_SKIP_DIRS = {"node_modules", ".git", "dist", "build", "out", "target", "__pycache__", ".venv", "venv", ".next"}


def _scan_dep_file(root: Path, fname: str, patterns) -> list:
    f = root / fname
    if not f.is_file():
        return []
    txt = _read_text(f) or ""
    hits = []
    for pat in patterns:
        if re.search(pat, txt, re.MULTILINE):
            hits.append(f"{fname}:{pat}")
    return hits


def _scan_sources(root: Path, patterns, max_depth: int = 3, max_files: int = 200) -> list:
    hits = []
    scanned = 0
    root_parts = len(root.parts)
    for dirpath, dirnames, filenames in os.walk(root):
        depth = len(Path(dirpath).parts) - root_parts
        if depth > max_depth:
            dirnames[:] = []
            continue
        dirnames[:] = [d for d in dirnames if d not in SOURCE_SKIP_DIRS and not d.startswith(".")]
        for name in filenames:
            if not name.endswith(SOURCE_EXTS):
                continue
            scanned += 1
            if scanned > max_files:
                return hits
            txt = _read_text(Path(dirpath) / name) or ""
            for pat in patterns:
                if re.search(pat, txt):
                    rel = str(Path(dirpath, name).relative_to(root))
                    hits.append(f"{rel}:{pat}")
                    break
    return hits


def _scan_compose_services(root: Path) -> dict:
    found = {"mysql": [], "postgres": [], "redis": [], "mongodb": []}
    for name in ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"):
        f = root / name
        if not f.is_file():
            continue
        txt = _read_text(f) or ""
        for m in re.finditer(r"image:\s*['\"]?([^\s'\"]+)", txt):
            img = m.group(1).lower()
            if "mysql" in img or "mariadb" in img:
                found["mysql"].append(f"{name}:image={img}")
            elif "postgres" in img:
                found["postgres"].append(f"{name}:image={img}")
            elif "redis" in img:
                found["redis"].append(f"{name}:image={img}")
            elif "mongo" in img:
                found["mongodb"].append(f"{name}:image={img}")
    return found


def detect_db_signals(root: Path) -> dict:
    signals = {"mysql": [], "postgres": [], "redis": [], "mongodb": []}

    for fname, pats in MYSQL_DEP_PATTERNS.items():
        signals["mysql"].extend(_scan_dep_file(root, fname, pats))

    for fname in MYSQL_DEP_PATTERNS.keys():
        for eng, pats in OTHER_ENGINE_PATTERNS.items():
            signals[eng].extend(_scan_dep_file(root, fname, pats))

    compose = _scan_compose_services(root)
    for eng in signals:
        signals[eng].extend(compose.get(eng, []))

    signals["mysql"].extend(_scan_sources(root, SOURCE_GREP_PATTERNS["mysql"]))

    # 去重并截断
    for eng in signals:
        signals[eng] = list(dict.fromkeys(signals[eng]))[:20]

    return signals


# --- app_meta 推断（保留） ---

def detect_app_meta(root: Path):
    name = None
    desc = None

    pkg = root / "package.json"
    if pkg.is_file():
        try:
            data = json.loads(pkg.read_text(encoding="utf-8"))
            name = name or data.get("name") or None
            desc = desc or data.get("description") or None
        except Exception:
            pass

    gomod = root / "go.mod"
    if gomod.is_file():
        try:
            txt = gomod.read_text(encoding="utf-8")
            m = re.search(r"^module\s+(\S+)", txt, re.M)
            if m:
                name = name or m.group(1).rsplit("/", 1)[-1]
        except Exception:
            pass

    pom = root / "pom.xml"
    if pom.is_file():
        try:
            txt = pom.read_text(encoding="utf-8")
            m_name = re.search(r"<name>\s*([^<]+?)\s*</name>", txt)
            m_aid = re.search(r"<artifactId>\s*([^<]+?)\s*</artifactId>", txt)
            m_desc = re.search(r"<description>\s*([^<]+?)\s*</description>", txt)
            name = name or (m_name and m_name.group(1)) or (m_aid and m_aid.group(1))
            desc = desc or (m_desc and m_desc.group(1))
        except Exception:
            pass

    for meta_file, pat_name, pat_desc in [
        ("setup.py", r"""name\s*=\s*['"]([^'"]+)['"]""", r"""description\s*=\s*['"]([^'"]+)['"]"""),
        ("pyproject.toml", r"""^name\s*=\s*['"]([^'"]+)['"]""", r"""^description\s*=\s*['"]([^'"]+)['"]"""),
    ]:
        f = root / meta_file
        if f.is_file():
            try:
                txt = f.read_text(encoding="utf-8")
                m_n = re.search(pat_name, txt, re.M)
                m_d = re.search(pat_desc, txt, re.M)
                name = name or (m_n and m_n.group(1))
                desc = desc or (m_d and m_d.group(1))
            except Exception:
                pass

    # Cargo.toml
    cargo = root / "Cargo.toml"
    if cargo.is_file():
        try:
            txt = cargo.read_text(encoding="utf-8")
            m_n = re.search(r'^name\s*=\s*"([^"]+)"', txt, re.M)
            m_d = re.search(r'^description\s*=\s*"([^"]+)"', txt, re.M)
            name = name or (m_n and m_n.group(1))
            desc = desc or (m_d and m_d.group(1))
        except Exception:
            pass

    # composer.json (PHP)
    composer = root / "composer.json"
    if composer.is_file():
        try:
            data = json.loads(composer.read_text(encoding="utf-8"))
            raw_name = data.get("name") or ""
            name = name or raw_name.rsplit("/", 1)[-1] or None
            desc = desc or data.get("description") or None
        except Exception:
            pass

    name = name or root.name
    return {"app_name": name, "app_desc": desc}


# --- 主入口 ---

def main():
    ap = argparse.ArgumentParser(
        description="采集项目原始信号，输出 JSON。由 Agent 读取后做项目类型判断。",
    )
    ap.add_argument(
        "--project",
        default=None,
        help="待分析项目的根目录绝对路径（默认 cwd）",
    )
    args = ap.parse_args()

    root_path = Path(args.project) if args.project else Path(os.getcwd())
    root = root_path.resolve()
    if not root.is_dir():
        print(f"--project 不是有效目录: {root}", file=sys.stderr)
        sys.exit(2)

    out = {
        "file_tree": scan_file_tree(root),
        "config_files": scan_config_files(root),
        "readme_excerpt": scan_readme(root),
        "source_samples": scan_source_samples(root),
        "env_files": scan_env_files(root),
        "db_signals": detect_db_signals(root),
        "app_meta": detect_app_meta(root),
    }

    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    sys.exit(main() or 0)
