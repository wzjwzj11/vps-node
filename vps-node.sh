#!/usr/bin/env bash
#
# vps-node.sh — 自建节点一键脚本 (sing-box)
# 协议: VLESS-Reality (TCP/443) + AnyTLS (TCP/8443) + Hysteria2 (随机高位 UDP 端口)
# 特点: 只从官方源下载 (SagerNet/sing-box GitHub Releases)，无第三方中转
# 用法: bash <(curl -fsSL <你的脚本地址>)     或     bash vps-node.sh
# 可自定义环境变量(全部可选):
#   UUID=...  VLESS_PORT=443  ANYTLS_PORT=8443  HY2_PORT=auto  SUB_PORT=2096  SNI=auto  TAG=myserver
#
set -euo pipefail

# ============ 可改默认值 ============
# 留空时由 sing-box 自动生成随机 UUID；不要把真实 UUID 写死进公开脚本
UUID="${UUID:-}"
VLESS_PORT="${VLESS_PORT:-443}"
ANYTLS_PORT="${ANYTLS_PORT:-8443}"
HY2_PORT="${HY2_PORT:-auto}"
SUB_PORT="${SUB_PORT:-2096}"
SNI="${SNI:-auto}"                 # auto=从候选伪装站中选择 TCP/443 延迟最低者
TAG="${TAG:-vps}"
SB_VER="${SB_VER:-}"              # 留空=自动取最新版
SCRIPT_VERSION="v1.0.31"
SCRIPT_URL="https://raw.githubusercontent.com/wzjwzj11/vps-node/${SCRIPT_VERSION}/vps-node.sh"
SCRIPT_LATEST_URL="https://raw.githubusercontent.com/wzjwzj11/vps-node/main/vps-node.sh"
ACTION="${ACTION:-menu}"       # menu / install / sb-update / script-update / update / bbr / net-tune / net-reset / speed-test / status / csv-scan / node-info / uninstall
REALITYCHECKER_VERSION="${REALITYCHECKER_VERSION:-v2.2.3}"
REALITYSCAN_DIR="${REALITYSCAN_DIR:-/root/reality-scan}"
SNI_FILE="/etc/sing-box/reality_sni"
SUB_DIR="/var/lib/vps-node/subscription"
SUB_PORT="${SUB_PORT:-2096}"
SUB_SERVICE="vps-node-subscription.service"
REALITY_TARGETS="${REALITY_TARGETS:-gateway.icloud.com,swdist.apple.com,addons.mozilla.org,www.microsoft.com,dl.google.com,images.unsplash.com,www.amazon.co.jp,yahoo.co.jp,www.intel.com,aws.amazon.com,www.amazon.com,www.samsung.com,www.amd.com,www.sony.com,www.nvidia.com,www.apple.com,www.google.com,www.bing.com,www.yahoo.com}"
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

