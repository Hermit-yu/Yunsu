#!/usr/bin/env bash
# recommend.sh — 用实测数据生成 sysctl 参数(数据驱动, 不写死)
# 数据源: 最近一次 detect 基线(实测带宽/RTT/CPU核/内存)
# 输出: $H2N_REPORT_DIR/recommend-latest.conf (sysctl格式, sysctl.sh 直接读) + 计算过程 md(大白话)
# 降级: 基线缺失/测速失败时用保守默认并明确标注可信度, 不虚构
# shellcheck disable=all

# 读最近一次 detect 基线
h2n_rec_load_baseline() {
  local f
  f="$(cat "$H2N_REPORT_DIR/.last_detect" 2>/dev/null || true)"
  if [[ -z "$f" || ! -f "$f" ]]; then
    h2n_warn "没找到 detect 基线, 先跑: ./h2n-netopt.sh detect"
    return 1
  fi
  # 键值提取: 基线文件是 env 行(远端 heredoc 原样落盘), 用 grep 精确取, 不 source(里面有 === 注释和多值行)
  _g() { grep -E "^$1=" "$f" 2>/dev/null | tail -1 | cut -d= -f2; }
  H2N_BW="$(_g H2N_SRV_BW_MBPS)"
  H2N_BW_SRC="$(_g H2N_SRV_BW_SRC)"
  [[ -z "$H2N_BW_SRC" ]] && H2N_BW_SRC="未测得"
  H2N_RTT="$(_g H2N_SRV_RTT_MS)"
  H2N_RTT_TRUST="$(_g H2N_RTT_TRUST)"
  H2N_CORES="$(_g CPU_CORES)"
  H2N_MEM="$(_g mem_total_mb)"
  H2N_CC="$(_g CC_NOW)"
  # 缺省 + 标注
  [[ "$H2N_BW" =~ ^[0-9]+$ ]] || { H2N_BW=100; H2N_BW_SRC="保守默认(基线无测速)"; }
  [[ "$H2N_RTT" =~ ^[0-9.]+$ ]] || { H2N_RTT=100; H2N_RTT_TRUST="low(未测得, 用保守100ms)"; }
  [[ "$H2N_CORES" =~ ^[0-9]+$ ]] || H2N_CORES=1
  [[ "$H2N_MEM" =~ ^[0-9]+$ ]] || { H2N_MEM=1024; H2N_MEM_SRC="保守默认"; }
  return 0
}

