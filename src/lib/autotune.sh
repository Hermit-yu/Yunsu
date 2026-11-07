#!/usr/bin/env bash
# autotune.sh — 性能闭环: 基准 -> 诊断/算参数 -> 安全应用 -> 重测 -> 评价(不达标自动回滚)
# 红线: 全程零重启; 无测试床时退化为"应用+内核值验证", 不虚报提速
# 依赖: bench.sh 的 h2n_bench(暴露 H2N_AFTER_SINGLE/CONC), sysctl.sh 的 h2n_sysctl_apply_from
# shellcheck disable=all

h2n_autotune_read() {
  # 从 bench 文件读数字: 单流取最好一轮(连接预热后), 并发取合计
  local f="${1:-}"
  [[ -n "$f" && -f "$f" ]] || { H2N_AT_SINGLE=""; H2N_AT_CONC=""; return 1; }
  H2N_AT_SINGLE="$(grep -oE '单流_run[0-9]+=[0-9.]+ Mbps' "$f" | cut -d= -f2 | cut -d' ' -f1 | sort -n | tail -1)"
  H2N_AT_CONC="$(grep -oE '并发=[0-9.]+ Mbps' "$f" | head -1 | cut -d= -f2 | cut -d' ' -f1)"
}

h2n_autotune() {
  local out ts bl bl2 a_s a_c verdict
  local H2N_BASE_SINGLE="" H2N_BASE_CONC=""
  ts="$(date +%Y%m%d-%H%M%S)"
  out="$H2N_REPORT_DIR/autotune-$ts.md"
  h2n_log "性能闭环开始: 基准 -> 推荐参数 -> 安全应用 -> 重测 -> 评价(回退>30%自动回滚)"

  # 1) 基准
  if [[ -n "${H2N_TB_HOST:-}" ]]; then
    h2n_log "1/5 基准测试(测试床经隧道拉服务端文件)..."
    if h2n_bench; then
      bl="$(ls -1 "$H2N_REPORT_DIR"/bench-*.txt 2>/dev/null | sort | tail -1)"
      h2n_autotune_read "$bl"
      H2N_BASE_SINGLE="$H2N_AT_SINGLE"; H2N_BASE_CONC="$H2N_AT_CONC"
      h2n_log "基准: 单流=${H2N_BASE_SINGLE:-未测} 并发=${H2N_BASE_CONC:-未测} (单流取最好一轮)"
    else
      h2n_warn "基准测试失败(测试床不可达?), 降级为 应用+内核值验证"
    fi
  else
    h2n_warn "无测试床: 闭环退化为 推荐参数->安全应用->内核值验证(不虚报提速)"
  fi

  # 2) 诊断/算参数
  h2n_log "2/5 按实测数据生成参数..."
  h2n_recommend || { h2n_err "参数生成失败, 闭环终止"; return 1; }

  # 3) 安全应用(用推荐参数; 失败自动回滚原值)
  h2n_log "3/5 安全应用(sysctl 备份->写conf->sysctl -p->逐项验证, 失败自动回滚)..."
  if ! h2n_sysctl_apply_from "$H2N_REPORT_DIR/recommend-latest.conf"; then
    h2n_err "应用失败(已自动回滚原值), 闭环终止"
    return 1
  fi

  # 4) 重测
  if [[ -n "${H2N_TB_HOST:-}" ]]; then
    h2n_log "4/5 重测..."
    if h2n_bench; then
      bl2="$(ls -1 "$H2N_REPORT_DIR"/bench-*.txt 2>/dev/null | sort | tail -1)"
      h2n_autotune_read "$bl2"
      h2n_log "重测: 单流=${H2N_AT_SINGLE:-未测} 并发=${H2N_AT_CONC:-未测}"
    else
      h2n_warn "重测失败, 无法评价提速(保留新参数, 需人工复测)"
    fi
  fi

  # 5) 评价 + 自动回滚判定
  a_s="${H2N_AT_SINGLE:-}"; a_c="${H2N_AT_CONC:-}"
  verdict="未评价(无带宽回归数据)"
  {
    echo "# 性能闭环报告 $(h2n_now)"
    echo
    echo "## 基准(应用前, 单流取最好一轮)"
    echo "单流 = ${H2N_BASE_SINGLE:-未测} Mbps, 并发 = ${H2N_BASE_CONC:-未测} Mbps"
    echo
    echo "## 重测(应用后)"
    echo "单流 = ${a_s:-未测} Mbps, 并发 = ${a_c:-未测} Mbps"
    echo
    if [[ -n "${H2N_BASE_SINGLE:-}" && -n "$a_s" && "${H2N_BASE_SINGLE}" != "0" ]]; then
      verdict="$(awk -v b="$H2N_BASE_SINGLE" -v a="$a_s" 'BEGIN{
        pct = (a-b)/b*100
        if (pct > 10) print "提速(+" sprintf("%.0f", pct) "%), 保留新参数"
        else if (pct > -30) print "回退" sprintf("%.0f", pct) "%, 在容忍范围, 保留新参数(人工可回滚)"
        else print "回退超30%(" sprintf("%.0f", pct) "%), 自动回滚"
      }')"
      echo "## 评价: $verdict"
      echo "$verdict" | grep -q "自动回滚" && echo "AUTO_ROLLBACK=yes" >> "$out"
    else
      verdict="无带宽回归数据, 仅完成参数应用+内核值验证(不虚报提速)"
      echo "## 评价: $verdict"
    fi
    echo
    echo "## 本次生成参数(recommend)"
    grep -vE '^#' "$H2N_REPORT_DIR/recommend-latest.conf" 2>/dev/null
  } > "$out"
  if grep -q "AUTO_ROLLBACK=yes" "$out"; then
    h2n_log "回退超阈值, 自动回滚 sysctl..."
    h2n_sysctl_rollback
  fi
  h2n_log "闭环完成, 报告: $out"
  cat "$out"
}
