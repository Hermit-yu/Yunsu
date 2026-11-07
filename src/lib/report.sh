#!/usr/bin/env bash
# report.sh — 汇总执行报告: 把各阶段产物合成一份人话报告
# shellcheck disable=all

h2n_report() {
  local ts out det bench
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$H2N_REPORT_DIR/report-$ts.md"
  det="$(cat "$H2N_REPORT_DIR/.last_detect" 2>/dev/null)"
  bench="$(ls -1 "$H2N_REPORT_DIR"/bench-*.txt 2>/dev/null | sort | tail -1)"
  {
    echo "# Hysteria2 隧道 + VPS 网络优化 执行报告"
    echo
    echo "- 执行时间: $(h2n_now)"
    echo "- 服务端: $H2N_SSH_HOST (端口 ${H2N_SSH_PORT:-默认})"
    echo "- 测试床: ${H2N_TB_HOST:-未配}"
    echo "- hyst2 端口: ${H2N_H2_PORT}/udp, 域名: ${H2N_H2_DOMAIN}"
    echo
    echo "## 关键结论"
    echo "- 调优杠杆最大项 = hyst2 拥塞控制(去掉 up/down_mbps 让客户端走BBR CC, 单流 ~60 -> 130-178Mbps), 不是内核 sysctl"
    echo "- 单流为准(多流在单核+BBR下互踩), 单流100MB x N轮取最好值"
    echo "- 单核CPU实测远没打满(sing-box 仅10-22%), 继续提带宽靠CC层不靠CPU"
    echo
    echo "## 各阶段"
    echo "### 基线 detect"
    [[ -n "$det" && -f "$det" ]] && sed 's/^/  /' "$det" | tail -40
    echo
    echo "### 性能 bench"
    [[ -n "$bench" && -f "$bench" ]] && sed 's/^/  /' "$bench" | grep -E "单流|并发|CPU采样|load|=" | head -20
    echo
    echo "## 回滚点"
    echo "- sysctl 备份: $(ls -1 "$H2N_BACKUP_DIR"/sysctl-backup-* 2>/dev/null | sort | tail -1)"
    echo "- sing-box 配置备份: $(h2n_run_server 'ls -1 /etc/sing-box/hyst2.json.bak-* 2>/dev/null | sort | tail -1')"
    echo
    echo "## 验证命令"
    echo "  systemctl is-active sing-box-hyst2 && ss -uln | grep $H2N_H2_PORT"
  } > "$out"
  echo "$out"
}
