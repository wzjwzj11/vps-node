#!/usr/bin/env bash
#
# vps-node.sh — 自建节点一键脚本 (sing-box)
# 协议: VLESS-Reality (TCP/443) + AnyTLS (TCP/8443) + Hysteria2 (随机高位 UDP 端口)
# 特点: 只从官方源下载 (SagerNet/sing-box GitHub Releases)，无第三方中转
# 用法: bash <(curl -fsSL <你的脚本地址>)     或     bash vps-node.sh
# 可自定义环境变量(全部可选):
#   UUID=...  VLESS_PORT=443  ANYTLS_PORT=8443  HY2_PORT=auto  SNI=auto  TAG=myserver
#
set -euo pipefail

# ============ 可改默认值 ============
# 留空时由 sing-box 自动生成随机 UUID；不要把真实 UUID 写死进公开脚本
UUID="${UUID:-}"
VLESS_PORT="${VLESS_PORT:-443}"
ANYTLS_PORT="${ANYTLS_PORT:-8443}"
HY2_PORT="${HY2_PORT:-auto}"
SNI="${SNI:-auto}"                 # auto=从候选伪装站中选择 TCP/443 延迟最低者
TAG="${TAG:-vps}"
SB_VER="${SB_VER:-}"              # 留空=自动取最新版
ACTION="${ACTION:-menu}"       # menu / install / update / bbr / status / uninstall
# ====================================

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; NC=$'\033[0m'
info() { echo "${CYN}[*]${NC} $*"; }
ok()   { echo "${GRN}[✓]${NC} $*"; }
warn() { echo "${YLW}[!]${NC} $*"; }
die()  { echo "${RED}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行 (sudo -i 或 root 登录)"

port_in_use() {
  local port="$1" proto="$2"
  if command -v ss >/dev/null 2>&1; then
    if [[ "$proto" == "tcp" ]]; then
      ss -H -ltn 2>/dev/null | awk -v p=":${port}" '$4 ~ p {found=1} END {exit !found}'
    else
      ss -H -lun 2>/dev/null | awk -v p=":${port}" '$5 ~ p {found=1} END {exit !found}'
    fi
  else
    return 1
  fi
}

random_high_port() {
  local candidate
  for _ in $(seq 1 100); do
    candidate="$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')"
    candidate=$((20000 + candidate % 45536))
    if ! port_in_use "$candidate" udp; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "无法找到空闲的随机高位 UDP 端口"
}

choose_sni() {
  [[ "$SNI" == "auto" ]] || return 0
  local best="" best_ms=999999 host ms
  # 不使用 www.cloudflare.com；以 VPS 到候选站 TCP/443 建连耗时作为路径近似
  for host in www.microsoft.com www.apple.com www.google.com www.bing.com www.yahoo.com; do
    ms="$(curl -4sk --connect-timeout 4 --max-time 5 -o /dev/null -w '%{time_connect}' "https://$host/" 2>/dev/null || true)"
    [[ "$ms" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    ms="$(awk -v t="$ms" 'BEGIN { printf "%d", t*1000 }')"
    if (( ms < best_ms )); then best="$host"; best_ms="$ms"; fi
  done
  SNI="${best:-www.microsoft.com}"
  info "伪装域名: $SNI（TCP/443 实测约 ${best_ms}ms；仅作路径延迟参考）"
}

show_status() {
  echo "========== VPS 节点状态 =========="
  . /etc/os-release 2>/dev/null || true
  echo "系统: ${PRETTY_NAME:-unknown}"
  echo "内核: $(uname -r) / 架构: $(uname -m)"
  echo "CPU: $(nproc 2>/dev/null || echo '?') 核 / 内存: $(free -h 2>/dev/null | awk '/^Mem:/{print $3 "/" $2}')"
  echo "IPv4: $(curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo unavailable)"
  echo "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable) / qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)"
  if command -v sing-box >/dev/null 2>&1; then sing-box version | head -1; else echo "sing-box: 未安装"; fi
  systemctl is-active sing-box 2>/dev/null || true
  local status_hy2_port="$HY2_PORT"
  if [[ "$status_hy2_port" == "auto" && -r /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
    status_hy2_port="$(jq -r '.inbounds[] | select(.tag=="hy2") | .listen_port' /etc/sing-box/config.json 2>/dev/null || echo auto)"
  fi
  for pair in "${VLESS_PORT}:tcp" "${ANYTLS_PORT}:tcp" "${status_hy2_port}:udp"; do
    p="${pair%%:*}"; proto="${pair##*:}"
    port_in_use "$p" "$proto" && echo "端口 $p/$proto: 已监听" || echo "端口 $p/$proto: 未监听"
  done
}

create_shortcut() {
  local target=/usr/local/bin/sb
  local raw_url="https://raw.githubusercontent.com/wzjwzj11/vps-node/v1.0.2/vps-node.sh"
  cat > "$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
RAW_URL="$raw_url"
TMP_SCRIPT="\$(mktemp /tmp/vps-node.XXXXXX.sh)"
trap 'rm -f "\$TMP_SCRIPT"' EXIT
curl -fsSL --retry 3 --connect-timeout 10 "\$RAW_URL" -o "\$TMP_SCRIPT"
chmod 700 "\$TMP_SCRIPT"
exec bash "\$TMP_SCRIPT" "\$@"
EOF
  chmod 755 "$target"
  hash -r 2>/dev/null || true
  ok "快捷命令已设置: 输入 sb 可重新打开 VPS 节点管理脚本"
}

create_shortcut

if [[ "$ACTION" == "menu" ]]; then
  while true; do
    echo
    echo "========== VPS 节点管理 =========="
    echo "1. 安装/重建节点配置"
    echo "2. 更新系统软件包"
    echo "3. 更新 sing-box"
    echo "4. 开启 BBR"
    echo "5. 查看系统、服务和端口状态"
    echo "6. 卸载 sing-box"
    echo "0. 退出"
    read -r -p "请选择: " choice
    case "$choice" in
      1) ACTION=install; break ;;
      2) ACTION=update; break ;;
      3) ACTION=sb-update; SB_VER=""; break ;;
      4) ACTION=bbr; break ;;
      5) show_status; continue ;;
      6) ACTION=uninstall; break ;;
      0) exit 0 ;;
      *) echo "无效选择" ;;
    esac
  done
