# 项目类型判断指南

Agent 读取 `analyze_project.py` 的信号输出后，按本文档做最终判断。

## app_type 映射

| 信号 | app_type | backend_entry 示例 |
|------|----------|-------------------|
| Dockerfile / docker-compose.yml | `docker` | — |
| go.mod | `binary-go` | `./server` |
| Cargo.toml（Rust） | `binary-go` | `./target/release/<name>` |
| pom.xml / build.gradle | `binary-java` | `java -jar app.jar` |
| package.json + express/fastify/koa/nest | `binary-node` | `node server.js` |
| requirements.txt / pyproject.toml + Python 入口 | `binary-python` | 见下表 |
| 纯前端（React/Vue/Vite，无后端） | `frontend-only` | — |

有 Dockerfile 时优先选 `docker`，除非用户明确不想用。Rust 编译产物是静态二进制，复用 `binary-go` 的 `binary` runtime。

## Python 框架启动命令

| 框架 | backend_entry | 默认端口 |
|------|---------------|---------|
| FastAPI | `uvicorn main:app --host 0.0.0.0 --port 8080` | 8080 |
| Flask | `gunicorn -b 0.0.0.0:8080 app:app` | 8080 |
| Django | `gunicorn -b 0.0.0.0:8080 <project>.wsgi:application` | 8080 |
| Streamlit | `streamlit run app.py --server.port 8080 --server.headless true` | 8080 |
| Gradio | `python3 app.py` | 7860 |
| 通用 | `python3 main.py` | 看代码 |

## nginx_mode 判定

| 条件 | nginx_mode |
|------|-----------|
| 有前端产物 + 有后端 | `static-proxy`（默认） |
| 无前端，纯后端（Flask/Django/Streamlit 等） | `proxy` |
| 纯前端，无后端 | `static` |

> `proxy` 模式下所有请求反代到后端。Flask/Django/Streamlit/Gradio **必须**用 `proxy`，误用 `static-proxy` 会导致 `try_files` 拦截路由。

## Agent 判断流程

1. 读 `file_tree` 理解整体结构
2. 读 `config_files` 中的依赖清单和构建配置
3. 读 `source_samples` 确认框架和端口
4. 读 `readme_excerpt` 获取构建/运行说明
5. 有把握 → 直接确定；不确定 → AskUserQuestion 询问

## `--backend-entry` 说明

`--backend-entry` 是**完整启动命令**（相对 `/opt/qianwenyun`），不是文件路径。脚本只把首个 token 解析成绝对路径，不会自动补解释器前缀。

- Go 二进制：`./server`
- Python：`python3 app.py` 或 `gunicorn -b :8080 app:app`
- Java：`java -jar app.jar`
- Node：`node server.js`

## Git URL 源的构建命令

| 类型 | 构建命令 |
|------|---------|
| Node.js | `npm install && npm run build` |
| Go | `go build -o <binary> .` |
| Python | `pip install -r requirements.txt` |
| Java | `mvn package -DskipTests` 或 `gradle build -x test` |
| Rust | `cargo build --release` |
| Docker | `docker build -t <name>:latest .` |
