#!/usr/bin/env bash
# detect.sh — 只读基线采集. 任何检测失败降级记录, 不退出.
# 输出: 大白话直说实际值; 数据写 $H2N_REPORT_DIR/detect-<ts>.env
# shellcheck disable=all

h2n_detect_baseline() {
  local ts out rc
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$H2N_REPORT_DIR/detect-$ts.env"
  {
    echo "# 检测基线 $(h2n_now)"
    echo "H2N_TS=$ts"
  } > "$out"
  append() { echo "$1" >> "$out"; }

  h2n_log "采服务端(基线主机)只读基线..."
  h2n_run_server "CERT_DIR='$H2N_H2_CERT_DIR' bash -s" <<'H2ND' 2>&1 | tee -a "$out"
echo "===CPU内存==="
echo "CPU_CORES=$(nproc)"
free -m | awk 'NR==2{print "mem_total_mb=" $2}'
echo "===内核与CC==="
uname -r
CCV=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
echo "CC_NOW=$CCV"
DEFIF=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}'); DEFIF="${DEFIF:-eth0}"
tc qdisc show dev "$DEFIF" 2>/dev/null | head -2
echo "===全部候选 sysctl 现值==="
sysctl -n net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog net.ipv4.ip_local_port_range net.ipv4.tcp_fin_timeout net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max net.netfilter.nf_conntrack_max net.core.somaxconn 2>&1 | tr -d " "
echo "===已有 90-/99- sysctl conf==="
ls /etc/sysctl.d/ 2>/dev/null | grep -E '^(90|99)-' || echo "(无)"
echo "===sing-box hyst2 服务==="
systemctl is-active sing-box-hyst2 2>/dev/null || echo inactive
/usr/local/bin/sing-box version 2>/dev/null | head -1 || echo "sing-box 未装"
echo "===证书目录内 pem 数==="
ls "$CERT_DIR" 2>/dev/null | grep -c pem || echo 0
H2ND
  rc=${PIPESTATUS[0]}
  [[ $rc -ne 0 ]] && h2n_warn "服务端基线采集部分失败(降级, 见上输出), 继续"

  # 把 envcheck 探测(发行版/root/包管理器/防火墙/工具缺失) 一并落盘, 供追溯
  h2n_log "记录 envcheck 探测到基线文件..."
  {
    echo "===envcheck==="
    h2n_envcheck_remote_probe h2n_run_server
  } >> "$out" 2>&1 || h2n_warn "envcheck 落盘失败(不影响基线)"

  h2n_log "测服务端出向带宽 + 到 CF 的 RTT (供 BDP 计算; 不可达时降级保守默认并标注)"
  h2n_run_server "bash -s" <<'H2NSPV' 2>&1 | tee -a "$out"
BW=0
for i in 1 2; do
  T=$(curl -s -o /dev/null -w "%{time_total}" "https://speed.cloudflare.com/__down?bytes=52428800" --max-time 60)
  V=$(awk -v t="$T" 'BEGIN{if(t+0>0)printf "%d", 52428800*8/1e6/t; else print 0}')
  [ "$V" -gt "$BW" ] && BW=$V
done
SRC="主动网速测试"
[ "$BW" -eq 0 ] && { BW=100; SRC="保守默认(测速失败或CF不可达)"; }
RTT=""; 
for i in 1 2 3; do
  C=$(curl -s -o /dev/null -w "%{time_connect}" "https://speed.cloudflare.com/" --max-time 10 2>/dev/null)
  M=$(awk -v c="$C" 'BEGIN{if(c+0>0)printf "%.1f", c*1000}')
  [ -n "$M" ] && RTT="$RTT $M"
done
RTT=$(echo $RTT | tr ' ' '\n' | grep -v '^$' | sort -n | sed -n '2p')
TRUST="实测"
[ -z "$RTT" ] && { RTT=100; TRUST="保守默认(连接RTT未测得)"; }
echo "H2N_SRV_BW_MBPS=$BW"
echo "H2N_SRV_BW_SRC=$SRC"
echo "H2N_SRV_RTT_MS=$RTT"
echo "H2N_RTT_TRUST=$TRUST"
exit 0
H2NSPV
  h2n_log "服务端出向带宽/RTT 已写入基线: $(grep -hE '^H2N_SRV_(BW|RTT)' "$out" 2>/dev/null | tr '\n' ' ')"

  h2n_log "采测试床 RTT + 出向带宽(分叉判定: 区分链路被云厂限速 vs 隧道本身)..."
  if [[ -n "${H2N_TB_HOST:-}" ]]; then
    h2n_run_tb "SRV='$H2N_SSH_HOST' bash -s" <<'H2NTB' 2>&1 | tee -a "$out"
echo "===测试床->服务端 RTT==="
ping -c 8 -i 0.2 "$SRV" 2>&1 | grep -E "min/avg/max/mdev|transmitted"
echo "===测试床出向带宽(CF 单流50MB x2)==="
for i in 1 2; do
  T=$(curl -s -o /dev/null -w "%{time_total}" "https://speed.cloudflare.com/__down?bytes=52428800" --max-time 60)
  awk -v t="$T" -v i="$i" 'BEGIN{if(t+0>0)printf "tb_cf_run%d=%.0f Mbps\n", i, 52428800*8/1e6/t; else print "tb_cf_run" i "=未测得(curl失败)"}'
done
H2NTB
    rc=${PIPESTATUS[0]}
    [[ $rc -ne 0 ]] && h2n_warn "测试床带宽测试失败(未装curl/被墙/不可达), 降级"
    local rtt
    rtt="$(grep -oE "min/avg/max/mdev = [0-9./]+" "$out" | tail -1 | awk -F' = ' '{split($2,a,"/"); print a[2]}')"
    append "H2N_RTT_MS=${rtt:-unmeasured}"
  fi

  h2n_log "基线已存: $out"
  echo "$out" > "$H2N_REPORT_DIR/.last_detect"
}
