#!/usr/bin/env bash
# sysctl.sh — 持久化 sysctl 层. 安全顺序不可调换:
#   1 备份原值(独立文件) -> 2 写 90-conf(带MARKER) -> 3 语法检查 -> 4 sysctl -p 只加载自己
#   -> 5 逐项验证(内核实际 vs 目标) -> 6 失败自动回滚(写回备份值+删自己conf, 不碰用户原配置)
# 先扫 /etc/sysctl.d 90-/99- 同键冲突, 冲突只报告不覆盖.
# shellcheck disable=all

# 实际执行(参数文件驱动): 备份原值 -> 冲突扫描 -> staging生成上载 -> sysctl -p -> 逐项验证 -> 失败回滚
# $1 = 参数文件(sysctl格式 "键=值", 值可含空格如 ip_local_port_range)
h2n_sysctl_apply_from() {
  local src="${1:-}"
  if [[ -z "$src" || ! -f "$src" ]]; then
    h2n_err "缺少参数文件: ${src:-未指定}"
    return 1
  fi
  # 读参数文件成数组(跳过注释/空行)
  local pairs=() p
  while IFS= read -r p; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    pairs+=("$p")
  done < "$src"
  if [[ ${#pairs[@]} -eq 0 ]]; then
    h2n_err "参数文件为空(无有效键值行): $src"
    return 1
  fi
  # 动态键列表(供备份/冲突扫描/验证用)
  local keys=() pk
  for p in "${pairs[@]}"; do pk="${p%%=*}"; keys+=("$pk"); done

  if [[ $(id -u) -ne 0 ]]; then
    h2n_fail "应用 sysctl 需要以 root 运行; 当前 uid=$(id -u)"
  fi
  local ts bak
  ts="$(date +%Y%m%d-%H%M%S)"
  bak="$H2N_BACKUP_DIR/sysctl-backup-$ts"
  h2n_log "1/6 备份当前原值(${#keys[@]}项) -> $(basename "$bak")"
  h2n_run_server "bash -s" <<H2NS > "$bak" || h2n_warn "原值备份不完整(降级: 继续, 但回滚依据减弱)"
for k in ${keys[*]}; do
  v=\$(sysctl -n "\$k" 2>/dev/null | tr -d ' ')
  echo "\$k=\$v"
done
exit 0
H2NS

  h2n_log "2/6 扫描 90-/99- 同键冲突(sysctl.d 字典序: 90-hyst2-netopt 最先加载, 后面的 90-*/99-* 会开机覆盖它)"
  local cscan
  cscan="$(mktemp "$H2N_BACKUP_DIR/conflict-scan.XXXX" 2>/dev/null || mktemp)"
  h2n_run_server "bash -s" <<H2NC > "$cscan" 2>&1
BAD=0
SELF=/etc/sysctl.d/90-hyst2-netopt.conf
for f in /etc/sysctl.d/90-*.conf /etc/sysctl.d/99-*.conf; do
  [ -f "\$f" ] || continue
  [ "\$f" = "\$SELF" ] && continue
  for k in ${keys[*]}; do
    hit=\$(grep -E "^\$k[[:space:]]*=" "\$f" 2>/dev/null | head -1)
    if [ -n "\$hit" ]; then
      echo "  冲突: \$f 里已有 \$hit (sysctl.d 按字典序后者覆盖前者, 开机时本脚本值会被盖掉)"
      BAD=1
    fi
  done
done
[ "\$BAD" = "0" ] && echo "  未发现同键冲突"
exit 0
H2NC
  cat "$cscan"
  if grep -q "冲突:" "$cscan" && [[ -z "${H2N_FORCE:-}" ]]; then
    h2n_err "检测到同键冲突(见上), 默认阻断: 强行写入只在当前生效, 开机会被字典序靠后的 90-*/99-* 文件覆盖."
    h2n_err "请先人工合并冲突文件, 或确认风险后用: ./h2n-netopt.sh apply --force (autotune 同支持 --force)"
    rm -f "$cscan"
    return 1
  fi
  [[ -z "${H2N_FORCE:-}" ]] || h2n_warn "检测到冲突但 --force 已指定, 继续(注意开机覆盖风险)"
  rm -f "$cscan"

  h2n_log "3/6 生成 conf(本地 staging 再上载, 不动执行机自身 /etc/sysctl.d)"
  local conf
  conf="$H2N_BACKUP_DIR/90-hyst2-netopt.stage.conf"
  mkdir -p "$H2N_BACKUP_DIR"
  {
    echo "$H2N_SYSCTL_MARKER"
    local line
    for line in "${pairs[@]}"; do
      echo "# 数据驱动生成(详见 reports/recommend-*.md). 回滚: 删本文件 + sysctl 写回 $(basename "$bak") 原值"
      echo "$line"
    done
    echo "${H2N_SYSCTL_MARKER}_END"
  } > "$conf"
  # 格式检查: 每个非注释行必须形如 键 = 值 (键名含下划线, 字符类必须带 _)
  local badline
  badline="$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -vE '^[a-z0-9._]+[[:space:]]*=' || true)"
  if [[ -n "$badline" ]]; then
    h2n_err "conf 里有非法行, 请人工检查: $badline"
    return 1
  fi
  # 上载到服务端(远端路径 $H2N_SYSCTL_CONF, 本地源 = staging 文件)
  h2n_run_server "cat > $H2N_SYSCTL_CONF" < "$conf" || h2n_fail "conf 上载失败"
  rm -f "$conf"

  h2n_log "4/6 语法检查 + 只加载自己的文件(sysctl -p, 不 --system)"
  h2n_run_server "sysctl -p $H2N_SYSCTL_CONF 2>&1" || {
    h2n_err "sysctl -p 失败, 自动回滚(写回备份值+删自己conf)"
    h2n_sysctl_rollback
    return 1
  }

  h2n_log "5/6 逐项验证(内核实际值 vs 目标, 多值键先标准化空白)"
  local fail=0 v key want
  for v in "${pairs[@]}"; do
    key="${v%%=*}"; want="$(echo "${v#*=}" | tr -d ' \t')"
    local got
    got="$(h2n_run_server "sysctl -n $key 2>/dev/null" | tr -d ' \t\n')"
    if [[ -z "$got" ]]; then
      h2n_warn "  $key 内核读不到(可能该版本已移除此项), 不计入回滚但需人工确认"
      continue
    fi
    if [[ "$got" != "$want" ]]; then
      h2n_err "  $key 内核实际=$got 目标=$want 不一致"
      fail=$((fail+1))
    fi
  done
  if [[ $fail -gt 0 ]]; then
    h2n_err "$fail 项不一致, 自动回滚全部(写回备份值+删自己conf)"
    h2n_sysctl_rollback
    return 1
  fi

  h2n_log "6/6 完成: ${#pairs[@]} 项全部内核值与目标一致, 回滚依据=$(basename "$bak"), 服务端持久化文件=$H2N_SYSCTL_CONF"
  return 0
}

# 默认实装: 用 139 实测验证过的固定参数(上一代行为, 供 apply 阶段直接调用)
H2N_SYSCTL_DEFAULTS_FILE=""
h2n_sysctl_apply() {
  local def f
  def="$H2N_BACKUP_DIR/defaults-sysctl.conf"
  {
    echo "net.ipv4.tcp_max_syn_backlog=2048"
    echo "net.core.netdev_max_backlog=16384"
    echo "net.ipv4.ip_local_port_range=10000 65535"
    echo "net.ipv4.tcp_fin_timeout=15"
    echo "net.ipv4.tcp_max_tw_buckets=32768"
    echo "net.ipv4.tcp_rmem=4096 131072 8388608"
    echo "net.ipv4.tcp_wmem=4096 65536 8388608"
    echo "net.core.rmem_max=8388608"
    echo "net.core.wmem_max=8388608"
    echo "net.netfilter.nf_conntrack_max=65536"
    echo "net.core.somaxconn=16384"
  } > "$def"
  h2n_sysctl_apply_from "$def"
}

# 回滚: 逐项 sysctl -w 写回备份值 + 删自己的 conf(不删用户原配置)
h2n_sysctl_rollback() {
  local bak line k v
  bak=$(ls -1 "$H2N_BACKUP_DIR"/sysctl-backup-* 2>/dev/null | sort | tail -1)
  if [[ -n "$bak" && -f "$bak" ]]; then
    h2n_log "按 $bak 逐项写回原值..."
    while IFS= read -r line; do
      [[ "$line" == *"="* && -n "$line" ]] || continue
      k="${line%%=*}"; v="${line#*=}"
      h2n_run_server "sysctl -w '$k=$v' >/dev/null 2>&1" || h2n_warn "  写回失败: $k (请人工: sysctl -w '$k=$v')"
    done < "$bak"
  else
    h2n_warn "找不到备份文件($H2N_BACKUP_DIR/sysctl-backup-*), 跳过原值写回, 仅删自己conf"
  fi
  h2n_run_server "rm -f $H2N_SYSCTL_CONF" || h2n_warn "删除自己的 conf 失败, 请手动 rm $H2N_SYSCTL_CONF"
  h2n_log "回滚完成: 已删 $H2N_SYSCTL_CONF, 原值已逐项写回(备份=$(basename "${bak:-无}"))"
}
