# vps-singbox-duo

生产级 sing-box 部署与调优实战手册（sing-box v1.14.4 零弃用语法），附流量限制功能。

- **单进程无面板**：常驻内存仅 ~20MB，没有面板进程。
- **四方案一键部署**：VLESS + REALITY、Cloudflare CDN、Hysteria 2、纯内核调优。
- **流量限制**：安装时设定每月限额（9999=不限），超限自动停服，下月 1 号自动恢复。
- **强校验**：写入配置后先跑 `sing-box check`，校验不过不启动服务。

> 本仓库基于 [CatEacc/vps-singbox-runbook](https://github.com/CatEacc/vps-singbox-runbook)（MIT 协议）：安装脚本与客户端模板来自上游，仅增加流量限制功能（安装时问限额、nftables 计数、cron 监控、超限自动停服），其余逻辑保持上游原样。LICENSE 文件为上游原版 MIT 协议。

---

## 快速开始

要求：Debian / Ubuntu（amd64 / arm64）、root、能访问 GitHub releases。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/duo-yy/vps-singbox-duo/main/singbox.sh)
```

按提示选 `1`～`5`，再输入每月流量限额（GB，`9999`=不限）。装完后屏幕会打印连接信息（分享链接、二维码）。

---

## 四套方案

| 方案 | 协议 | 默认端口 | 说明 |
| --- | --- | --- | --- |
| 1 | VLESS + REALITY + Vision | 443（可自选） | SNI 可测速优选或三选一：`addons.mozilla.org` / `dl.google.com` / 自定义；无需域名、无需证书；支持一键中转家宽 |
| 2 | Cloudflare CDN（VLESS + WS + TLS） | 回源 2053（可自选） | TLS 由 Cloudflare 在边缘终结；本机只监听 WS，需在 CF 侧做两步设置（见下） |
| 3 | Hysteria 2 + UDP 端口跳跃 | UDP 8443（可自选） | 跳跃段 20000-50000 由 iptables 重定向到监听端口；自签证书，客户端需跳过验证或填指纹 |
| 4 | 纯内核调优 | — | 不装 sing-box，只做系统调优 |
| 5 | 导出节点链接 | — | 只读：从现有配置导出分享链接与 Hy2 公钥指纹 |

方案 1-3 安装时自动做一遍内核调优（阶段一）。

### 方案 2 的 Cloudflare 设置（必须手动做）

1. 域名 A 记录指向 VPS 公网 IP，开启小黄云（代理）。
2. SSL/TLS 模式选 **灵活**（Flexible）。
3. 客户端用域名连接，端口填 **443**（Cloudflare 入口），不是 2053；2053 只是回源端口。

### 方案 4 的调优内容

- BBR + FQ（内核不支持 BBR 时自动跳过并提示）
- 网络缓冲区按内存分档：≤700MB 用 16MB、700MB–1.5GB 用 32MB、>1.5GB 用 64MB
- 无 Swap 时新建 1GB Swap
- 禁 MPTCP、Fail2ban（保护 SSH）、Journald 收敛到 50M

---

## 流量限制（本仓库增加的功能）

### 安装时设定

脚本运行时会问每月流量限额（GB）：

- 输入 `1`～`9998`：部署监控，超限自动停服。
- 输入 `9999`（或更大）：不限，不部署监控；如之前部署过限额，这次选 9999 会清理旧的限额配置。

### 工作原理

1. **计数**：nftables 在 `inet singbox_quota` 表里按监听端口双向计数——进方向 `dport` + 出方向 `sport`，两者相加就是节点总流量。
2. **累计**：cron 每 5 分钟跑一次 `quota-monitor.sh`，每次读取计数器与上次的差值，累加进 `/var/lib/sing-box-quota/usage.json`（含当月已用字节和月份）。
3. **超限**：当月用量达到限额时自动 `systemctl stop sing-box`，并写停用标记；之后即使手动启动，下次检查（5 分钟内）也会再次停服。
4. **月结**：每月 1 号 00:00 的 cron 跑 `--reset` 清零并恢复服务；监控脚本检测到月份变化时也会自动重置并恢复（双保险）。

### 管理命令

```bash
quota-monitor.sh status     # 查看当月用量、限额、剩余与服务状态
quota-monitor.sh --reset    # 手动清零当月用量并恢复服务
quota-monitor.sh --restore  # 手动恢复服务（不清零；仍超限会在下次检查时再次停服）
```

日志在 `/var/log/sing-box-quota.log`，只记事件（超限停服、月结恢复、手动操作），不刷屏。

### 诚实说明（限制）

- **按端口总量统计，不按用户区分**：一个监听端口上所有用户的流量都算在一起；多用户共用一个端口时，限额是全节点共用的，不是每人一份。
- **多节点共用一个总限额**：同一台机上再装一个节点时，新节点的端口会并进计数列表，最近一次输入的限额对所有端口的总量生效。
- **重启后计数器会清零**：nftables 计数器不持久化，但监控按“差值累计”，重启后从 0 重新累计，状态文件里的当月总量不受影响；重启到下次检查之间最多 5 分钟的流量可能漏计。
- **停服后重启有窗口**：机器重启后服务会先启动，最多 5 分钟后监控发现仍超限再停服。
- **需要 nftables + cron + systemd**：安装脚本会装好并持久化规则（写进 `/etc/nftables.d/sb-quota.nft`，并确保 nftables 服务开机加载）；不要手动删 `singbox_quota` 表，否则监控读不到数会报错退出、不断重试但不改状态。

---

## 客户端模板（client.json，来自上游）

上游附带的完整客户端配置，适配 Apple SFI/SFM、Android SFA、Windows/Linux。里面的服务器地址、UUID、密码、证书指纹都是占位符，先替换成安装信息里的真实值再导入：

- **入站**：TUN（自动路由）+ 混合代理只监听 `127.0.0.1:7890`，不向公网暴露端口。
- **零泄露 Fake-IP DNS**：国内域名走 `dns-direct`（阿里 DoH），海外走 `dns-fakeip` + `dns-remote`（CF DoH），`strategy: ipv4_only` 杜绝脏 IPv6。
- **分流**：AI（OpenAI / Claude / Gemini）与流媒体（Netflix / TikTok）走专用 selector，国内直连，其余走默认代理；出站用 selector，可在客户端里切换节点。
- **家宽落地**：模板里有“纯净家宽出口”出站（经前置优化机 `detour` 到住宅 SS-2022），需要你自己有住宅出口才用得上；没有就不用管它，默认代理走前置优化机。
- **Hysteria 2**：模板已带端口跳跃字段（`server_ports: 20000-50000`，`hop_interval: 30s`），与服务端跳跃段对齐；证书是安装时生成的自签证书，模板里写了占位指纹，讲究验证的话，把安装信息里的 SHA256 指纹填进去。

导入前先校验（占位符要先替换成真实值，否则校验会报格式错）：

```bash
sing-box check -c client.json
```

---

## 常用运维命令

```bash
# 校验配置语法（零报错无输出即通过）
sing-box check -c /etc/sing-box/config.json

