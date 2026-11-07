#!/usr/bin/env bash
# testbed.sh — 测试床方法论: 服务端临时线程文件服务(ufw只放行测试床IP) + 测试床客户端
# 测完由 clean.sh 一键全拆. 文件放 /opt(服务端tmpfs常很小, 不放/tmp).
# 密码只在执行机本地存在, 经 ssh 命令行前缀注入远端变量, 远端不落明文文件(仅客户端JSON).
# shellcheck disable=all

h2n_testbed_setup() {
  [[ -n "${H2N_TB_HOST:-}" ]] || { h2n_warn "未配测试床(H2N_TB_HOST为空), 跳过"; return 1; }
  local mb="${H2N_TB_FILE_MB:-200}"
  h2n_log "建服务端临时文件服务: ${mb}MB 文件 + 线程版 http.server 端口 ${H2N_TB_FILESERV_PORT}(防火墙只放行 $H2N_TB_HOST)"
  h2n_run_server "MB='$mb' PORT='$H2N_TB_FILESERV_PORT' TB='$H2N_TB_HOST' bash -s" <<'H2NFS' || h2n_err "文件服务建立失败(见上)"
set -u
D=/opt/netopt-files
mkdir -p "$D"
if [ ! -f "$D/bigfile-${MB}m.bin" ]; then
  echo "生成 ${MB}MB 测试文件(零填充)..."
  head -c $(($MB*1048576)) /dev/zero > "$D/bigfile-${MB}m.bin"
fi
PYBIN="$(command -v python3 || echo /usr/bin/python3)"
cat > /opt/netopt-threadsrv.py <<EOF
import http.server, socketserver, os
os.chdir("/opt/netopt-files")
class H(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
S(("0.0.0.0", int(os.environ.get("PORT","8890"))), H).serve_forever()
EOF
cat > /etc/systemd/system/netopt-fileserve.service <<EOF
[Unit]
Description=netopt temp threaded file server (test only, remove after)
After=network.target
[Service]
Environment=PORT=$PORT
ExecStart=$PYBIN /opt/netopt-threadsrv.py
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now netopt-fileserve 2>/dev/null || systemctl start netopt-fileserve
sleep 1
echo "服务: $(systemctl is-active netopt-fileserve)"
curl -s -o /dev/null -w "本地自检 http=%{http_code}\n" "http://127.0.0.1:$PORT/bigfile-${MB}m.bin" -r 0-100 --max-time 10
exit 0
H2NFS
  h2n_log "防火墙放行(仅 $H2N_TB_HOST -> 服务端 ${H2N_TB_FILESERV_PORT}/tcp):"
  h2n_run_server "TB='$H2N_TB_HOST' PORT='$H2N_TB_FILESERV_PORT' bash -s" <<'H2NFw'
set -u
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow from "$TB" to any port "$PORT" proto tcp 2>/dev/null && echo "ufw 放行完成"
  ufw status | grep "$PORT"
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
  firewall-cmd --permanent --add-rich-rule="family=ipv4 source address=$TB port port=$PORT protocol=tcp accept" 2>/dev/null && firewall-cmd --reload 2>/dev/null && echo "firewalld 放行完成"
elif command -v iptables >/dev/null 2>&1; then
  iptables -C INPUT -s "$TB" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -s "$TB" -p tcp --dport "$PORT" -j ACCEPT
  echo "iptables 放行完成"
else
  echo "警告: 没检测到活跃防火墙(ufw/firewalld/iptables), 请人工放行: $TB -> :$PORT/tcp (云安全组也要查)"
fi
exit 0
H2NFw
  h2n_testbed_client_up "tb"
}

# 在测试床起 sing-box hyst2 客户端(若没装先装). 密码经命令行前缀注入远端变量, heredoc 加引号本地不展开
h2n_testbed_client_up() {
  local tag="${1:-tb}" pw tjson prefix p
  pw="$(h2n_read_password)" || return 1
  tjson="false"; [[ "${H2N_TLS_ENABLED:-0}" == "1" ]] && tjson="true"
  # 前缀里的单引号转义: 密码含单引号时按 shell 规则 '->'\''
  pw_esc="${pw//\'/\'\\\'\'}"
  prefix="H2N_PWD='$pw_esc' SRV='$H2N_SSH_HOST' SPORT='$H2N_H2_PORT' DOM='$H2N_H2_DOMAIN' PP='${H2N_LOCAL_PROXY_PORT:-7890}' TAG='$tag' TJSON=$tjson TBFILE='${H2N_TB_FILE_MB:-200}' FSP='$H2N_TB_FILESERV_PORT'"
  h2n_log "测试床 $H2N_TB_HOST 起客户端 ${H2N_LOCAL_PROXY_PORT:-7890}(tag=$tag, 密码经变量注入不落盘)"
  h2n_run_tb "$prefix bash -s" <<'H2NTBC'
set -u
if ! command -v /usr/local/bin/sing-box >/dev/null 2>&1; then
  echo "测试床装 sing-box..."
  curl -fsSL -o /root/sbt.tgz "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz" 2>&1 | tail -1
  rm -rf /root/sb-x /root/sing-box-1.14.4-linux-amd64
  tar xzf /root/sbt.tgz -C /root
  install -m755 /root/sing-box-1.14.4-linux-amd64/sing-box /usr/local/bin/sing-box
  rm -f /root/sbt.tgz; rm -rf /root/sing-box-1.14.4-linux-amd64
fi
cat > "/tmp/sb-h2-client-$TAG.json" <<EOF
{
  "log": {"level":"warn","output":"/tmp/sb-h2-client-$TAG.log"},
  "inbounds":[{"type":"mixed","tag":"local-in","listen":"127.0.0.1","listen_port":$PP}],
  "outbounds":[
    {"type":"hysteria2","tag":"h2","server":"$SRV","server_port":$SPORT,
     "password":"$H2N_PWD","tls":{"enabled":$TJSON,"server_name":"$DOM"}},
    {"type":"direct","tag":"direct"}
  ],
  "route":{"final":"h2"}
}
EOF
/usr/local/bin/sing-box check -c "/tmp/sb-h2-client-$TAG.json" && echo "配置check通过"
pkill -f "sb-h2-client-$TAG.json" 2>/dev/null; sleep 1
( setsid /usr/local/bin/sing-box run -c "/tmp/sb-h2-client-$TAG.json" </dev/null >/dev/null 2>&1 & )
sleep 3
echo "代理口状态: $(ss -tln 2>/dev/null | grep -c ":$PP ")"
exit 0
H2NTBC
  p="$(h2n_run_tb "ss -tln 2>/dev/null | grep -c :${H2N_LOCAL_PROXY_PORT:-7890}")"
  [[ "$p" == "1" ]] || { h2n_err "测试床代理口 ${H2N_LOCAL_PROXY_PORT:-7890} 未起, 查 /tmp/sb-h2-client-$tag.log"; return 1; }
  local code
  code="$(h2n_run_tb "curl -s -o /dev/null -w '%{http_code}' -x http://127.0.0.1:${H2N_LOCAL_PROXY_PORT:-7890} -r 0-1048575 'http://$H2N_SSH_HOST:$H2N_TB_FILESERV_PORT/bigfile-${H2N_TB_FILE_MB:-200}m.bin' --max-time 30")"
  [[ "$code" == "200" ]] && h2n_log "隧道认证+连通验证通过(http=$code)" || h2n_err "隧道认证验证 http=$code(非200), 查密码/端口/防火墙"
}
