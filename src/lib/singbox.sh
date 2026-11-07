#!/usr/bin/env bash
# singbox.sh — 服务端 sing-box hyst2 安装与配置. 安全顺序:
#   备份现有 conf -> 生成新 conf(密码本地注入, 文件0600, 打印脱敏版) -> 写远端 -> sing-box check
#   -> restart 该服务(不重启机器) -> 验证 UDP 端口在听 + 证书有效期 -> 确保 ufw 放行
# 关键结论(2026-11-08 A/B 实测): 不设 up_mbps/down_mbps(设了会禁掉客户端BBR CC), bbr_profile=standard
# shellcheck disable=all

H2N_SRV_CONF_LOCAL=""

h2n_singbox_install() {
  h2n_log "检查/安装服务端 sing-box..."
  local ver
  ver="$(h2n_run_server "/usr/local/bin/sing-box version 2>/dev/null | head -1")"
  if [[ -n "$ver" ]]; then
    h2n_log "已装: $ver, 跳过下载"
    return 0
  fi
  h2n_log "未装, 下载 sing-box 1.14.4 (放 /usr/local/bin, 不占用服务端小 tmpfs)..."
  h2n_run_server '
    set -u
    cd /root
    curl -fSL -o /root/sb.tgz "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz" 2>&1 | tail -1
    tar xzf /root/sb.tgz -C /root
    install -m755 /root/sing-box-1.14.4-linux-amd64/sing-box /usr/local/bin/sing-box
    rm -f /root/sb.tgz; rm -rf /root/sing-box-1.14.4-linux-amd64
    /usr/local/bin/sing-box version | head -1
  ' || { h2n_err "sing-box 安装失败(检查服务端 GitHub 出网可达性)"; return 1; }
  h2n_log "安装完成: $(h2n_run_server "/usr/local/bin/sing-box version | head -1")"
}

# 生成服务端 conf 到本地临时文件(0600, 密码仅存于此文件), stdout 打脱敏版供人工预览
h2n_singbox_conf() {
  local pw
  pw="$(h2n_read_password)" || return 1
  H2N_SRV_CONF_LOCAL="$H2N_REPORT_DIR/.last-srv-conf.json"
  local pyc=0
  python3 - "$pw" > "$H2N_SRV_CONF_LOCAL" <<PYGEN || pyc=1
import json, sys, os
pw = sys.argv[1].strip()
cfg = {
  "log": {"level": "${H2N_H2_LOG_LEVEL:-info}", "output": "/var/log/sing-box/hyst2.log"},
  "inbounds": [{
    "type": "hysteria2",
    "tag": "hyst2-in",
    "listen": "::",
    "listen_port": int("${H2N_H2_PORT}"),
    "users": [{"name": "user1", "password": pw}],
    "tls": {
      "enabled": ${H2N_TLS_ENABLED:-1} == 1,
      "server_name": "${H2N_H2_DOMAIN}",
      "certificate_path": "${H2N_H2_CERT_DIR}/fullchain.pem",
      "key_path": "${H2N_H2_CERT_DIR}/privkey.pem",
    },
    "bbr_profile": "${H2N_H2_BBR_PROFILE:-standard}",
    "masquerade": "${H2N_H2_MASQUERADE:-https://www.youtube.com/}",
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}],
}
json.dump(cfg, sys.stdout, indent=2)
PYGEN
  if [[ $pyc -eq 1 ]]; then
    h2n_err "服务端 conf 生成失败(python 报错), 放弃"
    return 1
  fi
  chmod 600 "$H2N_SRV_CONF_LOCAL" 2>/dev/null
  # 脱敏预览: 密码替换为 <len=N>
  python3 -c '
import json,sys
c=json.load(open(sys.argv[1]))
u=c["inbounds"][0].get("users")
for x in (u or []):
    p=x.get("password","")
    x["password"]=f"<已脱敏,len={len(p)}>"
print(json.dumps(c,indent=1,ensure_ascii=False))
' "$H2N_SRV_CONF_LOCAL"
  # 用 sing-box 校验不了远端 schema, 本地先确保 JSON 可解析
  python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("JSON 合法")' "$H2N_SRV_CONF_LOCAL"
}

