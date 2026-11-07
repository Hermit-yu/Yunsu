#!/usr/bin/env bash
# envcheck.sh — 全发行版通用前置探测: 系统版本/root/架构/包管理器/防火墙后端/必需工具
# 原则: 探测结果写变量 + 大白话输出, 缺依赖给"哪个包管理器装哪个包"的建议, 不硬套 apt
# shellcheck disable=all

# 远端探测(跑在目标机), 输出键值行供本地解析
h2n_envcheck_remote_probe() {
  # $1 = ssh 封装函数名 (h2n_run_server 或 h2n_run_tb)
  "$1" 'bash -s' <<'H2NEP'
set -u
echo "===系统==="
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "DISTRO_ID=${ID:-unknown}"
  echo "DISTRO_VERSION=${VERSION_ID:-${PRETTY_NAME:-unknown}}"
  echo "DISTRO_PRETTY=${PRETTY_NAME:-unknown}"
else
  echo "DISTRO_ID=unknown"
  cat /proc/sys/kernel/osrelease 2>/dev/null
fi
echo "KERNEL=$(uname -r)"
echo "ARCH=$(uname -m)"
echo "===root==="
echo "UID=$(id -u)"
echo "===包管理器==="
PKG_PM="none"
for pm in apt dnf yum zypper apk pacman; do
  if command -v "$pm" >/dev/null 2>&1; then PKG_PM="$pm"; break; fi
done
echo "PKG_PM=$PKG_PM"
echo "===防火墙后端==="
FW=""
command -v ufw >/dev/null 2>&1 && { ufw status 2>/dev/null | grep -q "Status: active" && FW="ufw"; }
command -v firewall-cmd >/dev/null 2>&1 && [ -z "$FW" ] && { fw=$(firewall-cmd --state 2>/dev/null); [ "$fw" = "running" ] && FW="firewalld"; }
command -v nft >/dev/null 2>&1 && [ -z "$FW" ] && FW="nftables"
command -v iptables >/dev/null 2>&1 && [ -z "$FW" ] && FW="iptables"
[ -z "$FW" ] && FW="none"
echo "FIREWALL=$FW"
echo "===必需工具==="
for t in curl python3 ss openssl git; do
  command -v "$t" >/dev/null 2>&1 && echo "HAS_$t=1" || echo "HAS_$t=0"
done
echo "===CPU/内存==="
echo "CPU_CORES=$(nproc 2>/dev/null || echo 1)"
echo "MEM_TOTAL_MB=$(free -m 2>/dev/null | awk 'NR==2{print $2}')"
echo "===BCC==="
CC_NOW="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
CC_AVAIL="$(cat /proc/net/available_congestion_control 2>/dev/null)"
echo "CC_NOW=$CC_NOW"
echo "CC_AVAILABLE=$CC_AVAIL"
if echo "$CC_AVAIL" | grep -qw bbr || [ "$CC_NOW" = "bbr" ]; then echo "HAS_BBR=1"; else echo "HAS_BBR=0"; fi
H2NEP
}

# 本地(执行机 38)前置检查: root + 必需工具 + conf 存在
h2n_envcheck_local() {
  local ok=0
  # 执行机(38)只需能 ssh + 有 python3 生成 conf; root 不强求(但写 /opt 需要)
  if [[ $(id -u) -ne 0 ]]; then
    h2n_warn "执行机当前非 root(uid=$(id -u)) — 写 /opt/... 与部分操作可能失败; 生产请 root 跑。继续只读探测不受影响。"
  fi
  for t in ssh curl python3; do
    command -v "$t" >/dev/null 2>&1 || { h2n_err "执行机缺必需工具: $t"; ok=1; }
  done
  [[ $ok -eq 1 ]] && return 1
  return 0
}

# 服务端前置(root + 必需工具), 探测失败不退出只降级
h2n_envcheck_server() {
  local probe line
  probe="$(h2n_envcheck_remote_probe h2n_run_server)"
  echo "$probe" | sed 's/^/  [srv] /'
  local rootuid fw
  rootuid="$(echo "$probe" | grep '^UID=' | cut -d= -f2)"
  if [[ "${rootuid:-}" != "0" ]]; then
    h2n_err "服务端 uid=$rootuid 非 root — apply(sysctl/服务/ufw)需要 root。只读 detect 可继续。"
    return 1
  fi
  fw="$(echo "$probe" | grep '^FIREWALL=' | cut -d= -f2)"
  case "$fw" in
    ufw|firewalld|nftables|iptables) : ;;
    none) h2n_warn "服务端没检测到活跃防火墙(ufw/firewalld/nft/iptables) — 放行步骤会跳过, 请人工确认安全组" ;;
  esac
  # 必需工具缺失给建议
  local pm="apt"
  pm="$(echo "$probe" | grep '^PKG_PM=' | cut -d= -f2)"
  local missing
  missing="$(echo "$probe" | grep -E '^HAS_.*=0' | grep -v '^HAS_BBR=0' | sed -E 's/^HAS_//; s/=0$//')"
  if [[ -n "$missing" ]]; then
    local pkgmap
    case "$pm" in
      apt|none)
        pkgmap="curl=apt install curl; python3=apt install python3; ss=apt install iproute2; openssl=apt install openssl; git=apt install git" ;;
      dnf|yum)
        pkgmap="curl=dnf install curl; python3=dnf install python3; ss=dnf install iproute; openssl=dnf install openssl; git=dnf install git" ;;
      zypper)
        pkgmap="curl=zypper install curl; python3=zypper install python3; ss=zypper install iproute2; openssl=zypper install openssl; git=zypper install git" ;;
      apk)
        pkgmap="curl=apk add curl; python3=apk add python3; ss=apk add iproute2; openssl=apk add openssl; git=apk add git" ;;
      *) pkgmap="各工具用本机包管理器装(未识别包管理器)" ;;
    esac
    h2n_warn "服务端缺工具: $(echo $missing | tr '\n' ' ') — 装法($pm): $(echo $pkgmap)"
  fi
  return 0
}

# 测试床前置
h2n_envcheck_tb() {
  if [[ -z "${H2N_TB_HOST:-}" ]]; then
    h2n_warn "未配 H2N_TB_HOST — 跳过测试床, 所有调优测速将不可用(仅做静态安装+sysctl)"
    return 0
  fi
  h2n_envcheck_remote_probe h2n_run_tb | sed 's/^/  [tb]  /'
  return 0
}