fi

# 管理动作：不重建节点配置
case "$ACTION" in
  update)
    if command -v apt-get >/dev/null; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    elif command -v dnf >/dev/null; then dnf upgrade -y
    elif command -v yum >/dev/null; then yum update -y
    elif command -v apk >/dev/null; then apk update && apk upgrade
    else die "未识别的包管理器"; fi
    systemctl restart sing-box 2>/dev/null || true
    echo "系统更新完成；sing-box 若需更新请执行 ACTION=sb-update bash $0"; exit 0 ;;
  status)
    show_status; exit 0 ;;
  sb-update)
    # 继续执行下方官方二进制更新流程
    ;;
  bbr)
    command -v sysctl >/dev/null || die "缺少 sysctl"
    grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf 2>/dev/null || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p
    echo "当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"; exit 0 ;;
  uninstall)
    systemctl disable --now sing-box 2>/dev/null || true
    rm -f /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
    rm -rf /etc/sing-box
    systemctl daemon-reload
    echo "sing-box 已卸载（不会删除系统包和防火墙规则）"; exit 0 ;;
  install|sb-update) ;;
  *) die "ACTION 只能是 menu/install/sb-update/update/bbr/uninstall" ;;
esac


ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  SB_ARCH="amd64" ;;
  aarch64|arm64) SB_ARCH="arm64" ;;
  armv7l)        SB_ARCH="armv7" ;;
  *) die "不支持的架构: $ARCH" ;;
esac

if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID="${ID:-}"; else OS_ID=""; fi
info "系统: ${PRETTY_NAME:-unknown} / 架构: $ARCH"

PKG=""
command -v apt-get >/dev/null && PKG="apt"
command -v dnf     >/dev/null && PKG="dnf"
command -v yum     >/dev/null && [[ -z "$PKG" ]] && PKG="yum"
command -v apk     >/dev/null && [[ -z "$PKG" ]] && PKG="apk"

install_pkgs() {
  case "$PKG" in
    apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf|yum) $PKG install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *)   die "未识别的包管理器，请手动安装: $*" ;;
  esac
}

