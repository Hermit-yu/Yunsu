#!/usr/bin/env bash
# h2n-netopt.sh — Hysteria2 隧道 + VPS 网络优化 主入口(全发行版通用)
# 前置自动探测: 系统版本/root/包管理器/防火墙后端/必需工具(envcheck), 缺什么给建议不硬套apt
# 模块: detect(只读基线) envcheck sysctl singbox testbed bench clean report
# 用法: ./h2n-netopt.sh [detect|apply|testbed|bench|clean|report|status|menu] [选项]
# 选项: --conf <path> (指定conf, 默认同目录 hyst2-netopt.conf)
set -u
H2N_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export H2N_ROOT="$H2N_SELF_DIR"
H2N_CONF="${H2N_CONF:-$H2N_SELF_DIR/yunsu.conf}"

# shellcheck disable=SC1091
source "$H2N_SELF_DIR/src/lib/common.sh"
h2n_load_libs

usage() {
  cat <<'EOF'
h2n-netopt.sh — 云速 VPS 隧道+网络优化(全发行版通用, 自动探测系统/root)
用法: h2n-netopt.sh <阶段> [选项]
阶段:
  detect     只读基线(系统/root/内核/CC/sysctl现值/RTT/带宽分叉判定)
  apply      实装: sing-box安装+配置+服务 + sysctl持久化(默认只读模式请配合 --yes 确认)
  recommend  按实测数据生成sysctl参数(数据驱动, 计算过程落md报告)
  autotune   性能闭环: 基准->生成参数->安全应用->重测->评价(回退>30%自动回滚)
  testbed    建测试床(服务端文件服务+测试床客户端), 用于调优
  bench     性能闭环(单流x N轮 + 并发 + CPU余量采样)
  clean     一键拆测试床(不动 sing-box 本体/sysctl)
  rollback  回滚本次实装(sysctl 写回原值+删90-conf, sing-box 配置回 bak 并重启)
  full-clean 全拆: 测试床+sysctl+sing-box 配置
  report    汇总执行报告
  status    各服务现状速查
  menu      交互菜单(无参数时默认进入)
选项:
  --conf <path>   指定配置文件(默认: 脚本同目录 yunsu.conf)
  --yes           apply/autotune 阶段免确认直接执行(默认要确认, 高风险)
  --force         检测到 90-/99- 同键冲突时放行(默认阻断; 冲突=开机新参数会被字典序靠后的文件盖掉, 需人工合并)
EOF
}

# 交互菜单(函数必须先于入口定义)
h2n_menu() {
  local pick
  while true; do
    cat <<'EOF'
========== h2n-netopt 菜单 ==========
 1) 只读基线检测 (detect + envcheck)
 2) 实装(apply): sing-box + sysctl  [需root+确认]
 3) 建测试床 (testbed)
 4) 性能测试 (bench)
 5) 拆测试床 (clean)
 6) 汇总报告 (report)
 7) 现状速查 (status)
 8) 数据驱动推荐参数 (recommend)
 9) 性能闭环自动调参 (autotune, 含安全应用)
 0) 退出
======================================
EOF
    read -rp "选一个: " pick
    case "$pick" in
      1) h2n_envcheck_server; h2n_detect_baseline ;;
      2) h2n_apply_all ;;
      3) h2n_testbed_setup ;;
      4) h2n_bench ;;
      5) h2n_clean_testbed ;;
      6) h2n_report ;;
      7) h2n_status ;;
      8) h2n_recommend ;;
      9) local r; echo "autotune 会安全应用 sysctl(备份原值, 回退>30%自动回滚)."; read -rp "确认? [y/N] " r; [[ "$r" == "y" || "$r" == "Y" ]] && h2n_autotune ;;
      0) h2n_log "退出"; return 0 ;;
      *) h2n_warn "无效选项, 重选" ;;
    esac
  done
}

h2n_status() {
  h2n_log "== 服务端 sing-box 现状 =="
  h2n_run_server 'systemctl is-active sing-box-hyst2; /usr/local/bin/sing-box version 2>/dev/null | head -1; ss -uln 2>/dev/null | grep 57689 | head -1; python3 -c "import json;i=json.load(open(\"/etc/sing-box/hyst2.json\"))[\"inbounds\"][0];print(\"cc:\",i.get(\"bbr_profile\"),\"| up:\",i.get(\"up_mbps\",\"无\"),\"| down:\",i.get(\"down_mbps\",\"无\"))" 2>/dev/null' 2>&1
  h2n_log "== 服务端 sysctl 现状 =="
  h2n_run_server 'sysctl -n net.core.somaxconn net.core.netdev_max_backlog 2>/dev/null; ls /etc/sysctl.d/90-hyst2-netopt.conf 2>/dev/null || echo "无90-hyst2-netopt.conf"'
}

# 全量实装: 顺序固定(先探测->sysctl->singbox), 每步可回滚
h2n_apply_all() {
  h2n_envcheck_local || { h2n_err "本地前置不过, 见上"; return 1; }
  h2n_envcheck_server
  h2n_log "实装 1/3: sysctl 持久化(备份->写90-conf->check->sysctl -p->逐项验证->失败回滚)"
  h2n_sysctl_apply || h2n_warn "sysctl 层失败(已自动回滚), 继续 sing-box 层"
  h2n_log "实装 2/3: sing-box 安装+配置+服务"
  h2n_singbox_install
  h2n_singbox_apply
  h2n_log "实装 3/3: 验证"
  h2n_status
  h2n_log "完成. 有测试床可 h2n-testbed-setup + h2n-bench 验证吞吐; 报告: $(h2n_report)"
}

# main
main() {
  local stage="menu" yes="" conf_opt="" force=""
  local args=() i
  # 收集参数
  for i in "$@"; do args+=("$i"); done
  i=0
  while [[ $i -lt ${#args[@]} ]]; do
    case "${args[$i]}" in
      --yes) yes="1" ;;
      --force) force="1" ;;
      --conf) i=$((i+1)); [[ $i -lt ${#args[@]} ]] && conf_opt="${args[$i]}" || { h2n_err "--conf 需要值"; return 64; } ;;
      -h|--help) usage; return 0 ;;
      -*) h2n_err "未知选项: ${args[$i]} (见 --help)"; return 64 ;;
      *) if [[ "$stage" == "menu" ]]; then stage="${args[$i]}"; fi ;;
    esac
    i=$((i+1))
  done
  [[ -n "$conf_opt" ]] && H2N_CONF="$conf_opt"
  [[ -n "$force" ]] && export H2N_FORCE="$force"
  h2n_load_conf

  if [[ "$stage" == "apply" && -z "$yes" ]]; then
    local r
    echo "即将在 $H2N_SSH_HOST: 改 sysctl(备份原值) + 重装/重启 sing-box-hyst2 服务."
    read -rp "确认继续? [y/N] " r
    [[ "${r:-N}" == "y" || "${r:-N}" == "Y" ]] || { h2n_log "已取消"; return 1; }
  fi
  case "$stage" in
    detect)  h2n_envcheck_server; h2n_detect_baseline ;;
    apply)   h2n_apply_all ;;
    recommend) h2n_recommend ;;
    autotune)  h2n_autotune ;;
    testbed) h2n_testbed_setup ;;
    bench)   h2n_bench ;;
    clean)   h2n_clean_testbed ;;
    rollback) h2n_sysctl_rollback; h2n_singbox_rollback ;;
    full-clean) h2n_clean_all ;;
    report)  h2n_report ;;
    status)  h2n_status ;;
    menu|"") h2n_menu ;;
    *) usage; return 64 ;;
  esac
}
main "$@"
