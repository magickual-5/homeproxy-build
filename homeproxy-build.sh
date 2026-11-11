#!/bin/sh
# ============================================================
# 兼容层：OpenWrt 默认 shell 是 busybox ash，而本脚本重度依赖 bash
# （数组 / declare -A / [[ ]] / ${var,,} 等）。若当前不是 bash，
# 则自动用 bash 重新执行自身；若连 bash 都没有，提示安装后退出。
# 注意：本脚本不支持通过管道直接执行（如 wget -O - URL | sh），
# 因为重跑自身需要 $0 指向真实文件。请先下载到本地再执行。
# ============================================================
if [ -z "$BASH_VERSION" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "本脚本需要 bash，但当前系统中未找到。请先安装：" >&2
  echo "  opkg update && opkg install bash" >&2
  exit 1
fi
set -euo pipefail

#################### 依赖自检 ####################
# OpenWrt 精简系统可能缺少 bash/jq/curl/openssl/unzip。
# 这里自动检测并在用户确认后通过 opkg 安装，确保“拉取后即可运行”。
ensure_deps() {
  # 命令 -> OpenWrt 软件包名
  local -A PKG=( [bash]=bash [jq]=jq [curl]=curl [openssl]=openssl-util [unzip]=unzip )
  local need=() cmd pkgs=""
  for cmd in bash jq curl openssl unzip; do
    command -v "$cmd" >/dev/null 2>&1 || need+=("$cmd")
  done
  [[ ${#need[@]} -eq 0 ]] && return 0

  echo "检测到缺少运行依赖：${need[*]}"
  for cmd in "${need[@]}"; do pkgs="$pkgs ${PKG[$cmd]}"; done
  pkgs="${pkgs# }"

  if ! command -v opkg >/dev/null 2>&1; then
    echo "未找到 opkg（非 OpenWrt 环境？），请手动安装以下命令后重试：$pkgs" >&2
    return 0
  fi

  local ans="y"
  if [[ -t 0 ]]; then
    read -r -p "是否通过 opkg 安装缺少的依赖 [$pkgs]？[Y/n]: " ans || ans="y"
  fi
  if [[ "${ans,,}" == "n" || "${ans,,}" == "no" ]]; then
    echo "已跳过依赖安装，脚本可能因缺少命令而失败。" >&2
    return 0
  fi

  opkg update 2>&1 | tail -n 2 || true
  # shellcheck disable=SC2086
  opkg install $pkgs
}
ensure_deps

#################### 基础路径 ####################
HP_CUSTOM_JSON="/etc/homeproxy/hiddify-c.json"
HP_UCI_CONFIG="/etc/config/homeproxy"
HP_GEN_UC="/etc/homeproxy/scripts/generate_client.uc"
HP_SUB_UPDATE="/etc/homeproxy/scripts/update_subscriptions.uc"

WORK_DIR="/tmp/homeproxy-build"
UPLOAD_DIR="/tmp/upload"
SUB_FILE="${WORK_DIR}/subscriptions.json"
NODES_FILE="${WORK_DIR}/outbounds.json"
FINAL_FILE="${UPLOAD_DIR}/sing-box-c.json"
BACKUP_DIR="/tmp/homeproxy-bak"

mkdir -p "$WORK_DIR" "$UPLOAD_DIR" "$BACKUP_DIR"
[[ -f "$SUB_FILE" ]] || echo '[]' > "$SUB_FILE"

#################### 应用模式 ####################
APPLY_MODE="auto"   # auto / uci / file

#################### 可调参数 ####################
LISTEN_ADDR="::"
REDIRECT_PORT="5331"
TPROXY_PORT="5332"
MIXED_PORT="5333"
BYPASS_IPS=()

#################### 面板 (Dashboard) ####################
# 新版 HomeProxy 不再自带面板；这里用 sing-box 的 clash_api + external_ui
# 把 clash-api 兼容面板（zashboard / yacd-meta / metacubexd，均兼容 /ui 子路径）
# 托管到路由器本地，访问地址： http://<路由器LAN IP>:<CLASH_API_PORT>/ui/
# 因为 OpenClash(OC) 与 HomeProxy 一般只能同时开一个（都抢 nftables 重定向/DNS 接管），
# 所以默认优先复用 OC 已经装好的 zashboard 面板，两者共用同一份静态文件，无需重复下载。
CLASH_API_BIND="0.0.0.0"            # 监听所有接口（配合 secret + 防火墙仅放行 LAN）
CLASH_API_PORT="9090"
CLASH_API_SECRET_FILE="/etc/homeproxy/clash_secret"   # 持久化 secret，重启后不变
DASHBOARD_REUSE_OC="auto"            # auto=检测到 OC 面板就复用；never=总是自己下载
DASHBOARD_DIR="/etc/homeproxy/ui"    # 默认 external_ui 目录（未复用 OC 时使用）
DASHBOARD_TOOL="yacd-meta"           # 自己下载安装时的面板名称（仅用于提示）
# 想用 metacubexd 的界面？无需本地安装，直接用官方托管： https://d.metacubex.one
# （本脚本已开启私有网络放行，打开后填 http://<IP>:<CLASH_API_PORT> + secret 即可）
DASHBOARD_DOWNLOAD_URL="https://github.com/MetaCubeX/Yacd-meta/archive/refs/heads/gh-pages.zip"

#################### 规则集 URL ####################
GEOSITE_CN_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
GEOIP_CN_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
GEOSITE_GFW_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs"

RULE_SETS_EXTRA=(
  "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-apple.srs|geosite-apple"
  "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-microsoft.srs|geosite-microsoft"
  "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs|geosite-openai"
  "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs|geosite-netflix"
  "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-disney.srs|geosite-disney"
  "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-youtube.srs|geosite-youtube"
)

#################### 工具函数 ####################
info()  { printf "\033[32m[INFO]\033[0m %s\n" "$*"; }
warn()  { printf "\033[33m[WARN]\033[0m %s\n" "$*"; }
error() { printf "\033[31m[ERROR]\033[0m %s\n" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { error "缺少命令：$1，请先安装（opkg install curl jq）"; exit 1; }
}
need_cmd curl
need_cmd jq

#################### 探测 sub2sing-box ####################
SUB2SINGBOX_BIN=""
if command -v sub2sing-box >/dev/null 2>&1; then
  SUB2SINGBOX_BIN="sub2sing-box"
elif command -v sub2singbox >/dev/null 2>&1; then
  SUB2SINGBOX_BIN="sub2singbox"
fi

#################### 读取 HomeProxy self_mark ####################
SELF_MARK="100"
if command -v uci >/dev/null 2>&1; then
  SELF_MARK="$(uci -q get homeproxy.infra.self_mark 2>/dev/null \
            || uci -q get homeproxy.config.self_mark 2>/dev/null \
            || echo "100")"
  [[ -z "$SELF_MARK" || "$SELF_MARK" == "nil" ]] && SELF_MARK="100"
fi

#################### 读取 LAN 绕过 IP ####################
if [[ -f "${WORK_DIR}/bypass_ips.txt" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    BYPASS_IPS+=("$line")
  done < "${WORK_DIR}/bypass_ips.txt"
fi

#################### 探测 HomeProxy 类型 ####################
detect_flavor() {
  if [[ -f "$HP_GEN_UC" && -f "$HP_UCI_CONFIG" ]]; then
    echo "uci"
  else
    echo "file"
  fi
}

#################### 面板：clash_api secret / 局域网 IP / 安装 ####################
clash_api_secret() {
  # 生成并持久化一个随机 secret；已存在则直接复用，保证重启后不变
  if [[ -s "$CLASH_API_SECRET_FILE" ]]; then
    cat "$CLASH_API_SECRET_FILE"
    return 0
  fi
  local s=""
  s="$(head -c 24 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [[ -z "$s" ]] && s="$(openssl rand -hex 24 2>/dev/null)" || true
  [[ -z "$s" ]] && s="$(date +%s%N | md5sum | cut -d' ' -f1)"
  mkdir -p "$(dirname "$CLASH_API_SECRET_FILE")"
  printf '%s' "$s" > "$CLASH_API_SECRET_FILE"
  chmod 600 "$CLASH_API_SECRET_FILE"
  echo "$s"
}

lan_ip() {
  local ip=""
  if command -v uci >/dev/null 2>&1; then
    ip="$(uci -q get network.lan.ipaddr 2>/dev/null)" || true
  fi
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 -o addr show br-lan 2>/dev/null | awk '{print $4; exit}')"
    ip="${ip%%/*}"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 -o addr show 2>/dev/null | awk '$2!="lo"{print $4; exit}')"
    ip="${ip%%/*}"
  fi
  [[ -z "$ip" ]] && ip="192.168.1.1"
  echo "$ip"
}

try_download() {
  # $1 = 本地目标 zip，其余参数为候选 URL（依次尝试镜像）
  local dest="$1"; shift
  local u
  for u in "$@"; do
    info "尝试下载面板：${u}" >&2
    if curl -fsSL --connect-timeout 15 --max-time 180 -A "Mozilla/5.0" "$u" -o "$dest"; then
      return 0
    fi
    warn "下载失败：${u}" >&2
  done
  return 1
}

detect_oc_dashboard() {
  # 探测 OpenClash 已安装的面板目录（zashboard / yacd / metacubexd 静态文件）
  # 返回可用的绝对目录；找不到则无输出并返回 1
  local candidates=()
  if command -v uci >/dev/null 2>&1; then
    local p; p="$(uci -q get openclash.config.dashboard_path 2>/dev/null)" || true
    [[ -n "$p" ]] && candidates+=("$p")
  fi
  candidates+=("/etc/openclash/dashboard" "/usr/share/openclash/dashboard")

  local base
  for base in "${candidates[@]}"; do
    [[ -d "$base" ]] || continue
    # 优先：目录内直接有 index.html（已是展平后的面板）
    if [[ -f "$base/index.html" ]]; then
      echo "$base"; return 0
    fi
    # 否则在一级子目录里找一个含 index.html 的（OC 可能按面板名分子目录）
    local sub
    while IFS= read -r sub; do
      if [[ -f "$sub/index.html" ]]; then
        echo "$sub"; return 0
      fi
    done < <(find "$base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
  done
  return 1
}

resolve_dashboard_dir() {
  # 决定 external_ui 用哪个目录：auto 且用户尚未显式选择独立安装时，优先复用 OC 面板
  if [[ "$DASHBOARD_REUSE_OC" == "auto" && -z "${DASHBOARD_REUSE_SOURCE:-}" ]]; then
    local oc_dir; oc_dir="$(detect_oc_dashboard)" || true
    if [[ -n "$oc_dir" ]]; then
      DASHBOARD_DIR="$oc_dir"
    else
      DASHBOARD_DIR="/etc/homeproxy/ui"
    fi
  fi
}

setup_dashboard_firewall() {
  # 仅放行 LAN 区访问面板端口，避免 0.0.0.0 监听暴露到 WAN
  if ! command -v uci >/dev/null 2>&1; then
    warn "未找到 uci，跳过防火墙规则；请确保 LAN 可访问 :${CLASH_API_PORT}。"
    return 0
  fi
  if uci show firewall 2>/dev/null | grep -q "Allow-HomeProxy-Dashboard"; then
    info "防火墙规则已存在：Allow-HomeProxy-Dashboard"
    return 0
  fi
  local rid
  rid="$(uci add firewall rule 2>/dev/null)" || { warn "添加防火墙规则失败。"; return 0; }
  uci -q set "firewall.${rid}.name=Allow-HomeProxy-Dashboard"
  uci -q set "firewall.${rid}.src=lan"
  uci -q set "firewall.${rid}.proto=tcp"
  uci -q set "firewall.${rid}.dest_port=${CLASH_API_PORT}"
  uci -q set "firewall.${rid}.target=ACCEPT"
  uci commit firewall 2>/dev/null || { warn "提交防火墙失败。"; return 0; }
  if [[ -x /etc/init.d/firewall ]]; then
    /etc/init.d/firewall restart >/dev/null 2>&1 || true
  fi
  info "已放行 LAN → 路由器 :${CLASH_API_PORT}（仅 LAN 区可访问面板）。"
}

dashboard_info() {
  local secret; secret="$(clash_api_secret)"
  local lip; lip="$(lan_ip)"
  echo
  echo "=============================================="
  echo "  面板访问信息"
  echo "=============================================="
  echo "  本地面板（sing-box 托管）： http://${lip}:${CLASH_API_PORT}/ui/"
  echo "  备用（官方托管，无需安装）： https://d.metacubex.one"
  echo "    —— 在该页『API 地址』填： http://${lip}:${CLASH_API_PORT}"
  echo "    —— 密钥 (secret)： ${secret}"
  echo "----------------------------------------------"
  echo "  说明："
  echo "   · /ui 由 sing-box clash_api 直接托管，同源访问无需额外 CORS。"
  echo "   · 本地面板文件位于：${DASHBOARD_DIR}"
  if [[ -n "${DASHBOARD_REUSE_SOURCE:-}" ]]; then
    echo "   · 当前复用来源：${DASHBOARD_REUSE_SOURCE}"
  fi
  echo "   · secret 已持久化到 ${CLASH_API_SECRET_FILE}，重启不变。"
  echo "   · 请先执行菜单 [3] 生成并应用配置，clash_api 才会生效。"
  echo "   · 若 /ui 打不开，多半是 ${DASHBOARD_DIR} 为空或下载失败；"
  echo "     可重跑 [4] 安装，或改用上面的官方托管面板。"
  echo "   · 注意：access_control_allow_private_network 需 sing-box ≥1.10；"
  echo "     若 sing-box check 报未知字段（旧版），删掉该字段即可，本地 /ui 不受影响。"
  echo "=============================================="
}

setup_dashboard() {
  echo
  clash_api_secret >/dev/null   # 确保 secret 已生成并持久化

  local force=false
  [[ "${1:-}" == "--force" ]] && force=true

  # ---------- 路径 A：复用 OpenClash 已安装的面板（zashboard 等）----------
  local oc_dir=""
  if [[ "$DASHBOARD_REUSE_OC" != "never" ]]; then
    oc_dir="$(detect_oc_dashboard)" || true
  fi

  if [[ -n "$oc_dir" ]]; then
    # 让用户确认是否复用（默认复用）
    echo "检测到 OpenClash 面板目录： ${oc_dir}"
    read -r -p "复用该面板作为 HomeProxy 面板？[Y/n]: " ans || ans=""
    if [[ "${ans,,}" != "n" && "${ans,,}" != "no" ]]; then
      DASHBOARD_DIR="$oc_dir"
      DASHBOARD_REUSE_SOURCE="OpenClash 面板：${oc_dir}"
      info "已指向 OpenClash 面板，HomeProxy 运行时将通过 /ui 共用它（不重复下载）。"
      setup_dashboard_firewall
      dashboard_info
      return 0
    fi
    warn "已跳过复用，将改为下载并安装独立面板。"
  fi

  # 未复用（OC 不存在，或用户选择不复用，或 OC 已被卸载）：用默认独立目录
  DASHBOARD_DIR="/etc/homeproxy/ui"
  DASHBOARD_REUSE_SOURCE=""

  # ---------- 路径 B：自己下载安装（默认目录 /etc/homeproxy/ui）----------
  DASHBOARD_REUSE_SOURCE=""
  mkdir -p "$DASHBOARD_DIR"

  if [[ -f "${DASHBOARD_DIR}/index.html" && "$force" != "true" ]]; then
    info "面板文件已存在于 ${DASHBOARD_DIR}（index.html），跳过下载。"
  else
    if ! command -v unzip >/dev/null 2>&1; then
      warn "缺少 unzip，无法解压面板；请先 opkg install unzip。"
    else
      local zip="${WORK_DIR}/dashboard.zip"
      if ! try_download "$zip" \
           "$DASHBOARD_DOWNLOAD_URL" \
           "https://ghfast.top/${DASHBOARD_DOWNLOAD_URL}" \
           "https://mirror.ghproxy.com/${DASHBOARD_DOWNLOAD_URL}" \
           "https://ghproxy.net/${DASHBOARD_DOWNLOAD_URL}"; then
        warn "面板下载全部失败。可手动把 ${DASHBOARD_TOOL} 解压到 ${DASHBOARD_DIR}，"
        warn "或直接用官方托管面板 https://d.metacubex.one（填 http://$(lan_ip):${CLASH_API_PORT} + secret）。"
      else
        local tmp; tmp="$(mktemp -d)"
        if unzip -oq "$zip" -d "$tmp" 2>/dev/null; then
          local src; src="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
          [[ -z "$src" ]] && src="$tmp"
          rm -rf "${DASHBOARD_DIR:?}"/* 2>/dev/null || true
          cp -a "$src"/. "$DASHBOARD_DIR"/ 2>/dev/null || cp -r "$src"/. "$DASHBOARD_DIR"/
          rm -rf "$tmp"
          if [[ -f "${DASHBOARD_DIR}/index.html" ]]; then
            info "面板已安装到 ${DASHBOARD_DIR}（${DASHBOARD_TOOL}）。"
          else
            warn "解压后未找到 index.html，请检查面板包结构。"
          fi
        else
          warn "解压失败：$zip"
        fi
      fi
    fi
  fi

  setup_dashboard_firewall
  dashboard_info
}

#################### 菜单 ####################
list_subscriptions() {
  local count
  count=$(jq 'length' "$SUB_FILE")
  if [[ "$count" -eq 0 ]]; then
    echo "  （暂无订阅）"
  else
    jq -r 'to_entries[] | "  \(.key + 1). \(.value)"' "$SUB_FILE"
  fi
}

menu() {
  clear
  echo "=============================================="
  echo "   HomeProxy 配置生成 · 双路径自动应用版"
  echo "=============================================="
  echo "已添加订阅："
  list_subscriptions
  echo "----------------------------------------------"
  echo "  1) 添加订阅链接（可连续添加多条）"
  echo "  2) 拉取最新规则（清空 sing-box 规则缓存）"
  echo "  3) 生成配置并自动应用到 HomeProxy"
  echo "  4) 配置面板（优先复用 OC 的 zashboard，否则下载）"
  echo "  5) 显示面板访问信息"
  echo "  0) 退出"
  echo "----------------------------------------------"
  echo "  应用模式 APPLY_MODE=${APPLY_MODE}（auto/uci/file）"
  echo "=============================================="
  read -r -p "请选择 [0-5]: " choice || { echo; exit 0; }
  case "$choice" in
    1) add_subscription ;;
    2) refresh_rules ;;
    3) build_and_apply ;;
    4) setup_dashboard ;;
    5) dashboard_info ;;
    0) exit 0 ;;
    *) warn "无效选项"; sleep 1; menu ;;
  esac
}

#################### 选项 1：添加订阅 ####################
add_subscription() {
  echo
  read -r -p "请输入订阅链接（留空返回菜单）: " url || { echo; menu; }
  [[ -z "$url" ]] && menu

  if [[ ! "$url" =~ ^https?:// ]]; then
    warn "链接必须以 http:// 或 https:// 开头"
    sleep 1
    add_subscription
  fi

  if jq -e --arg u "$url" 'index($u) != null' "$SUB_FILE" >/dev/null; then
    warn "该订阅已存在"
  else
    jq --arg u "$url" '. + [$u]' "$SUB_FILE" > "${SUB_FILE}.tmp" && mv "${SUB_FILE}.tmp" "$SUB_FILE"
    info "已添加：$url"
  fi

  read -r -p "继续添加？[y/N]: " cont || cont=""
  if [[ "${cont,,}" == "y" || "${cont,,}" == "yes" ]]; then
    add_subscription
  else
    menu
  fi
}

#################### 选项 2：清空规则缓存 ####################
refresh_rules() {
  info "清空 sing-box 规则集缓存（cache_file）..."
  rm -f /var/run/homeproxy/cache.db 2>/dev/null || true
  info "完成。下次 HomeProxy 启动时会重新拉取远程 rule_set。"
  sleep 2
  menu
}

#################### 订阅解析 ####################
parse_subscription_to_outbounds() {
  local url="$1"
  local tmp
  tmp="$(mktemp)"

  info "获取订阅：$url" >&2
  if ! curl -fsSL --connect-timeout 15 --max-time 60 -A "sing-box/1.10" "$url" -o "$tmp"; then
    warn "获取失败，跳过：$url" >&2
    rm -f "$tmp"
    return 0
  fi

  if jq -e 'has("outbounds") and (.outbounds | type == "array")' "$tmp" >/dev/null 2>&1; then
    info "识别为 sing-box JSON 订阅，提取 outbounds" >&2
    jq '.outbounds' "$tmp"
    rm -f "$tmp"
    return 0
  fi

  if [[ -n "$SUB2SINGBOX_BIN" ]]; then
    info "调用 ${SUB2SINGBOX_BIN} 转换订阅 ..." >&2
    local conv
    conv="$(mktemp)"
    if "$SUB2SINGBOX_BIN" convert -s "$url" -o "$conv" >/dev/null 2>&1 && \
       jq -e 'has("outbounds") and (.outbounds | type == "array")' "$conv" >/dev/null 2>&1; then
      info "转换成功，提取 outbounds" >&2
      jq '.outbounds' "$conv"
      rm -f "$tmp" "$conv"
      return 0
    else
      warn "sub2sing-box 未能识别该订阅格式" >&2
      rm -f "$conv"
    fi
  else
    warn "未安装 sub2sing-box，无法自动转换 Clash/base64 订阅。" >&2
    warn "可执行 opkg install sub2sing-box，或先用 Sub-Store 转为 sing-box JSON。" >&2
  fi

  local raw="${WORK_DIR}/raw-$(echo "$url" | md5sum | cut -d' ' -f1).txt"
  cp "$tmp" "$raw"
  warn "原始订阅已保存：$raw" >&2
  rm -f "$tmp"
  return 0
}

collect_all_nodes() {
  local urls
  urls=$(jq -r '.[]' "$SUB_FILE")
  : > "$NODES_FILE"

  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    local part
    part=$(parse_subscription_to_outbounds "$u")
    if [[ -n "$part" ]]; then
      echo "$part" >> "$NODES_FILE"
    fi
  done <<< "$urls"

  if [[ ! -s "$NODES_FILE" ]]; then
    warn "没有提取到任何节点，将生成只含 direct/block 的配置。"
    echo '[]' > "$NODES_FILE"
    return 0
  fi

  jq -s 'add | unique_by(.tag)' "$NODES_FILE" > "${NODES_FILE}.merged" \
    && mv "${NODES_FILE}.merged" "$NODES_FILE"

  info "共提取到 $(jq 'length' "$NODES_FILE") 个节点 outbound。"
}

#################### 生成裸 sing-box JSON ####################
build_json() {
  local secret; secret="$(clash_api_secret)"
  resolve_dashboard_dir || true
  NODE_TAGS=$(jq -r '.[].tag // empty' "$NODES_FILE" 2>/dev/null || true)
  SELECTOR_OPTIONS='["direct"]'
  if [[ -n "$NODE_TAGS" ]]; then
    SELECTOR_OPTIONS=$(echo "$NODE_TAGS" | jq -R . | jq -s '. + ["direct"]')
  fi

  local bypass_json="[]"
  if [[ ${#BYPASS_IPS[@]} -gt 0 ]]; then
    bypass_json=$(printf '%s\n' "${BYPASS_IPS[@]}" | jq -R . | jq -s '{ source_ip_cidr: ., outbound: "direct-out" }' | jq -c .)
    bypass_json="[$bypass_json]"
  fi

  info "生成裸 sing-box JSON（防污染 + 分流）..."
  jq -n \
    --argjson nodes "$(cat "$NODES_FILE")" \
    --argjson selector_options "$SELECTOR_OPTIONS" \
    --arg geosite_cn "$GEOSITE_CN_URL" \
    --arg geoip_cn "$GEOIP_CN_URL" \
    --arg geosite_gfw "$GEOSITE_GFW_URL" \
    --argjson extra_sets "$(printf '%s\n' "${RULE_SETS_EXTRA[@]}" | jq -R 'split("|") | {url:.[0], tag:.[1]}' | jq -s .)" \
    --arg self_mark "$SELF_MARK" \
    --arg listen_addr "$LISTEN_ADDR" \
    --arg redirect_port "$REDIRECT_PORT" \
    --arg tproxy_port "$TPROXY_PORT" \
    --arg mixed_port "$MIXED_PORT" \
    --argjson bypass_rules "$bypass_json" \
    --arg clash_bind "$CLASH_API_BIND" \
    --arg clash_port "$CLASH_API_PORT" \
    --arg clash_secret "$secret" \
    --arg external_ui "$DASHBOARD_DIR" \
    --arg external_ui_dl "$DASHBOARD_DOWNLOAD_URL" \
    '
    ($nodes | map(if has("domain_resolver") then . else . + {"domain_resolver": "dns-remote"} end)) as $nodes_fixed |

    ($nodes_fixed + [
      { "type": "direct", "tag": "direct-out", "domain_resolver": "dns-remote" },
      { "type": "block",  "tag": "block-out"  }
    ]) as $all_nodes |

    ({
      "type": "selector",
      "tag": "proxy",
      "outbounds": $selector_options,
      "default": (if ($selector_options | length) > 0 then $selector_options[0] else "direct-out" end),
      "interrupt_exist_connections": true
    }) as $selector |

    (if ($nodes_fixed | length) > 0 then
      [{
        "type": "urltest",
        "tag": "auto-proxy",
        "outbounds": ($nodes_fixed | map(.tag)),
        "url": "https://www.gstatic.com/generate_204",
        "interval": "10m",
        "tolerance": 50,
        "interrupt_exist_connections": true
      }]
    else [] end) as $urltest |

    ([
      { "tag": "geosite-cn",  "type": "remote", "format": "binary", "url": $geosite_cn,  "download_detour": "proxy" },
      { "tag": "geoip-cn",    "type": "remote", "format": "binary", "url": $geoip_cn,    "download_detour": "proxy" },
      { "tag": "geosite-gfw", "type": "remote", "format": "binary", "url": $geosite_gfw, "download_detour": "proxy" }
    ] + $extra_sets) as $rule_sets |

    {
      "log": { "level": "info", "timestamp": true },
      "experimental": {
        "cache_file": { "enabled": true, "store_fakeip": true, "store_rdrc": true },
        "clash_api": {
          "external_controller": ($clash_bind + ":" + $clash_port),
          "secret": $clash_secret,
          "external_ui": $external_ui,
          "external_ui_download_url": $external_ui_dl,
          "external_ui_download_detour": "proxy",
          "default_mode": "rule",
          "access_control_allow_origin": ["*"],
          "access_control_allow_private_network": true
        }
      },
      "dns": {
        "independent_cache": true,
        "disable_cache": false,
        "strategy": "prefer_ipv4",
        "servers": [
          {
            "tag": "dns-cn",
            "type": "https",
            "server": "223.5.5.5",
            "server_port": 443,
            "tls": { "enabled": true, "server_name": "dns.alidns.com" },
            "path": "/dns-query",
            "detour": "direct-out"
          },
          {
            "tag": "dns-remote",
            "type": "https",
            "server": "1.1.1.1",
            "server_port": 443,
            "tls": { "enabled": true, "server_name": "cloudflare-dns.com" },
            "path": "/dns-query",
            "detour": "proxy"
          },
          { "tag": "dns-system", "type": "local", "detour": "direct-out" },
          {
            "tag": "dns-fakeip",
            "type": "fakeip",
            "inet4_range": "198.18.0.0/15",
            "inet6_range": "fc00::/18"
          }
        ],
        "rules": [
          { "ip_is_private": true, "server": "dns-system" },
          { "rule_set": ["geosite-apple", "geosite-microsoft"], "server": "dns-system" },
          { "rule_set": "geosite-cn", "server": "dns-cn" },
          { "rule_set": "geosite-cn", "query_type": ["HTTPS", "SVCB"], "server": "dns-cn" },
          { "query_type": ["HTTPS", "SVCB"], "action": "reject" },
          { "query_type": ["A", "AAAA"], "rule_set": "geosite-gfw", "server": "dns-fakeip" },
          { "server": "dns-remote" }
        ],
        "final": "dns-remote"
      },
      "inbounds": [
        { "type": "mixed", "tag": "mixed-in", "listen": $listen_addr, "listen_port": ($mixed_port | tonumber) },
        { "type": "redirect", "tag": "redirect-in", "listen": $listen_addr, "listen_port": ($redirect_port | tonumber), "sniff": true, "sniff_override_destination": false },
        # 修正：tproxy 的 network 省略即同时监听 TCP+UDP；只写 "udp" 会限制 TCP 透明代理
        { "type": "tproxy", "tag": "tproxy-in", "listen": $listen_addr, "listen_port": ($tproxy_port | tonumber), "sniff": true, "sniff_override_destination": false }
      ],
      "outbounds": ([$selector] + $urltest + $all_nodes),
      "route": {
        "default_mark": ($self_mark | tonumber),
        "auto_detect_interface": true,
        "default_domain_resolver": "dns-remote",
        "rules": (
          $bypass_rules + [
            { "action": "sniff" },
            { "protocol": "dns", "action": "hijack-dns" },
            { "ip_is_private": true, "outbound": "direct-out" },
            { "rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct-out" },
            { "rule_set": ["geosite-apple", "geosite-microsoft"], "outbound": "direct-out" },
            { "ip_cidr": ["198.18.0.0/15"], "outbound": "proxy" },
            { "rule_set": ["geosite-netflix", "geosite-disney", "geosite-youtube", "geosite-openai"], "outbound": "proxy" },
            { "protocol": "quic", "port": 443, "action": "reject" },
            { "rule_set": "geosite-gfw", "outbound": "proxy" }
          ]
        ),
        "rule_set": $rule_sets,
        "final": "proxy"
      }
    }
    ' > "$FINAL_FILE"

  if ! jq . "$FINAL_FILE" >/dev/null 2>&1; then
    error "生成的 JSON 无效：$FINAL_FILE"
    exit 1
  fi

  info "裸配置已生成：$FINAL_FILE"
  echo "节点数：$(jq '[.outbounds[] | select(.type != "selector" and .type != "urltest" and .type != "direct" and .type != "block")] | length' "$FINAL_FILE")"
  echo "规则集数：$(jq '.route.rule_set | length' "$FINAL_FILE")"
  echo "入站数：$(jq '.inbounds | length' "$FINAL_FILE")"
}

#################### 路径一：文件型 ####################
apply_file_based() {
  local ts bak
  ts="$(date +%Y%m%d-%H%M%S)"
  bak="${BACKUP_DIR}/hiddify-c.json.bak.${ts}"
  mkdir -p "$(dirname "$HP_CUSTOM_JSON")"
  if [[ -f "$HP_CUSTOM_JSON" ]]; then
    cp "$HP_CUSTOM_JSON" "$bak"
    info "已备份原配置：$bak"
  fi

  cp "$FINAL_FILE" "$HP_CUSTOM_JSON"
  info "已写入裸 JSON：$HP_CUSTOM_JSON"

  if command -v uci >/dev/null 2>&1; then
    local cur
    cur="$(uci -q get homeproxy.config.routing_mode || true)"
    if [[ "$cur" != "custom" ]]; then
      uci set homeproxy.config.routing_mode='custom'
      uci commit homeproxy
      info "已将 HomeProxy 路由模式切换为 custom"
    else
      info "HomeProxy 路由模式已经是 custom，无需切换"
    fi
  else
    warn "未找到 uci，请手动在 LuCI 把路由模式设为 Custom。"
  fi

  if [[ -x /etc/init.d/homeproxy ]]; then
    info "重启 HomeProxy ..."
    /etc/init.d/homeproxy restart >/dev/null 2>&1 && info "重启成功。" || warn "重启返回非零，请检查日志。"
  else
    warn "未找到 /etc/init.d/homeproxy，无法自动重启。"
  fi

  echo
  echo "【验证】"
  echo "  ls -l /var/run/homeproxy/sing-box-c.json"
  echo "  sing-box check -c /var/run/homeproxy/sing-box-c.json"
  echo "  tail -n 50 /var/run/homeproxy/sing-box-c.log"
  echo "  回滚：cp ${bak} ${HP_CUSTOM_JSON} && /etc/init.d/homeproxy restart"
}

#################### 路径二：标准 immortalwrt UCI ####################
apply_uci_based() {
  if ! command -v uci >/dev/null 2>&1; then
    error "未找到 uci 命令，无法写 UCI 段。"
    return 1
  fi

  info "标准 immortalwrt 路径：写入 UCI 段"

  ########## 2.1 注入订阅 URL 并拉取节点 ##########
  local sub_urls have_http_sub=false
  sub_urls=$(jq -r '.[]' "$SUB_FILE")
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    case "$u" in
      http://*|https://*)
        uci add_list homeproxy.subscription.subscription_url="$u" 2>/dev/null || true
        have_http_sub=true
        ;;
    esac
  done <<< "$sub_urls"

  if $have_http_sub; then
    uci commit homeproxy
    if [[ -x "$HP_SUB_UPDATE" ]]; then
      info "执行订阅更新 ..."
      "$HP_SUB_UPDATE" >/dev/null 2>&1 || warn "订阅更新脚本返回非零，请检查日志。"
    else
      warn "未找到 $HP_SUB_UPDATE，无法自动拉取节点。"
    fi
  else
    warn "没有 http(s) 订阅链接；UCI 路径需要标准订阅 URL 来生成 node 段。"
    warn "sing-box JSON 订阅请改用 APPLY_MODE=file。"
  fi

  ########## 2.2 枚举 node 段 ##########
  local node_sections=()
  while IFS= read -r line; do
    [[ "$line" == homeproxy.*=node ]] || continue
    local ns="${line#homeproxy.}"
    ns="${ns%=node}"
    node_sections+=("$ns")
  done < <(uci show homeproxy 2>/dev/null)

  # 关键修正：node_sections 为空时立即中止，不写半套 UCI
  if [[ ${#node_sections[@]} -eq 0 ]]; then
    error "UCI 路径没有找到任何 node 段（订阅可能未被 update_subscriptions.uc 解析）。"
    error "中止 UCI 写入，避免生成引用不存在节点的 routing_rule / dns_rule。"
    return 1
  fi

  ########## 2.3 创建 routing_node（关键：引用一律用 uci 段名，不用 label）##########
  local rn_names=() ridx=0
  for ns in "${node_sections[@]}"; do
    local rn
    rn="$(uci add homeproxy routing_node)"   # rn 即段名（如 cfgXXXX），下游引用必须用段名
    uci set "homeproxy.${rn}.label=routing_node_${ridx}"
    uci set "homeproxy.${rn}.enabled=1"
    uci set "homeproxy.${rn}.domain_strategy=ipv4_only"
    uci set "homeproxy.${rn}.domain_resolver=default-dns"   # 节点域名解析走系统 DNS
    uci set "homeproxy.${rn}.node=${ns}"
    rn_names+=("$rn")                       # 存段名，不是 label
    ridx=$((ridx + 1))
  done
  info "已创建 ${#rn_names[@]} 个 routing_node（domain_resolver=default-dns）。"

  local proxy_label="${rn_names[0]}"         # 段名，供 default_outbound / routing_rule.outbound 引用

  ########## 2.4 routing 顶层 ##########
  uci set homeproxy.config.routing_mode='custom'
  uci set homeproxy.config.routing_port='common'
  uci set homeproxy.config.proxy_mode='redirect_tproxy'
  # 端口在 infra 段（源码 uci.get(infra, 'redirect_port'/'tproxy_port')），不是 config 段
  uci set homeproxy.infra.redirect_port="$REDIRECT_PORT"
  uci set homeproxy.infra.tproxy_port="$TPROXY_PORT"
  uci set homeproxy.config.ipv6_support='1'
  uci set homeproxy.routing.default_outbound="$proxy_label"   # 段名，get_outbound 据此读 node
  uci set homeproxy.routing.domain_strategy='ipv4_only'
  uci set homeproxy.routing.udp_timeout='300'

  ########## 2.5 ruleset（RS_MAP 存段名，rule_set 引用必须命中 cfg-<段名>-rule）##########
  declare -A RS_MAP=()
  add_ruleset() {
    local url="$1" tag="$2"
    local tmp name
    tmp="$(basename "$url")"
    name="${tmp%.*}"
    name="$(echo "$name" | sed 's/[-.*#@!&]/_/g')"
    case "$url" in
      *geoip*|*_ip*) [[ "$name" != *geoip* ]] && name="geoip_${name}" ;;
      *geosite*)      [[ "$name" != *geosite* ]] && name="geosite_${name}" ;;
    esac
    local rs; rs="$(uci add homeproxy ruleset)"
    uci set "homeproxy.${rs}.label=${name}"
    uci set "homeproxy.${rs}.enabled=1"
    uci set "homeproxy.${rs}.type=remote"
    uci set "homeproxy.${rs}.update_interval=24h"
    uci set "homeproxy.${rs}.url=${url}"
    uci set "homeproxy.${rs}.format=binary"
    RS_MAP["$tag"]="$rs"                    # 关键修正：存段名而非 label
  }
  add_ruleset "$GEOSITE_CN_URL" "geosite-cn"
  add_ruleset "$GEOIP_CN_URL"   "geoip-cn"
  add_ruleset "$GEOSITE_GFW_URL" "geosite-gfw"
  local raw
  for raw in "${RULE_SETS_EXTRA[@]}"; do
    add_ruleset "${raw%%|*}" "${raw##*|}"
  done

  ########## 2.6 dns 顶层 + dns_server + dns_rule ##########
  # 源码读取：default_strategy / default_server / disable_cache
  uci set homeproxy.dns.default_strategy='ipv4_only'
  uci set homeproxy.dns.disable_cache='0'

  # dns_server 段读取的是 type/server/server_port/path/tls_sni/outbound，不读 address！
  add_dns_server() {
    local label="$1" server="$2" port="$3" path="$4" sni="$5" outbound="$6"
    local ds; ds="$(uci add homeproxy dns_server)"
    uci set "homeproxy.${ds}.label=dns_server_${label}"
    uci set "homeproxy.${ds}.enabled=1"
    uci set "homeproxy.${ds}.type=https"
    uci set "homeproxy.${ds}.server=${server}"
    uci set "homeproxy.${ds}.server_port=${port}"
    uci set "homeproxy.${ds}.path=${path}"
    uci set "homeproxy.${ds}.tls_sni=${sni}"   # 必填：IP 形态 DoH 也需 server_name 校验证书
    uci set "homeproxy.${ds}.outbound=${outbound}"
    echo "$ds"                                 # 返回段名供 default_server / dns_rule.server 引用
  }
  local dns_cn_ds dns_remote_ds
  # 国内 DoH：直连（outbound=direct-out）；远程 DoH：走代理（outbound=proxy 段名）
  dns_cn_ds="$(add_dns_server "cn" "223.5.5.5" "443" "/dns-query" "dns.alidns.com" "direct-out")"
  dns_remote_ds="$(add_dns_server "remote" "1.1.1.1" "443" "/dns-query" "cloudflare-dns.com" "$proxy_label")"

  # default_server 经 get_resolver() 变 cfg-<段名>-dns，必须传段名
  uci set homeproxy.dns.default_server="$dns_remote_ds"

  add_dns_rule() {
    local label="$1" server="$2"; shift 2
    local dr; dr="$(uci add homeproxy dns_rule)"
    uci set "homeproxy.${dr}.label=dns_rule_${label}"
    uci set "homeproxy.${dr}.enabled=1"
    uci set "homeproxy.${dr}.mode=default"
    uci set "homeproxy.${dr}.server=${server}"   # 段名或 default-dns/system-dns
    local r
    for r in "$@"; do
      uci add_list "homeproxy.${dr}.rule_set=${r}"   # 段名
    done
  }
  add_dns_rule "cn" "$dns_cn_ds" "${RS_MAP[geosite-cn]}"
  add_dns_rule "apple_ms" "default-dns" "${RS_MAP[geosite-apple]}" "${RS_MAP[geosite-microsoft]}"
  add_dns_rule "gfw" "$dns_remote_ds" "${RS_MAP[geosite-gfw]}"   # 显式 gfw → 远程 DoH

  # 路由级域名解析也走远程 DoH over 代理（更严格防污染）
  uci set homeproxy.routing.default_outbound_dns="$dns_remote_ds"

  ########## 2.7 routing_rule（outbound / rule_set 均用段名）##########
  add_route_rule() {
    local label="$1" outbound="$2" ip_priv="${3:-0}"; shift 3
    local rr; rr="$(uci add homeproxy routing_rule)"
    uci set "homeproxy.${rr}.label=routing_rule_${label}"
    uci set "homeproxy.${rr}.enabled=1"
    uci set "homeproxy.${rr}.source_ip_is_private=0"
    uci set "homeproxy.${rr}.ip_is_private=${ip_priv}"          # private 规则需为 1
    uci set "homeproxy.${rr}.rule_set_ipcidr_match_source=0"
    uci set "homeproxy.${rr}.outbound=${outbound}"              # 段名或 direct-out/block-out
    local r
    for r in "$@"; do
      uci add_list "homeproxy.${rr}.rule_set=${r}"              # 段名
    done
  }
  add_route_rule "private" "direct-out" "1"
  add_route_rule "cn" "direct-out" "0" "${RS_MAP[geosite-cn]}" "${RS_MAP[geoip-cn]}"
  add_route_rule "apple_ms" "direct-out" "0" "${RS_MAP[geosite-apple]}" "${RS_MAP[geosite-microsoft]}"
  add_route_rule "streaming" "$proxy_label" "0" "${RS_MAP[geosite-netflix]}" "${RS_MAP[geosite-disney]}" "${RS_MAP[geosite-youtube]}" "${RS_MAP[geosite-openai]}"
  add_route_rule "gfw" "$proxy_label" "0" "${RS_MAP[geosite-gfw]}"

  ########## 2.8 面板 clash_api（best-effort：键名随 HomeProxy 版本可能不同）##########
  # UCI 路径下 clash_api 由 generate_client.uc 重新生成，下面这些键可能被读取、也可能被忽略。
  # 若生成后的配置里没有 clash_api（用 sing-box check 验证），请在 LuCI 的『客户端/服务状态』
  # 里手动设置 external_controller / secret / external_ui，或用 HomeProxy 自带的
  # 『Clash dashboard version 更新』按钮拉取 UI。
  local dsecret; dsecret="$(clash_api_secret)"
  uci -q set homeproxy.config.external_controller="${CLASH_API_BIND}:${CLASH_API_PORT}" || true
  uci -q set homeproxy.config.secret="$dsecret" || true
  uci -q set homeproxy.config.external_ui="$DASHBOARD_DIR" || true
  uci -q set homeproxy.config.external_ui_download_url="$DASHBOARD_DOWNLOAD_URL" || true
  info "已尝试写入 clash_api（external_controller/secret/external_ui），UCI 路径请以 sing-box check 验证是否生效。"

  ########## 2.9 提交并重启 ##########
  uci commit homeproxy
  info "UCI 配置已提交。"

  if [[ -x /etc/init.d/homeproxy ]]; then
    info "重启 HomeProxy ..."
    /etc/init.d/homeproxy restart >/dev/null 2>&1 && info "重启成功。" || warn "重启返回非零，请检查日志。"
  else
    warn "未找到 /etc/init.d/homeproxy，无法自动重启。"
  fi

  echo
  echo "【验证】"
  echo "  uci show homeproxy | grep -E 'routing_node|routing_rule|dns_server|dns_rule|ruleset' | head -20"
  echo "  sing-box check -c /var/run/homeproxy/sing-box-c.json"
  echo "  tail -n 50 /var/run/homeproxy/sing-box-c.log"
  echo "  —— UCI 路径使用 realip + 远程 DoH over 代理，不启用 FakeIP。"
  echo "  —— 若想某台 LAN 设备完全不走代理，用 LuCI 的『访问控制 / LAN 策略』。"
}

#################### 选项 3：生成 + 自动应用 ####################
build_and_apply() {
  echo
  if [[ $(jq 'length' "$SUB_FILE") -eq 0 ]]; then
    warn "尚未添加任何订阅。"
    read -r -p "仍然生成只含直连/拦截的配置并应用？[y/N]: " ans || ans=""
    [[ "${ans,,}" != "y" ]] && { menu; return; }
  fi

  info "收集订阅节点 ..."
  collect_all_nodes
  build_json

  echo "----------------------------------------------"
  info "开始自动应用 ..."

  local mode="$APPLY_MODE"
  if [[ "$mode" == "auto" ]]; then
    mode="$(detect_flavor)"
    info "自动探测结果：HomeProxy 类型 = ${mode}"
  fi

  case "$mode" in
    uci)
      if ! apply_uci_based; then
        warn "UCI 路径不可用（无节点段或 uci 缺失），回退到文件型。"
        apply_file_based
      fi
      ;;
    file|*)
      apply_file_based
      ;;
  esac

  echo "----------------------------------------------"
  read -r -p "按回车返回菜单 ..." _ || true
  menu
}

#################### 启动 ####################
menu