NEED=()
for c in curl tar openssl jq; do command -v "$c" >/dev/null || NEED+=("$c"); done
# jq 在 alpine 叫 jq, 其它同名; openssl 必需(生成自签证书)
[[ ${#NEED[@]} -gt 0 ]] && { info "安装依赖: ${NEED[*]}"; install_pkgs "${NEED[@]}"; }

[[ "$HY2_PORT" == "auto" ]] && HY2_PORT="$(random_high_port)"
choose_sni

# ---------- 1. 安装 sing-box (官方 GitHub Release) ----------
for pair in "${VLESS_PORT}:tcp" "${ANYTLS_PORT}:tcp" "${HY2_PORT}:udp"; do
  p="${pair%%:*}"; proto="${pair##*:}"
  if port_in_use "$p" "$proto" && ! systemctl is-active --quiet sing-box 2>/dev/null; then
    warn "端口 $p/$proto 已被其他服务监听；后续 sing-box 启动可能失败"
  fi
done

INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/sing-box"
mkdir -p "$CONF_DIR"

if [[ -z "$SB_VER" ]]; then
  info "查询 sing-box 最新版本..."
  SB_VER="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)"
  [[ -n "$SB_VER" && "$SB_VER" != "null" ]] || die "获取版本失败，可手动指定: SB_VER=v1.11.0 bash $0"
fi
SB_VER_NOV="${SB_VER#v}"
ok "sing-box 版本: $SB_VER"

if command -v sing-box >/dev/null && sing-box version 2>/dev/null | grep -q "$SB_VER_NOV"; then
  ok "sing-box 已是最新，跳过下载"
else
  TARBALL="sing-box-${SB_VER_NOV}-linux-${SB_ARCH}.tar.gz"
  URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/${TARBALL}"
  info "下载: $URL"
  TMPD="$(mktemp -d)"
  curl -fSL --retry 3 -o "$TMPD/$TARBALL" "$URL" || die "下载失败"
  tar -xzf "$TMPD/$TARBALL" -C "$TMPD"
  install -m 0755 "$TMPD/sing-box-${SB_VER_NOV}-linux-${SB_ARCH}/sing-box" "$INSTALL_DIR/sing-box"
  rm -rf "$TMPD"
  ok "已安装到 $INSTALL_DIR/sing-box"
fi
sing-box version
if [[ "$ACTION" == "sb-update" ]]; then
  [[ -s "$CONF_DIR/config.json" ]] || die "未找到现有配置，请先执行 ACTION=install"
  sing-box check -c "$CONF_DIR/config.json" || die "现有配置与此 sing-box 版本不兼容，未重启服务"
  systemctl restart sing-box
  systemctl is-active --quiet sing-box || die "sing-box 更新后启动失败，请查看 journalctl -u sing-box"
  ok "sing-box 已更新，原有 UUID、密钥、端口和配置保持不变"
  exit 0
fi

# ---------- 2. 生成密钥 ----------
info "生成 UUID / Reality 密钥对 / Hysteria2 密码 / 自签证书..."
if [[ -z "$UUID" ]]; then
  UUID="$(sing-box generate uuid)"
fi
[[ "$UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]] || die "UUID 格式无效: $UUID"
KEYS="$(sing-box generate reality-keypair)"
PRIV_KEY="$(awk '/PrivateKey/{print $2}' <<<"$KEYS")"
PUB_KEY="$(awk '/PublicKey/{print $2}' <<<"$KEYS")"
SHORT_ID="$(openssl rand -hex 8)"
ANYTLS_PASS="$(openssl rand -hex 18)"
HY2_PASS="$(openssl rand -hex 18)"
[[ -n "$PRIV_KEY" && -n "$PUB_KEY" ]] || die "Reality 密钥生成失败"

# hy2 自签证书 (客户端 insecure=1 或跳过验证)
CERT="$CONF_DIR/self.crt"; KEY="$CONF_DIR/self.key"
if [[ ! -s "$CERT" ]]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY" -out "$CERT" -days 3650 -nodes \
    -subj "/CN=bing.com" >/dev/null 2>&1
  chmod 600 "$KEY"
fi
ok "密钥就绪"

cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [
        { "name": "default", "uuid": "${UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${SNI}", "server_port": 443 },
          "private_key": "${PRIV_KEY}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    },
    {
      "type": "anytls",
      "tag": "anytls",
      "listen": "::",
      "listen_port": ${ANYTLS_PORT},
      "users": [ { "name": "default", "password": "${ANYTLS_PASS}" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [ { "name": "default", "password": "${HY2_PASS}" } ],
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block",  "tag": "block"  }
  ]
}
EOF

sing-box check -c "$CONF_DIR/config.json" || die "配置校验失败"
ok "配置校验通过"

# ---------- 4. systemd 服务 ----------
info "配置 systemd 服务..."
cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
sleep 2
systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 30 --no-pager; die "sing-box 启动失败，见上方日志"; }
ok "sing-box 服务运行中 (开机自启)"

# ---------- 5. 防火墙 + BBR ----------
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi active; then
  ufw allow ${VLESS_PORT}/tcp >/dev/null; ufw allow ${ANYTLS_PORT}/tcp >/dev/null; ufw allow ${HY2_PORT}/udp >/dev/null
  ok "ufw 已放行 ${VLESS_PORT}/tcp ${ANYTLS_PORT}/tcp ${HY2_PORT}/udp"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
  firewall-cmd --permanent --add-port=${VLESS_PORT}/tcp --add-port=${ANYTLS_PORT}/tcp --add-port=${HY2_PORT}/udp >/dev/null
  firewall-cmd --reload >/dev/null
  ok "firewalld 已放行端口"
else
  warn "未检测到活动防火墙；如 VPS 商家有网页安全组，请自行放行 ${VLESS_PORT}/tcp、${ANYTLS_PORT}/tcp 与 ${HY2_PORT}/udp"
fi

if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  if [[ -w /etc/sysctl.conf ]] && grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    { echo "net.core.default_qdisc=fq"; echo "net.ipv4.tcp_congestion_control=bbr"; } >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 && ok "已开启 BBR" || warn "BBR 开启失败(可忽略)"
  fi
fi

# ---------- 6. 输出节点信息 ----------
PUB_IP="$(curl -fsSL -4 --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsSL -4 --max-time 8 https://ifconfig.me 2>/dev/null || echo '<你的VPS_IP>')"

VLESS_LINK="vless://${UUID}@${PUB_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}&type=tcp#${TAG}-reality"
ANYTLS_LINK="anytls://${ANYTLS_PASS}@${PUB_IP}:${ANYTLS_PORT}?security=tls&sni=${SNI}&insecure=1#${TAG}-anytls"
HY2_LINK="hysteria2://${HY2_PASS}@${PUB_IP}:${HY2_PORT}/?sni=${SNI}&insecure=1&alpn=h3#${TAG}-hy2"

INFO_FILE="/root/node_info_$(date +%Y%m%d).txt"
{
  echo "====== 节点信息 $(date '+%F %T') ======"
  echo "IP:            $PUB_IP"
  echo "UUID:          $UUID"
  echo "--- VLESS-Reality ---"
  echo "端口:          $VLESS_PORT/tcp"
  echo "flow:          xtls-rprx-vision"
  echo "sni/伪装:      $SNI"
  echo "public_key:    $PUB_KEY"
  echo "short_id:      $SHORT_ID"
  echo "--- AnyTLS ---"
  echo "端口:          $ANYTLS_PORT/tcp"
  echo "密码:          $ANYTLS_PASS"
  echo "--- Hysteria2 ---"
  echo "端口:          $HY2_PORT/udp"
  echo "密码:          $HY2_PASS"
  echo "sni:           $SNI (自签证书, 客户端需允许不安全/insecure)"
  echo "--- 分享链接 ---"
  echo "$VLESS_LINK"
  echo "$ANYTLS_LINK"
  echo "$HY2_LINK"
} | tee "$INFO_FILE"
chmod 600 "$INFO_FILE"

echo
ok "全部完成！节点信息已保存到 $INFO_FILE"
warn "VLESS-Reality 用 v2rayN(sing-box/xray内核均可)；Hysteria2 必须切 sing-box 内核。"
warn "升级: SB_VER= 留空重跑本脚本即升级到最新版; 卸载: systemctl disable --now sing-box && rm -rf /usr/local/bin/sing-box /etc/sing-box /etc/systemd/system/sing-box.service"
