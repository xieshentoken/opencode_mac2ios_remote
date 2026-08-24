#!/usr/bin/env bash
# ============================================================
# OpenCode / Hermes Mobile 启动器 (macOS)
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
#   launcher.sh stop     停止 OpenCode 隧道 (serve 保持运行)
#
# Hermes:
#   launcher.sh init-hermes    交互生成仅含 scrypt hash 的认证配置
#   launcher.sh start-hermes   启动 hermes serve + 独立快速隧道
#   launcher.sh status-hermes  查看 Hermes 状态
#   launcher.sh url-hermes     打印 Hermes 隧道 URL
#   launcher.sh stop-hermes    停止 Hermes 隧道 (serve 保持运行)
#
# 配置:
#   首次运行前创建 ~/opencode-mobile/server.conf:
#     OPENCODE_SERVER_PASSWORD=你的密码
#   Hermes 另用 ~/opencode-mobile/hermes.conf（必须 chmod 600）:
#     HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin
#     HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH='scrypt$...'
#     HERMES_DASHBOARD_BASIC_AUTH_SECRET='至少32字节随机值'
# ============================================================
set -euo pipefail

PORT="${OC_PORT:-4096}"
DIR="${HOME}/opencode-mobile"
OPENCODE_LOG="${DIR}/opencode.log"
TUNNEL_LOG="${DIR}/tunnel.log"
PID_FILE="${DIR}/tunnel.pid"
CONF="${DIR}/server.conf"
HERMES_PORT="${HERMES_PORT:-9119}"
HERMES_BIN="${HERMES_BIN:-${HOME}/.local/bin/hermes}"
HERMES_PYTHON="${HERMES_PYTHON:-${HOME}/.hermes/hermes-agent/venv/bin/python}"
HERMES_LOG="${DIR}/hermes.log"
HERMES_TUNNEL_LOG="${DIR}/hermes-tunnel.log"
HERMES_PID_FILE="${DIR}/hermes-tunnel.pid"
HERMES_CONF="${DIR}/hermes.conf"
mkdir -p "${DIR}"

# ---------- helpers ----------

