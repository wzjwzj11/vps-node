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
sudo env UUID='你的UUID' VLESS_PORT=443 ANYTLS_PORT=8443 HY2_PORT=auto \
  SNI=www.microsoft.com TAG=my-vps bash vps-node.sh
```

执行后节点信息保存到 `/root/node_info_YYYYMMDD.txt`。脚本只从 GitHub 官方 Release 下载 sing-box，不使用第三方下载器或远程执行代码。

## 新 VPS 推荐操作顺序

拿到新 VPS 后，按以下顺序操作：

```text
1. 查看 VPS 基础状态
2. 更新系统软件包
3. 开启 BBR
4. Reality 目标扫描
5. 安装/重建节点配置
6. 查询节点信息
```

说明：

1. 先确认系统、架构、内存、公网 IP、内核和端口情况。
2. 更新系统软件包，减少旧依赖和安全更新遗漏。
3. 开启 BBR；如果当前内核不支持，脚本会提示而不会强行更换内核。
4. 扫描 Reality 候选目标，观察 TLS、ALPN、证书和重复测量延迟。
5. 安装节点，`SNI=auto` 会重新测量并选择 TLS 握手中位延迟较低的候选目标，HY2 自动选择空闲高位 UDP 端口。
6. 查询节点信息，复制 VLESS、AnyTLS、Hysteria2 链接，并确认服务和监听端口。

- `4. 网络参数优化（保守）`：在不更换内核、不安装第三方工具的前提下，应用 BBR+FQ、适度 TCP 缓冲区、MTU 探测和 Fast Open
- `5. 网络测速`：测试多个独立下载地址，显示 HTTP 状态、实际收到字节数和平均下载速度；单个测速站失败不会中断其他测试
- `10. 恢复网络参数`：删除本脚本的网络优化 drop-in，并恢复执行前保存的参数；BBR 配置本身不删除

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


菜单中的 `6. Reality 目标扫描` 会检测候选域名的：

- TCP/443 是否可连接
- TLS 版本
- ALPN（优先协商 h2）
- 证书 CN/Subject
- TCP 建连延迟和 TLS 完整握手延迟（每个目标三次采样取中位数）

默认候选列表不含 `www.cloudflare.com`。也可以自定义：

```bash
sudo env REALITY_TARGETS='www.intel.com,aws.amazon.com,www.apple.com,www.microsoft.com' ACTION=scan bash vps-node.sh
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
