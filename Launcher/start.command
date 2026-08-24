#!/usr/bin/env bash
# 双击启动 OpenCode Mobile 服务 (serve + Cloudflare 隧道)
# 运行后可在任意终端用 `launcher.sh status|stop` 管理
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/launcher.sh" start
