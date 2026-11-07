#!/usr/bin/env bash
# common.sh — hyst2-netopt 公共层: 路径/配置/SSH封装/日志
# 规则: 只用 set -u; 失败降级不退出; 用户可见信息大白话直说实际值.
# shellcheck disable=all

# 根目录推导: 脚本从 src/lib 被 source, 主入口传 H2N_ROOT
H2N_ROOT="${H2N_ROOT:-}"
if [[ -z "$H2N_ROOT" ]]; then
  H2N_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
H2N_LIB_DIR="${H2N_LIB_DIR:-$H2N_ROOT/src/lib}"
H2N_REPORT_DIR="${H2N_REPORT_DIR:-$H2N_ROOT/reports}"
H2N_BACKUP_DIR="${H2N_BACKUP_DIR:-$H2N_ROOT/backups}"
H2N_CONF="${H2N_CONF:-$H2N_ROOT/yunsu.conf}"

h2n_log()  { echo "[h2n] $*"; }
h2n_warn() { echo "[h2n 注意] $*" >&2; }
h2n_err()  { echo "[h2n 错误] $*" >&2; }
h2n_fail() { h2n_err "$*"; exit 1; }

# 装载全部模块并硬校验: 缺任何一个立即报错退出2, 不蒙混
h2n_load_libs() {
  local m
  for m in common envcheck detect sysctl singbox testbed bench clean report recommend autotune; do
    if [[ ! -f "$H2N_LIB_DIR/$m.sh" ]]; then
      h2n_err "缺少引擎模块（$m）: $H2N_LIB_DIR/$m.sh 不存在"
      h2n_err "修复: 带完整目录运行(不要只拷主脚本), 或设置 H2N_LIB_DIR 指向 src/lib"
      exit 2
    fi
    # shellcheck disable=SC1091
    source "$H2N_LIB_DIR/$m.sh"
  done
}

# 装载 conf (env 风格), 密码永不落 conf
h2n_load_conf() {
  if [[ ! -f "$H2N_CONF" ]]; then
    h2n_err "缺少配置文件: $H2N_CONF"
    h2n_err "修复: 复制 hyst2-netopt.conf.example 为 hyst2-netopt.conf 并填本机参数"
    exit 3
  fi
  # shellcheck disable=SC1090
  source "$H2N_CONF"
  # 必填校验
  local missing=()
  [[ -n "${H2N_SSH_HOST:-}" ]]  || missing+=(H2N_SSH_HOST)
  [[ -n "${H2N_TB_HOST:-}"  ]]  || missing+=(H2N_TB_HOST)
  [[ -n "${H2N_H2_DOMAIN:-}" || "${H2N_TLS_ENABLED:-0}" == "0" ]] || missing+=(H2N_H2_DOMAIN)
  if [[ "${H2N_TLS_ENABLED:-0}" == "1" ]]; then
    [[ -n "${H2N_H2_PASSWORD_FILE:-}" ]] || missing+=(H2N_H2_PASSWORD_FILE)
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    h2n_fail "配置缺必填项: ${missing[*]} (见 $H2N_CONF)"
  fi
  mkdir -p "$H2N_REPORT_DIR" "$H2N_BACKUP_DIR"
}

# SSH 封装: 服务端
# shellcheck disable=SC2086
h2n_ssh_server() {
  local cmd=( "${H2N_SSH_BIN:-ssh}" -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
  [[ -n "${H2N_SSH_PORT:-}" ]] && cmd+=( -p "$H2N_SSH_PORT" )
  [[ -n "${H2N_SSH_KEY:-}"  ]] && cmd+=( -i "$H2N_SSH_KEY" )
  cmd+=( "${H2N_SSH_USER:-root}@${H2N_SSH_HOST}" )
  "${cmd[@]}" "$@"
}

# SSH 封装: 测试床
h2n_ssh_tb() {
  local cmd=( "${H2N_SSH_BIN:-ssh}" -o ConnectTimeout=15 -o BatchMode=yes -o StrictHostKeyChecking=accept-new )
  [[ -n "${H2N_TB_PORT:-}" ]] && cmd+=( -p "$H2N_TB_PORT" )
  [[ -n "${H2N_TB_KEY:-}"  ]] && cmd+=( -i "$H2N_TB_KEY" )
  cmd+=( "${H2N_TB_USER:-root}@${H2N_TB_HOST}" )
  "${cmd[@]}" "$@"
}

# 远程执行服务端命令(脚本字符串)
h2n_run_server() { h2n_ssh_server "$1"; }
# 远程执行测试床命令
h2n_run_tb() { h2n_ssh_tb "$1"; }

# 读密码文件(只在 38 本地读, 永不打印)
h2n_read_password() {
  local f="${H2N_H2_PASSWORD_FILE:-}"
  if [[ -z "$f" || ! -r "$f" ]]; then
    h2n_err "密码文件不存在或不可读: ${f:-未配置 H2N_H2_PASSWORD_FILE}"
    return 1
  fi
  cat "$f"
}

# 大白话时间戳
h2n_now() { date '+%Y-%m-%d %H:%M:%S'; }
