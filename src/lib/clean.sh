#!/usr/bin/env bash
# clean.sh — 一键全拆测试床(服务端文件服务+文件+防火墙规则, 测试床客户端), 不碰 sing-box 服务本身
# shellcheck disable=all

h2n_clean_testbed() {
  h2n_log "拆服务端临时文件服务..."
  h2n_run_server "PORT='$H2N_TB_FILESERV_PORT' TB='$H2N_TB_HOST' bash -s" <<'H2NCLEAN'
set -u
systemctl disable --now netopt-fileserve 2>/dev/null
rm -f /etc/systemd/system/netopt-fileserve.service /opt/netopt-threadsrv.py
rm -f /opt/netopt-files/bigfile-*.bin 2>/dev/null
rmdir /opt/netopt-files 2>/dev/null
systemctl daemon-reload
# 防火墙规则撤回(只撤自己加的测试床->PORT 规则)
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw delete allow from "$TB" to any port "$PORT" proto tcp 2>/dev/null || true
  ufw status | grep "$PORT" && echo "  ufw 里 $PORT 仍有规则(可能是别人的), 人工确认" || echo "ufw 测试规则已撤"
fi
echo "服务端: $(systemctl is-active netopt-fileserve 2>/dev/null || echo 已停)"
exit 0
H2NCLEAN
  if [[ -n "${H2N_TB_HOST:-}" ]]; then
    h2n_log "停测试床 $H2N_TB_HOST 客户端..."
    h2n_run_tb "pkill -f 'sb-h2-client-' 2>/dev/null; rm -f /tmp/sb-h2-client-*.json /tmp/sb-h2-client-*.log; echo 测试床客户端已清"
  fi
  h2n_log "测试床已全拆(sing-box 服务本体不动, sysctl/90-conf 不动)"
}

h2n_clean_all() {
  h2n_clean_testbed
  h2n_sysctl_rollback
  h2n_singbox_rollback
  h2n_log "全量回滚完成(测试床+sysctl+sing-box 配置)"
}
