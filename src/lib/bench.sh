#!/usr/bin/env bash
# bench.sh — 性能闭环: 单流(100MB x N轮) + 并发组 + 服务端CPU余量采样
# 结论口径: 单流为准(多流在单核+BBR下互踩); CPU采样决定"瓶颈是算力还是带宽/CC层"
# 输出: 大白话直说 Mbps 数字 + CPU%, 存 reports/bench-<ts>.txt
# shellcheck disable=all

h2n_bench() {
  [[ -n "${H2N_TB_HOST:-}" ]] || { h2n_warn "无测试床, 跳过性能测试(可先 h2n-testbed-setup 建床)"; return 1; }
  local out ts
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$H2N_REPORT_DIR/bench-$ts.txt"
  h2n_log "性能测试: 单流 ${H2N_TB_TEST_MB}MB x ${H2N_TB_RUNS}轮 + ${H2N_TB_CONCURRENCY}并发, 同时采服务端 sing-box CPU..."
  # CPU 采样(服务端, 后台) 与 下载(测试床, 前台) 并行
  ( h2n_bench_cpu_sample "$out" ) &
  local cpid=$!
  # 测试床跑下载
  h2n_run_tb "PP='${H2N_LOCAL_PROXY_PORT:-7890}' SRV='$H2N_SSH_HOST' FSP='$H2N_TB_FILESERV_PORT' MB='${H2N_TB_FILE_MB:-200}' TESTMB='${H2N_TB_TEST_MB:-100}' RUNS='${H2N_TB_RUNS:-3}' CONC='${H2N_TB_CONCURRENCY:-4}' bash -s" >> "$out" 2>&1 <<'H2NBENCH'
set -u
B=$((TESTMB*1048576))
URL="http://$SRV:$FSP/bigfile-${MB}m.bin"
P="http://127.0.0.1:$PP"
mbps() { awk -v b="$1" -v t="$2" 'BEGIN{if(t+0>0)printf "%.1f", b*8/1e6/t; else print 0}'; }
echo "== 单流 ${TESTMB}MB x ${RUNS}轮 =="
for i in $(seq 1 "$RUNS"); do
  T=$(curl -s -o /dev/null -w "%{time_total}" -x "$P" -r 0-$((B-1)) "$URL" --max-time 300)
  echo "  单流_run$i=$(mbps $B $T) Mbps"
done
echo "== ${CONC}并发 各${TESTMB}MB(不重叠区段, 总文件够时) =="
T0=$(date +%s.%N)
i=0
for s in $(seq 0 $((CONC-1))); do
  OFF=$((s*B)); END=$((s*B + B - 1))
  curl -s -o /dev/null -x "$P" -r "$OFF-$END" "$URL" --max-time 300 &
  i=$((i+1))
done
wait
T1=$(date +%s.%N); DT=$(awk "BEGIN{print $T1-$T0}")
echo "  ${CONC}并发=$(mbps $((B*CONC)) $DT) Mbps (${DT}s)"
exit 0
H2NBENCH
  wait "$cpid" 2>/dev/null
  h2n_log "结果已存 $out"
  # 暴露给 autotune 复用(单流取 run1, 并发取合计)
  H2N_AFTER_SINGLE="$(grep -oE '单流_run1=[0-9.]+ Mbps' "$out" | head -1 | cut -d= -f2 | cut -d' ' -f1)"
  H2N_AFTER_CONC="$(grep -oE '并发=[0-9.]+ Mbps' "$out" | head -1 | cut -d= -f2 | cut -d' ' -f1)"
  cat "$out" | grep -E "单流_run|并发=" | head -8
}

# 服务端 CPU 采样: 每2s 一次 x5, 写 bench 文件
h2n_bench_cpu_sample() {
  local out="$1" pid
  sleep 4  # 等下载开始
  pid="$(h2n_run_server "pgrep -f 'sing-box run -c /etc/sing-box/hyst2.json' | head -1")"
  if [[ -z "$pid" ]]; then
    echo "  [CPU采样] 找不到 sing-box 进程, 跳过" >> "$out"
    return 0
  fi
  local i a b
  for i in 1 2 3 4 5; do
    a="$(h2n_run_server "awk '{print \$14+\$15}' /proc/$pid/stat 2>/dev/null")"
    sleep 2
    b="$(h2n_run_server "awk '{print \$14+\$15}' /proc/$pid/stat 2>/dev/null")"
    if [[ -n "$a" && -n "$b" ]]; then
      echo "  CPU采样$i: sing-box=$(awk -v a="$a" -v b="$b" 'BEGIN{printf "%.0f", (b-a)*100/200}')% (100%=单核打满)" >> "$out"
    fi
  done
  local load
  load="$(h2n_run_server "awk '{print \$1}' /proc/loadavg")"
  echo "  整机load=$load (0.5/1核机 load>1 = 过载)" >> "$out"
}
