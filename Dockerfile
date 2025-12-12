# 前端构建阶段
FROM node:20-alpine AS frontend-builder
WORKDIR /app
RUN npm install -g pnpm
COPY ui/package.json ./
RUN npm config set registry https://registry.npmmirror.com
RUN pnpm install
COPY ui/ .
RUN pnpm build

# 后端构建阶段
FROM maven:3.8-openjdk-17 AS backend-builder
WORKDIR /app
COPY genie-backend/pom.xml .
COPY genie-backend/src ./src
COPY genie-backend/build.sh genie-backend/start.sh ./
RUN chmod +x build.sh start.sh
RUN ./build.sh

# Python 环境准备阶段
FROM python:3.11-slim AS python-base
WORKDIR /app
# 仅安装 uv，不需要编译环境，减少体积
RUN pip install uv

# 最终运行阶段
FROM python:3.11-slim

# 设置阿里源 (加速 apt)
RUN rm /etc/apt/sources.list.d/* && \
    echo 'deb https://mirrors.aliyun.com/debian/ bookworm main contrib non-free non-free-firmware' > /etc/apt/sources.list && \
    echo 'deb https://mirrors.aliyun.com/debian-security bookworm-security main contrib non-free non-free-firmware' >> /etc/apt/sources.list && \
    echo 'deb https://mirrors.aliyun.com/debian/ bookworm-updates main contrib non-free non-free-firmware' >> /etc/apt/sources.list

# 安装基础工具、Java 17 和 Node.js (使用 NodeSource 源解决依赖冲突)
RUN apt-get clean && apt-get update && \
    apt-get install -y --no-install-recommends \
    openjdk-17-jre-headless \
    netcat-openbsd \
    procps \
    curl \
    gnupg \
    ca-certificates \
    && \
    # 安装 Node.js 20 (自带 npm，解决 Debian 自带 npm 依赖报错的问题)
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g pnpm && \
    # 清理缓存
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 设置工作目录
WORKDIR /app

# 复制前端构建产物
COPY --from=frontend-builder /app/dist /app/ui/dist
COPY --from=frontend-builder /app/package.json /app/ui/package.json
COPY --from=frontend-builder /app/node_modules /app/ui/node_modules

# 复制后端构建产物
COPY --from=backend-builder /app/target /app/backend/target
COPY genie-backend/start.sh /app/backend/
RUN chmod +x /app/backend/start.sh

# 复制 Python 工具和依赖
COPY --from=python-base /usr/local/bin/uv /usr/local/bin/uv

# 复制 genie-client
WORKDIR /app/client
COPY genie-client/pyproject.toml genie-client/uv.lock ./
COPY genie-client/app ./app
COPY genie-client/main.py genie-client/server.py genie-client/start.sh ./

# 使用 uv 安装依赖 (使用清华源)
RUN chmod +x start.sh && \
    uv venv .venv && \
    . .venv/bin/activate && \
    export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple" && \
    uv sync

# 复制 genie-tool
WORKDIR /app/tool
COPY genie-tool/pyproject.toml genie-tool/uv.lock ./
COPY genie-tool/genie_tool ./genie_tool
COPY genie-tool/server.py genie-tool/start.sh genie-tool/.env_template ./

# 创建虚拟环境并安装依赖
RUN chmod +x start.sh && \
    uv venv .venv && \
    . .venv/bin/activate && \
    export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple" && \
    uv sync && \
    mkdir -p /data/genie-tool && \
    cp .env_template .env && \
    python -m genie_tool.db.db_engine

# 设置数据卷
VOLUME ["/data/genie-tool"]

# 复制统一启动脚本
WORKDIR /app
COPY start_genie.sh .
RUN chmod +x start_genie.sh

EXPOSE 3000 8080 1601

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000 || exit 1

# 启动所有服务
CMD ["./start_genie.sh"]