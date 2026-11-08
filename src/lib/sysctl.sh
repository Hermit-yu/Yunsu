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
SELF=$H2N_SYSCTL_CONF
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

  h2n_log "3/6 生成 conf(本地 staging) + 上载远端 staging(标记块合并, 共享文件不再整份覆盖)"
  local conf
  conf="$H2N_BACKUP_DIR/90-hyst2-netopt.stage.conf"
  mkdir -p "$H2N_BACKUP_DIR"
  {
    local line
    for line in "${pairs[@]}"; do
      echo "$line"
    done
  } > "$conf"
  # 格式检查: 每个非注释行必须形如 键 = 值
  local badline
  badline="$(grep -vE '^[[:space:]]*(#|$)' "$conf" | grep -vE '^[a-z0-9._]+[[:space:]]*=' || true)"
  if [[ -n "$badline" ]]; then
    h2n_err "参数里有非法行(必须 键=值): $badline"
    return 1
  fi
  local remote_cur merged
  remote_cur="$H2N_BACKUP_DIR/remote-current.conf"
  merged="$H2N_BACKUP_DIR/merged.conf"
  h2n_run_server "cat $H2N_SYSCTL_CONF 2>/dev/null || true" > "$remote_cur"
  python3 - "$H2N_SYSCTL_MARKER" "$remote_cur" "$conf" "$merged" <<'PYMERGE'
import sys, os
marker, cur_f, new_f, out_f = sys.argv[1:5]
start, end = marker, marker + "_END"
cur = open(cur_f).read()
new_lines = [l for l in open(new_f).read().splitlines() if l.strip() and not l.strip().startswith('#')]
new_keys = {l.split('=', 1)[0].strip() for l in new_lines}
def key_of(l):
    s = l.strip()
    if not s or s.startswith('#'):
        return None
    return s.split('=', 1)[0].strip()
kept, skipping = [], False
for l in cur.splitlines():
    s = l.strip()
    if s == start:
        skipping = True
        continue
    if s == end:
        skipping = False
        continue
    if skipping:
        continue
    if key_of(l) in new_keys:      # 块外的同键旧行清掉, 新块放文件末尾=开机最终值
        continue
    kept.append(l)
out = '\n'.join(kept).rstrip() + '\n\n'
out += start + '\n' + '\n'.join(new_lines) + '\n' + end + '\n'
open(out_f, 'w').write(out)
PYMERGE
  # 写回远端共享文件(只替换自己, 块外其他键原样保留)
  h2n_run_server "cat > $H2N_SYSCTL_CONF" < "$merged" || h2n_fail "写回失败"
  rm -f "$merged"

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

# 回滚: 逐项 sysctl -w 写回备份值 + 只删共享文件里自己的标记块(不删文件本身/不动别人的键)
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
    h2n_warn "找不到备份文件($H2N_BACKUP_DIR/sysctl-backup-*), 跳过原值写回, 仅删自己的标记块"
  fi
  # 只删标记块, 共享文件里其他键保留
  local rb
  rb="$(mktemp "$H2N_BACKUP_DIR/rollback-strip.XXXX" 2>/dev/null || mktemp)"
  cat > "$rb" <<STRIPTAIL
import re, sys
f, m = sys.argv[1], sys.argv[2]
start, end = m, m + "_END"
s = open(f).read()
out = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", "", s, flags=re.S)
open(f, "w").write(out.rstrip() + "\n")
STRIPTAIL
  if h2n_run_server "cat > /tmp/h2n-strip.py" < "$rb" 2>/dev/null; then
    h2n_run_server "python3 /tmp/h2n-strip.py '$H2N_SYSCTL_CONF' '$H2N_SYSCTL_MARKER'" || h2n_warn "标记块删除失败, 请手动检查 $H2N_SYSCTL_CONF"
    h2n_run_server "rm -f /tmp/h2n-strip.py"
  else
    h2n_warn "无法上载剥离脚本(服务端无python3?), 请手动删除 $H2N_SYSCTL_CONF 里 $H2N_SYSCTL_MARKER 到 ${H2N_SYSCTL_MARKER}_END 之间的行"
  fi
  rm -f "$rb"
  h2n_log "回滚完成: 已删自己的标记块(共享文件 $H2N_SYSCTL_CONF 保留), 原值已逐项写回(备份=$(basename "${bak:-无}"))"
}