h2n_recommend() {
  h2n_rec_load_baseline || return 1
  local out_conf out_md ts bdp bufcap
  ts="$(date +%Y%m%d-%H%M%S)"
  out_conf="$H2N_REPORT_DIR/recommend-latest.conf"
  out_md="$H2N_REPORT_DIR/recommend-$ts.md"
  local notes=()

  h2n_log "按实测数据生成参数: 带宽=${H2N_BW}Mbps(来源:$H2N_BW_SRC) 延迟=${H2N_RTT}ms(可信度:$H2N_RTT_TRUST) 核=${H2N_CORES} 内存=${H2N_MEM}MB CC=${H2N_CC:-未知}"

  # --- BDP = 带宽 × 延迟 (bytes) = bw_mbps*1e6/8 * rtt_ms/1000 = bw*rtt*125 ---
  bdp="$(awk -v bw="$H2N_BW" -v rtt="$H2N_RTT" 'BEGIN{printf "%.0f", bw*rtt*125}')"
  notes+=("BDP = 带宽 ${H2N_BW}Mbps × 延迟 ${H2N_RTT}ms = ${bdp} 字节 (公式: bw*rtt*125)")

  # --- 缓冲上限: BDP×2 取整, 但按内存封顶 ---
  # 内存余量规则: ≤512MB 封顶 2%内存; 否则 4%内存; 且不低于 512KB
  bufcap="$(awk -v bdp="$bdp" -v mem="$H2N_MEM" 'BEGIN{
    t = bdp*2
    cap = mem*1048576 * (mem<=512 ? 0.02 : 0.04)
    if (cap < 512*1024) cap = 512*1024
    if (t > cap) t = cap
    printf "%.0f", t }')"
  notes+=("缓冲上限 = min(BDP×2=${bdp}x2, 内存$((H2N_MEM>512?4:2))%=${H2N_MEM}MB, 下限512KB) -> ${bufcap} 字节")

  # --- 核数决定队列类参数(单核 shaper 类全避开) ---
  local somaxconn backlog synbacklog portrange conntrack
  if [[ "$H2N_BW" -ge 500 ]]; then
    somaxconn=16384; backlog=16384; synbacklog=2048
    portrange="10000 65535"; conntrack=$((H2N_CORES * 32768)); [[ $conntrack -lt 65536 ]] && conntrack=65536
    notes+=("带宽 ${H2N_BW}Mbps ≥ 500: 队列类拉满(somaxconn=$somaxconn, backlog=$backlog), 端口范围扩大到 65535(出向并发), conntrack=${conntrack}(${H2N_CORES}核×32768, 下限65536)")
  elif [[ "$H2N_BW" -ge 100 ]]; then
    somaxconn=8192; backlog=8192; synbacklog=1024
    portrange="10000 65000"; conntrack=$((H2N_CORES * 16384)); [[ $conntrack -lt 32768 ]] && conntrack=32768
    notes+=("带宽 ${H2N_BW}Mbps 100-500: 队列类中档(somaxconn=$somaxconn), conntrack=${conntrack}")
  else
    somaxconn=4096; backlog=4096; synbacklog=512
    portrange="10000 60000"; conntrack=32768
    notes+=("带宽 ${H2N_BW}Mbps <100: 队列类小档(省资源, somaxconn=$somaxconn), conntrack=${conntrack}")
  fi

  # --- CC 缺失提示(不自动换内核, 只报告) ---
  if [[ "$H2N_CC" != "bbr" ]]; then
    notes+=("注意: 当前 CC=${H2N_CC:-未知}, 不是 bbr — 高带宽场景建议换 bbr 内核或 modprobe, 本工具不自动换内核(零重启红线)")
  fi

  # --- 生成 conf ---
  {
    echo "# hyst2-netopt 数据驱动推荐参数 $(h2n_now)"
    echo "# 依据: 带宽=${H2N_BW}Mbps 延迟=${H2N_RTT}ms BDP=${bdp}字节 核=${H2N_CORES} 内存=${H2N_MEM}MB CC=${H2N_CC:-未知}"
    echo "net.ipv4.tcp_max_syn_backlog = $synbacklog"
    echo "net.core.netdev_max_backlog = $backlog"
    echo "net.ipv4.ip_local_port_range = $portrange"
    echo "net.ipv4.tcp_fin_timeout = 15"
    echo "net.ipv4.tcp_max_tw_buckets = 32768"
    echo "net.ipv4.tcp_rmem = 4096 131072 $bufcap"
    echo "net.ipv4.tcp_wmem = 4096 65536 $bufcap"
    echo "net.core.rmem_max = $bufcap"
    echo "net.core.wmem_max = $bufcap"
    echo "net.netfilter.nf_conntrack_max = $conntrack"
    echo "net.core.somaxconn = $somaxconn"
  } > "$out_conf"

  # --- 计算过程 md(大白话) ---
  {
    echo "# 参数推荐报告 $(h2n_now)"
    echo
    echo "## 输入数据"
    echo "- 带宽 = ${H2N_BW} Mbps (来源: $H2N_BW_SRC)"
    echo "- 延迟 = ${H2N_RTT} ms (可信度: $H2N_RTT_TRUST)"
    echo "- CPU 核 = ${H2N_CORES}, 内存 = ${H2N_MEM} MB, 拥塞控制 = ${H2N_CC:-未知}"
    echo
    echo "## 计算过程"
    local n
    for n in "${notes[@]}"; do echo "- $n"; done
    echo
    echo "## 生成参数"
    grep -vE '^#' "$out_conf"
    echo
    echo "## 可信度标注"
    [[ "$H2N_BW_SRC" == *保守* || "$H2N_RTT_TRUST" == *low* ]] && echo "- 部分输入为保守默认(测速/RTT未真实测得), 结果偏保守, 测速恢复后重跑 detect 刷新" || echo "- 全部输入为实测值"
  } > "$out_md"

  h2n_log "推荐参数已生成: $(basename "$out_conf") (计算过程: $(basename "$out_md"))"
  grep -vE '^#' "$out_conf" | head -12
  echo "$out_md"
  return 0
}