# 查看服务状态与实时日志
systemctl status sing-box
journalctl -u sing-box -n 50 --no-pager

# 重启生效
systemctl restart sing-box

# 流量用量
quota-monitor.sh status

# 查看 sing-box 版本
sing-box version
```

---

## 卸载

```bash
systemctl stop sing-box
systemctl disable sing-box
rm -f /etc/systemd/system/sing-box.service
rm -rf /etc/sing-box /usr/local/bin/sing-box /usr/local/bin/quota-monitor.sh
rm -rf /var/lib/sing-box-quota /var/log/sing-box-quota.log
crontab -l | grep -v "quota-monitor.sh" | crontab -
nft delete table inet singbox_quota
rm -f /etc/nftables.d/sb-quota.nft
systemctl daemon-reload
```

---

## 常见问题

- **安装时端口被占用**：先 `ss -ltnp` 看是谁占了，换个端口重装。
- **BBR 显示不支持**：容器或老内核常见，相关调优会跳过，不影响 sing-box 运行。
- **Cloudflare 方案连不上**：先确认小黄云开了、SSL 模式是灵活、客户端端口填 443；再看 VPS 上 `ss -ltn` 有没有监听 2053。
- **Hysteria 2 客户端报证书错**：自签证书是预期的，客户端开跳过验证，或用安装信息里的 SHA256 指纹做验证。
- **流量统计和面板对不上**：监控只统计监听端口的双向流量；中转、直连、DNS 等流量不算在内，少量误差正常。
- **超限停服后想立刻恢复**：`quota-monitor.sh --restore`（不清零，仍超限会再停）；或 `--reset` 清零后恢复。
- **`sing-box check` 报错**：先看报错行；不要手动改 `/etc/sing-box/config.json` 后直接重启——改完先 `sing-box check -c` 通过再 `systemctl restart sing-box`。

---

## 免责声明

本项目及脚本仅供 Linux 服务器性能调优、网络协议研究与合规技术学习使用，请遵守当地法律法规。