load_password() {
  if [[ -f "${CONF}" ]]; then
    local mode
    mode="$(stat -f '%Lp' "${CONF}" 2>/dev/null || true)"
    if [[ "${mode}" != "600" ]]; then
      echo "OpenCode 配置权限不安全 (${mode:-unknown}): 请运行 chmod 600 ${CONF}" >&2
      exit 1
    fi
    # shellcheck disable=SC1090
    source "${CONF}"
  fi
  if [[ -z "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
    echo "未配置密码: 请创建 ${CONF} 并写入 OPENCODE_SERVER_PASSWORD=你的密码" >&2
    exit 1
  fi
  if [[ "${OPENCODE_SERVER_PASSWORD}" == *$'\n'* || "${OPENCODE_SERVER_PASSWORD}" == *$'\r'* ]]; then
    echo "OpenCode 密码不能包含换行符" >&2
    exit 1
  fi
  # Keep the password in this shell for local probes, but do not let a config
  # containing `export` leak it to cloudflared or unrelated child processes.
  export -n OPENCODE_SERVER_PASSWORD 2>/dev/null || true
}

# Feed curl credentials through its stdin config so the password never appears
# in process arguments (`ps`). Backslashes and quotes are escaped for curl's
# double-quoted config syntax; newlines were rejected by load_password.
opencode_curl() {
  local credential="opencode:${OPENCODE_SERVER_PASSWORD}"
  credential="${credential//\\/\\\\}"
  credential="${credential//\"/\\\"}"
  printf 'user = "%s"\n' "${credential}" | curl --noproxy '*' --config - "$@"
}

is_serve_running() {
  pgrep -f "opencode serve --port ${PORT}" >/dev/null
}

# The quick-tunnel hostname can be deregistered by Cloudflare while the
# cloudflared process is still alive; only trust a URL that still answers.
tunnel_alive() {
  local p url code
  p="$(tunnel_pid)"
  pid_matches_cloudflared "${p}" "${PORT}" || return 1
  url="$(tunnel_url)"
  [[ -n "${url}" ]] || return 1
  # An authenticated OpenCode health endpoint must reject an anonymous probe.
  # Cloudflare error pages (such as 502/530/1033) are stale, not alive.
  code="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "${url}/global/health" 2>/dev/null || echo 000)"
  [[ "${code}" == "401" || "${code}" == "403" ]]
}

tunnel_pid() {
  if [[ -f "${PID_FILE}" ]]; then cat "${PID_FILE}"; fi
}

tunnel_url() {
  grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "${TUNNEL_LOG}" 2>/dev/null | head -1 || true
}

load_hermes_auth() {
  if [[ ! -f "${HERMES_CONF}" ]]; then
    echo "未配置 Hermes 认证: 请创建 ${HERMES_CONF}" >&2
    echo "至少设置 HERMES_DASHBOARD_BASIC_AUTH_USERNAME、PASSWORD_HASH（或 PASSWORD）和 AUTH_SECRET" >&2
    exit 1
  fi
  local mode
  mode="$(stat -f '%Lp' "${HERMES_CONF}" 2>/dev/null || true)"
  if [[ "${mode}" != "600" ]]; then
    echo "Hermes 配置权限不安全 (${mode:-unknown}): 请运行 chmod 600 ${HERMES_CONF}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${HERMES_CONF}"
  if [[ -z "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}" ]]; then
    echo "Hermes 用户名未配置" >&2
    exit 1
  fi
  if [[ -z "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:-}" && -z "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ]]; then
    echo "Hermes PASSWORD_HASH/PASSWORD 均未配置" >&2
    exit 1
  fi
  local auth_secret="${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}"
  if [[ ${#auth_secret} -lt 32 ]]; then
    echo "Hermes AUTH_SECRET 至少需要 32 个字符" >&2
    exit 1
  fi
  # A manually-authored config may contain `export`. Keep the values in this
  # shell but explicitly remove their export attribute so cloudflared and
  # other child processes cannot inherit the auth hash/secret/password.
  export -n HERMES_DASHBOARD_BASIC_AUTH_USERNAME 2>/dev/null || true
  export -n HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH 2>/dev/null || true
  export -n HERMES_DASHBOARD_BASIC_AUTH_PASSWORD 2>/dev/null || true
  export -n HERMES_DASHBOARD_BASIC_AUTH_SECRET 2>/dev/null || true
}

init_hermes_auth() {
  if [[ -e "${HERMES_CONF}" ]]; then
    echo "配置已存在，不覆盖: ${HERMES_CONF}" >&2
    return 1
  fi
  if [[ ! -x "${HERMES_PYTHON}" ]]; then
    echo "找不到 Hermes Python: ${HERMES_PYTHON}" >&2
    return 1
  fi
  local username password confirm password_hash auth_secret
  read -r -p "Hermes 用户名 [admin]: " username
  username="${username:-admin}"
  read -r -s -p "Hermes 强密码: " password; echo
  read -r -s -p "再次输入: " confirm; echo
  if [[ -z "${password}" || "${password}" != "${confirm}" ]]; then
    echo "密码为空或两次输入不一致" >&2
    return 1
  fi
  password_hash="$(printf '%s' "${password}" | "${HERMES_PYTHON}" -c 'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.stdin.read()))')"
  password=""; confirm=""
  auth_secret="$(openssl rand -base64 48 | tr -d '\n')"
  umask 077
  {
    printf 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME=%q\n' "${username}"
    printf 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=%q\n' "${password_hash}"
    printf 'HERMES_DASHBOARD_BASIC_AUTH_SECRET=%q\n' "${auth_secret}"
  } >"${HERMES_CONF}"
  chmod 600 "${HERMES_CONF}"
  echo "· 已创建 ${HERMES_CONF}（仅保存 scrypt hash，不保存原密码）"
}

is_hermes_running() {
  pgrep -f "hermes serve.*--port ${HERMES_PORT}" >/dev/null
}

hermes_tunnel_pid() {
  if [[ -f "${HERMES_PID_FILE}" ]]; then cat "${HERMES_PID_FILE}"; fi
}

hermes_tunnel_url() {
  grep -aoE 'https://[a-z0-9-]+\.trycloudflare\.com' "${HERMES_TUNNEL_LOG}" 2>/dev/null | head -1 || true
}

hermes_tunnel_alive() {
  local p url status_json auth_required protected_code
  p="$(hermes_tunnel_pid)"
  pid_matches_cloudflared "${p}" "${HERMES_PORT}" || return 1
  url="$(hermes_tunnel_url)"
  [[ -n "${url}" ]] || return 1
  status_json="$(curl -fsS -m 8 "${url}/api/status" 2>/dev/null)" || return 1
  auth_required="$(printf '%s' "${status_json}" | "${HERMES_PYTHON}" -c 'import json, sys; print("true" if json.load(sys.stdin).get("auth_required") is True else "false")' 2>/dev/null || true)"
  [[ "${auth_required}" == "true" ]] || return 1
  protected_code="$(curl -sS -o /dev/null -m 8 -w '%{http_code}' "${url}/api/auth/me" 2>/dev/null || echo 000)"
  [[ "${protected_code}" == "401" || "${protected_code}" == "403" ]]
}

pid_matches_cloudflared() {
  local p="${1:-}" port="${2:-}" command_line
  [[ "${p}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${p}" 2>/dev/null || return 1
  command_line="$(ps -p "${p}" -o command= 2>/dev/null || true)"
  [[ "${command_line}" == *"cloudflared tunnel --url http://127.0.0.1:${port}"* ]]
}

write_pid_atomically() {
  local p="$1" file="$2" temporary="${file}.tmp.$$"
  printf '%s\n' "${p}" >"${temporary}"
  mv -f "${temporary}" "${file}"
}

stop_managed_connector() {
  local file="$1" port="$2" label="$3" p i
  p="$(if [[ -f "${file}" ]]; then cat "${file}"; fi)"
  if ! pid_matches_cloudflared "${p}" "${port}"; then
    rm -f "${file}"
    return 0
  fi
  kill "${p}" 2>/dev/null || return 1
  for i in $(seq 1 20); do
    if ! kill -0 "${p}" 2>/dev/null; then
      rm -f "${file}"
      return 0
    fi
    sleep 0.1
  done
  echo "${label} 未能正常停止，拒绝再启动第二个公网连接器 (pid ${p})" >&2
  return 1
}

verify_hermes_auth_gate() {
  local status_json auth_required protected_code
  status_json="$(curl --noproxy '*' -fsS -m 8 "http://127.0.0.1:${HERMES_PORT}/api/status")" || {
    echo "无法读取 Hermes /api/status，拒绝启动公网隧道" >&2
    return 1
  }
  auth_required="$(printf '%s' "${status_json}" | "${HERMES_PYTHON}" -c 'import json, sys; print("true" if json.load(sys.stdin).get("auth_required") is True else "false")' 2>/dev/null || true)"
  if [[ "${auth_required}" != "true" ]]; then
    echo "Hermes 未启用认证 (auth_required != true)，拒绝暴露到公网" >&2
    return 1
  fi
  protected_code="$(curl --noproxy '*' -sS -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:${HERMES_PORT}/api/auth/me" 2>/dev/null || echo 000)"
  if [[ "${protected_code}" != "401" && "${protected_code}" != "403" ]]; then
    echo "Hermes 匿名认证探针异常 (HTTP ${protected_code})，拒绝启动公网隧道" >&2
    return 1
  fi
}

verify_opencode_auth_gate() {
  local anonymous_code authenticated_code
  anonymous_code="$(curl --noproxy '*' -sS -o /dev/null -m 8 -w '%{http_code}' \
    "http://127.0.0.1:${PORT}/global/health" 2>/dev/null || echo 000)"
  if [[ "${anonymous_code}" != "401" && "${anonymous_code}" != "403" ]]; then
    echo "OpenCode 匿名认证探针异常 (HTTP ${anonymous_code})，拒绝启动公网隧道" >&2
    return 1
  fi
  authenticated_code="$(opencode_curl -sS -o /dev/null -m 8 -w '%{http_code}' \
    "http://127.0.0.1:${PORT}/global/health" 2>/dev/null || echo 000)"
  if [[ "${authenticated_code}" != "200" ]]; then
    echo "OpenCode 凭据探针失败 (HTTP ${authenticated_code})，拒绝启动公网隧道" >&2
    return 1
  fi
}

# ---------- commands ----------

start_serve() {
  load_password
  if is_serve_running; then
    echo "· opencode serve 已在运行 (port ${PORT})"
    return 0
  fi
  echo "· 启动 opencode serve → ${OPENCODE_LOG}"
  OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD}" \
    nohup opencode serve --port "${PORT}" --hostname 127.0.0.1 \
    >"${OPENCODE_LOG}" 2>&1 &
  local i
  for i in $(seq 1 30); do
    if opencode_curl -sf \
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
  verify_opencode_auth_gate
  if tunnel_alive; then
    echo "· Cloudflare Tunnel 已在运行: $(tunnel_url)"
    return 0
  fi
  stop_managed_connector "${PID_FILE}" "${PORT}" "OpenCode cloudflared"
  echo "· 启动 Cloudflare Tunnel (--protocol http2) → ${TUNNEL_LOG}"
  nohup cloudflared tunnel --url "http://127.0.0.1:${PORT}" --protocol http2 \
    >"${TUNNEL_LOG}" 2>&1 &
  write_pid_atomically "$!" "${PID_FILE}"
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
  if pid_matches_cloudflared "${p}" "${PORT}"; then
    stop_managed_connector "${PID_FILE}" "${PORT}" "OpenCode cloudflared"
    echo "· 已停止 Cloudflare Tunnel"
  else
    rm -f "${PID_FILE}"
    echo "· 没有运行中的隧道"
  fi
  echo "· opencode serve 保持运行 (stop 不停止它)"
}

start_hermes_serve() {
  if is_hermes_running; then
    echo "· hermes serve 已在运行 (port ${HERMES_PORT})"
    return 0
  fi
  if [[ ! -x "${HERMES_BIN}" ]]; then
    echo "找不到 Hermes: ${HERMES_BIN}" >&2
    return 1
  fi
  load_hermes_auth
  echo "· 启动受认证的 hermes serve → ${HERMES_LOG}"
  # Hermes 0.19.1 deliberately disables dashboard auth on loopback binds;
  # a non-loopback bind is required for auth_required=true. The gate below
  # fails closed before cloudflared is allowed to publish the listener.
  HERMES_DASHBOARD_BASIC_AUTH_USERNAME="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME}" \
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:-}" \
  HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" \
  HERMES_DASHBOARD_BASIC_AUTH_SECRET="${HERMES_DASHBOARD_BASIC_AUTH_SECRET}" \
    nohup "${HERMES_BIN}" serve --host 0.0.0.0 --port "${HERMES_PORT}" --skip-build \
    >"${HERMES_LOG}" 2>&1 &
  local i
  for i in $(seq 1 45); do
    if curl --noproxy '*' -sf "http://127.0.0.1:${HERMES_PORT}/api/status" >/dev/null 2>&1; then
      echo "  ✓ Hermes serve 就绪（认证已启用）"
      return 0
    fi
    sleep 1
  done
  echo "  ✗ Hermes 启动超时, 日志: ${HERMES_LOG}" >&2
  return 1
}

start_hermes_tunnel() {
  verify_hermes_auth_gate
  if hermes_tunnel_alive; then
    echo "· Hermes Tunnel 已在运行: $(hermes_tunnel_url)"
    return 0
  fi
  stop_managed_connector "${HERMES_PID_FILE}" "${HERMES_PORT}" "Hermes cloudflared"
  echo "· 启动 Hermes Cloudflare Tunnel (--protocol http2) → ${HERMES_TUNNEL_LOG}"
  nohup cloudflared tunnel --url "http://127.0.0.1:${HERMES_PORT}" --protocol http2 \
    >"${HERMES_TUNNEL_LOG}" 2>&1 &
  write_pid_atomically "$!" "${HERMES_PID_FILE}"
  local i url
  for i in $(seq 1 40); do
    url="$(hermes_tunnel_url)"
    if [[ -n "${url}" ]]; then
      echo "  ✓ Hermes 隧道就绪"
      return 0
    fi
    if ! kill -0 "$(hermes_tunnel_pid)" 2>/dev/null; then
      echo "  ✗ Hermes cloudflared 已退出, 日志: ${HERMES_TUNNEL_LOG}" >&2
      return 1
    fi
    sleep 2
  done
  echo "  ✗ Hermes 隧道启动超时, 日志: ${HERMES_TUNNEL_LOG}" >&2
  return 1
}

stop_hermes_tunnel() {
  local p; p="$(hermes_tunnel_pid)"
  if pid_matches_cloudflared "${p}" "${HERMES_PORT}"; then
    stop_managed_connector "${HERMES_PID_FILE}" "${HERMES_PORT}" "Hermes cloudflared"
    echo "· 已停止 Hermes Cloudflare Tunnel"
  else
    rm -f "${HERMES_PID_FILE}"
    echo "· 没有运行中的 Hermes 隧道"
  fi
  echo "· hermes serve 保持运行"
}

hermes_status() {
  if is_hermes_running; then
    echo "· hermes serve:        运行中 (port ${HERMES_PORT})"
  else
    echo "· hermes serve:        未运行"
  fi
  if hermes_tunnel_alive; then
    echo "· Hermes Tunnel:       运行中  $(hermes_tunnel_url)"
  else
    echo "· Hermes Tunnel:       未运行"
  fi
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
  sed -n '2,28p' "${0}" | sed 's/^# \{0,1\}//'
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
    echo "  模式:   Quick Tunnel / REST polling（权限事件不可用）"
    echo "════════════════════════════════════════════════════"
    ;;
  status) status ;;
  url)    tunnel_url; echo ;;
  stop)   stop_tunnel ;;
  init-hermes) init_hermes_auth ;;
  start-hermes)
    load_hermes_auth
    start_hermes_serve
    start_hermes_tunnel
    echo
    echo "════════════════════════════════════════════════════"
    echo "  App 类型: Hermes"
    echo "  服务器地址: $(hermes_tunnel_url)"
    echo "  用户名: ${HERMES_DASHBOARD_BASIC_AUTH_USERNAME}"
    echo "  密码:   输入生成 PASSWORD_HASH 时使用的原密码"
    echo "  模式:   WSS JSON-RPC（失败时 App 仅开放 REST 历史）"
    echo "  注意:   Quick Tunnel 是动态公网入口，请使用唯一强密码"
    echo "════════════════════════════════════════════════════"
    ;;
  status-hermes) hermes_status ;;
  url-hermes)    hermes_tunnel_url; echo ;;
  stop-hermes)   stop_hermes_tunnel ;;
  *)      usage ;;
esac
