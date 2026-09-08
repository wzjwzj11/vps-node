# vps-node

自建 VPS 节点安装脚本：使用官方 SagerNet/sing-box，安装 VLESS-Reality、AnyTLS 和 Hysteria2。

## 协议与端口

- VLESS-Reality：`443/tcp`，TCP 原始流（sing-box 中 `type: vless`，没有 WebSocket/gRPC）。严格说它不是“raw 协议”，而是 VLESS over TCP + Reality。
- AnyTLS：`8443/tcp`
- Hysteria2：随机高位 `udp` 端口（默认范围 `20000-65535`，每次重建时重新选择空闲端口）

## 使用

```bash
# 先下载审计，不要盲目执行远程脚本
curl -fLo vps-node.sh https://你的域名/vps-node.sh
less vps-node.sh

# 安装；UUID 自动随机生成，SNI=auto 自动选择 TCP/443 建连延迟最低的候选域名
sudo bash vps-node.sh

# 显式指定参数
sudo env UUID='你的UUID' VLESS_PORT=443 ANYTLS_PORT=8443 HY2_PORT=auto \
  SNI=www.microsoft.com TAG=my-vps bash vps-node.sh
```

执行后节点信息保存到 `/root/node_info_YYYYMMDD.txt`。脚本只从 GitHub 官方 Release 下载 sing-box，不使用第三方下载器或远程执行代码。

## 快捷命令

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

`ACTION=sb-update` 只替换官方 sing-box 二进制，保留现有节点 UUID、Reality 密钥、密码和端口；更新前会用新二进制校验现有配置，校验失败不会重启服务。

## Reality 目标扫描

菜单中的 `6. Reality 目标扫描` 会检测候选域名的：

- TCP/443 是否可连接
- TLS 版本
- ALPN（优先协商 h2）
- 证书 CN/Subject
- TCP 建连延迟

默认候选列表不含 `www.cloudflare.com`。也可以自定义：

```bash
sudo env REALITY_TARGETS='www.intel.com,aws.amazon.com,www.apple.com,www.microsoft.com' ACTION=scan bash vps-node.sh
```

扫描器用于筛选 Reality 握手目标，不会修改现有配置。最终是否适合作为 Reality 目标，还应确认目标支持 TLS 1.3、HTTP/2，并由 VPS 到目标的实际网络路径决定。


`SNI=auto` 会从脚本内的候选站点逐个测试 VPS 到其 `TCP/443` 的连接耗时，选择当前测得最低者。候选站点不包含 `www.cloudflare.com`，当前包括 Microsoft、Apple、Google、Bing、Yahoo。它是网络路径延迟选择，不是严格的地理距离，也不保证长期最优。需要固定时直接设置 `SNI=www.microsoft.com` 等候选域名。

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

- AnyTLS 和 Hysteria2 当前使用自签证书，客户端需要启用 `insecure=1`；生产环境更推荐给 VPS 绑定域名并换成受信任证书。
- Reality 的私钥只保存在 VPS；客户端使用输出的公钥，不能把私钥分享出去。
- 公网发布前请固定 sing-box 版本并自行核对 Release 校验和；默认通过 GitHub API 获取最新版。
- VPS 服务商、所在地区及当地法律法规可能限制代理服务，请自行确认合规性。

## 检查与卸载

```bash
systemctl status sing-box --no-pager
journalctl -u sing-box -n 50 --no-pager
sing-box check -c /etc/sing-box/config.json
```
