# vps-node

自建 VPS 节点安装脚本：使用官方 SagerNet/sing-box，安装 VLESS-Reality、AnyTLS 和 Hysteria2。

## 协议与端口

- VLESS-Reality：`443/tcp`，TCP 原始流（sing-box 中 `type: vless`，没有 WebSocket/gRPC）。严格说它不是“raw 协议”，而是 VLESS over TCP + Reality。
- AnyTLS：`8443/tcp`，使用 Reality，不需要自签证书和 `insecure=1`
- Hysteria2：随机高位 `udp` 端口（默认范围 `20000-65535`，每次重建时重新选择空闲端口）

## 一键安装

公开仓库可以直接使用固定版本一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wzjwzj11/vps-node/v1.0.12/vps-node.sh)
```

也可以使用 `main` 获取最新脚本：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/wzjwzj11/vps-node/main/vps-node.sh)
```

推荐首次安装使用固定版本；确认新版本稳定后，再在 VPS 菜单中选择“更新本机脚本”。粘贴命令时只复制纯 URL，不要包含网页或聊天界面附加的 `@url:`、反引号等标记。

## 使用

```bash
# 先下载审计，不要盲目执行远程脚本
curl -fLo vps-node.sh https://raw.githubusercontent.com/wzjwzj11/vps-node/v1.0.12/vps-node.sh
less vps-node.sh

# 安装；UUID 自动随机生成，SNI=auto 自动选择 TCP/443 延迟最低的候选域名
sudo bash vps-node.sh

# 显式指定参数
sudo env UUID='你的UUID' VLESS_PORT=443 ANYTLS_PORT=8443 HY2_PORT=auto SUB_PORT=2096 \
  SNI=www.microsoft.com TAG=my-vps bash vps-node.sh
```

执行后节点信息保存到 `/root/node_info_YYYYMMDD.txt`。脚本只从 GitHub 官方 Release 下载 sing-box，不使用第三方下载器或远程执行代码。

## 新 VPS 推荐操作顺序

拿到新 VPS 后，按以下顺序操作：

```text
1. 查看 VPS 基础状态
2. 更新系统软件包
3. 开启 BBR
4. 网络参数优化（保守）
5. 网络测速
6. CSV Reality 扫描/修改域名
7. 安装/重建节点配置
8. 查询节点信息
9. 更新 sing-box
10. 更新本机脚本
11. 恢复网络参数
12. 卸载 sing-box
```

说明：

1. 先确认系统、架构、内存、公网 IP、内核和端口情况。
2. 更新系统软件包，减少旧依赖和安全更新遗漏。
3. 开启 BBR；如果当前内核不支持，脚本会提示而不会强行更换内核。
4. 应用保守网络参数优化（可选）。
5. 网络测速，了解 VPS 到不同线路的真实下载速度。
6. 在本地扫描 VPS IP、上传 CSV，在 VPS 上批量检测并选择 Reality 域名。
7. 安装节点，`SNI=auto` 会重新测量并选择 TLS 握手中位延迟较低的候选目标，HY2 自动选择空闲高位 UDP 端口。
8. 查询节点信息，复制 VLESS、AnyTLS、Hysteria2 链接，并确认服务和监听端口。

- `4. 网络参数优化（保守）`：在不更换内核、不安装第三方工具的前提下，应用 BBR+FQ、适度 TCP 缓冲区、MTU 探测和 Fast Open
- `5. 网络测速`：测试多个独立下载地址，显示 HTTP 状态、实际收到字节数和平均下载速度；单个测速站失败不会中断其他测试
- `8. 查询节点信息` 会同时显示三个独立节点链接和私有订阅地址；客户端添加订阅后，后续刷新即可同步最新三个节点链接
- `11. 恢复网络参数`：删除本脚本的网络优化 drop-in，并恢复执行前保存的参数；BBR 配置本身不删除

首次执行脚本后会自动创建：

```text
/usr/local/bin/sb
```

以后在 VPS 上直接输入：

```bash
sb
```

即可重新打开管理菜单。`sb` 启动时会从固定版本 `v1.0.0` 的公开 Raw 地址下载脚本，避免 `main` 分支被意外修改影响现有 VPS。升级到新版本后，重新执行新版本安装命令即可更新快捷命令。


也可以无菜单执行：

```bash
sudo env ACTION=install bash vps-node.sh
sudo env ACTION=update bash vps-node.sh
sudo env ACTION=sb-update bash vps-node.sh
sudo env ACTION=bbr bash vps-node.sh
sudo env ACTION=status bash vps-node.sh
sudo env ACTION=scan bash vps-node.sh
sudo env ACTION=script-update bash vps-node.sh
sudo env ACTION=uninstall bash vps-node.sh
```

`ACTION=script-update` 从公开仓库的 `main` 下载最新脚本，先检查文件非空、Shell 语法和版本标记，全部通过后才替换 `/usr/local/bin/vps-node.sh`；失败时保留旧版本。

`ACTION=sb-update` 只替换官方 sing-box 二进制，保留现有节点 UUID、Reality 密钥、密码和端口；更新前会用新二进制校验现有配置，校验失败不会重启服务。
可自定义测速地址（逗号分隔，建议使用你信任的文件服务器）：

