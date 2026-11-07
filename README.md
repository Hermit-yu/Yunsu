# YunSu — 云速 VPS 隧道 + 网络全面提速工具(全发行版通用)

蒸馏自 2026-11-08 对 139.28.232.33(服务端)/45.62.110.201(测试床) 的实机调优全过程。
单核小内存 VPS 上 hyst2 单流 57~64 → **131~178 Mbps**，全程零重启。

## 核心结论(调优优先级)
1. **hyst2 拥塞控制配置 > 内核 sysctl**。`up_mbps/down_mbps` 设值会禁掉客户端 BBR CC，两边都去掉是最大杠杆(T6→T7 实测翻倍)。
2. 单核不是墙：全速下载时 sing-box CPU 仅 10~40%，load 1.1 未过载。瓶颈在 CC/带宽层。
3. 单流口径：多流在单核+BBR 下互抢，实用以单流 100MB 为评估基准。
4. GSO：quic-go 内核≥5 自动启用，GODEBUG 开关无效、无需特编二进制。
5. 内核层收益：4 并发 TCP 2151→5276Mbps，重传 10%→4~6%。

## 目录
```
h2n-netopt.sh            主入口(菜单+CLI, 函数定义在前入口在后)
hyst2-netopt.conf        本机参数(服务端/测试床 SSH、hyst2 端口域名、测试床参数)
hyst2-netopt.conf.example 样例
src/lib/
  common.sh    路径/配置/SSH封装(缺模块立即退出码2)
  envcheck.sh  全发行版探测: 系统版本/root/包管理器/防火墙后端/工具缺失装法建议
  detect.sh    只读基线: CPU/内核/CC/sysctl现值/90-/99-conf清单/RTT/带宽分叉判定
  sysctl.sh    安全6步: 备份原值→扫同键冲突→写90-conf(staging上载)→sysctl -p只加载自己→逐项验证→失败自动回滚
  singbox.sh   安装+生成配置(密码本地注入不落远端明文)+systemd+logrotate+check+重启+端口/证书验证
  testbed.sh   服务端临时线程文件服务(ufw/firewalld/iptables 自适应, 只放行测试床IP)+测试床客户端
  bench.sh     单流100MBxN + 并发 + 服务端CPU余量采样(判瓶颈是算力还是CC层)
  clean.sh     一键拆测试床(不动sing-box本体/sysctl)
  report.sh    执行报告(回滚点+验证命令)
reports/ backups/  运行产物
```

## 用法
```bash
./h2n-netopt.sh detect       # 只读: 系统/root/包管理器/防火墙自动探测 + 基线(含出向带宽/RTT实测, 供BDP计算)
./h2n-netopt.sh recommend    # 数据驱动: 按最近detect实测数据算sysctl参数, 计算过程落reports/recommend-*.md
./h2n-netopt.sh apply        # 实装 sysctl(默认固定参数)+sing-box(默认需确认, --yes 跳过)
./h2n-netopt.sh autotune --yes [--force]  # 性能闭环: 基准->生成参数->安全应用->重测->评价(回退>30%自动回滚)
./h2n-netopt.sh testbed      # 建测试床(服务端文件服务+测试床客户端)
./h2n-netopt.sh bench        # 性能测试(单流+并发+CPU采样)
./h2n-netopt.sh clean        # 拆测试床
./h2n-netopt.sh rollback     # 回滚本次实装(sysctl原值写回+删90-conf, sing-box回bak重启)
./h2n-netopt.sh full-clean   # 全拆
./h2n-netopt.sh report       # 执行报告
./h2n-netopt.sh              # 无参数进菜单
```
选项: `--yes`(免确认) `--force`(同键冲突放行, 默认阻断) `--conf <path>`(自定义配置)

### 数据驱动 autotune 闭环说明
1. 基准: 测试床经隧道拉服务端文件(单流取最好一轮, 避预热误差)
2. 生成参数: 读最近 detect 基线的实测带宽/RTT/核数/内存, BDP=bw×rtt×125, 缓冲=min(BDP×2, 内存2~4%上限, 下限512KB), 队列类按带宽三档(≥500/100-500/<100)
3. 安全应用: 备份原值->冲突扫描->staging上载->sysctl -p只加载自己->逐项内核验证->失败自动回滚
4. 重测同方法, 评价: 提速>10% 保留; -30%~+10% 保留(人工可回滚); 回退>30% 自动回滚写回原值
5. 无测试床时闭环退化为 生成参数->安全应用->内核值验证, 明确标注"不虚报提速"

## 安全保证
- **零重启**: 全程无 reboot, 只 systemctl restart 单一服务
- **回滚点**: sysctl 原值备份 `backups/sysctl-backup-*`; sing-box 配置备份 `/etc/sing-box/hyst2.json.bak-*`
- **密码不落远端明文**: 仅经 ssh 变量注入客户端配置, 服务端 conf 备份为带密码文件(0600 由 sing-box 用户权限保证)
- **同键冲突默认阻断**: sysctl 层先扫 90-/99- 他人 conf(字典序后者开机覆盖本脚本), 有冲突默认拒绝写入, `--force` 显式放行(自担风险); 防"当场验证过但开机丢"的假成功
- **执行机隔离**: sysctl conf 经 staging 上载, 不写执行机自身 /etc/sysctl.d

## 换发行版
envcheck 自动识别 apt/dnf/yum/zypper/apk/pacman, 缺工具给对应装法; 防火墙 ufw/firewalld/nftables/iptables 自适应; 文件放 /opt(不占小 tmpfs); 内核 BBR 缺失时提示装 bbr 内核或保持 cubic(脚本不强行换内核)。

## 已验证(2026-11-08)
|- 9 模块 + 2 新(recommend/autotune) bash -n + shellcheck -S error 全绿
|- 数据驱动: 139 实测 bw=2137Mbps/rtt=14.9ms → 自动生成推荐参数, 内核逐项验证一致
|- 性能闭环 autotune 真跑: 基准 154.4→重测 144.9(-6%, 容忍范围内保留新参数), sysctl 安全应用+回滚验证通过
|- sysctl 同键冲突阻断真跑: 139 上有手工 90-netopt.conf 同键, 无 --force 时自动拒绝写入; --force 放行并自动回滚写回
|- 全机扫描后 139 收尾安全: 8890+ufw规则已拆、45端代理可保留、hyst2 服务 active、sysctl 实测值不变
