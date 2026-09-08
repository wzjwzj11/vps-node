# vps-node

自建 VPS 节点安装脚本：使用官方 SagerNet/sing-box，安装 VLESS-Reality、AnyTLS 和 Hysteria2。

## 协议与端口

- VLESS-Reality：`443/tcp`，TCP 原始流（sing-box 中 `type: vless`，没有 WebSocket/gRPC）。严格说它不是“raw 协议”，而是 VLESS over TCP + Reality。
- AnyTLS：`8443/tcp`
- Hysteria2：`8444/udp`

## 使用

```bash
# 先下载审计，不要盲目执行远程脚本
curl -fLo vps-node.sh https://你的域名/vps-node.sh
less vps-node.sh

# 安装；UUID 自动随机生成，SNI=auto 自动选择 TCP/443 建连延迟最低的候选域名
sudo bash vps-node.sh

# 显式指定参数
sudo env UUID='你的UUID' VLESS_PORT=443 ANYTLS_PORT=8443 HY2_PORT=8444 \
  SNI=www.microsoft.com TAG=my-vps bash vps-node.sh
```

执行后节点信息保存到 `/root/node_info_YYYYMMDD.txt`。脚本只从 GitHub 官方 Release 下载 sing-box，不使用第三方下载器或远程执行代码。

## 管理菜单

直接运行脚本会进入菜单，提供安装/重建、系统更新、sing-box 更新、BBR、状态查看和卸载。

也可以无菜单执行：

```bash
sudo env ACTION=install bash vps-node.sh
sudo env ACTION=update bash vps-node.sh
sudo env ACTION=sb-update bash vps-node.sh
sudo env ACTION=bbr bash vps-node.sh
sudo env ACTION=status bash vps-node.sh
sudo env ACTION=uninstall bash vps-node.sh
```

`ACTION=sb-update` 只替换官方 sing-box 二进制，保留现有节点 UUID、Reality 密钥、密码和端口；更新前会用新二进制校验现有配置，校验失败不会重启服务。

## 伪装域名选择

`SNI=auto` 会从脚本内的候选站点逐个测试 VPS 到其 `TCP/443` 的连接耗时，选择当前测得最低者。它是网络路径延迟选择，不是严格的地理距离，也不保证长期最优。需要固定时直接设置 `SNI=www.microsoft.com` 等候选域名。

## VPS 安全组

必须放行：

- `443/tcp`（VLESS-Reality）
- `8443/tcp`（AnyTLS）
- `8444/udp`（Hysteria2）

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