h2n_singbox_apply() {
  local ts
  [[ -n "$H2N_SRV_CONF_LOCAL" && -f "$H2N_SRV_CONF_LOCAL" ]] || h2n_singbox_conf || return 1
  ts="$(date +%Y%m%d-%H%M%S)"
  h2n_log "备份现有服务端 conf(若存在) -> /etc/sing-box/hyst2.json.bak-$ts"
  h2n_run_server "mkdir -p /etc/sing-box /var/log/sing-box; [ -f /etc/sing-box/hyst2.json ] && cp /etc/sing-box/hyst2.json /etc/sing-box/hyst2.json.bak-$ts; echo 备份完成" || h2n_warn "旧 conf 备份失败(可能首次安装), 继续"
  h2n_log "上载新 conf + 写 systemd 单元 + logrotate + check + 重启服务"
  h2n_run_server "cat > /etc/sing-box/hyst2.json" < "$H2N_SRV_CONF_LOCAL" || h2n_fail "conf 上载失败, 未动服务"
  # 远端 heredoc 不带密码: 单元与 logrotate 由远端变量生成
  h2n_run_server "DOMAIN='${H2N_H2_DOMAIN}' PORT='${H2N_H2_PORT}' bash -s" <<'H2NUNIT'
set -u
/usr/local/bin/sing-box check -c /etc/sing-box/hyst2.json || { echo "sing-box check 失败, 服务不动, 见上方"; exit 1; }
cat > /etc/systemd/system/sing-box-hyst2.service <<EOF
[Unit]
Description=sing-box hysteria2 inbound (${DOMAIN}:${PORT}/udp)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/hyst2.json
Restart=on-failure
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/logrotate.d/sing-box <<EOF
/var/log/sing-box/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
systemctl daemon-reload
systemctl restart sing-box-hyst2 2>/dev/null || systemctl start sing-box-hyst2
sleep 2
echo "服务状态: $(systemctl is-active sing-box-hyst2)"
H2NUNIT
  local port_active
  port_active="$(h2n_run_server "ss -uln 2>/dev/null | grep -c :${H2N_H2_PORT}")"
  [[ "$port_active" == "1" ]] || { h2n_err "UDP ${H2N_H2_PORT} 未在听, 查 /var/log/sing-box/hyst2.log"; return 1; }
  if [[ "${H2N_TLS_ENABLED:-0}" == "1" ]]; then
    local exp
    exp="$(h2n_run_server "openssl x509 -noout -enddate -in ${H2N_H2_CERT_DIR}/fullchain.pem 2>/dev/null | cut -d= -f2")"
    [[ -n "$exp" ]] && h2n_log "证书有效期: 到 $exp" || h2n_warn "证书读取失败(${H2N_H2_CERT_DIR}/fullchain.pem), 人工确认"
  fi
  h2n_run_server "ufw allow ${H2N_H2_PORT}/udp 2>/dev/null || true; echo ufw放行已确保" >/dev/null
  h2n_log "sing-box 应用完成: ${H2N_H2_PORT}/udp 在听, 回滚点=/etc/sing-box/hyst2.json.bak-$ts"
  rm -f "$H2N_SRV_CONF_LOCAL"
  H2N_SRV_CONF_LOCAL=""
  return 0
}

h2n_singbox_rollback() {
  local last
  last="$(h2n_run_server "ls -1 /etc/sing-box/hyst2.json.bak-* 2>/dev/null | sort | tail -1")"
  if [[ -n "$last" ]]; then
    if h2n_run_server "cp '$last' /etc/sing-box/hyst2.json && /usr/local/bin/sing-box check -c /etc/sing-box/hyst2.json && systemctl restart sing-box-hyst2"; then
      h2n_log "已回滚到 $last 并重启服务"
    else
      h2n_err "回滚失败(check不过或服务重启失败), 需人工: $last"
    fi
  else
    h2n_warn "无 bak 可回滚(可能首次安装), 仅停止服务"
    h2n_run_server "systemctl stop sing-box-hyst2 2>/dev/null || true"
  fi
}
