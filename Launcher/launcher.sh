#!/usr/bin/env bash
# ============================================================
# OpenCode Mobile 启动器 (macOS)
#
# 一键启动:
#   1. opencode serve   (若未运行)
#   2. Cloudflare 快速隧道 (--protocol http2, 本网络 QUIC 被封锁)
#   并打印手机端要填写的隧道 URL。
#
# 用法:
#   launcher.sh start    启动 serve + 隧道 (默认)
#   launcher.sh status   查看运行状态与当前 URL
#   launcher.sh url      打印当前隧道 URL
#   launcher.sh stop     停止隧道 (serve 保持运行)
#
# 配置:
#   首次运行前创建 ~/opencode-mobile/server.conf:
#     OPENCODE_SERVER_PASSWORD=你的密码
# ============================================================
set -euo pipefail

PORT="${OC_PORT:-4096}"
DIR="${HOME}/opencode-mobile"
OPENCODE_LOG="${DIR}/opencode.log"
TUNNEL_LOG="${DIR}/tunnel.log"
PID_FILE="${DIR}/tunnel.pid"
CONF="${DIR}/server.conf"
mkdir -p "${DIR}"

# ---------- helpers ----------

load_password() {
  if [[ -f "${CONF}" ]]; then
    # shellcheck disable=SC1090
    source "${CONF}"
  fi
  if [[ -z "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
    echo "未配置密码: 请创建 ${CONF} 并写入 OPENCODE_SERVER_PASSWORD=你的密码" >&2
    exit 1
  fi
}

is_serve_running() {
  pgrep -f "opencode serve --port ${PORT}" >/dev/null
}

tunnel_pid() {
  if [[ -f "${PID_FILE}" ]]; then cat "${PID_FILE}"; fi
}

tunnel_alive() {
  local p; p="$(tunnel_pid)"
  [[ -n "${p}" ]] && kill -0 "${p}" 2>/dev/null
}

tunnel_url() {
  grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "${TUNNEL_LOG}" 2>/dev/null | head -1 || true
}

# ---------- commands ----------

start_serve() {
  if is_serve_running; then
    echo "· opencode serve 已在运行 (port ${PORT})"
    return 0
  fi
  load_password
  echo "· 启动 opencode serve → ${OPENCODE_LOG}"
  OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD}" \
    nohup opencode serve --port "${PORT}" --hostname 127.0.0.1 \
    >"${OPENCODE_LOG}" 2>&1 &
  local i
  for i in $(seq 1 30); do
    if curl -sf -u "opencode:${OPENCODE_SERVER_PASSWORD}" \
      "http://127.0.0.1:${PORT}/global/health" >/dev/null 2>&1; then
      echo "  ✓ serve 就绪"
      return 0
    fi
    sleep 1
  done
  echo "  ✗ serve 启动超时, 日志: ${OPENCODE_LOG}" >&2
  return 1
}

start_tunnel() {
  if tunnel_alive; then
    echo "· Cloudflare Tunnel 已在运行: $(tunnel_url)"
    return 0
  fi
  echo "· 启动 Cloudflare Tunnel (--protocol http2) → ${TUNNEL_LOG}"
  nohup cloudflared tunnel --url "http://127.0.0.1:${PORT}" --protocol http2 \
    >"${TUNNEL_LOG}" 2>&1 &
  echo $! >"${PID_FILE}"
  local i url
  for i in $(seq 1 40); do
    url="$(tunnel_url)"
    if [[ -n "${url}" ]]; then
      echo "  ✓ 隧道就绪"
      return 0
    fi
    if ! kill -0 "$(tunnel_pid)" 2>/dev/null; then
      echo "  ✗ cloudflared 已退出, 日志: ${TUNNEL_LOG}" >&2
      return 1
    fi
    sleep 2
  done
  echo "  ✗ 隧道启动超时, 日志: ${TUNNEL_LOG}" >&2
  return 1
}

stop_tunnel() {
  local p; p="$(tunnel_pid)"
  if [[ -n "${p}" ]] && kill -0 "${p}" 2>/dev/null; then
    kill "${p}" 2>/dev/null || true
    rm -f "${PID_FILE}"
    echo "· 已停止 Cloudflare Tunnel"
  else
    echo "· 没有运行中的隧道"
  fi
  echo "· opencode serve 保持运行 (stop 不停止它)"
}

status() {
  if is_serve_running; then
    echo "· opencode serve:      运行中 (port ${PORT})"
  else
    echo "· opencode serve:      未运行"
  fi
  if tunnel_alive; then
    echo "· Cloudflare Tunnel:   运行中  $(tunnel_url)"
  else
    echo "· Cloudflare Tunnel:   未运行"
  fi
}

usage() {
  sed -n '2,20p' "${0}" | sed 's/^# \{0,1\}//'
}

# ---------- main ----------

case "${1:-start}" in
  start)
    start_serve
    start_tunnel
    echo
    echo "════════════════════════════════════════════════════"
    echo "  手机 App 设置 → 服务器地址:  $(tunnel_url)"
    echo "  用户名: opencode"
    echo "  密码:   见 ${CONF}"
    echo "════════════════════════════════════════════════════"
    ;;
  status) status ;;
  url)    tunnel_url; echo ;;
  stop)   stop_tunnel ;;
  *)      usage ;;
esac