probe_host() {
  local host="$1" i sample tcp tls
  local -a tcp_values=() tls_values=()
  for i in 1 2 3; do
    sample="$(curl -4sk --connect-timeout 4 --max-time 8 -o /dev/null -w '%{time_connect} %{time_appconnect}' "https://${host}/" 2>/dev/null || true)"
    tcp="${sample%% *}"; tls="${sample##* }"
    [[ "$tcp" =~ ^[0-9]+\.[0-9]+$ ]] && tcp_values+=("$tcp")
    [[ "$tls" =~ ^[0-9]+\.[0-9]+$ && "$tls" != "0.000000" ]] && tls_values+=("$tls")
  done
  if ((${#tcp_values[@]} == 0)); then
    printf '%s\n' "- -"; return 0
  fi
  # 中位数比单次采样更不容易被 CDN/瞬时抖动误导
  tcp="$(printf '%s\n' "${tcp_values[@]}" | sort -n | awk '{a[NR]=$1} END{printf "%d", a[int((NR+1)/2)]*1000}')"
  if ((${#tls_values[@]} > 0)); then
    tls="$(printf '%s\n' "${tls_values[@]}" | sort -n | awk '{a[NR]=$1} END{printf "%d", a[int((NR+1)/2)]*1000}')"
  else
    tls="-"
  fi
  printf '%s %s\n' "$tcp" "$tls"
}

scan_reality_targets() {
  command -v openssl >/dev/null 2>&1 || die "扫描器需要 openssl"
  command -v curl >/dev/null 2>&1 || die "扫描器需要 curl"
  local targets="$REALITY_TARGETS" host result tcp_ms tls_ms cert
  printf '%-30s %-8s %-8s %-8s %-35s %-10s %-10s\n' "目标" "状态" "TLS" "ALPN" "证书" "TCP延迟" "TLS延迟"
  printf '%-30s %-8s %-8s %-8s %-35s %-10s %-10s\n' "------------------------------" "--------" "--------" "--------" "-----------------------------------" "----------" "----------"
  IFS=',' read -ra target_list <<< "$targets"
  for host in "${target_list[@]}"; do
    host="${host//[[:space:]]/}"
    [[ -n "$host" ]] || continue
    result="$(timeout 8 openssl s_client -connect "${host}:443" -servername "$host" -alpn h2 </dev/null 2>&1 || true)"
    read -r tcp_ms tls_ms <<< "$(probe_host "$host")"
    if grep -q 'CONNECTED' <<< "$result" && grep -q 'Verify return code: 0' <<< "$result"; then
      tls="$(grep -m1 '^New, TLSv' <<< "$result" | sed -E 's/^New, (TLSv[^, ]+).*/\1/' || true)"
      [[ -n "$tls" ]] || tls="$(grep -m1 '^Protocol *:' <<< "$result" | awk '{print $3}' || true)"
      alpn="$(grep -m1 'ALPN protocol:' <<< "$result" | sed 's/.*: //' || true)"
      cert="$(awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{exit}' <<< "$result" | openssl x509 -noout -subject 2>/dev/null | sed -E 's/^subject=.*CN = //; s/^subject=//')"
      printf '%-30s %-8s %-8s %-8s %-35s %-10s %-10s\n' "${host}:443" "可用" "${tls:--}" "${alpn:--}" "${cert:--}" "${tcp_ms} ms" "${tls_ms} ms"
    else
      printf '%-30s %-8s %-8s %-8s %-35s %-10s %-10s\n' "${host}:443" "不可用" "-" "-" "-" "${tcp_ms} ms" "${tls_ms} ms"
    fi
  done
}


country_for_ip() {
  local ip="$1" result=""
  [[ -n "$ip" ]] || return 0
  result="$(curl -4fsSL --connect-timeout 3 --max-time 5 "https://ipapi.co/${ip}/country/" 2>/dev/null || true)"
  printf '%s' "$result" | tr -d '[:space:]' | head -c 2 || true
}

country_for_host() {
  local host="$1" ip=""
  ip="$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  [[ -n "$ip" ]] || return 0
  country_for_ip "$ip" || true
}

choose_sni() {
  [[ "$SNI" == "auto" ]] || return 0
  local best="" best_ms=999999 host tcp_ms tls_ms vps_ip vps_country host_country
  local -a target_list=() eligible=()
  IFS=',' read -ra target_list <<< "$REALITY_TARGETS"
  vps_ip="$(curl -4fsSL --connect-timeout 4 --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  vps_country="$(country_for_ip "$vps_ip")"
  if [[ -n "$vps_country" ]]; then
    for host in "${target_list[@]}"; do
      host="${host//[[:space:]]/}"
      [[ -n "$host" ]] || continue
      host_country="$(country_for_host "$host")"
      [[ "$host_country" == "$vps_country" ]] && eligible+=("$host")
    done
  fi
  # 有同国家候选时只测这些；GeoIP/DNS 失败或无匹配时回退到完整候选池
  ((${#eligible[@]} > 0)) || eligible=("${target_list[@]}")
  for host in "${eligible[@]}"; do
    host="${host//[[:space:]]/}"
    [[ -n "$host" ]] || continue
    read -r tcp_ms tls_ms <<< "$(probe_host "$host")"
    [[ "$tls_ms" =~ ^[0-9]+$ ]] || continue
    if (( tls_ms < best_ms )); then best="$host"; best_ms="$tls_ms"; fi
  done
  SNI="${best:-www.microsoft.com}"
  if [[ -n "$vps_country" && ${#eligible[@]} -lt ${#target_list[@]} ]]; then
    info "伪装域名: $SNI（与 VPS 同国家/地区代码 $vps_country，TLS 握手中位数约 ${best_ms}ms）"
  else
    info "伪装域名: $SNI（未找到同国家/地区候选，TLS 握手中位数约 ${best_ms}ms）"
  fi
}

network_tune() {
  enable_bbr
  local conf=/etc/sysctl.d/99-vps-node-network.conf backup=/var/lib/vps-node/network-tune.before
  install -d -m 700 /var/lib/vps-node /etc/sysctl.d || die "无法创建网络优化目录"
  if [[ ! -s "$backup" ]]; then
    {
      sysctl -n net.core.rmem_max 2>/dev/null || true
      sysctl -n net.core.wmem_max 2>/dev/null || true
      sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true
      sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true
      sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || true
      sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || true
      sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || true
      sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || true
    } > "$backup"
    chmod 600 "$backup"
  fi
  cat > "$conf" <<'EOF'
# Managed by vps-node; conservative TCP tuning, no third-party kernel
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 131072 33554432
net.ipv4.tcp_wmem=4096 131072 33554432
net.ipv4.tcp_limit_output_bytes=4194304
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
EOF
  if ! sysctl --load="$conf"; then
    rm -f "$conf"; die "网络优化参数应用失败，未保留新配置"
  fi
  ok "已应用保守网络优化（BBR+FQ、TCP 缓冲区、MTU 探测）"
  echo "配置文件: $conf"
  echo "当前: qdisc=$(sysctl -n net.core.default_qdisc) cc=$(sysctl -n net.ipv4.tcp_congestion_control)"
}

network_reset() {
  local conf=/etc/sysctl.d/99-vps-node-network.conf backup=/var/lib/vps-node/network-tune.before
  rm -f "$conf"
  if [[ -s "$backup" ]]; then
    mapfile -t old < "$backup"
    [[ -n "${old[0]:-}" ]] && sysctl -w net.core.rmem_max="${old[0]}" >/dev/null || true
    [[ -n "${old[1]:-}" ]] && sysctl -w net.core.wmem_max="${old[1]}" >/dev/null || true
    [[ -n "${old[2]:-}" ]] && sysctl -w net.ipv4.tcp_rmem="${old[2]}" >/dev/null || true
    [[ -n "${old[3]:-}" ]] && sysctl -w net.ipv4.tcp_wmem="${old[3]}" >/dev/null || true
    [[ -n "${old[4]:-}" ]] && sysctl -w net.ipv4.tcp_limit_output_bytes="${old[4]}" >/dev/null || true
    [[ -n "${old[5]:-}" ]] && sysctl -w net.ipv4.tcp_slow_start_after_idle="${old[5]}" >/dev/null || true
    [[ -n "${old[6]:-}" ]] && sysctl -w net.ipv4.tcp_fastopen="${old[6]}" >/dev/null || true
    [[ -n "${old[7]:-}" ]] && sysctl -w net.ipv4.tcp_mtu_probing="${old[7]}" >/dev/null || true
    rm -f "$backup"
  fi
  ok "已移除 vps-node 网络优化配置；BBR 配置保持不变"
}

enable_bbr() {
  command -v sysctl >/dev/null 2>&1 || { die "缺少 sysctl"; return 1; }
  [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] || { die "系统不支持读取 TCP 拥塞控制算法"; return 1; }
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    die "当前 Linux 内核不支持 BBR；请升级到支持 BBR 的内核后重试"
    return 1
  fi
  local conf=/etc/sysctl.d/99-vps-node-bbr.conf
  install -d -m 755 /etc/sysctl.d || { die "无法创建 /etc/sysctl.d"; return 1; }
  if ! cat > "$conf" <<'EOF'
# Managed by vps-node
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  then
    die "无法写入 $conf"; return 1
  fi
  if ! sysctl --load="$conf"; then
    die "无法应用 $conf"; return 1
  fi
  local current_qdisc current_cc
  current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ "$current_cc" == "bbr" ]]; then
    ok "BBR 已启用；qdisc=$current_qdisc"
  else
    die "配置已写入，但当前拥塞控制算法是 '$current_cc'，不是 bbr"
    return 1
  fi
}

show_node_info() {
  local info_file latest=""
  if [[ ! -s "$SUB_DIR/token" ]]; then
    ensure_subscription_from_info >/dev/null 2>&1 || true
  fi
  latest="$(find /root -maxdepth 1 -type f -name 'node_info_*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print}')"
  echo "========== 节点信息 =========="
  if [[ -n "$latest" && -r "$latest" ]]; then
    echo "信息文件: $latest"
    cat "$latest"
  else
    echo "未找到 /root/node_info_*.txt"
    [[ -r /etc/sing-box/config.json ]] && echo "配置文件存在: /etc/sing-box/config.json" || true
  fi
  echo "---------- 当前服务 ----------"
  systemctl --no-pager --full status sing-box 2>/dev/null | sed -n '1,12p' || true
  echo "---------- 订阅地址 ----------"
  if [[ -s "$SUB_DIR/token" ]]; then
    local sub_ip
    sub_ip="$(curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo '<VPS_IP>')"
    echo "http://${sub_ip}:${SUB_PORT}/sub/$(tr -d '[:space:]' < "$SUB_DIR/token")"
    echo "订阅服务: $(systemctl is-active "$SUB_SERVICE" 2>/dev/null || echo inactive)"
  else
    echo "未生成订阅"
  fi
  echo "---------- 当前监听 ----------"
  ss -ltnup 2>/dev/null | grep -E ':(443|8443|[2-9][0-9]{4}|[1-9][0-9]{4})[[:space:]]' || echo "未读取到监听端口"
}

speed_test() {
  local urls="$SPEEDTEST_URLS" url name code size speed time_total error
  local -a url_list=()
  command -v curl >/dev/null 2>&1 || die "测速需要 curl"
  IFS=',' read -ra url_list <<< "$urls"
  echo "========== 网络测速 =========="
  echo "每个地址最多下载 10-100 MB；结果只代表 VPS 到该测速站的线路。"
  printf '%-32s %-8s %-14s %-18s %s\n' "测速地址" "HTTP" "实际大小" "速度" "结果"
  printf '%-32s %-8s %-14s %-18s %s\n' "--------------------------------" "--------" "--------------" "------------------" "----------------"
  for url in "${url_list[@]}"; do
    url="${url//[[:space:]]/}"
    [[ -n "$url" ]] || continue
    name="${url#*://}"; name="${name%%/*}"
    # 写临时文件确保统计的是实际收到的字节数，不接受仅凭 HTTP 200 判断成功
    local tmp="$(mktemp /tmp/vps-node-speed.XXXXXX)"
    local metrics=""
    metrics="$(curl -4L --connect-timeout 8 --max-time 45 -sS "$url" -o "$tmp" -w '%{http_code} %{size_download} %{speed_download} %{time_total}' 2>&1)" || true
    rm -f "$tmp"
    if read -r code size speed_bytes time_total <<< "$metrics" && [[ "$code" =~ ^[0-9]{3}$ && "$size" =~ ^[0-9]+$ && "$speed_bytes" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      speed="$(awk -v s="$speed_bytes" 'BEGIN { printf "%.2f MB/s", s/1024/1024 }')"
      if [[ "$code" =~ ^2 && "$size" -ge 1048576 ]]; then
        printf '%-32s %-8s %-14s %-18s %s\n' "$name" "$code" "$size bytes" "$speed" "成功"
      else
        printf '%-32s %-8s %-14s %-18s %s\n' "$name" "$code" "$size bytes" "-" "服务端拒绝/响应过小"
      fi
    else
      error="${metrics//$'\n'/ }"; error="${error:0:45}"
      printf '%-32s %-8s %-14s %-18s %s\n' "$name" "-" "0 bytes" "-" "$error"
    fi
  done
}

reality_checker_csv() {
  if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl unzip
    elif command -v dnf >/dev/null 2>&1; then dnf install -y curl unzip
    elif command -v yum >/dev/null 2>&1; then yum install -y curl unzip
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl unzip
    else die "CSV 检测需要 curl 和 unzip"; fi
  fi
  command -v curl >/dev/null 2>&1 || die "CSV 检测需要 curl"
  command -v unzip >/dev/null 2>&1 || die "CSV 检测需要 unzip"
  mkdir -p "$REALITYSCAN_DIR"
  local checker="$REALITYSCAN_DIR/reality-checker"
  if [[ ! -x "$checker" ]]; then
    info "下载 RealityChecker ${REALITYCHECKER_VERSION} ARM64..."
    local zip="$REALITYSCAN_DIR/reality-checker.zip"
    curl -fL --retry 3 -o "$zip" "https://github.com/V2RaySSR/RealityChecker/releases/download/${REALITYCHECKER_VERSION}/reality-checker-linux-arm64.zip" || die "RealityChecker 下载失败"
    unzip -o "$zip" -d "$REALITYSCAN_DIR" >/dev/null || die "RealityChecker 解压失败"
    chmod 755 "$checker"
    rm -f "$zip"
  fi
  local csv_file=""
  csv_file="$(find "$REALITYSCAN_DIR" -maxdepth 1 -type f -name '*.csv' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print}')"
  [[ -n "$csv_file" && -r "$csv_file" ]] || die "未找到 CSV。请先在本地用 RealiTLScanner 扫描 VPS IP，再通过 SSH 上传到 $REALITYSCAN_DIR/"
  local report="$REALITYSCAN_DIR/$(basename "${csv_file%.*}")-reality-check.txt" checker_output cleaned candidates row
  echo "========== RealityChecker 批量检测 =========="
  echo "CSV: $csv_file"
  checker_output="$("$checker" csv "$csv_file" 2>&1 || true)"
  printf '%s\n' "$checker_output" | tee "$report" >/dev/null
  echo "完整报告: $report"
  echo "筛选条件: *****、基础条件✓、证书有效、CDN=无、热门=-、页面状态=200"
  # 表格列：最终域名、基础条件、握手时间、证书时间、CDN、热门、推荐、页面状态。
  # 只保留严格全绿候选；302/404 是可接受状态，但不算全绿，因此排除。
  cleaned="$(printf '%s\n' "$checker_output" | sed -E $'s/\x1B\[[0-9;]*[[:alpha:]]//g; s/[│┃]/|/g')"
  candidates="$(printf '%s\n' "$cleaned" | awk -F '|' '
    NF >= 9 {
      for (i=1; i<=NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      domain=$2; basic=$3; hs=$4; cert=$5; cdn=$6; hot=$7; stars=$8; status=$9
      if (domain !~ /^[A-Za-z0-9.-]+$/ || stars != "*****" || basic !~ /✓/ || cert == "无效" || cdn != "无" || hot != "-" || status != "200") next
      if (match(hs, /[0-9]+/)) print substr(hs, RSTART, RLENGTH) "\t" domain "\t" hs "\t" cert "\t" cdn "\t" hot "\t" stars "\t" status
    }
  ' | sort -n -k1,1)"
  [[ -n "$candidates" ]] || { warn "没有符合“五星全绿 + 页面200”的候选；未修改节点配置。完整报告: $report"; return 1; }
  echo
  echo "========== 五星全绿候选（按握手延迟排序） =========="
  printf '%-4s %-38s %-10s %-10s %-8s %-8s %-8s %-8s\n' "编号" "最终域名" "握手" "证书" "CDN" "热门" "推荐" "页面"
  printf '%-4s %-38s %-10s %-10s %-8s %-8s %-8s %-8s\n' "----" "--------------------------------------" "----------" "----------" "--------" "--------" "--------" "--------"
  local -a candidate_rows=()
  mapfile -t candidate_rows <<< "$candidates"
  local i choice selected
  for i in "${!candidate_rows[@]}"; do
    IFS=$'\t' read -r best_ms selected hs cert cdn hot stars status <<< "${candidate_rows[$i]}"
    printf '%-4s %-38s %-10s %-10s %-8s %-8s %-8s %-8s\n' "$((i+1))" "$selected" "$hs" "$cert" "$cdn" "$hot" "$stars" "$status"
  done
  while true; do
    read -r -p "输入编号选择 Reality 域名，0 取消: " choice
    [[ "$choice" == 0 ]] && { echo "已取消，不修改节点配置"; return 0; }
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#candidate_rows[@]})); then
      IFS=$'\t' read -r best_ms selected hs cert cdn hot stars status <<< "${candidate_rows[$((choice-1))]}"
      break
    fi
    echo "请输入有效编号"
  done
  echo "已选择: $selected（握手 $hs）"
  apply_reality_sni "$selected"
}

subscription_payload() {
  mkdir -p "$SUB_DIR"
  if [[ ! -s "$SUB_DIR/token" ]]; then
    openssl rand -hex 24 > "$SUB_DIR/token"
    chmod 600 "$SUB_DIR/token"
  fi
  SUB_TOKEN="$(tr -d '[:space:]' < "$SUB_DIR/token")"
  printf '%s\n' "$VLESS_LINK" "$ANYTLS_LINK" "$HY2_LINK" > "$SUB_DIR/links.txt"
  chmod 600 "$SUB_DIR/links.txt"
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0 "$SUB_DIR/links.txt" > "$SUB_DIR/subscription.b64"
  else
    base64 "$SUB_DIR/links.txt" | tr -d '\n' > "$SUB_DIR/subscription.b64"
  fi
  chmod 644 "$SUB_DIR/subscription.b64"
}

ensure_subscription_from_info() {
  local info_file latest="" vless_link anytls_link hy2_link sub_ip
  latest="$(find /root -maxdepth 1 -type f -name 'node_info_*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print}')"
  [[ -n "$latest" && -r "$latest" ]] || return 1
  vless_link="$(grep -m1 '^vless://' "$latest" || true)"
  anytls_link="$(grep -m1 '^anytls://' "$latest" || true)"
  hy2_link="$(grep -m1 '^hysteria2://' "$latest" || true)"
  [[ -n "$vless_link" && -n "$anytls_link" && -n "$hy2_link" ]] || return 1
  mkdir -p "$SUB_DIR"
  if [[ ! -s "$SUB_DIR/token" ]]; then
    openssl rand -hex 24 > "$SUB_DIR/token"
    chmod 600 "$SUB_DIR/token"
  fi
  SUB_TOKEN="$(tr -d '[:space:]' < "$SUB_DIR/token")"
  printf '%s\n' "$vless_link" "$anytls_link" "$hy2_link" > "$SUB_DIR/links.txt"
  chmod 600 "$SUB_DIR/links.txt"
  if base64 --help 2>&1 | grep -q -- '-w'; then base64 -w0 "$SUB_DIR/links.txt" > "$SUB_DIR/subscription.b64"; else base64 "$SUB_DIR/links.txt" | tr -d '\n' > "$SUB_DIR/subscription.b64"; fi
  chmod 644 "$SUB_DIR/subscription.b64"
  install_subscription_service
  sub_ip="$(curl -4fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo '<VPS_IP>')"
  SUB_LINK="http://${sub_ip}:${SUB_PORT}/sub/${SUB_TOKEN}"
  return 0
}

install_subscription_service() {
  command -v python3 >/dev/null 2>&1 || die "订阅服务需要 python3"
  install -d -m 755 /usr/local/libexec
  cat > /usr/local/libexec/vps-node-subscription.py <<'PY'
#!/usr/bin/env python3
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--dir', required=True)
parser.add_argument('--port', required=True, type=int)
args = parser.parse_args()
root = Path(args.dir)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        token = (root / 'token').read_text().strip()
        if self.path != '/sub/' + token:
            self.send_error(404)
            return
        data = (root / 'subscription.b64').read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(('0.0.0.0', args.port), Handler).serve_forever()
PY
  chmod 755 /usr/local/libexec/vps-node-subscription.py
  cat > "/etc/systemd/system/$SUB_SERVICE" <<EOF
[Unit]
Description=vps-node private subscription
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/libexec/vps-node-subscription.py --dir $SUB_DIR --port $SUB_PORT
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SUB_SERVICE" >/dev/null 2>&1
  systemctl is-active --quiet "$SUB_SERVICE" || die "订阅服务启动失败，请查看 journalctl -u $SUB_SERVICE"
}

refresh_subscription_sni() {
  local old="$1" new="$2"
  [[ -s "$SUB_DIR/links.txt" ]] || return 0
  sed -i "s|$old|$new|g" "$SUB_DIR/links.txt"
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0 "$SUB_DIR/links.txt" > "$SUB_DIR/subscription.b64"
  else
    base64 "$SUB_DIR/links.txt" | tr -d '\n' > "$SUB_DIR/subscription.b64"
  fi
  chmod 644 "$SUB_DIR/subscription.b64"
}

validate_reality_target() {
  local target="$1" tcp_ms tls_ms
  read -r tcp_ms tls_ms <<< "$(probe_host "$target")"
  [[ "$tls_ms" =~ ^[0-9]+$ ]] || die "VPS 到目标 $target 的 TLS 握手失败，未修改配置"
}

apply_reality_sni() {
  local selected="$1" conf=/etc/sing-box/config.json backup old_sni info_file
  [[ "$selected" =~ ^[A-Za-z0-9.-]+$ ]] || die "域名格式无效: $selected"
  [[ -s "$conf" ]] || die "未找到 $conf，请先安装节点"
  command -v jq >/dev/null 2>&1 || die "修改配置需要 jq"
  validate_reality_target "$selected"
  backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"
  old_sni="$(jq -r '[.inbounds[] | select((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true) | .tls.server_name][0] // empty' "$conf")"
  [[ -n "$old_sni" ]] || die "配置中没有 VLESS/AnyTLS Reality 入站"
  cp -a "$conf" "$backup"
  local tmp="$(mktemp /tmp/vps-node-config.XXXXXX.json)"
  jq --arg sni "$selected" '.inbounds |= map(if ((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true) then (.tls.server_name=$sni | .tls.reality.handshake.server=$sni) else . end)' "$conf" > "$tmp" || { rm -f "$tmp"; die "生成新配置失败，原配置未修改"; }
  install -m 600 "$tmp" "$conf"
  rm -f "$tmp"
  if ! sing-box check -c "$conf"; then
    cp -a "$backup" "$conf"; rm -f "$backup"
    die "新配置校验失败，已恢复原配置"
  fi
  systemctl restart sing-box
  if ! systemctl is-active --quiet sing-box; then
    cp -a "$backup" "$conf"; systemctl restart sing-box; rm -f "$backup"
    die "重启 sing-box 失败，已恢复原配置"
  fi
  info_file="$(find /root -maxdepth 1 -type f -name 'node_info_*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{$1=""; sub(/^ /,""); print}')"
  if [[ -n "$info_file" && -w "$info_file" ]]; then sed -i "s|$old_sni|$selected|g" "$info_file"; fi
  refresh_subscription_sni "$old_sni" "$selected"
  rm -f "$backup"
  ok "Reality 域名已修改: $old_sni -> $selected"
  ok "VLESS 和 AnyTLS 已重启生效；新的节点链接可用菜单查询节点信息获取"
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
    status_hy2_port="$(jq -r '.inbounds[] | select(.tag==\"hy2\") | .listen_port' /etc/sing-box/config.json 2>/dev/null || echo auto)"
  fi
  for pair in "${VLESS_PORT}:tcp" "${ANYTLS_PORT}:tcp" "${status_hy2_port}:udp" "${SUB_PORT}:tcp"; do
    p="${pair%%:*}"; proto="${pair##*:}"
    port_in_use "$p" "$proto" && echo "端口 $p/$proto: 已监听" || echo "端口 $p/$proto: 未监听"
  done
}

update_script() {
  local tmp current="${SCRIPT_VERSION:-unknown}" new_version
  tmp="$(mktemp /tmp/vps-node-update.XXXXXX.sh)"
  info "检查脚本更新: $SCRIPT_LATEST_URL"
  if ! curl -fsSL --retry 3 --connect-timeout 10 "$SCRIPT_LATEST_URL" -o "$tmp"; then
    rm -f "$tmp"; die "下载新版脚本失败，旧版本保持不变"
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "新版脚本为空，旧版本保持不变"; }
  bash -n "$tmp" || { rm -f "$tmp"; die "新版脚本语法检查失败，旧版本保持不变"; }
  grep -q '^SCRIPT_VERSION="v[0-9]' "$tmp" || { rm -f "$tmp"; die "新版脚本版本标记缺失，旧版本保持不变"; }
  new_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"/\1/p' "$tmp" | head -1)"
  install -m 755 "$tmp" /usr/local/bin/vps-node.sh
  rm -f "$tmp"
  cat > /usr/local/bin/sb <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash /usr/local/bin/vps-node.sh "$@"
EOF
  chmod 755 /usr/local/bin/sb
  ok "脚本已更新: $current -> $new_version"
  ok "以后输入 sb 将运行本地新版脚本"
}

create_shortcut() {
  local target=/usr/local/bin/sb
  cat > "$target" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec bash /usr/local/bin/vps-node.sh "$@"
EOF
  chmod 755 "$target"
  if [[ -f "$0" ]]; then
    local source_path target_path
    source_path="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0")"
    target_path="$(readlink -f /usr/local/bin/vps-node.sh 2>/dev/null || realpath /usr/local/bin/vps-node.sh 2>/dev/null || printf '%s' /usr/local/bin/vps-node.sh)"
    if [[ "$source_path" != "$target_path" ]]; then
      install -m 755 "$0" /usr/local/bin/vps-node.sh
    fi
  else
    local tmp="$(mktemp /tmp/vps-node-local.XXXXXX.sh)"
    curl -fsSL --retry 3 --connect-timeout 10 "$SCRIPT_URL" -o "$tmp" || die "无法保存本机脚本"
    bash -n "$tmp" || die "本机脚本语法检查失败"
    install -m 755 "$tmp" /usr/local/bin/vps-node.sh
    rm -f "$tmp"
  fi
  hash -r 2>/dev/null || true
  ok "快捷命令已设置: 输入 sb 可重新打开 VPS 节点管理脚本"
}



create_shortcut

if [[ "$ACTION" == "menu" ]]; then
  while true; do
    echo
    echo "========== VPS 节点管理 =========="
    echo "1. 查看 VPS 基础状态"
    echo "2. 更新系统软件包"
    echo "3. 开启 BBR"
    echo "4. 网络参数优化（保守）"
    echo "5. 网络测速"
    echo "6. CSV Reality 扫描/修改域名"
    echo "7. 安装/重建节点配置"
    echo "8. 查询节点信息"
    echo "9. 更新 sing-box"
    echo "10. 更新本机脚本"
    echo "11. 恢复网络参数"
    echo "12. 卸载 sing-box"
    echo "0. 退出"
    read -r -p "请选择: " choice
    case "$choice" in
      1) ACTION=status; break ;;
      2) ACTION=update; break ;;
      3) ACTION=bbr; break ;;
      4) ACTION=net-tune; break ;;
      5) ACTION=speed-test; break ;;
      6) ACTION=csv-scan; break ;;
      7) ACTION=install; break ;;
      8) ACTION=node-info; break ;;
      9) ACTION=sb-update; SB_VER=""; break ;;
      10) ACTION=script-update; break ;;
      11) ACTION=net-reset; break ;;
      12) ACTION=uninstall; break ;;
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
  speed-test)
    speed_test; exit 0 ;;
  csv-scan)
    reality_checker_csv; exit 0 ;;
  node-info)
    show_node_info; exit 0 ;;
  script-update)
    update_script; exit 0 ;;
  sb-update)
    # 继续执行下方官方二进制更新流程
    ;;
  bbr)
    enable_bbr; exit 0 ;;
  net-tune)
    network_tune; exit 0 ;;
  net-reset)
    network_reset; exit 0 ;;
  uninstall)
    systemctl disable --now "$SUB_SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SUB_SERVICE" /usr/local/libexec/vps-node-subscription.py
    rm -rf "$SUB_DIR"
    systemctl daemon-reload
    systemctl disable --now sing-box 2>/dev/null || true
    rm -f /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
    rm -rf /etc/sing-box
    systemctl daemon-reload
    echo "sing-box 已卸载（不会删除系统包和防火墙规则）"; exit 0 ;;
  install|sb-update|script-update|node-info) ;;
  *) die "ACTION 只能是 menu/install/sb-update/script-update/update/bbr/net-tune/net-reset/speed-test/status/csv-scan/node-info/uninstall" ;;
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
for c in curl tar openssl jq unzip; do command -v "$c" >/dev/null || NEED+=("$c"); done
# jq 在 alpine 叫 jq, 其它同名; openssl 必需(生成自签证书)
[[ ${#NEED[@]} -gt 0 ]] && { info "安装依赖: ${NEED[*]}"; install_pkgs "${NEED[@]}"; }

[[ "$HY2_PORT" == "auto" ]] && HY2_PORT="$(random_high_port)"
choose_sni || { SNI="${SNI:-www.microsoft.com}"; warn "伪装域名自动选择失败，回退到 $SNI"; }

# ---------- 1. 安装 sing-box (官方 GitHub Release) ----------
for pair in "${VLESS_PORT}:tcp" "${ANYTLS_PORT}:tcp" "${HY2_PORT}:udp" "${SUB_PORT}:tcp"; do
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
  ufw allow ${VLESS_PORT}/tcp >/dev/null; ufw allow ${ANYTLS_PORT}/tcp >/dev/null; ufw allow ${HY2_PORT}/udp >/dev/null; ufw allow ${SUB_PORT}/tcp >/dev/null
  ok "ufw 已放行 ${VLESS_PORT}/tcp ${ANYTLS_PORT}/tcp ${HY2_PORT}/udp ${SUB_PORT}/tcp"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
  firewall-cmd --permanent --add-port=${VLESS_PORT}/tcp --add-port=${ANYTLS_PORT}/tcp --add-port=${HY2_PORT}/udp --add-port=${SUB_PORT}/tcp >/dev/null
  firewall-cmd --reload >/dev/null
  ok "firewalld 已放行端口"
else
  warn "未检测到活动防火墙；如 VPS 商家有网页安全组，请自行放行 ${VLESS_PORT}/tcp、${ANYTLS_PORT}/tcp、${HY2_PORT}/udp 与订阅 ${SUB_PORT}/tcp"
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
ANYTLS_LINK="anytls://${ANYTLS_PASS}@${PUB_IP}:${ANYTLS_PORT}?security=reality&sni=${SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}#${TAG}-anytls"
HY2_LINK="hysteria2://${HY2_PASS}@${PUB_IP}:${HY2_PORT}/?sni=${SNI}&insecure=1&alpn=h3#${TAG}-hy2"

subscription_payload
install_subscription_service
SUB_LINK="http://${PUB_IP}:${SUB_PORT}/sub/${SUB_TOKEN}"

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
  echo "--- AnyTLS (Reality) ---"
  echo "端口:          $ANYTLS_PORT/tcp"
  echo "密码:          $ANYTLS_PASS"
  echo "--- Hysteria2 ---"
  echo "端口:          $HY2_PORT/udp"
  echo "密码:          $HY2_PASS"
  echo "sni:           $SNI (自签证书, 客户端需允许不安全/insecure)"
  echo "--- 订阅地址 ---"
  echo "$SUB_LINK"
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
echo "安装脚本已结束，返回 Shell。"
exit 0