```bash
SPEEDTEST_URLS='https://speed.cloudflare.com/__down?bytes=10000000,http://ash-speed.hetzner.com/100MB.bin' ACTION=speed-test bash vps-node.sh
```


## 订阅地址

安装/重建节点后会生成一个带随机令牌的订阅地址，例如：

```text
http://VPS_IP:2096/sub/随机令牌
```

订阅内容是三个节点的 Base64 列表：

- VLESS-Reality
- AnyTLS-Reality
- Hysteria2

客户端只需添加一次订阅，之后在 VPS 上修改 Reality 域名或重建节点后，客户端刷新订阅即可获得当前链接。重建节点会重新生成密码/密钥，旧订阅内容会随之更新。

订阅服务监听 `SUB_PORT`，默认 `2096/tcp`。Oracle Cloud 还需要在 OCI Security List/NSG 放行该端口。订阅令牌相当于访问凭据，不要公开分享；如泄露，可删除 `/var/lib/vps-node/subscription/token` 后重新运行安装生成新令牌。


新的菜单 `6. CSV Reality 扫描/修改域名` 不再从 VPS 直接扫描 VPS IP。推荐流程是：

1. 在本地 Windows 运行 RealiTLScanner，扫描甲骨文 VPS 的公网 IP；
2. 生成 CSV；
3. 通过 SSH/SCP 上传到 VPS；
4. VPS 自动下载 ARM64 RealityChecker；
5. 运行 `reality-checker csv` 批量检测；
6. 选择目标域名；
7. 备份并修改 VLESS-Reality、AnyTLS-Reality 的 SNI；
8. 运行 `sing-box check`，重启服务；失败会恢复原配置。

本地工具脚本：

```text
tools/reality-scan-upload.ps1
```

在 PowerShell 中运行（`SshTarget` 例如 `root@你的VPS_IP`）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\reality-scan-upload.ps1 `
  -VpsIp "你的VPS公网IP" `
  -SshTarget "root@你的VPS公网IP" `
  -SshKey "D:\Keys\oracle-vps" `
  -RunRemoteCheck
```

如果 VPS 使用密码登录，省略 `-SshKey`：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\reality-scan-upload.ps1 `
  -VpsIp "你的VPS公网IP" `
  -SshTarget "root@你的VPS公网IP" `
  -RunRemoteCheck
```

CSV 会上传到：

```text
/root/reality-scan/
```

甲骨文 ARM VPS 使用 RealityChecker `v2.2.3` 的 `linux-arm64` 版本。修改域名后，UUID、Reality 公钥、Short ID 和密码不变，但旧分享链接中的 SNI 失效；请用菜单 `8. 查询节点信息` 获取新链接。RealityChecker 批量结果会检测 TLS 1.3、X25519、HTTP/2、SNI/证书匹配、CDN 和重定向；只有通过检测的域名才列入选择菜单。

现有的直接候选扫描说明：

- TLS 版本
- ALPN（优先协商 h2）
- 证书 CN/Subject
- TCP 建连延迟和 TLS 完整握手延迟（每个目标三次采样取中位数）

默认候选列表不含 `www.cloudflare.com`。也可以自定义：

```bash
sudo env REALITY_TARGETS='www.intel.com,aws.amazon.com,www.apple.com,www.microsoft.com' ACTION=csv-scan bash vps-node.sh
```

扫描器用于筛选 Reality 握手目标，不会修改现有配置。最终是否适合作为 Reality 目标，还应确认目标支持 TLS 1.3、HTTP/2，并由 VPS 到目标的实际网络路径决定。


`SNI=auto` 会先查询 VPS 公网 IP 的国家/地区代码，再查询候选域名解析到的 IP 的国家/地区代码；如果存在同国家/地区候选，只在这些候选中按三次 TLS 完整握手的中位延迟选择最低者。GeoIP 或 DNS 查询失败、或没有同国家/地区候选时，自动回退到全部候选。这里的国家/地区匹配基于公开 GeoIP 和 CDN 当前解析结果，仅作路径选择参考，不是严格地理距离保证。候选站点不包含 `www.cloudflare.com`。

## VPS 安全组

必须放行：

- `443/tcp`（VLESS-Reality）
- `8443/tcp`（AnyTLS）
- `随机高位 udp 端口`（Hysteria2；安装完成后以输出的实际端口和分享链接为准）

如果只需要某个协议，可在安装后关闭对应端口和入站配置。修改配置后先运行：

```bash
sing-box check -c /etc/sing-box/config.json
systemctl restart sing-box
```

## 注意

- AnyTLS 使用 Reality，与 VLESS 共用生成的 Reality 公钥、Short ID 和 SNI；Hysteria2 仍使用自签证书，客户端需要 `insecure=1`。
- Reality 的私钥只保存在 VPS；客户端使用输出的公钥，不能把私钥分享出去。
- 公网发布前请固定 sing-box 版本并自行核对 Release 校验和；默认通过 GitHub API 获取最新版。
- VPS 服务商、所在地区及当地法律法规可能限制代理服务，请自行确认合规性。

## 检查与卸载

```bash
systemctl status sing-box --no-pager
journalctl -u sing-box -n 50 --no-pager
sing-box check -c /etc/sing-box/config.json
```
