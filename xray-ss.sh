#!/usr/bin/env bash
# Xray SS Manager: standalone SS / SS2022 / VLESS + Reality / SOCKS5 / HTTP node manager.
# Supports major Linux distributions and common init systems; see README for scope.
# This is an independent implementation, not a fork of singbox-deploy.
set -Eeuo pipefail
umask 077

SERVICE_NAME=xray-ss
SERVICE=xray-ss.service
ETC_DIR="${XSS_ETC_DIR:-/etc/xray-ss}"
OPT_DIR="${XSS_OPT_DIR:-/opt/xray-ss}"
CORE_DIR="$OPT_DIR/versions"
CORE_LINK="${XSS_CORE_LINK:-/usr/local/bin/xray-ss-core}"
ENTRY="${XSS_ENTRY:-/usr/local/bin/xnode}"
CONFIG="$ETC_DIR/config.json"
HOST_FILE="$ETC_DIR/host.txt"    # 旧版全局连接地址：仅用于读取旧节点
NODE_HOSTS_FILE="$ETC_DIR/node-hosts.json"
NODE_META_FILE="$ETC_DIR/node-meta.json"
DDNS_FILE="$ETC_DIR/ddns.json"
DDNS_SERVICE_FILE="${XSS_DDNS_SERVICE_FILE:-/etc/systemd/system/xnode-ddns.service}"
DDNS_TIMER_FILE="${XSS_DDNS_TIMER_FILE:-/etc/systemd/system/xnode-ddns.timer}"
BACKUP_DIR="$ETC_DIR/backups"
UNIT_FILE="${XSS_UNIT_FILE:-/etc/systemd/system/$SERVICE}"
OPENRC_UNIT_FILE="${XSS_OPENRC_UNIT_FILE:-/etc/init.d/xray-ss}"
SYSV_UNIT_FILE="${XSS_SYSV_UNIT_FILE:-/etc/init.d/xray-ss}"
PROCD_UNIT_FILE="${XSS_PROCD_UNIT_FILE:-/etc/init.d/xray-ss}"
RUNIT_SERVICE_DIR="${XSS_RUNIT_SERVICE_DIR:-/etc/sv/xray-ss}"
RUNIT_ENABLED_DIR="${XSS_RUNIT_ENABLED_DIR:-/var/service/xray-ss}"
LOG_FILE="${XSS_LOG_FILE:-/var/log/xray-ss.log}"
PID_FILE="${XSS_PID_FILE:-/run/xray-ss.pid}"
MANUAL_UNIT_FILE="${XSS_MANUAL_UNIT_FILE:-$OPT_DIR/standalone-service.sh}"
GITHUB_API='https://api.github.com/repos/XTLS/Xray-core/releases'
# 默认安装目标版本；保留手动输入/选择其他版本的能力。
DEFAULT_XRAY_VERSION='v26.6.1'
# Reality 使用同一默认版本；候选站点仍需逐个通过实际隧道测试。
REALITY_MIN_XRAY_VERSION="$DEFAULT_XRAY_VERSION"
# 创建时选择协议；快速创建使用对应的默认加密、Reality 参数和代理账号。
DEFAULT_SS_METHOD='aes-256-gcm'
DEFAULT_SS2022_METHOD='2022-blake3-aes-256-gcm'
# 使用 IP 地址引导 DoH，避免 NAT 出口工具把节点目标解析成 Fake-IP。
# 同时提供 IPv4 / IPv6 入口，兼容只有 IPv6 的服务器。
DEFAULT_DNS_SERVERS='[
  "https+local://1.1.1.1/dns-query",
  "https+local://8.8.8.8/dns-query",
  "https+local://[2606:4700:4700::1111]/dns-query",
  "https+local://[2001:4860:4860::8888]/dns-query"
]'
# 已在 VPS 上逐个通过 Reality + Vision 和 HTTPS 测试的非 Cloudflare 目标。
# 每次创建打乱顺序，并在当前服务器重新实测，失败时继续尝试下一项。
REALITY_SERVERS=(
  www.bing.com www.amazon.com www.samsung.com www.nvidia.com www.sony.com
  www.oracle.com www.intel.com www.adobe.com www.yahoo.com www.ebay.com
)
DISTRO_ID=unknown
DISTRO_NAME=unknown
PKG_MANAGER=''
INIT_SYSTEM=''
XRAY_ARCH=''

say() { printf '%s\n' "$*"; }
info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
fail() { warn "$*"; return 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail '请使用 root 用户或 sudo 运行此脚本。'; }
need_core() { [[ -x "$CORE_LINK" ]] || fail '尚未安装 Xray 内核。主菜单选择 1 可自动安装并创建节点，或到高级设置中安装指定版本。'; }

# 仅在彩色终端中使用 ANSI，重定向、TERM=dumb 和 NO_COLOR 下保持纯文本。
ui_text() {
  local style="$1" text="$2"
  if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR+x}" ]]; then
    printf '\033[%sm%s\033[0m\n' "$style" "$text"
  else
    printf '%s\n' "$text"
  fi
}

ui_title() {
  say ''
  ui_text '36' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  ui_text '1;36' "  $1"
  ui_text '36' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
}

ui_section() { say ''; ui_text '1;36' "  $1"; }
ui_item() { printf '  %s）%s\n' "$1" "$2"; }
ui_back() { say ''; ui_item 0 "${1:-返回上级菜单}"; say ''; }

detect_distribution() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-${NAME:-$DISTRO_ID}}"
  fi
}

detect_architecture() {
  case "$(uname -m)" in
    x86_64|amd64) XRAY_ARCH=64 ;;
    i386|i486|i586|i686) XRAY_ARCH=32 ;;
    aarch64|arm64) XRAY_ARCH=arm64-v8a ;;
    armv7l|armv7*|armv8l) XRAY_ARCH=arm32-v7a ;;
    armv6l|armv6*) XRAY_ARCH=arm32-v6 ;;
    armv5tel|armv5tejl|armv5*) XRAY_ARCH=arm32-v5 ;;
    mips) XRAY_ARCH=mips32 ;;
    mipsel) XRAY_ARCH=mips32le ;;
    mips64) XRAY_ARCH=mips64 ;;
    mips64el) XRAY_ARCH=mips64le ;;
    ppc64) XRAY_ARCH=ppc64 ;;
    ppc64le) XRAY_ARCH=ppc64le ;;
    riscv64) XRAY_ARCH=riscv64 ;;
    s390x) XRAY_ARCH=s390x ;;
    loongarch64) XRAY_ARCH=loong64 ;;
    *) fail "不支持当前 CPU 架构 $(uname -m)。当前 Xray 官方发布包可能没有对应架构。"; return 1 ;;
  esac
}

detect_package_manager() {
  if command -v opkg >/dev/null 2>&1; then PKG_MANAGER=opkg
  elif command -v apt-get >/dev/null 2>&1; then PKG_MANAGER=apt
  elif command -v dnf >/dev/null 2>&1; then PKG_MANAGER=dnf
  elif command -v microdnf >/dev/null 2>&1; then PKG_MANAGER=microdnf
  elif command -v yum >/dev/null 2>&1; then PKG_MANAGER=yum
  elif command -v zypper >/dev/null 2>&1; then PKG_MANAGER=zypper
  elif command -v pacman >/dev/null 2>&1; then PKG_MANAGER=pacman
  elif command -v apk >/dev/null 2>&1 && [[ "${DISTRO_ID:-}" == openwrt ]]; then PKG_MANAGER=openwrt-apk
  elif command -v apk >/dev/null 2>&1; then PKG_MANAGER=apk
  elif command -v xbps-install >/dev/null 2>&1; then PKG_MANAGER=xbps
  elif command -v emerge >/dev/null 2>&1; then PKG_MANAGER=emerge
  else PKG_MANAGER=''
  fi
}

detect_init_system() {
  local pid1=''
  if [[ -n "${XSS_INIT_SYSTEM:-}" ]]; then
    case "$XSS_INIT_SYSTEM" in
      systemd|openrc|sysvinit|runit|procd|manual) INIT_SYSTEM="$XSS_INIT_SYSTEM"; return 0 ;;
      *) fail "XSS_INIT_SYSTEM 值无效：$XSS_INIT_SYSTEM"; return 1 ;;
    esac
  fi
  # BusyBox ps 不一定支持 -p/-o，直接读取 /proc 进程信息。
  if [[ -r /proc/1/comm ]]; then IFS= read -r pid1 < /proc/1/comm || true; fi
  if [[ "$pid1" == procd ]] || { [[ -r /etc/openwrt_release ]] && command -v ubus >/dev/null 2>&1 && [[ -x /etc/rc.common ]]; }; then
    INIT_SYSTEM=procd
  elif [[ "$pid1" == systemd || -d /run/systemd/system ]]; then
    command -v systemctl >/dev/null 2>&1 || { fail '检测到 systemd，但找不到 systemctl 命令。'; return 1; }
    INIT_SYSTEM=systemd
  elif [[ "$pid1" == openrc-init ]] || { [[ -d /run/openrc ]] && command -v rc-service >/dev/null 2>&1; }; then
    command -v rc-service >/dev/null 2>&1 || { fail '检测到 OpenRC，但找不到 rc-service 命令。'; return 1; }
    INIT_SYSTEM=openrc
  elif [[ "$pid1" == runsvdir || "$pid1" == runit ]] || { [[ -d /run/runit ]] && command -v sv >/dev/null 2>&1; }; then
    command -v sv >/dev/null 2>&1 || { fail '检测到 runit，但找不到 sv 命令。'; return 1; }
    INIT_SYSTEM=runit
  elif [[ -d /etc/init.d && ( "$pid1" == init || -x /etc/init.d/rc || -x /etc/rc.d/rc ) ]]; then
    INIT_SYSTEM=sysvinit
  else
    INIT_SYSTEM=manual
    warn '未识别到受支持的服务管理器：将使用手动管理模式，服务不会自动随系统启动。'
  fi
}

install_missing_dependencies() {
  local -a required=(curl jq unzip openssl sha256sum base64)
  local -a missing=()
  local cmd list
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) && return 0
  if [[ "${XSS_SKIP_DEP_INSTALL:-0}" == 1 ]]; then
    fail "测试模式下仍缺少依赖：${missing[*]}"; return 1
  fi
  detect_package_manager
  if [[ -z "$PKG_MANAGER" ]]; then
    list="${missing[*]}"
    fail "当前系统缺少必要依赖且无法自动识别软件包管理器。请手动安装以下依赖。 $list"; return 1
  fi
  info "正在通过 $PKG_MANAGER 安装缺失依赖：${missing[*]}"
  case "$PKG_MANAGER" in
    apt)
      apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash curl jq unzip openssl ca-certificates coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    dnf|microdnf|yum)
      # Rocky / Alma / Fedora 精简镜像可能已提供 curl-minimal、coreutils-single。
      # 只补缺失命令，避免强装完整版触发包冲突。
      local -a rpm_packages=(ca-certificates)
      local rpm_coreutils=0
      for cmd in "${missing[@]}"; do
        case "$cmd" in
          sha256sum|base64) rpm_coreutils=1 ;;
          *) rpm_packages+=("$cmd") ;;
        esac
      done
      if ((rpm_coreutils)); then rpm_packages+=(coreutils); fi
      "$PKG_MANAGER" install -y "${rpm_packages[@]}" || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    zypper)
      zypper --non-interactive install --no-recommends bash curl jq unzip openssl ca-certificates coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    pacman)
      pacman -S --noconfirm --needed bash curl jq unzip openssl ca-certificates coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    apk)
      apk add --no-cache bash curl jq unzip openssl ca-certificates coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    openwrt-apk)
      apk update && apk add --no-cache bash curl jq unzip openssl-util ca-bundle coreutils-sha256sum coreutils-base64 || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    xbps)
      xbps-install -Sy bash curl jq unzip openssl ca-certificates coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    emerge)
      emerge --ask=n --noreplace app-shells/bash net-misc/curl app-misc/jq app-arch/unzip dev-libs/openssl app-misc/ca-certificates sys-apps/coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    opkg)
      opkg update && opkg install bash curl jq unzip openssl-util ca-bundle coreutils-sha256sum coreutils-base64 || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    *) fail "暂不支持通过 $PKG_MANAGER 自动安装依赖，请手动安装：${missing[*]}"; return 1 ;;
  esac
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || { fail "依赖安装后仍找不到命令：$cmd"; return 1; }
  done
}

need_env() {
  [[ $(uname -s) == Linux ]] || { fail '仅支持 Linux 系统。'; return 1; }
  detect_distribution
  detect_architecture || return 1
  detect_package_manager
  detect_init_system || return 1
  install_missing_dependencies || return 1
}

# 只为本脚本的 direct 出站补齐缺省项，保留已有自定义 DNS 和解析策略。
# 按当前可用路由查询真实地址，优先 IPv4、回退 IPv6；保留私有地址拦截。
with_default_dns() {
  jq --argjson servers "$DEFAULT_DNS_SERVERS" '
    if any(.outbounds[]?; .tag=="direct" and .protocol=="freedom") then
      (if .dns==null then .dns={servers:$servers,queryStrategy:"UseSystem",enableParallelQuery:true} else . end) |
      (.outbounds[] | select(.tag=="direct" and .protocol=="freedom" and .settings.domainStrategy==null)
        | .settings.domainStrategy)="UseIPv4v6"
    else . end
  ' "$@"
}

# 只迁移旧版默认日志；保留用户显式开启的日志和自定义日志配置。
with_default_logging() {
  jq '
    if .log==null or .log=={loglevel:"warning"} or .log=={loglevel:"none"} then
      .log={access:"none",error:"none",loglevel:"none",dnsLog:false}
    else . end
  '
}

logging_disabled() {
  [[ -f "$CONFIG" ]] && jq -e '.log.loglevel=="none" and (.log.access // "none")=="none"' "$CONFIG" >/dev/null
}

logging_status() {
  if logging_disabled; then printf '%s\n' '关闭'; else printf '%s\n' '开启'; fi
}

prepare_log_file() {
  local config="${1:-$CONFIG}"
  jq -e --arg path "$LOG_FILE" '.log.error==$path' "$config" >/dev/null || return 0
  if [[ -L "$LOG_FILE" || ( -e "$LOG_FILE" && ! -f "$LOG_FILE" ) ]]; then
    fail "日志路径不是普通文件，已停止修改：$LOG_FILE"; return 1
  fi
  mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
}

init_config() {
  mkdir -p "$ETC_DIR" "$BACKUP_DIR" "$CORE_DIR"
  chmod 700 "$ETC_DIR" "$BACKUP_DIR"
  chmod 755 "$CORE_DIR"
  mkdir -p "$(dirname "$ENTRY")" "$(dirname "$CORE_LINK")"
  if [[ ! -f "$CONFIG" ]]; then
    if ! with_default_dns <<< '{"log":{"access":"none","error":"none","loglevel":"none","dnsLog":false},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}' > "$CONFIG"; then
      rm -f "$CONFIG"
      fail '无法生成默认节点配置。'; return 1
    fi
    chmod 600 "$CONFIG"
  fi
  if [[ ! -f "$NODE_HOSTS_FILE" ]]; then
    printf '{}\n' > "$NODE_HOSTS_FILE"
    chmod 600 "$NODE_HOSTS_FILE"
  fi
  if [[ ! -f "$NODE_META_FILE" ]]; then
    printf '{}\n' > "$NODE_META_FILE"
    chmod 600 "$NODE_META_FILE"
  fi
  if [[ ! -e "$ENTRY" && ! -L "$ENTRY" ]]; then
    # Install a copy, so this manager remains available after removing the download.
    cp "${BASH_SOURCE[0]}" "$ENTRY"
    chmod 700 "$ENTRY"
  fi
}

service_daemon_reload() {
  if [[ "$INIT_SYSTEM" == systemd ]]; then systemctl daemon-reload; fi
}

check_managed_service_file() {
  local path="$1"
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  if [[ -L "$path" ]]; then
    fail "同名服务文件是符号链接，已拒绝修改：$path"; return 1
  fi
  if grep -Fq 'XSS-MANAGED: xray-ss' "$path"; then return 0; fi
  # Compatible with the original v0.2 systemd unit, which had no marker.
  if [[ "$INIT_SYSTEM" == systemd ]] &&
     grep -Fq 'Description=Xray Shadowsocks standalone service' "$path" &&
     grep -Fq "ExecStart=$CORE_LINK run -config $CONFIG" "$path"; then
    return 0
  fi
  fail "发现同名但不属于此脚本的服务文件，拒绝覆盖或删除：$path"
}

service_unit_path() {
  case "$INIT_SYSTEM" in
    systemd) printf '%s\n' "$UNIT_FILE" ;;
    openrc) printf '%s\n' "$OPENRC_UNIT_FILE" ;;
    sysvinit) printf '%s\n' "$SYSV_UNIT_FILE" ;;
    manual) printf '%s\n' "$MANUAL_UNIT_FILE" ;;
    runit) printf '%s\n' "$RUNIT_SERVICE_DIR/run" ;;
    procd) printf '%s\n' "$PROCD_UNIT_FILE" ;;
    *) return 1 ;;
  esac
}

# 日志由内核直接写入指定文件；服务输出丢弃，关闭时也不累积启动横幅。
# 只更新本项目服务的日志项，保留已有服务中的其他配置。
configure_service_log_output() {
  local path tmp
  jq -e --arg path "$LOG_FILE" '.log.loglevel=="none" or .log.error==$path' "$CONFIG" >/dev/null || return 0
  path="$(service_unit_path)" || return 1
  [[ -e "$path" || -L "$path" ]] || return 0
  check_managed_service_file "$path" || return 1
  tmp="$(mktemp "$(dirname "$path")/.xray-log-output.XXXXXX")" || return 1
  if ! cp -p "$path" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! awk -v init="$INIT_SYSTEM" -v log_path="$LOG_FILE" '
    init=="systemd" && /^\[/ {
      service=($0=="[Service]"); print
      if (service) {
        print "StandardOutput=null"; print "StandardError=null"
        print "ReadWritePaths=-" log_path
      }
      next
    }
    init=="systemd" && service && (/^Standard(Output|Error)=/ || $0=="ReadWritePaths=-" log_path) {next}
    init=="openrc" && /^(output_log|error_log)=/ {sub(/=.*/, "=\"/dev/null\"")}
    (init=="sysvinit" || init=="manual") && /^[[:space:]]*nohup / {sub(/>>"\$LOG"/, ">/dev/null")}
    init=="runit" && /^exec >>/ {$0="exec >/dev/null 2>&1"}
    init=="procd" && /procd_set_param (stdout|stderr) [01]/ {sub(/[01][[:space:]]*$/, "0")}
    {print}
  ' "$path" > "$tmp"; then rm -f "$tmp"; return 1; fi
  if cmp -s "$path" "$tmp"; then rm -f "$tmp"; return 0; fi
  if ! mv -f "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
}

install_service_unit() {
  detect_init_system || return 1
  case "$INIT_SYSTEM" in
    systemd)
      mkdir -p "$(dirname "$UNIT_FILE")"
      check_managed_service_file "$UNIT_FILE" || return 1
      if [[ ! -e "$UNIT_FILE" ]]; then
        cat > "$UNIT_FILE" <<EOF
# XSS-MANAGED: xray-ss
[Unit]
Description=Xray node manager service (SS / SS2022 / Reality)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$CORE_LINK run -config $CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 "$UNIT_FILE"
      fi
      ;;
    openrc)
      mkdir -p "$(dirname "$OPENRC_UNIT_FILE")" "$(dirname "$LOG_FILE")"
      check_managed_service_file "$OPENRC_UNIT_FILE" || return 1
      if [[ ! -e "$OPENRC_UNIT_FILE" ]]; then
        cat > "$OPENRC_UNIT_FILE" <<EOF
#!/sbin/openrc-run
# XSS-MANAGED: xray-ss
name="Xray node manager"
description="Xray Shadowsocks service"
command="$CORE_LINK"
command_args="run -config $CONFIG"
command_background="yes"
pidfile="$PID_FILE"
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
  need net
  after firewall
}
EOF
        chmod 755 "$OPENRC_UNIT_FILE"
      fi
      ;;
    sysvinit|manual)
      local service_script="$SYSV_UNIT_FILE"
      if [[ "$INIT_SYSTEM" == manual ]]; then service_script="$MANUAL_UNIT_FILE"; fi
      mkdir -p "$(dirname "$service_script")" "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"
      check_managed_service_file "$service_script" || return 1
      if [[ ! -e "$service_script" ]]; then
        cat > "$service_script" <<EOF
#!/bin/sh
# XSS-MANAGED: xray-ss
### BEGIN INIT INFO
# Provides:          xray-ss
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Xray SS / SS2022 / Reality service
### END INIT INFO
CORE="$CORE_LINK"
CONFIG="$CONFIG"
PID="$PID_FILE"
LOG="$LOG_FILE"
is_running() {
  [ -f "\$PID" ] || return 1
  p="\$(cat "\$PID" 2>/dev/null)"
  case "\$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "\$p" 2>/dev/null || return 1
  [ -r "/proc/\$p/cmdline" ] || return 1
  tr '\\000' ' ' < "/proc/\$p/cmdline" | grep -F "\$CORE" >/dev/null 2>&1
}
start_service() {
  if is_running; then echo "xray-ss already running"; return 0; fi
  mkdir -p "\$(dirname "\$PID")" "\$(dirname "\$LOG")"
  rm -f "\$PID"
  nohup "\$CORE" run -config "\$CONFIG" >>"\$LOG" 2>&1 </dev/null &
  echo \$! > "\$PID"
  sleep 1
  if is_running; then echo "xray-ss started"; else rm -f "\$PID"; echo "xray-ss failed to start"; return 1; fi
}
stop_service() {
  if ! is_running; then rm -f "\$PID"; echo "xray-ss not running"; return 0; fi
  p="\$(cat "\$PID")"
  kill "\$p" 2>/dev/null || true
  i=0
  while kill -0 "\$p" 2>/dev/null && [ "\$i" -lt 10 ]; do sleep 1; i=\$((i+1)); done
  if kill -0 "\$p" 2>/dev/null; then kill -9 "\$p" 2>/dev/null || true; fi
  rm -f "\$PID"
  echo "xray-ss stopped"
}
case "\$1" in
  start) start_service ;;
  stop) stop_service ;;
  restart|force-reload) stop_service; start_service ;;
  status) if is_running; then echo "xray-ss running"; exit 0; else echo "xray-ss stopped"; exit 1; fi ;;
  *) echo "Usage: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
EOF
        chmod 755 "$service_script"
      fi
      ;;
    runit)
      mkdir -p "$RUNIT_SERVICE_DIR" "$(dirname "$LOG_FILE")"
      check_managed_service_file "$RUNIT_SERVICE_DIR/run" || return 1
      if [[ ! -e "$RUNIT_SERVICE_DIR/run" ]]; then
        cat > "$RUNIT_SERVICE_DIR/run" <<EOF
#!/bin/sh
# XSS-MANAGED: xray-ss
exec >>"$LOG_FILE" 2>&1
exec "$CORE_LINK" run -config "$CONFIG"
EOF
        chmod 755 "$RUNIT_SERVICE_DIR/run"
      fi
      ;;
    procd)
      mkdir -p "$(dirname "$PROCD_UNIT_FILE")"
      check_managed_service_file "$PROCD_UNIT_FILE" || return 1
      if [[ ! -e "$PROCD_UNIT_FILE" ]]; then
        cat > "$PROCD_UNIT_FILE" <<EOF
#!/bin/sh /etc/rc.common
# XSS-MANAGED: xray-ss
START=95
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command "$CORE_LINK" run -config "$CONFIG"
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
        chmod 755 "$PROCD_UNIT_FILE"
      fi
      ;;
    *) fail "不支持的服务管理方式：$INIT_SYSTEM"; return 1 ;;
  esac
  prepare_log_file || return 1
  configure_service_log_output || return 1
  service_daemon_reload
}

service_is_active() {
  case "$INIT_SYSTEM" in
    systemd) systemctl is-active --quiet "$SERVICE" ;;
    openrc) rc-service "$SERVICE_NAME" status >/dev/null 2>&1 ;;
    sysvinit) "$SYSV_UNIT_FILE" status >/dev/null 2>&1 ;;
    manual) "$MANUAL_UNIT_FILE" status >/dev/null 2>&1 ;;
    runit) sv status "$RUNIT_ENABLED_DIR" 2>/dev/null | grep -q '^run:' ;;
    procd) ubus call service list "{\"name\":\"$SERVICE_NAME\"}" 2>/dev/null | jq -e --arg n "$SERVICE_NAME" '(.[$n].instances // {}) | to_entries | any(.value.running == true)' >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

service_is_enabled() {
  local path
  case "$INIT_SYSTEM" in
    systemd) systemctl is-enabled --quiet "$SERVICE" ;;
    openrc) rc-update show default 2>/dev/null | grep -Eq "(^|[[:space:]])${SERVICE_NAME}([[:space:]]|$)" ;;
    sysvinit)
      for path in /etc/rc*.d/S??"$SERVICE_NAME" /etc/rc.d/rc?.d/S??"$SERVICE_NAME"; do
        [[ -e "$path" || -L "$path" ]] && return 0
      done
      return 1
      ;;
    runit) [[ -L "$RUNIT_ENABLED_DIR" && "$(readlink "$RUNIT_ENABLED_DIR")" == "$RUNIT_SERVICE_DIR" ]] ;;
    procd)
      for path in /etc/rc.d/S??"$SERVICE_NAME"; do [[ -e "$path" || -L "$path" ]] && return 0; done
      return 1
      ;;
    manual) return 1 ;;
    *) return 1 ;;
  esac
}

service_enable() {
  install_service_unit || return 1
  case "$INIT_SYSTEM" in
    systemd) systemctl enable "$SERVICE" ;;
    openrc) rc-update add "$SERVICE_NAME" default ;;
    sysvinit)
      if command -v update-rc.d >/dev/null 2>&1; then update-rc.d "$SERVICE_NAME" defaults
      elif command -v chkconfig >/dev/null 2>&1; then chkconfig --add "$SERVICE_NAME" && chkconfig "$SERVICE_NAME" on
      elif command -v insserv >/dev/null 2>&1; then insserv "$SERVICE_NAME"
      else warn '未找到 SysVinit 开机自启注册工具；服务可手动启动。'; fi
      ;;
    runit)
      if [[ ! -d "$(dirname "$RUNIT_ENABLED_DIR")" && ! -L "$(dirname "$RUNIT_ENABLED_DIR")" ]]; then
        if [[ -d /etc/runit/runsvdir/current ]]; then ln -s /etc/runit/runsvdir/current "$(dirname "$RUNIT_ENABLED_DIR")"
        elif [[ -d /run/runit/service ]]; then ln -s /run/runit/service "$(dirname "$RUNIT_ENABLED_DIR")"
        else fail '未找到 runit 的服务目录，请先配置 /var/service。'; return 1; fi
      fi
      if [[ -e "$RUNIT_ENABLED_DIR" || -L "$RUNIT_ENABLED_DIR" ]]; then
        [[ "$(readlink "$RUNIT_ENABLED_DIR" 2>/dev/null || true)" == "$RUNIT_SERVICE_DIR" ]] || { fail 'runit 服务入口已存在且指向其他位置，已停止修改。'; return 1; }
      else
        ln -s "$RUNIT_SERVICE_DIR" "$RUNIT_ENABLED_DIR"
      fi
      ;;
    procd) "$PROCD_UNIT_FILE" enable ;;
    manual) warn '当前使用手动管理模式：本脚本可启动服务，但无法配置开机自启。' ;;
  esac
}

service_start() {
  case "$INIT_SYSTEM" in
    systemd) systemctl start "$SERVICE" ;;
    openrc) rc-service "$SERVICE_NAME" start ;;
    sysvinit) "$SYSV_UNIT_FILE" start ;;
    manual) "$MANUAL_UNIT_FILE" start ;;
    runit) sv up "$RUNIT_ENABLED_DIR" ;;
    procd) "$PROCD_UNIT_FILE" start ;;
  esac
}

service_stop() {
  case "$INIT_SYSTEM" in
    systemd) systemctl stop "$SERVICE" ;;
    openrc) rc-service "$SERVICE_NAME" stop ;;
    sysvinit) "$SYSV_UNIT_FILE" stop ;;
    manual) "$MANUAL_UNIT_FILE" stop ;;
    runit) sv down "$RUNIT_ENABLED_DIR" ;;
    procd) "$PROCD_UNIT_FILE" stop ;;
  esac
}

service_restart() {
  case "$INIT_SYSTEM" in
    systemd) systemctl restart "$SERVICE" ;;
    openrc) if service_is_active; then rc-service "$SERVICE_NAME" restart; else rc-service "$SERVICE_NAME" start; fi ;;
    sysvinit) "$SYSV_UNIT_FILE" restart ;;
    manual) "$MANUAL_UNIT_FILE" restart ;;
    runit) if service_is_active; then sv restart "$RUNIT_ENABLED_DIR"; else sv up "$RUNIT_ENABLED_DIR"; fi ;;
    procd) "$PROCD_UNIT_FILE" restart ;;
  esac
}

service_disable() {
  case "$INIT_SYSTEM" in
    systemd) systemctl disable --now "$SERVICE" >/dev/null 2>&1 || systemctl stop "$SERVICE" >/dev/null 2>&1 || true ;;
    openrc) rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true; rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true ;;
    sysvinit)
      "$SYSV_UNIT_FILE" stop >/dev/null 2>&1 || true
      if command -v update-rc.d >/dev/null 2>&1; then update-rc.d -f "$SERVICE_NAME" remove >/dev/null 2>&1 || true
      elif command -v chkconfig >/dev/null 2>&1; then chkconfig --del "$SERVICE_NAME" >/dev/null 2>&1 || true
      elif command -v insserv >/dev/null 2>&1; then insserv -r "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
      ;;
    runit)
      if [[ -L "$RUNIT_ENABLED_DIR" && "$(readlink "$RUNIT_ENABLED_DIR")" != "$RUNIT_SERVICE_DIR" ]]; then
        fail "检测到同名 runit 服务指向其他目录，拒绝修改：$RUNIT_ENABLED_DIR"
        return 1
      fi
      sv down "$RUNIT_ENABLED_DIR" >/dev/null 2>&1 || true
      if [[ -L "$RUNIT_ENABLED_DIR" && "$(readlink "$RUNIT_ENABLED_DIR")" == "$RUNIT_SERVICE_DIR" ]]; then
        rm -f "$RUNIT_ENABLED_DIR"
      fi
      ;;
    procd) "$PROCD_UNIT_FILE" stop >/dev/null 2>&1 || true; "$PROCD_UNIT_FILE" disable >/dev/null 2>&1 || true ;;
    manual) "$MANUAL_UNIT_FILE" stop >/dev/null 2>&1 || true ;;
  esac
}

service_logs() {
  if logging_disabled || jq -e --arg path "$LOG_FILE" '.log.error==$path' "$CONFIG" >/dev/null; then
    if [[ -f "$LOG_FILE" && ! -L "$LOG_FILE" && -s "$LOG_FILE" ]]; then tail -n 80 "$LOG_FILE"
    else say '暂时没有本工具记录的日志。'; fi
    return 0
  fi
  case "$INIT_SYSTEM" in
    systemd) journalctl -u "$SERVICE" -n 80 --no-pager ;;
    procd)
      if command -v logread >/dev/null 2>&1; then logread -e xray-ss-core || logread -e xray-ss
      else say '当前系统没有 logread 命令。'; return 1; fi
      ;;
    *)
      if [[ -s "$LOG_FILE" ]]; then tail -n 80 "$LOG_FILE"
      else say "暂时没有日志文件：$LOG_FILE"; return 0; fi
      ;;
  esac
}

valid_version() {
  [[ "$1" =~ ^v[0-9]+(\.[0-9]+){1,3}(-[a-zA-Z0-9.-]+)?$ ]]
}

release_menu() {
  local json='' pick='' tag='' n=1 line
  if json="$(curl -fsSL --connect-timeout 10 --max-time 30 "$GITHUB_API?per_page=30")" && jq -e 'type=="array"' >/dev/null <<< "$json"; then
    info "可选 Xray 版本（正式版 / 预发布版），默认 $DEFAULT_XRAY_VERSION：" >&2
    local -a release_tags=() release_labels=()
    while IFS=$'\t' read -r tag line; do
      [[ -n "$tag" ]] || continue
      release_tags+=("$tag")
      release_labels+=("$line")
      (( n += 1 ))
      (( n <= 17 )) || break
    done < <(jq -r '.[] | select(.draft == false) | select(.tag_name | test("^v[0-9]+(\\.[0-9]+){1,3}(-[a-zA-Z0-9.-]+)?$")) | [.tag_name, (if .prerelease then "预发布版" else "正式版" end)] | @tsv' <<< "$json")
    for (( n=0; n<${#release_tags[@]}; n++ )); do
      printf '%2d） %-16s %s\n' "$((n+1))" "${release_tags[n]}" "${release_labels[n]}" >&2
    done
    read -r -p "请输入版本序号或完整版本号（直接回车使用 $DEFAULT_XRAY_VERSION）：" pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#release_tags[@]})); then
      printf '%s\n' "${release_tags[pick-1]}"
      return 0
    fi
  else
    warn '获取 GitHub 版本列表失败，可以手动输入版本号。'
    read -r -p "请输入完整 Xray 版本号（直接回车使用 $DEFAULT_XRAY_VERSION）：" pick
  fi
  pick="${pick:-$DEFAULT_XRAY_VERSION}"
  valid_version "$pick" || { fail '版本号格式无效。'; return 1; }
  printf '%s\n' "$pick"
}

# 条件分支中调用函数时 Bash 会忽略 errexit，下载和校验必须显式检查返回值。
fetch_xray_archive() {
  local tag="$1" arch="$2" directory="$3" archive url expected actual
  archive="Xray-linux-${arch}.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/$tag/$archive"
  curl -fLsS --retry 3 --connect-timeout 15 --max-time 240 -o "$directory/$archive" "$url" || {
    fail "下载 Xray $tag 安装包失败（$arch）。请确认官方已发布该版本和架构，并检查网络：$url"
    return 1
  }
  curl -fLsS --retry 3 --connect-timeout 15 --max-time 60 -o "$directory/$archive.dgst" "$url.dgst" || {
    fail "下载 Xray $tag 官方校验文件失败，已停止安装：$url.dgst"
    return 1
  }
  expected="$(awk -F '=' '/^[[:space:]]*SHA(2-)?256[[:space:]]*=/{v=$2;gsub(/[[:space:]]/,"",v);print tolower(v);exit}' "$directory/$archive.dgst")" || return 1
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { fail '未找到有效的 SHA256 校验值。'; return 1; }
  actual="$(sha256sum "$directory/$archive" | awk '{print $1}')" || return 1
  [[ "$actual" == "$expected" ]] || { fail 'SHA256 校验失败，下载文件与官方校验值不一致。'; return 1; }
}

# 在版本目录所在文件系统暂存，校验、解压和执行均成功后再原子替换文件。
download_version() (
  set -euo pipefail
  local tag="$1" dest="$CORE_DIR/$1" tmp archive
  valid_version "$tag" || { fail '版本号格式无效。'; exit 1; }
  if [[ -x "$dest/xray" ]] && "$dest/xray" -version >/dev/null 2>&1; then exit 0; fi
  mkdir -p "$CORE_DIR" || exit 1
  tmp="$(mktemp -d "$CORE_DIR/.install.XXXXXX")" || exit 1
  trap 'rm -rf "$tmp"' EXIT
  archive="Xray-linux-${XRAY_ARCH}.zip"
  info "正在下载 Xray $tag，处理器架构：$XRAY_ARCH……" >&2
  fetch_xray_archive "$tag" "$XRAY_ARCH" "$tmp" || exit 1
  if ! unzip -joq "$tmp/$archive" xray -d "$tmp"; then
    warn 'Xray 安装包解压失败，已停止安装。'
    exit 1
  fi
  chmod 755 "$tmp/xray" || exit 1
  if ! "$tmp/xray" -version >/dev/null 2>&1; then
    if [[ "$XRAY_ARCH" == mips32* ]]; then
      # Prefer the in-archive soft-float binary where available (older releases).
      if unzip -joq "$tmp/$archive" xray_softfloat -d "$tmp" >/dev/null 2>&1 &&
         chmod 755 "$tmp/xray_softfloat" &&
         "$tmp/xray_softfloat" -version >/dev/null 2>&1; then
        mv -f "$tmp/xray_softfloat" "$tmp/xray" || exit 1
      else
        # Newer releases may publish a dedicated mips32-softfloat archive.
        local soft_archive="Xray-linux-${XRAY_ARCH}-softfloat.zip"
        fetch_xray_archive "$tag" "${XRAY_ARCH}-softfloat" "$tmp" || exit 1
        unzip -joqo "$tmp/$soft_archive" xray -d "$tmp" || exit 1
        chmod 755 "$tmp/xray" || exit 1
      fi
      if "$tmp/xray" -version >/dev/null 2>&1; then
        info '当前 MIPS 设备已自动使用软浮点内核。' >&2
      fi
    fi
    if ! "$tmp/xray" -version >/dev/null 2>&1; then
      warn '下载的内核无法执行。请检查 CPU 架构、系统内核和官方发布包兼容性。'
      exit 1
    fi
  fi
  mkdir -p "$dest" || exit 1
  mv -f "$tmp/xray" "$dest/xray" || exit 1
  info "校验通过，Xray $tag 安装完成。" >&2
)

switch_version() {
  local tag="$1" target="$CORE_DIR/$1/xray" old='' link_tmp
  valid_version "$tag" || { fail '版本号格式无效。'; return 1; }
  need_env || return 1
  init_config || return 1
  install_service_unit || return 1
  download_version "$tag" || return 1
  "$target" run -test -format json -config "$CONFIG" || { fail "当前节点配置与 Xray $tag 不兼容，已取消切换。"; return 1; }
  [[ ! -L "$CORE_LINK" ]] || old="$(readlink "$CORE_LINK")"
  if [[ -e "$CORE_LINK" && ! -L "$CORE_LINK" ]]; then
    fail "目标路径 $CORE_LINK 已存在非符号链接文件，为避免覆盖已停止安装。"
    return 1
  fi
  link_tmp="${CORE_LINK}.new.$$"
  ln -s "$target" "$link_tmp"
  mv -f "$link_tmp" "$CORE_LINK"
  if service_is_active; then
    if ! service_restart || ! service_is_active; then
      warn '新版本启动失败，正在回滚至旧版内核。'
      if [[ -n "$old" ]]; then
        ln -s "$old" "$link_tmp"
        mv -f "$link_tmp" "$CORE_LINK"
        service_restart || true
      else
        rm -f "$CORE_LINK"
      fi
      return 1
    fi
  fi
  info "当前 Xray 版本：$tag"
}

port_in_use() {
  local port="$1"
  if [[ -f "$CONFIG" ]] && jq -e --argjson p "$port" '.inbounds[]? | select(.port==$p)' "$CONFIG" >/dev/null; then return 0; fi
  if command -v ss >/dev/null && ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"; then return 0; fi
  if command -v netstat >/dev/null && netstat -lntu 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)${port}$"; then return 0; fi
  if proc_port_in_use "$port" all; then return 0; fi
  return 1
}

normalize_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#$value))
  ((value >= 1 && value <= 65535)) || return 1
  printf '%s\n' "$value"
}

choose_port() {
  local proposed='' tries=0
  if [[ "${1:-}" != auto ]]; then
    read -r -p '请输入节点端口（直接回车自动选择空闲端口）：' proposed || return 1
  fi
  if [[ -z "$proposed" ]]; then
    while ((tries < 50)); do
      local random_hex random_num
      random_hex="$(openssl rand -hex 4)"
      random_num=$((16#$random_hex))
      proposed=$((10000 + random_num % 50001))
      if ! port_in_use "$proposed"; then printf '%s\n' "$proposed"; return 0; fi
      ((tries+=1))
    done
    fail '未找到可用的随机端口，请手动指定。'; return 1
  fi
  proposed="$(normalize_port "$proposed")" || { fail '端口号无效，请输入 1～65535 之间的数字。'; return 1; }
  port_in_use "$proposed" && { fail "端口 $proposed 已被占用。"; return 1; }
  printf '%s\n' "$proposed"
}

choose_method() {
  local -a methods=(
    aes-128-gcm aes-256-gcm chacha20-poly1305 xchacha20-poly1305
    2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305
  )
  local n sel default=2
  case "${1:-}" in
    ss) methods=(aes-128-gcm aes-256-gcm chacha20-poly1305 xchacha20-poly1305) ;;
    ss2022) methods=(2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305) ;;
  esac
  for ((n=0;n<${#methods[@]};n++)); do printf '%d） %s\n' "$((n+1))" "${methods[n]}" >&2; done
  read -r -p "请选择加密方式 [1～${#methods[@]}，默认 $default]：" sel || return 1
  sel="${sel:-$default}"
  [[ "$sel" =~ ^[1-7]$ ]] && ((sel <= ${#methods[@]})) || { fail '请输入列表中的加密方式序号。'; return 1; }
  printf '%s\n' "${methods[sel-1]}"
}

new_password() {
  case "$1" in
    2022-blake3-aes-128-gcm) openssl rand -base64 16 ;;
    2022-blake3-*) openssl rand -base64 32 ;;
    *) openssl rand -hex 24 ;;
  esac
}

# 节点名称允许中文和其他 UTF-8 字符；最长 48 个 Unicode 码点。
# 禁止控制符以及 /、\，避免终端/配置文本显示混乱。标签只写入 JSON，不拼接文件路径。
safe_name() {
  jq -en --arg name "$1" '
    ($name | length) as $count |
    ($count >= 1 and $count <= 48)
    and ($name | (startswith(" ") | not) and (endswith(" ") | not))
    and ($name | explode | all(.[]; . >= 32 and . != 127 and . != 47 and . != 92))
  ' >/dev/null
}

# 旧版内部标签为 xss-xxx；保持真实 JSON tag 不变，但对用户显示为 ss-xxx。
visible_node_name() {
  case "$1" in
    xss-*) printf 'ss-%s\n' "${1#xss-}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# 兼容选择新标签、旧标签和不带前缀的名称，避免升级后无法管理原有节点。
resolve_node_tag() {
  local input="$1" tag
  local -a choices=()
  case "$input" in
    ss-*) choices=("$input" "xss-${input#ss-}") ;;
    vless-*) choices=("$input") ;;
    xss-*) choices=("$input" "ss-${input#xss-}") ;;
    *) choices=("$input" "ss-$input" "xss-$input" "vless-$input") ;;
  esac
  choices+=("socks5-$input" "http-$input")
  for tag in "${choices[@]}"; do
    if [[ -f "$CONFIG" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$CONFIG" >/dev/null; then
      printf '%s\n' "$tag"
      return 0
    fi
  done
  fail '未找到指定节点。'
}

# 用户选择创建节点即自动准备缺失的内核；已安装时保留当前版本。
ensure_core_for_new_node() {
  [[ -x "$CORE_LINK" ]] && return 0
  info "首次创建：正在自动安装 Xray $DEFAULT_XRAY_VERSION。"
  switch_version "$DEFAULT_XRAY_VERSION"
}

# 按数字比较正式版本部分，避免把 26.6.1 按字符串误判为新于 26.10.10。
version_at_least() {
  local current="${1#v}" minimum="${2#v}" i
  local -a actual=() required=()
  valid_version "v$current" && valid_version "v$minimum" || return 1
  IFS=. read -r -a actual <<< "${current%%-*}"
  IFS=. read -r -a required <<< "${minimum%%-*}"
  for ((i=0; i<4; i++)); do
    if ((10#${actual[i]:-0} > 10#${required[i]:-0})); then return 0; fi
    if ((10#${actual[i]:-0} < 10#${required[i]:-0})); then return 1; fi
  done
  return 0
}

ensure_reality_core() {
  local current
  need_core || return 1
  current="$("$CORE_LINK" -version 2>/dev/null | awk 'NR==1 {print $2}')" || current=''
  if version_at_least "$current" "$REALITY_MIN_XRAY_VERSION"; then return 0; fi
  info "当前 Xray ${current:-版本未知} 未达到 Reality 已验证版本 $REALITY_MIN_XRAY_VERSION，正在升级至 $DEFAULT_XRAY_VERSION。"
  switch_version "$DEFAULT_XRAY_VERSION"
}

apply_config() {
  local candidate="$1" backup old_active=0
  need_core
  jq -e '.inbounds | type=="array"' "$candidate" >/dev/null || { rm -f "$candidate"; fail '配置文件 JSON 格式无效。'; return 1; }
  if ! "$CORE_LINK" run -test -format json -config "$candidate"; then
    rm -f "$candidate"
    fail 'Xray 配置校验失败，原配置保持不变。'
    return 1
  fi
  install_service_unit || return 1
  backup="$(mktemp "$BACKUP_DIR/config-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.json")"
  cp -p "$CONFIG" "$backup"
  if service_is_active; then old_active=1; fi
  chmod 600 "$candidate"
  mv -f "$candidate" "$CONFIG"
  service_daemon_reload
  if ! service_enable; then
    cp -p "$backup" "$CONFIG"
    fail '无法启用 Xray 服务，已恢复上一份配置。'
    return 1
  fi
  if ! service_restart || ! service_is_active; then
    warn '服务启动失败，正在恢复上一份配置。'
    cp -p "$backup" "$CONFIG"
    if ((old_active)); then service_restart || true; else service_stop >/dev/null 2>&1 || true; fi
    return 1
  fi
  info '配置校验通过，Xray 服务已运行。'
}

# 应用运行设置时保留服务的启停状态，失败则一并恢复配置和服务日志设置。
apply_runtime_config() {
  local candidate="$1" message="$2" backup path unit_backup='' old_active=0
  if ! jq -e '(.inbounds | type=="array") and (.log | type=="object")' "$candidate" >/dev/null; then
    rm -f "$candidate"
    fail '运行设置 JSON 无效，原配置保持不变。'; return 1
  fi
  if jq -e --slurpfile updated "$candidate" '.==$updated[0]' "$CONFIG" >/dev/null; then
    rm -f "$candidate"
    return 0
  fi
  # 校验内核配置前就检查日志路径，避免内核跟随符号链接或缺少日志目录。
  if ! prepare_log_file "$candidate"; then rm -f "$candidate"; return 1; fi
  if [[ -x "$CORE_LINK" ]] && ! "$CORE_LINK" run -test -format json -config "$candidate"; then
    rm -f "$candidate"
    fail '运行设置未通过 Xray 校验，原配置保持不变。'; return 1
  fi
  path="$(service_unit_path)" || { rm -f "$candidate"; return 1; }
  if [[ -e "$path" || -L "$path" ]]; then
    check_managed_service_file "$path" || { rm -f "$candidate"; return 1; }
    unit_backup="$(mktemp "$ETC_DIR/.runtime-service.XXXXXX")" || { rm -f "$candidate"; return 1; }
    if ! cp -p "$path" "$unit_backup"; then rm -f "$candidate" "$unit_backup"; return 1; fi
  fi
  backup="$(mktemp "$BACKUP_DIR/config-before-settings-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.json")" || { rm -f "$candidate" "${unit_backup:-}"; return 1; }
  if ! cp -p "$CONFIG" "$backup"; then rm -f "$candidate" "${unit_backup:-}" "$backup"; return 1; fi
  if service_is_active; then old_active=1; fi
  if ! chmod 600 "$candidate" || ! mv -f "$candidate" "$CONFIG"; then
    rm -f "$candidate" "${unit_backup:-}"
    return 1
  fi
  if ! configure_service_log_output || ! service_daemon_reload ||
     { ((old_active)) && { ! service_restart || ! service_is_active; }; }; then
    warn '运行设置应用失败，正在恢复上一份配置和服务设置。'
    cp -p "$backup" "$CONFIG" || { rm -f "${unit_backup:-}"; return 1; }
    if [[ -n "$unit_backup" ]]; then
      cp -p "$unit_backup" "$path" || { rm -f "$unit_backup"; return 1; }
      rm -f "$unit_backup"
    fi
    service_daemon_reload || true
    if ((old_active)); then service_restart || true; fi
    return 1
  fi
  rm -f "${unit_backup:-}"
  info "$message，原配置已备份：$backup" >&2
}

# 默认关闭日志，同时补齐旧版 DNS；显式开启和自定义配置均保留。
migrate_default_config() {
  local candidate
  candidate="$(mktemp "$ETC_DIR/.defaults.XXXXXX")" || return 1
  if ! with_default_dns "$CONFIG" | with_default_logging > "$candidate"; then
    rm -f "$candidate"
    fail '无法生成默认运行设置，原配置保持不变。'; return 1
  fi
  apply_runtime_config "$candidate" '已更新默认日志 / DNS 设置'
}

set_logging() {
  local mode="$1" level='none' destination='none' candidate
  case "$mode" in
    on) level='warning'; destination="$LOG_FILE" ;;
    off) ;;
    *) fail '日志开关只支持 on 或 off。'; return 1 ;;
  esac
  candidate="$(mktemp "$ETC_DIR/.logging.XXXXXX")" || return 1
  if ! jq --arg level "$level" --arg destination "$destination" '
    .log=(.log // {}) | .log.loglevel=$level | .log.access="none" |
    .log.error=$destination | .log.dnsLog=false
  ' "$CONFIG" > "$candidate"; then rm -f "$candidate"; return 1; fi
  apply_runtime_config "$candidate" '已更新日志开关' || return 1
  if [[ "$mode" == on ]]; then
    info "日志已开启（仅 warning / error，不记录访问日志）：$LOG_FILE"
    info '排障完成后可关闭日志，并清空历史日志以释放空间。'
  else
    info '日志已关闭，不再记录 Xray 访问日志和错误日志；历史日志可单独清空。'
  fi
}

clear_logs() {
  if [[ -L "$LOG_FILE" || ( -e "$LOG_FILE" && ! -f "$LOG_FILE" ) ]]; then
    fail "日志路径不是普通文件，已拒绝清空：$LOG_FILE"; return 1
  fi
  if [[ -e "$LOG_FILE" ]]; then
    : > "$LOG_FILE" || return 1
    info '已清空本工具的历史日志。'
  else
    info '没有需要清空的本工具日志文件。'
  fi
}

next_node_name() {
  local n=1
  while resolve_node_tag "节点$n" >/dev/null 2>&1; do ((n+=1)); done
  printf '节点%s\n' "$n"
}

add_node() {
  init_config || return 1
  local name method='' default_name protocol endpoint sni='' credentials=''
  ui_title '自定义创建节点'
  protocol="$(choose_protocol)" || return 1
  default_name="$(next_node_name)" || return 1
  read -r -p "节点名称（支持中文，直接回车使用 $default_name）：" name || return 1
  name="${name:-$default_name}"
  safe_name "$name" || { fail '节点名称无效：需为 1～48 个字符，不能包含控制字符、斜杠或首尾空格。'; return 1; }
  if resolve_node_tag "$name" >/dev/null 2>&1; then
    fail '该节点名称已存在（含旧版节点），请使用不同的名称。'; return 1
  fi
  if [[ "$protocol" == vless ]]; then
    sni="$(choose_reality_server)" || return 1
  elif [[ "$protocol" == socks || "$protocol" == http ]]; then
    credentials="$(choose_proxy_credentials)" || return 1
  else
    method="$(choose_method "$protocol")" || return 1
  fi
  endpoint="$(choose_connection_setup custom)" || return 1
  ensure_core_for_new_node || return 1
  create_selected_node "$protocol" "$name" "$method" "$endpoint" "$sni" "$credentials"
}

quick_add_node() {
  init_config || return 1
  ui_title '快速创建节点'
  local name protocol endpoint method=''
  protocol="$(choose_protocol)" || return 1
  name="$(next_node_name)" || return 1
  endpoint="$(choose_connection_setup auto)" || return 1
  case "$protocol" in ss) method="$DEFAULT_SS_METHOD" ;; ss2022) method="$DEFAULT_SS2022_METHOD" ;; esac
  ensure_core_for_new_node || return 1
  create_selected_node "$protocol" "$name" "$method" "$endpoint" ''
}

choose_protocol() {
  ui_title '选择节点协议' >&2
  ui_item 1 'SS（兼容常见客户端）' >&2
  ui_item 2 'SS2022（客户端需支持 Shadowsocks 2022）' >&2
  ui_item 3 'VLESS + Reality（自动生成 UUID 和密钥）' >&2
  ui_item 4 'SOCKS5（账号密码认证，TCP 代理）' >&2
  ui_item 5 'HTTP（账号密码认证，支持 CONNECT）' >&2
  ui_item 0 '取消创建' >&2
  local choice
  while :; do
    read -r -p '请选择协议 [1-5，回车选 SS，0 返回]：' choice || return 1
    case "$choice" in
      1|'') printf 'ss\n'; return 0 ;;
      2) printf 'ss2022\n'; return 0 ;;
      3) printf 'vless\n'; return 0 ;;
      4) printf 'socks\n'; return 0 ;;
      5) printf 'http\n'; return 0 ;;
      0) return 1 ;;
      *) warn '请输入 1～5，或输入 0 返回。' ;;
    esac
  done
}

valid_proxy_credential() {
  jq -en --arg value "$1" --arg kind "$2" '
    ($value | utf8bytelength) as $size |
    ($size >= 1 and $size <= 255) and
    ($value | explode | all(.[]; . >= 32 and . != 127)) and
    ($kind != "username" or ($value | contains(":") | not))
  ' >/dev/null
}

choose_proxy_credentials() {
  local username password
  say '请设置代理账号和密码（均必填，最长 255 字节；密码输入时明文显示）。' >&2
  while :; do
    IFS= read -r -p '代理账号：' username || return 1
    if valid_proxy_credential "$username" username; then break; fi
    warn '账号不能为空、超过 255 字节或包含冒号、控制字符。'
  done
  while :; do
    IFS= read -r -p '代理密码（明文显示）：' password || return 1
    if valid_proxy_credential "$password" password; then break; fi
    warn '密码不能为空、超过 255 字节或包含控制字符。'
  done
  jq -n --arg user "$username" --arg pass "$password" '{user:$user,pass:$pass}'
}

choose_reality_server() {
  local host
  say 'Reality 伪装站点需支持 TLS 1.3，并能从服务器访问；它与节点的 DDNS 域名是两个地址。' >&2
  read -r -p 'Reality 伪装域名（回车从已测试的非 Cloudflare 候选池随机选择）：' host || return 1
  if [[ -n "$host" ]]; then
    valid_domain "$host" || { fail '请输入有效的伪装域名。'; return 1; }
  fi
  printf '%s\n' "$host"
}

# Fisher-Yates 洗牌；完整输出后才开始测试，随机源失败时不退回固定域名。
random_reality_servers() {
  local -a servers=("${REALITY_SERVERS[@]}")
  local i j random_hex swapped
  ((${#servers[@]})) || { fail 'Reality 候选域名池为空。'; return 1; }
  for ((i=${#servers[@]}-1; i>0; i--)); do
    random_hex="$(openssl rand -hex 4)" || return 1
    j=$((16#$random_hex % (i+1)))
    swapped="${servers[i]}"
    servers[i]="${servers[j]}"
    servers[j]="$swapped"
  done
  printf '%s\n' "${servers[@]}"
}

choose_connection_setup() {
  local style="${1:-auto}" current_port="${2:-}" choice host port public_port='' nat=false dynamic=false input
  ui_title '服务器的网络环境' >&2
  ui_item 1 '独立公网 / 固定 IP（普通 VPS，默认）' >&2
  ui_item 2 'NAT / 端口映射（服务商分配端口、家用路由器）' >&2
  ui_item 3 '动态公网 IP + DDNS 域名' >&2
  ui_item 4 'NAT + 动态 IP + DDNS 域名' >&2
  ui_item 0 '取消创建' >&2
  while :; do
    read -r -p '请选择网络环境 [1-4，默认 1，0 返回]：' choice || return 1
    case "$choice" in
      ''|1) break ;;
      2) nat=true; break ;;
      3) dynamic=true; break ;;
      4) nat=true; dynamic=true; break ;;
      0) return 1 ;;
      *) warn '请输入 1～4，或输入 0 返回。' ;;
    esac
  done
  if [[ "$nat" == true ]]; then
    say '先查看服务商 NAT 面板或路由器的端口转发：公网访问端口 → 本机监听端口。' >&2
    say '只有出站网络、未分配入站端口的 NAT 无法直接接入。端口不清楚时请返回查看，不能随机猜测。' >&2
    while :; do
      read -r -p '公网访问端口（服务商/路由器分配的端口，0 返回）：' input || return 1
      [[ "$input" != 0 ]] || return 1
      if public_port="$(normalize_port "$input")"; then break; fi
      warn '请填写已分配的 1～65535 端口，或输入 0 返回。'
    done
    port="${current_port:-$public_port}"
    if [[ "$port" != "$current_port" ]] && port_in_use "$port"; then
      fail "本机端口 $port 已占用，无法创建同端口映射节点。"
      return 1
    fi
    say "本机监听端口使用 $port；如需映射到其他本机端口，可在创建后通过 管理节点 → 修改本机监听端口 调整。" >&2
  elif [[ -n "$current_port" ]]; then
    port="$current_port"
  elif [[ "$style" == custom ]]; then
    port="$(choose_port)" || return 1
  else
    port="$(choose_port auto)" || return 1
  fi
  host="$(choose_node_host "$dynamic")" || return 1
  if ! valid_domain "$host"; then
    dynamic=false
  elif [[ "$dynamic" == true && "$nat" == true ]]; then
    say '本机 DDNS 更新要求出口 IP 与入站映射 IP 相同；服务商入口/出口不同，请使用上游设备维护的已有 DDNS。' >&2
  fi
  jq -n --arg host "$host" --argjson port "$port" --argjson nat "$nat" --argjson dynamic "$dynamic" \
    --arg public_port "$public_port" '{host:$host,port:$port,nat:$nat,dynamic:$dynamic} +
    (if $nat then {public_port:($public_port|tonumber)} else {} end)'
}

create_selected_node() {
  local protocol="$1" name="$2" method="$3" endpoint="$4" sni="$5" credentials="${6:-}" port host
  port="$(jq -er .port <<< "$endpoint")" || return 1
  host="$(jq -er .host <<< "$endpoint")" || return 1
  if [[ "$protocol" == vless ]]; then
    create_reality_node "$name" "$port" "$host" "$endpoint" "$sni"
  elif [[ "$protocol" == socks || "$protocol" == http ]]; then
    create_proxy_node "$protocol" "$name" "$port" "$host" "$endpoint" "$credentials"
  else
    create_node "$name" "$method" "$port" "$host" "$endpoint"
  fi
}

# 两种创建入口共用配置校验、地址保存和服务启动流程。
create_node() {
  local name="$1" method="$2" port="$3" host="$4"
  local tag="ss-$name" network='tcp,udp' pass node meta="${5:-}" listen
  listen="$(node_listen_address)"

  # 每次仅创建一个带独立密码的节点；不再询问单用户/多用户模式。
  pass="$(new_password "$method")" || return 1
  node="$(jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" \
    --arg pass "$pass" --arg network "$network" --arg listen "$listen" \
    '{tag:$tag,listen:$listen,port:$port,protocol:"shadowsocks",settings:{method:$method,password:$pass,network:$network}}')" || return 1
  [[ -n "$meta" ]] || meta='{}'
  commit_new_node "$tag" "$node" "$host" "$meta"
}

create_proxy_node() {
  local protocol="$1" name="$2" port="$3" host="$4" meta="$5" credentials="${6:-}"
  local prefix="$protocol" tag username password node listen
  [[ "$protocol" != socks ]] || prefix=socks5
  tag="$prefix-$name"
  if [[ -z "$credentials" ]]; then
    username="user_$(openssl rand -hex 6)" || return 1
    password="$(new_password "$protocol")" || return 1
  else
    username="$(jq -er '.user | select(type=="string")' <<< "$credentials")" || return 1
    password="$(jq -er '.pass | select(type=="string")' <<< "$credentials")" || return 1
  fi
  if ! valid_proxy_credential "$username" username || ! valid_proxy_credential "$password" password; then
    fail '代理账号或密码无效，未创建节点。'; return 1
  fi
  listen="$(node_listen_address)"
  node="$(jq -n --arg tag "$tag" --argjson port "$port" --arg protocol "$protocol" \
    --arg user "$username" --arg pass "$password" --arg listen "$listen" '
    {tag:$tag,listen:$listen,port:$port,protocol:$protocol,settings:{accounts:[{user:$user,pass:$pass}]}} |
    if $protocol=="socks" then .settings += {auth:"password",udp:false} else . end')" || return 1
  commit_new_node "$tag" "$node" "$host" "$meta"
}

node_listen_address() {
  # Go 的双栈监听支持 IPv4 和 IPv6；禁用 IPv6 的主机使用 IPv4。
  if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == 0 ]]; then
    printf '::\n'
  else
    printf '0.0.0.0\n'
  fi
}

probe_reality_target() {
  local sni="$1" target="${2:-$1:443}" dial_host port host tls_result
  valid_domain "$sni" || return 1
  [[ "$target" == *:* ]] || return 1
  dial_host="${target%:*}"
  port="$(normalize_port "${target##*:}")" || return 1
  host="${dial_host#[}"; host="${host%]}"
  valid_share_host "$host" || return 1
  if [[ "$host" == *:* ]]; then dial_host="[$host]"; else dial_host="$host"; fi
  # 使用与 Xray 相同的直连路径；HTTP 301/403 等响应也说明 TLS 握手已完成。
  # 不跟随跳转，避免把跳转后其他站点的握手误当成目标站点的结果。
  if tls_result="$(curl --silent --show-error --noproxy '*' --connect-timeout 5 --max-time 10 \
    --tlsv1.3 --tls-max 1.3 --connect-to "$sni:443:$dial_host:$port" \
    --head --output /dev/null --write-out '%{ssl_verify_result} %{time_appconnect}' "https://$sni/" 2>/dev/null)"; then
    return 0
  fi
  # TLS 已完成且证书校验通过时，后续的 HTTP 空响应/超时不影响 Reality 目标判断。
  awk 'NF==2 && $1=="0" && $2 ~ /^[0-9]+[.][0-9]+$/ && ($2+0)>0 {ok=1} END {exit !ok}' <<< "$tls_result"
}

# Xray 不同版本使用 Public key、PublicKey、Password 或 Password (PublicKey)。
# 只按明确的密钥标签读取；Hash32 是哈希，不能用作客户端公钥。
read_reality_key() {
  local kind="$1" key
  key="$(awk -F: -v kind="$kind" '
    NF >= 2 {
      label=tolower($1)
      gsub(/[[:space:]]/, "", label)
      if ((kind=="private" && label=="privatekey") ||
          (kind=="public" && (label=="publickey" || label=="password" || label=="password(publickey)"))) {
        value=substr($0, index($0, ":")+1)
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ')" || return 1
  [[ "$key" =~ ^[a-zA-Z0-9_-]{43}$ ]] || return 1
  printf '%s\n' "$key"
}

create_reality_node() {
  local name="$1" port="$2" host="$3" meta="$4" sni="$5"
  local tag="vless-$name" keys private public uuid sid node listen candidates result
  local -a servers=()
  ensure_reality_core || return 1
  if [[ -z "$sni" ]]; then
    candidates="$(random_reality_servers)" || return 1
    while IFS= read -r sni; do servers+=("$sni"); done <<< "$candidates"
    info "已随机排列 ${#servers[@]} 个非 Cloudflare 伪装站点，将使用首个实测通过的目标。"
  else
    servers=("$sni")
  fi
  # 同时捕获两个输出通道，失败时也不将可能含私钥的原始输出显示到终端。
  keys="$("$CORE_LINK" x25519 2>&1)" || { fail 'Xray 密钥命令执行失败，请在高级设置中检查或切换内核版本。'; return 1; }
  if ! private="$(read_reality_key private <<< "$keys")" ||
     ! public="$(read_reality_key public <<< "$keys")"; then
    fail '无法解析 Xray 返回的 Reality 密钥。请更新管理脚本；仍失败时，请提供内核版本和输出字段名称，不要提供密钥内容。'
    return 1
  fi
  uuid="$("$CORE_LINK" uuid)" || return 1
  [[ "$uuid" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] || { fail '内核未生成有效 UUID。'; return 1; }
  sid="$(openssl rand -hex 8)" || return 1
  listen="$(node_listen_address)"
  meta="$(jq --arg key "$public" '.reality_public_key=$key' <<< "$meta")" || return 1
  for sni in "${servers[@]}"; do
    info "检查 Reality 伪装站点 $sni:443 的 TLS 1.3 连接……"
    if ! probe_reality_target "$sni"; then
      warn "伪装站点 $sni 的 TLS 1.3 访问未通过。"
      continue
    fi
    node="$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg private "$private" \
      --arg sni "$sni" --arg sid "$sid" --arg listen "$listen" '{tag:$tag,listen:$listen,port:$port,protocol:"vless",
      settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},
      streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,
        serverNames:[$sni],privateKey:$private,shortIds:[$sid]}}}')" || return 1
    if commit_new_node "$tag" "$node" "$host" "$meta"; then
      return 0
    else
      result=$?
    fi
    # 只有隧道自检失败可换站点；保存配置或启用服务失败时立即停止。
    [[ "$result" == 2 ]] || return "$result"
    warn "伪装站点 $sni 的 Reality + Vision 实测未通过。"
  done
  fail '本次伪装站点均未通过连接测试，未创建节点。请检查出站网络，或在自定义创建中指定其他域名。'
  return 1
}

commit_new_node() {
  local tag="$1" node="$2" host="$3" meta="$4" tmp port public_port traffic
  if resolve_node_tag "${tag#*-}" >/dev/null 2>&1; then fail '节点名称已存在，请重新创建。'; return 1; fi
  tmp="$(mktemp "$ETC_DIR/.config.XXXXXX")" || return 1
  jq --argjson node "$node" '.inbounds += [$node]' "$CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! save_node_host "$tag" "$host"; then rm -f "$tmp"; return 1; fi
  if ! save_node_meta "$tag" "$meta"; then remove_node_host "$tag"; rm -f "$tmp"; return 1; fi
  if [[ "$tag" == vless-* ]]; then
    info '正在用临时实例验证 Reality + Vision 握手和 HTTPS 代理请求……'
    if ! CONFIG="$tmp" probe_reality_connection "$tag" isolated; then
      remove_node_host "$tag" || warn '自检失败，节点地址记录未能清理。'
      rm -f "$tmp"
      warn 'Reality 实际连接自检失败，未创建节点。普通 TLS 1.3 可访问不代表兼容 Reality。'
      return 2
    fi
    info 'Reality + Vision 握手和 HTTPS 代理请求通过。'
  fi
  if ! apply_config "$tmp"; then
    remove_node_host "$tag" || warn '服务创建失败，节点地址记录未能清理。'
    return 1
  fi
  port="$(jq -r .port <<< "$node")"
  public_port="$(node_public_port "$tag")" || return 1
  if [[ "$tag" == vless-* || "$tag" == socks5-* || "$tag" == http-* ]]; then traffic='TCP'; else traffic='TCP + UDP'; fi
  info "已创建节点：$tag。"
  warn "请在服务器防火墙中放行本机端口 $port（$traffic）。"
  if jq -e '.nat==true' <<< "$meta" >/dev/null; then
    say "NAT 映射：公网 $host:$public_port → 本机监听端口 $port（$traffic）。"
    say '请在服务商面板或路由器确认此映射已启用；脚本只配置本机和连接链接。'
  else
    say "请同时在服务商安全组中放行公网端口 $public_port（$traffic）。"
  fi
  if show_node_connection "$tag"; then
    if [[ "$tag" == socks5-* || "$tag" == http-* ]]; then
      say '下一步：在客户端填写地址、端口和账号密码；支持此类链接的客户端也可直接导入。'
    else
      say '下一步：复制上面的完整链接，在客户端选择“从剪贴板导入”。'
    fi
    if [[ "$tag" == vless-* ]]; then say 'Reality 无法连接时，运行 sudo xnode diagnose 检查原因。'; fi
  else
    warn '节点已创建，但连接信息显示失败。可在主菜单 2 中重新查看。'
  fi
}

list_nodes() {
  [[ -f "$CONFIG" ]] || { say '尚未创建配置文件。'; return 0; }
  local rows
  rows="$(jq -r --slurpfile meta "$NODE_META_FILE" '.inbounds | to_entries[] | .key as $i | .value |
    [($i+1|tostring), (.tag | if startswith("xss-") then "ss-" + .[4:] else . end), (.port|tostring),
     (($meta[0][.tag].public_port // .port)|tostring),
     (if .protocol=="vless" then "VLESS+Reality" elif .protocol=="socks" then "SOCKS5"
      elif .protocol=="http" then "HTTP" else (.settings.method // (.settings.users[0].method // "未知")) end)] | @tsv' "$CONFIG")" || return 1
  [[ -n "$rows" ]] || { say '当前没有任何节点。主菜单选择 1 即可快速创建。'; return 0; }
  {
    printf '序号\t节点名称\t本机端口\t公网端口\t协议/加密\n'
    printf '%s\n' "$rows"
  } | { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }
}

choose_node() {
  local input tag n
  local -a tags=()
  [[ -f "$CONFIG" ]] || { say '当前没有任何节点。主菜单选择 1 即可快速创建。' >&2; return 2; }
  while IFS= read -r tag; do tags+=("$tag"); done < <(jq -r '.inbounds[]?.tag' "$CONFIG")
  ((${#tags[@]})) || { say '当前没有任何节点。主菜单选择 1 即可快速创建。' >&2; return 2; }
  if [[ "${1:-}" == auto && ${#tags[@]} -eq 1 ]]; then
    info "已自动选中唯一节点：$(visible_node_name "${tags[0]}")" >&2
    printf '%s\n' "${tags[0]}"
    return 0
  fi
  list_nodes >&2 || return 1
  while :; do
    if ((${#tags[@]} == 1)); then
      read -r -p '输入节点序号或名称（回车选中唯一节点，0 返回）：' input || return 2
      input="${input:-1}"
    else
      read -r -p '输入节点序号或名称（0 或直接回车返回）：' input || return 2
      [[ -n "$input" ]] || return 2
    fi
    [[ "$input" != 0 ]] || return 2
    for ((n=0; n<${#tags[@]}; n++)); do
      if [[ "$input" == "$((n+1))" ]]; then
        printf '%s\n' "${tags[n]}"
        return 0
      fi
    done
    if tag="$(resolve_node_tag "$input" 2>/dev/null)"; then printf '%s\n' "$tag"; return 0; fi
    warn '未找到该节点，请输入列表中的序号或名称。'
  done
}

change_port() {
  need_core || return 1
  local tag="${1:-}" port tmp
  if [[ -z "$tag" ]]; then tag="$(choose_node)" || return 1; fi
  port="$(choose_port)" || return 1
  tmp="$(mktemp "$ETC_DIR/.config.XXXXXX")"
  jq --arg t "$tag" --argjson p "$port" '(.inbounds[] | select(.tag==$t) | .port)=$p' "$CONFIG" > "$tmp"
  apply_config "$tmp" || return 1
  warn "请在本机防火墙放行新监听端口 $port。"
  if jq -e --arg t "$tag" '.[$t].nat==true' "$NODE_META_FILE" >/dev/null; then
    say "请同步修改服务商/路由器映射：公网端口保持 $(node_public_port "$tag")，转发到新的本机端口 $port。"
  else
    say "请在服务商安全组中放行公网端口 $port，并重新复制更新后的链接。"
  fi
  show_node_connection "$tag"
}

restore_node_endpoints() {
  local hosts="$1" meta="$2" tmp
  tmp="$(mktemp "$ETC_DIR/.hosts-restore.XXXXXX")" || return 1
  printf '%s\n' "$hosts" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$NODE_HOSTS_FILE"
  tmp="$(mktemp "$ETC_DIR/.meta-restore.XXXXXX")" || return 1
  printf '%s\n' "$meta" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$NODE_META_FILE"
}

change_node_endpoint() {
  local tag="$1" endpoint old_port port host old_hosts old_meta meta tmp
  old_port="$(jq -er --arg t "$tag" '.inbounds[]|select(.tag==$t)|.port' "$CONFIG")" || return 1
  endpoint="$(choose_connection_setup address "$old_port")" || return 1
  host="$(jq -er .host <<< "$endpoint")" || return 1
  port="$(jq -er .port <<< "$endpoint")" || return 1
  old_hosts="$(cat "$NODE_HOSTS_FILE")" || return 1
  old_meta="$(cat "$NODE_META_FILE")" || return 1
  meta="$(jq --arg t "$tag" --argjson endpoint "$endpoint" '(.[$t] // {}) + $endpoint | if .nat then . else del(.public_port) end' "$NODE_META_FILE")" || return 1
  if ! save_node_host "$tag" "$host" || ! save_node_meta "$tag" "$meta"; then
    restore_node_endpoints "$old_hosts" "$old_meta"; return 1
  fi
  if [[ "$port" != "$old_port" ]]; then
    tmp="$(mktemp "$ETC_DIR/.config.XXXXXX")" || { restore_node_endpoints "$old_hosts" "$old_meta"; return 1; }
    jq --arg t "$tag" --argjson p "$port" '(.inbounds[]|select(.tag==$t)|.port)=$p' "$CONFIG" > "$tmp" || { rm -f "$tmp"; restore_node_endpoints "$old_hosts" "$old_meta"; return 1; }
    if ! apply_config "$tmp"; then restore_node_endpoints "$old_hosts" "$old_meta"; return 1; fi
  fi
  info '节点公网地址和映射信息已更新。'
  if jq -e .nat <<< "$endpoint" >/dev/null; then
    say "请确认外部映射：公网 $host:$(node_public_port "$tag") → 本机端口 $port。"
  fi
  show_node_connection "$tag"
}

delete_node() {
  need_core || return 1
  local tag="${1:-}" tmp yes
  if [[ -z "$tag" ]]; then tag="$(choose_node)" || return 1; fi
  read -r -p "将删除节点 $(visible_node_name "$tag")，请输入 '确认删除' 以继续：" yes || return 2
  [[ "$yes" == "确认删除" ]] || { info '已取消删除。'; return 2; }
  tmp="$(mktemp "$ETC_DIR/.config.XXXXXX")"
  jq --arg t "$tag" '.inbounds |= map(select(.tag!=$t))' "$CONFIG" > "$tmp"
  if apply_config "$tmp"; then
    remove_node_host "$tag" || warn '节点已删除，但独立连接地址记录清理失败。'
    info "已删除节点：$(visible_node_name "$tag")。"
  else
    return 1
  fi
}

# 公网地址用于生成分享链接；Xray 使用本机监听端口。
# 新节点的地址按节点标签分别存入 node-hosts.json，互不干扰。
valid_ipv4() {
  local ip="$1" item
  local -a parts
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$ip"
  ((${#parts[@]} == 4)) || return 1
  for item in "${parts[@]}"; do
    ((${#item} <= 3)) || return 1
    ((10#$item <= 255)) || return 1
  done
}

valid_ipv6() {
  local ip="$1" left right part compressed=0
  local -a groups=()
  [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" != *:::* ]] || return 1
  if [[ "$ip" == *::* ]]; then
    [[ "${ip#*::}" != *::* ]] || return 1
    compressed=1
    left="${ip%%::*}"
    right="${ip#*::}"
    if [[ -n "$left" ]]; then
      IFS=: read -r -a groups <<< "$left"
    fi
    [[ "$ip" != :* || "$ip" == ::* ]] || return 1
    [[ "$ip" != *: || "$ip" == *:: ]] || return 1
    if [[ -n "$right" ]]; then
      local -a tail=()
      IFS=: read -r -a tail <<< "$right"
      groups+=("${tail[@]}")
    fi
  else
    [[ "$ip" != :* && "$ip" != *: ]] || return 1
    IFS=: read -r -a groups <<< "$ip"
  fi
  for part in "${groups[@]}"; do
    [[ "$part" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
  done
  if ((compressed)); then
    ((${#groups[@]} < 8))
  else
    ((${#groups[@]} == 8))
  fi
}

valid_domain() {
  local host="$1" label
  local -a labels=()
  [[ ${#host} -ge 3 && ${#host} -le 253 && "$host" == *.* ]] || return 1
  [[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
  # 域名不能是纯数字的伪 IPv4 地址。
  [[ ! "$host" =~ ^[0-9.]+$ ]] || return 1
  IFS=. read -r -a labels <<< "$host"
  [[ "$host" != *. && "$host" != .* && "$host" != *..* ]] || return 1
  ((${#labels[@]} >= 2)) || return 1
  for label in "${labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
  done
  # 顶级域名只允许英文（含 punycode）以避免误将非法地址保存为域名。
  [[ "${labels[${#labels[@]}-1]}" =~ [a-zA-Z] ]]
}

valid_share_host() { valid_ipv4 "$1" || valid_ipv6 "$1" || valid_domain "$1"; }

valid_public_ip() {
  local ip="${1,,}" first second
  if valid_ipv4 "$ip"; then
    IFS=. read -r first second _ <<< "$ip"
    first=$((10#$first)); second=$((10#$second))
    ((first > 0 && first < 224 && first != 10 && first != 127)) || return 1
    ! ((first==192 && second==168 || first==172 && second>=16 && second<=31 ||
        first==169 && second==254 || first==100 && second>=64 && second<=127))
  elif valid_ipv6 "$ip"; then
    case "$ip" in ::|::1|fc*:*|fd*:*|fe8*:*|fe9*:*|fea*:*|feb*:*|ff*:*) return 1 ;; *) return 0 ;; esac
  else return 1; fi
}

# 依次尝试多个公网 IP 查询源，避免单个服务不可用时中断自动获取。
detect_public_ip() {
  local family="${1:-4}" ip url
  local -a urls=()
  case "$family" in
    4) urls=(https://api.ipify.org https://ipv4.icanhazip.com https://v4.ident.me) ;;
    6) urls=(https://api6.ipify.org https://ipv6.icanhazip.com https://v6.ident.me) ;;
    *) return 1 ;;
  esac
  for url in "${urls[@]}"; do
    # 绕过环境代理，避免把代理服务器的 IP 当成本机公网 IP。
    ip="$(curl "-$family" -fsSL --noproxy '*' --connect-timeout 4 --max-time 8 "$url" 2>/dev/null)" || continue
    ip="${ip//$'\r'/}"
    valid_public_ip "$ip" || continue
    if { [[ "$family" == 4 ]] && valid_ipv4 "$ip"; } || { [[ "$family" == 6 ]] && valid_ipv6 "$ip"; }; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

# DDNS 凭据只保存在权限为 600 的 JSON 文件中，不作为 shell 代码加载。
cloudflare_api() {
  local token="$1" method="$2" path="$3" data="${4:-}" response
  local -a args=(-fsS --connect-timeout 6 --max-time 25 --config - -X "$method" -H 'Content-Type: application/json')
  [[ -z "$data" ]] || args+=(--data "$data")
  # Token 经标准输入交给 curl，避免出现在进程参数中。
  response="$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl "${args[@]}" "https://api.cloudflare.com/client/v4/$path")" || { fail 'Cloudflare 请求失败，请检查网络和 API Token 权限。'; return 1; }
  jq -e '.success==true' <<< "$response" >/dev/null || { fail 'Cloudflare 拒绝请求。Token 需具备该域名的区域读取和 DNS 编辑权限。'; return 1; }
  printf '%s\n' "$response"
}

cloudflare_sync() {
  local cfg="$1" ip="$2" token domain family zone record result suffix payload type record_count
  token="$(jq -er .token <<< "$cfg")" || return 1
  domain="$(jq -er .host <<< "$cfg")" || return 1
  family="$(jq -r '.family // "4"' <<< "$cfg")"
  if [[ "$family" == 6 ]]; then type=AAAA; else type=A; fi
  zone="$(jq -r '.zone_id // empty' <<< "$cfg")"
  if [[ -z "$zone" ]]; then
    suffix="$domain"
    while [[ "$suffix" == *.* ]]; do
      result="$(cloudflare_api "$token" GET "zones?name=$suffix")" || return 1
      zone="$(jq -r '.result[0].id // empty' <<< "$result")"
      [[ -z "$zone" ]] || break
      suffix="${suffix#*.}"
    done
  fi
  [[ "$zone" =~ ^[a-fA-F0-9]{32}$ ]] || { fail '未找到此域名的 Cloudflare 区域，请确认域名和 Token 的访问范围。'; return 1; }
  result="$(cloudflare_api "$token" GET "zones/$zone/dns_records?type=$type&name=$domain")" || return 1
  record_count="$(jq -er '.result|length' <<< "$result")" || return 1
  ((record_count <= 1)) || { fail '同名 DNS 记录不止一条，请先在 Cloudflare 整理该域名的记录。'; return 1; }
  payload="$(jq -n --arg name "$domain" --arg type "$type" --arg ip "$ip" '{type:$type,name:$name,content:$ip,ttl:120,proxied:false}')" || return 1
  if ((record_count == 0)); then
    result="$(cloudflare_api "$token" POST "zones/$zone/dns_records" "$payload")" || return 1
    record="$(jq -er .result.id <<< "$result")" || return 1
  else
    record="$(jq -er '.result[0].id' <<< "$result")" || return 1
    [[ "$record" =~ ^[a-fA-F0-9]{32}$ ]] || { fail 'Cloudflare 返回的记录 ID 无效。'; return 1; }
    if ! jq -e --arg ip "$ip" '.result[0] | .content==$ip and .proxied==false' <<< "$result" >/dev/null; then
      cloudflare_api "$token" PATCH "zones/$zone/dns_records/$record" "$payload" >/dev/null || return 1
    fi
  fi
  jq --arg zone "$zone" --arg record "$record" '.zone_id=$zone | .record_id=$record' <<< "$cfg"
}

duckdns_sync() {
  local cfg="$1" ip="$2" domain token family sub response encoded_ip url
  domain="$(jq -er .host <<< "$cfg")" || return 1
  token="$(jq -er .token <<< "$cfg")" || return 1
  family="$(jq -r '.family // "4"' <<< "$cfg")"
  sub="${domain%.duckdns.org}"
  [[ "$domain" == *.duckdns.org && "$sub" != *.* && -n "$sub" ]] || { fail 'DuckDNS 需要填写你已申请的 xxx.duckdns.org 域名。'; return 1; }
  encoded_ip="$(jq -rn --arg ip "$ip" '$ip|@uri')"
  url="https://www.duckdns.org/update?domains=$sub&token=$token"
  if [[ "$family" == 6 ]]; then url+="&ip=&ipv6=$encoded_ip"; else url+="&ip=$encoded_ip"; fi
  response="$(printf 'url = "%s"\n' "$url" | curl -fsS --connect-timeout 6 --max-time 25 --config -)" || { fail 'DuckDNS 请求失败，请检查网络。'; return 1; }
  [[ "${response%%$'\n'*}" == OK ]] || { fail 'DuckDNS 更新失败，请确认域名归属和 Token。'; return 1; }
  printf '%s\n' "$cfg"
}

ddns_update() {
  local config_file="${1:-$DDNS_FILE}" cfg provider family ip tmp token domain
  [[ -s "$config_file" ]] || { fail '尚未配置本机 DDNS 自动更新。请到高级设置 → DDNS 自动更新中配置。'; return 1; }
  cfg="$(jq -ec 'select(type=="object")' "$config_file")" || return 1
  provider="$(jq -er .provider <<< "$cfg")" || return 1
  family="$(jq -r '.family // "4"' <<< "$cfg")"
  domain="$(jq -er .host <<< "$cfg")" || return 1
  token="$(jq -er .token <<< "$cfg")" || return 1
  valid_domain "$domain" && [[ "$token" =~ ^[a-zA-Z0-9_-]{10,200}$ && "$family" =~ ^[46]$ ]] || { fail 'DDNS 配置无效，请重新配置。'; return 1; }
  ip="$(detect_public_ip "$family")" || { fail "无法获取公网 IPv$family，本次未修改 DNS。"; return 1; }
  case "$provider" in
    cloudflare) cfg="$(cloudflare_sync "$cfg" "$ip")" || return 1 ;;
    duckdns) cfg="$(duckdns_sync "$cfg" "$ip")" || return 1 ;;
    *) fail 'DDNS 服务商无效。'; return 1 ;;
  esac
  tmp="$(mktemp "$ETC_DIR/.ddns.XXXXXX")" || return 1
  jq --arg ip "$ip" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_ip=$ip | .last_success=$now' <<< "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$config_file"
  info "DDNS 已更新：$domain → $ip。" >&2
}

check_ddns_unit() {
  local path="$1"
  [[ ! -e "$path" && ! -L "$path" ]] && return 0
  [[ ! -L "$path" ]] && grep -Fq '# XSS-MANAGED: xnode-ddns' "$path" && return 0
  fail "DDNS 定时任务路径已被其他文件占用：$path"
}

install_ddns_scheduler() {
  local jobs task
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    check_ddns_unit "$DDNS_SERVICE_FILE" && check_ddns_unit "$DDNS_TIMER_FILE" || return 1
    mkdir -p "$(dirname "$DDNS_SERVICE_FILE")" "$(dirname "$DDNS_TIMER_FILE")" || return 1
    cat > "$DDNS_SERVICE_FILE" <<EOF
# XSS-MANAGED: xnode-ddns
[Unit]
Description=Xnode DDNS update
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
Environment="XSS_ETC_DIR=$ETC_DIR"
ExecStart="$ENTRY" ddns-update
EOF
    cat > "$DDNS_TIMER_FILE" <<'EOF'
# XSS-MANAGED: xnode-ddns
[Unit]
Description=Update Xnode DDNS every five minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=30s
[Install]
WantedBy=timers.target
EOF
    chmod 644 "$DDNS_SERVICE_FILE" "$DDNS_TIMER_FILE"
    systemctl daemon-reload && systemctl enable --now xnode-ddns.timer || return 1
  else
    command -v crontab >/dev/null 2>&1 || { fail '系统没有可用的定时任务工具。请安装并启动 cron，或使用路由器/ddns-go 更新域名。'; return 1; }
    [[ "$ENTRY" =~ ^/[a-zA-Z0-9_./-]+$ && "$ETC_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || { fail 'cron 自动更新需要使用常规安装路径，例如 /usr/local/bin/xnode 和 /etc/xray-ss。'; return 1; }
    jobs="$(crontab -l 2>/dev/null || true)"
    task="*/5 * * * * XSS_ETC_DIR=$ETC_DIR $ENTRY ddns-update >/dev/null 2>&1 # XSS-MANAGED: xnode-ddns"
    { if [[ -n "$jobs" ]]; then printf '%s\n' "$jobs" | awk '!/# XSS-MANAGED: xnode-ddns$/'; fi; printf '%s\n' "$task"; } | crontab - || return 1
    warn '已写入每 5 分钟执行的 cron 任务；请确保系统的 cron 服务正在运行。'
  fi
  info 'DDNS 自动更新已启用，每 5 分钟检查一次。'
}

remove_ddns_scheduler() {
  local jobs path managed_timer=0
  [[ -f "$DDNS_FILE" ]] || return 0
  if [[ -f "$DDNS_TIMER_FILE" && ! -L "$DDNS_TIMER_FILE" ]] && grep -Fq '# XSS-MANAGED: xnode-ddns' "$DDNS_TIMER_FILE"; then managed_timer=1; fi
  if ((managed_timer)) && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now xnode-ddns.timer >/dev/null 2>&1 || return 1
    systemctl stop xnode-ddns.service >/dev/null 2>&1 || true
  fi
  for path in "$DDNS_TIMER_FILE" "$DDNS_SERVICE_FILE"; do
    if [[ -f "$path" && ! -L "$path" ]] && grep -Fq '# XSS-MANAGED: xnode-ddns' "$path"; then rm -f "$path" || return 1; fi
  done
  if ((managed_timer)); then systemctl daemon-reload || return 1; fi
  if command -v crontab >/dev/null 2>&1; then
    jobs="$(crontab -l 2>/dev/null || true)"
    if [[ "$jobs" == *'# XSS-MANAGED: xnode-ddns'* ]]; then
      printf '%s\n' "$jobs" | awk '!/# XSS-MANAGED: xnode-ddns$/' | crontab - || return 1
    fi
  fi
}

configure_ddns() {
  local provider="$1" host="${2:-}" token family cfg tmp
  init_config || return 1
  if [[ -z "$host" ]]; then
    read -r -p '你拥有的 DDNS 域名（例如 node.example.com 或 xxx.duckdns.org，0 返回）：' host || return 1
  fi
  [[ "$host" != 0 ]] || return 1
  host="${host,,}"
  valid_domain "$host" || { fail '域名格式无效。'; return 1; }
  if [[ "$provider" == cloudflare ]]; then
    say '请准备仅授权此域名的 API Token：区域读取 + DNS 编辑；此记录将设为“仅 DNS”，关闭橙云代理。' >&2
  else
    [[ "$host" == *.duckdns.org && "${host%.duckdns.org}" != *.* ]] || { fail '请先在 DuckDNS 申请 xxx.duckdns.org 域名。'; return 1; }
    say '填写 DuckDNS 账户的 Token。' >&2
  fi
  read -r -s -p 'API Token（输入不回显）：' token || return 1
  printf '\n' >&2
  [[ "$token" =~ ^[a-zA-Z0-9_-]{10,200}$ ]] || { fail 'Token 格式无效。'; return 1; }
  read -r -p '更新的 IP 版本 [4/6，默认 4]：' family || return 1
  family="${family:-4}"
  [[ "$family" =~ ^[46]$ ]] || { fail '请输入 4 或 6。'; return 1; }
  if [[ "$INIT_SYSTEM" == systemd ]]; then
    check_ddns_unit "$DDNS_SERVICE_FILE" && check_ddns_unit "$DDNS_TIMER_FILE" || return 1
  else
    command -v crontab >/dev/null 2>&1 || { fail '请先安装并启动 cron，或选择已有 DDNS。'; return 1; }
  fi
  cfg="$(jq -n --arg provider "$provider" --arg host "$host" --arg token "$token" --arg family "$family" \
    '{provider:$provider,host:$host,token:$token,family:$family}')" || return 1
  tmp="$(mktemp "$ETC_DIR/.ddns-setup.XXXXXX")" || return 1
  printf '%s\n' "$cfg" > "$tmp"
  chmod 600 "$tmp"
  if ! ddns_update "$tmp"; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$DDNS_FILE"
  install_ddns_scheduler || { fail 'DNS 已更新，但定时任务启用失败。配置已保留，可在 DDNS 菜单重新配置或立即更新。'; return 1; }
  say '请确保此域名没有指向其他旧 IP 的记录；若还有其他设备更新同一域名，请关闭重复更新。'
}

choose_dynamic_host() {
  local choice host="$1" saved=''
  valid_domain "$host" || { fail '请输入有效的 DDNS 域名。'; return 1; }
  if [[ -f "$DDNS_FILE" ]]; then saved="$(jq -r '.host // empty' "$DDNS_FILE")" || return 1; fi
  ui_title '动态 IP 使用 DDNS 域名' >&2
  say "连接域名：$host" >&2
  ui_item 1 '使用已有 DDNS（路由器、ddns-go 等已负责更新）' >&2
  ui_item 2 '配置 Cloudflare 自动更新（需要自己的域名和 Token）' >&2
  ui_item 3 '配置 DuckDNS 自动更新（需要已申请的免费域名和 Token）' >&2
  ui_item 0 '返回' >&2
  read -r -p '请选择 DDNS 方式 [1-3，默认 1，0 返回]：' choice || return 1
  case "$choice" in
    1|'')
      if [[ "$host" == "$saved" && -n "$saved" ]]; then info '沿用已配置的本机 DDNS 自动更新。' >&2
      else warn '请确保路由器或 DDNS 客户端持续更新此域名；只填写域名不会自动更新 DNS。'; fi
      ;;
    2|3)
      if [[ "$choice" == 2 ]]; then configure_ddns cloudflare "$host" >&2 || return 1
      else configure_ddns duckdns "$host" >&2 || return 1; fi
      host="$(jq -er .host "$DDNS_FILE")" || return 1
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$host"
}

ddns_menu() {
  local ans
  while :; do
    ui_title 'DDNS 自动更新'
    if [[ -f "$DDNS_FILE" ]]; then
      jq -r '"  域名：\(.host)  ·  服务商：\(.provider)","  上次成功：\(.last_success // "尚未更新")  ·  IP：\(.last_ip // "未知")"' "$DDNS_FILE"
    else say '  尚未配置本机自动更新；已有路由器/DDNS 客户端的用户可以直接使用其域名。'; fi
    ui_item 1 '配置 Cloudflare 自动更新'
    ui_item 2 '配置 DuckDNS 自动更新'
    ui_item 3 '立即更新一次'
    ui_item 4 '停止本机自动更新并清除 Token'
    ui_back
    read -r -p '请选择 [1-4 / 0]：' ans || return 0
    case "$ans" in
      1) configure_ddns cloudflare || true ;;
      2) configure_ddns duckdns || true ;;
      3) ddns_update || true ;;
      4) if remove_ddns_scheduler; then rm -f "$DDNS_FILE"; info '本机 DDNS 自动更新已停止，Token 已清除。节点仍使用原域名。'; fi ;;
      0) return 0 ;;
      '') continue ;;
      *) warn '请输入 1～4，或输入 0 返回。' ;;
    esac
  done
}

detect_public_host() {
  detect_public_ip 4 || detect_public_ip 6
}

choose_node_host() {
  local dynamic="${1:-false}" answer host=''
  read -r -p '此节点是否使用域名（含 DDNS）作为连接地址？[y/N，回车自动获取本机公网 IP，0 返回]：' answer || return 1
  case "$answer" in
    y|Y|yes|YES|是)
      read -r -p '节点连接域名（如 ss.example.com，回车自动获取本机公网 IP，0 返回）：' host || return 1
      [[ "$host" != 0 ]] || return 1
      if [[ -n "$host" ]]; then
        valid_domain "$host" || { fail '域名格式不正确，请只输入域名，不要包含 http://、端口、路径或空格。'; return 1; }
        if [[ "$dynamic" == true ]]; then
          host="$(choose_dynamic_host "$host")" || return 1
        else
          info "此节点将使用域名：$host" >&2
          warn '请自行确认域名 DNS 已指向该服务器；这里只修改分享链接，不配置 DNS 或 TLS。' >&2
        fi
      fi
      ;;
    ''|n|N|no|NO|否) ;;
    0) return 1 ;;
    *) fail '请选择 y 或 n（直接回车自动获取本机公网 IP，0 返回）。'; return 1 ;;
  esac
  if [[ -z "$host" ]]; then
    host="$(detect_public_host)" || { fail '无法自动获取本机公网 IP，请检查服务器出站网络后重试，或选择使用域名。'; return 1; }
    info "已自动获取本机公网 IP：$host" >&2
  fi
  printf '%s\n' "$host"
}

save_node_host() {
  local tag="$1" host="$2" tmp
  valid_share_host "$host" || { fail '节点连接地址无效，未保存。'; return 1; }
  tmp="$(mktemp "$ETC_DIR/.node-hosts.XXXXXX")" || return 1
  if ! jq -e --arg t "$tag" --arg h "$host" '.[$t]=$h' "$NODE_HOSTS_FILE" > "$tmp"; then
    rm -f "$tmp"
    fail '无法保存节点连接地址。'
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$NODE_HOSTS_FILE"
}

remove_node_host() {
  local tag="$1" tmp
  [[ -f "$NODE_HOSTS_FILE" ]] || return 0
  tmp="$(mktemp "$ETC_DIR/.node-hosts.XXXXXX")" || return 1
  if ! jq -e --arg t "$tag" 'del(.[$t])' "$NODE_HOSTS_FILE" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$NODE_HOSTS_FILE"
  if [[ -f "$NODE_META_FILE" ]]; then
    tmp="$(mktemp "$ETC_DIR/.node-meta.XXXXXX")" || return 1
    jq -e --arg t "$tag" 'del(.[$t])' "$NODE_META_FILE" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f "$tmp" "$NODE_META_FILE"
  fi
}

save_node_meta() {
  local tag="$1" meta="$2" tmp
  tmp="$(mktemp "$ETC_DIR/.node-meta.XXXXXX")" || return 1
  if ! jq -e --arg t "$tag" --argjson m "$meta" '.[$t]=($m|del(.host,.port))' "$NODE_META_FILE" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$NODE_META_FILE"
}

node_public_port() {
  local tag="$1" port=''
  if [[ -f "$NODE_META_FILE" ]]; then
    port="$(jq -er --arg t "$tag" '.[$t].public_port // empty' "$NODE_META_FILE")" || port=''
  fi
  if [[ -z "$port" ]]; then port="$(jq -er --arg t "$tag" '.inbounds[]|select(.tag==$t)|.port' "$CONFIG")" || return 1; fi
  normalize_port "$port" || { fail '节点公网端口无效。'; return 1; }
}

node_reality_public_key() {
  local tag="$1" key='' private output
  if [[ -f "$NODE_META_FILE" ]]; then
    key="$(jq -er --arg t "$tag" '.[$t].reality_public_key // empty' "$NODE_META_FILE")" || key=''
  fi
  if [[ -z "$key" ]]; then
    private="$(jq -er --arg t "$tag" '.inbounds[]|select(.tag==$t)|.streamSettings.realitySettings.privateKey' "$CONFIG")" || return 1
    if ! output="$("$CORE_LINK" x25519 -i "$private" 2>&1)" ||
       ! key="$(read_reality_key public <<< "$output")"; then
      fail '无法读取此节点的 Reality 公钥，请检查内核版本和密钥输出格式，不要提供私钥内容。'
      return 1
    fi
  fi
  [[ "$key" =~ ^[a-zA-Z0-9_-]{43}$ ]] || { fail '无法读取此节点的 Reality 公钥。'; return 1; }
  printf '%s\n' "$key"
}

make_node_uri() {
  local tag="$1" node host port display protocol method password uuid sni sid public label hostpart username scheme
  node="$(jq -ec --arg t "$tag" '.inbounds[]|select(.tag==$t)' "$CONFIG")" || return 1
  host="$(node_share_host "$tag")" || return 1
  port="$(node_public_port "$tag")" || return 1
  display="$(visible_node_name "$tag")"
  protocol="$(jq -r .protocol <<< "$node")"
  case "$protocol" in
    shadowsocks)
      jq -e '.settings.users==null' <<< "$node" >/dev/null || { fail '旧版多用户节点请查看全部链接。'; return 1; }
      method="$(jq -er .settings.method <<< "$node")" || return 1
      password="$(jq -er .settings.password <<< "$node")" || return 1
      make_ss_uri "$method" "$password" "$host" "$port" "$display"
      ;;
    vless)
      jq -e '.streamSettings.security=="reality" and (.settings.clients|length)==1' <<< "$node" >/dev/null || return 1
      public="$(node_reality_public_key "$tag")" || return 1
      uuid="$(jq -er '.settings.clients[0].id' <<< "$node")" || return 1
      sni="$(jq -er '.streamSettings.realitySettings.serverNames[0]' <<< "$node")" || return 1
      sid="$(jq -er '.streamSettings.realitySettings.shortIds[0]' <<< "$node")" || return 1
      sni="$(jq -rn --arg s "$sni" '$s|@uri')"
      label="$(jq -rn --arg s "$display" '$s|@uri')"
      hostpart="$host"; [[ "$host" != *:* ]] || hostpart="[$host]"
      printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=%s&fp=chrome&pbk=%s&sid=%s#%s\n' \
        "$uuid" "$hostpart" "$port" "$sni" "$public" "$sid" "$label"
      ;;
    socks|http)
      jq -e '(.settings.accounts | length)==1' <<< "$node" >/dev/null || return 1
      username="$(jq -er '.settings.accounts[0].user | @uri' <<< "$node")" || return 1
      password="$(jq -er '.settings.accounts[0].pass | @uri' <<< "$node")" || return 1
      scheme="$protocol"; [[ "$protocol" != socks ]] || scheme=socks5
      hostpart="$host"; [[ "$host" != *:* ]] || hostpart="[$host]"
      label="$(jq -rn --arg s "$display" '$s|@uri')"
      printf '%s://%s:%s@%s:%s#%s\n' "$scheme" "$username" "$password" "$hostpart" "$port" "$label"
      ;;
    *) fail '暂不支持此节点的分享链接。'; return 1 ;;
  esac
}

node_share_host() {
  local tag="$1" host=''
  if [[ -s "$NODE_HOSTS_FILE" ]]; then
    host="$(jq -er --arg t "$tag" '.[$t] // empty' "$NODE_HOSTS_FILE" 2>/dev/null || true)"
  fi
  if [[ -n "$host" ]]; then
    valid_share_host "$host" || { fail "节点 $tag 保存的连接地址无效。"; return 1; }
    printf '%s\n' "$host"
    return 0
  fi
  # 旧节点未保存独立地址时，沿用旧版 host.txt，不修改已有节点或密码。
  if [[ -s "$HOST_FILE" ]]; then
    host="$(tr -d '\r\n' < "$HOST_FILE")"
    if valid_share_host "$host"; then printf '%s\n' "$host"; return 0; fi
  fi
  detect_public_host || fail "无法确定节点 $tag 的公网地址。"
}

# SIP002: legacy AEAD uses base64url userinfo; SS2022 MUST use plain percent-encoded userinfo.
make_ss_uri() {
  local method="$1" password="$2" host="$3" port="$4" name="$5" userinfo hostpart label
  if [[ "$method" == 2022-* ]]; then
    userinfo="${method}:$(jq -rn --arg p "$password" '$p|@uri')"
  else
    userinfo="$(printf '%s' "${method}:${password}" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
  fi
  hostpart="$host"
  [[ "$host" != *:* ]] || hostpart="[$host]"
  label="$(jq -rn --arg n "$name" '$n|@uri')"
  printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$hostpart" "$port" "$label"
}


show_node_connection() {
  local tag="$1" node display host port public_port uri protocol method network
  node="$(jq -ec --arg t "$tag" '.inbounds[]|select(.tag==$t)' "$CONFIG")" || return 1
  uri="$(make_node_uri "$tag")" || return 1
  host="$(node_share_host "$tag")" || return 1
  port="$(jq -r .port <<< "$node")"
  public_port="$(node_public_port "$tag")" || return 1
  display="$(visible_node_name "$tag")"
  protocol="$(jq -r .protocol <<< "$node")"
  say ''
  say '========== 节点连接信息 =========='
  say "节点名称：$display"
  say "服务器地址：$host"
  say "公网访问端口：$public_port"
  say "本机监听端口：$port"
  if [[ "$protocol" == vless ]]; then
    say '协议：VLESS + Reality'
    say "用户 UUID：$(jq -r '.settings.clients[0].id' <<< "$node")"
    say "Reality 伪装域名：$(jq -r '.streamSettings.realitySettings.serverNames[0]' <<< "$node")"
    say "Reality 公钥：$(node_reality_public_key "$tag")"
    say '传输方式：TCP；客户端需支持 Reality 和 Vision。'
    say ''
    say 'VLESS + Reality 分享链接（复制到客户端即可导入）：'
  elif [[ "$protocol" == socks || "$protocol" == http ]]; then
    if [[ "$protocol" == socks ]]; then say '协议：SOCKS5'; else say '协议：HTTP（支持 CONNECT）'; fi
    say '传输方式：TCP；账号密码认证。'
    say "代理账号：$(jq -r '.settings.accounts[0].user' <<< "$node")"
    say "代理密码：$(jq -r '.settings.accounts[0].pass' <<< "$node")"
    say ''
    say '代理连接链接（客户端支持时可导入，也可手动填写地址、端口和账号密码）：'
  else
    method="$(jq -r .settings.method <<< "$node")"
    if [[ "$method" == 2022-* ]]; then say '协议：SS2022'; else say '协议：SS'; fi
    say "加密方式：$method"
    network="$(jq -r '.settings.network // "tcp"' <<< "$node")"
    case "$network" in tcp) say '传输方式：仅 TCP' ;; udp) say '传输方式：仅 UDP' ;; *) say '传输方式：TCP + UDP' ;; esac
    say "连接密码：$(jq -r .settings.password <<< "$node")"
    say ''
    say 'SS / SS2022 分享链接（复制到客户端即可导入）：'
  fi
  printf '%s\n' "$uri"
  say '=================================='
  warn '分享链接包含连接凭据，请妥善保管。'
}

# 从节点真实入站配置生成可复制到 Xray outbounds 数组中的单个出站对象。
# 使用 jq 构建 JSON，避免中文节点名、Base64 密钥等内容被手工拼接破坏。
# 配置沿用 Xray 兼容的 settings.servers 形式，以便旧版 3x-ui 手动添加出站。
make_node_outbound_json() {
  local tag="$1" host json display_tag port protocol public
  [[ -s "$CONFIG" ]] || { fail '尚未创建节点配置。'; return 1; }
  host="$(node_share_host "$tag")" || return 1
  port="$(node_public_port "$tag")" || return 1
  display_tag="$(visible_node_name "$tag")" || return 1
  protocol="$(jq -er --arg t "$tag" '.inbounds[]|select(.tag==$t)|.protocol' "$CONFIG")" || return 1
  if [[ "$protocol" == vless ]]; then
    public="$(node_reality_public_key "$tag")" || return 1
    jq -e --arg t "$tag" --arg host "$host" --argjson port "$port" --arg display "$display_tag" --arg public "$public" '
      .inbounds[]|select(.tag==$t and .streamSettings.security=="reality" and (.settings.clients|length)==1)|
      {tag:$display,protocol:"vless",settings:{vnext:[{address:$host,port:$port,
        users:[{id:.settings.clients[0].id,encryption:"none",flow:(.settings.clients[0].flow // "xtls-rprx-vision")}]}]},
       streamSettings:{network:"tcp",security:"reality",realitySettings:{fingerprint:"chrome",publicKey:$public,
         serverName:.streamSettings.realitySettings.serverNames[0],shortId:.streamSettings.realitySettings.shortIds[0]}}}' "$CONFIG"
    return $?
  fi
  if [[ "$protocol" == socks || "$protocol" == http ]]; then
    jq -e --arg t "$tag" --arg host "$host" --argjson port "$port" --arg display "$display_tag" '
      .inbounds[] | select(.tag==$t and (.settings.accounts | length)==1) |
      {tag:$display,protocol:.protocol,settings:{servers:[{address:$host,port:$port,
        users:[{user:.settings.accounts[0].user,pass:.settings.accounts[0].pass}]}]}}' "$CONFIG"
    return $?
  fi
  if ! jq -e --arg t "$tag" '
      .inbounds[]? |
      select(.tag==$t and .protocol=="shadowsocks" and .settings.users==null and
             (.port|type)=="number" and (.settings.method|type)=="string" and
             (.settings.password|type)=="string")
    ' "$CONFIG" >/dev/null; then
    fail '当前节点不是可导出的单用户 SS / SS2022 节点，无法生成出站 JSON。'
    return 1
  fi
  # 出站 tag 与菜单显示的节点名称一致；兼容旧 xss- 节点的显示名 ss-。
  display_tag="$(visible_node_name "$tag")" || return 1
  json="$(jq -e --arg t "$tag" --arg host "$host" --argjson port "$port" --arg display_tag "$display_tag" '
    .inbounds[]? |
    select(.tag==$t and .protocol=="shadowsocks" and .settings.users==null) |
    {
      tag: $display_tag,
      protocol: "shadowsocks",
      settings: {
        servers: [{
          address: $host,
          port: $port,
          method: .settings.method,
          password: .settings.password
        }]
      }
    }
  ' "$CONFIG")" || { fail '生成出站 JSON 失败。'; return 1; }
  [[ -n "$json" ]] || { fail '生成出站 JSON 失败：未找到目标节点。'; return 1; }
  printf '%s\n' "$json"
}

show_node_outbound_json() {
  local tag="$1" json
  json="$(make_node_outbound_json "$tag")" || return 1
  say ''
  say '========== Xray 出站 JSON =========='
  say "节点名称：$(visible_node_name "$tag")"
  say '复制下面完整的 JSON 对象，添加到 3x-ui 的 Xray 配置 outbounds 数组中：'
  printf '%s\n' "$json"
  say '===================================' 
  say '提示：这是一条出站对象，不是完整的 Xray 配置文件；如需走该出口，请配置相应路由。'
  warn '出站 JSON 包含节点密码，请勿公开分享。'
}

show_links() {
  [[ -f "$CONFIG" ]] || { fail '尚未创建节点配置。'; return 1; }
  if ! jq -e '.inbounds | length>0' "$CONFIG" >/dev/null; then
    say '当前没有任何节点。主菜单选择 1 即可快速创建。'
    return 0
  fi
  ui_title '节点分享链接'
  say '复制 ss:// 或 vless:// 开头的完整一行，在客户端选择“从剪贴板导入”。'
  if jq -e '.inbounds[]? | select(.protocol=="socks" or .protocol=="http")' "$CONFIG" >/dev/null; then
    say 'SOCKS5 / HTTP 提供 socks5:// / http:// 链接；客户端不支持导入时，可在管理节点中查看账号密码手动配置。'
  fi
  local host tag display port method password nickname
  while IFS=$'\t' read -r tag port method password nickname; do
    [[ -n "$tag" ]] || continue
    host="$(node_share_host "$tag")" || { warn "节点 $tag 的分享链接生成失败，已跳过。"; continue; }
    port="$(node_public_port "$tag")" || continue
    display="$(visible_node_name "$tag")"
    if [[ "$nickname" == '节点' ]]; then
      printf '\n%s\n' "$display"
      make_ss_uri "$method" "$password" "$host" "$port" "$display"
    else
      printf '\n%s / %s\n' "$display" "$nickname"
      make_ss_uri "$method" "$password" "$host" "$port" "$display-$nickname"
    fi
  done < <(jq -r '.inbounds[]? | select(.protocol=="shadowsocks") | . as $n | if (.settings.users | type)=="array" then .settings.users[] | [$n.tag, ($n.port|tostring), ($n.settings.method // .method), (if (($n.settings.method // "") | startswith("2022-")) then ($n.settings.password + ":" + .password) else .password end), (.email // "user")] | @tsv else [$n.tag, ($n.port|tostring), .settings.method, .settings.password, "节点"] | @tsv end' "$CONFIG")
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    printf '\n%s\n' "$(visible_node_name "$tag")"
    make_node_uri "$tag" || warn "节点 $tag 的分享链接生成失败。"
  done < <(jq -r '.inbounds[]?|select(.protocol=="vless" or .protocol=="socks" or .protocol=="http")|.tag' "$CONFIG")
  warn '以上链接包含节点密钥，请妥善保管，不要公开传播。'
}

view_node_connections() {
  local tag choice selection_status
  if tag="$(choose_node auto)"; then :
  else
    selection_status=$?
    [[ "$selection_status" == 2 ]] && return 0
    return "$selection_status"
  fi
  while :; do
    say ''
    ui_title "查看节点：$(visible_node_name "$tag")"
    ui_item 1 '查看 SS / SS2022 / Reality / SOCKS5 / HTTP 连接链接'
    ui_item 2 '查看 Xray 出站 JSON（用于 3x-ui 手动添加出站）'
    ui_back
    read -r -p '请输入选项（1/2/0）：' choice || return 0
    case "$choice" in
      1) show_node_connection "$tag"; return $? ;;
      2) show_node_outbound_json "$tag"; return $? ;;
      0|'') return 0 ;;
      *) warn '请输入 1、2 或 0。' ;;
    esac
  done
}

# 精简系统可能既没有 iproute2，也没有 net-tools；从内核端口表查询。
# 返回 0 表示占用，1 表示空闲，2 表示无法读取端口表。
proc_port_in_use() {
  local port hex mode="${2:-tcp}" path
  local -a tables=()
  port="$(normalize_port "$1")" || return 2
  printf -v hex '%04X' "$port"
  for path in /proc/net/tcp /proc/net/tcp6; do
    [[ ! -r "$path" ]] || tables+=("$path")
  done
  if [[ "$mode" == all ]]; then
    for path in /proc/net/udp /proc/net/udp6; do
      [[ ! -r "$path" ]] || tables+=("$path")
    done
  fi
  ((${#tables[@]})) || return 2
  awk -v port="$hex" -v mode="$mode" '
    toupper($2) ~ (":" port "$") && (mode=="all" || $4=="0A") {found=1}
    END {exit !found}' "${tables[@]}"
}

tcp_port_is_listening() {
  local port="$1" sockets
  if command -v ss >/dev/null 2>&1 && sockets="$(ss -H -ltn 2>/dev/null)"; then
    awk -v port="$port" '$4 ~ (":" port "$") {found=1} END {exit !found}' <<< "$sockets"
    return $?
  fi
  if command -v netstat >/dev/null 2>&1 && sockets="$(netstat -lnt 2>/dev/null)"; then
    awk -v port="$port" '$4 ~ (":" port "$") {found=1} END {exit !found}' <<< "$sockets"
    return $?
  fi
  proc_port_in_use "$port" tcp
}

# 自检沿用实际导出的客户端参数，连接本机入站；NAT 公网地址不参与回环测试。
make_reality_probe_config() {
  local tag="$1" proxy_port node outbound address port
  proxy_port="$(normalize_port "$2")" || return 1
  node="$(jq -ec --arg t "$tag" '.inbounds[]|select(.tag==$t)' "$CONFIG")" || return 1
  outbound="$(make_node_outbound_json "$tag")" || return 1
  jq -e '.protocol=="vless" and .streamSettings.security=="reality"' <<< "$outbound" >/dev/null || return 1
  address="$(jq -r '.listen // "0.0.0.0"' <<< "$node")"
  case "$address" in
    '::') address='::1' ;;
    '0.0.0.0'|'*') address='127.0.0.1' ;;
  esac
  port="$(jq -er .port <<< "$node")" || return 1
  if [[ -n "${3:-}" ]]; then
    address='127.0.0.1'
    port="$(normalize_port "$3")" || return 1
  fi
  jq -n --argjson outbound "$outbound" --arg address "$address" --argjson port "$port" --argjson proxy_port "$proxy_port" '
    {log:{loglevel:"debug"},
     inbounds:[{tag:"reality-probe-in",listen:"127.0.0.1",port:$proxy_port,protocol:"socks",
       settings:{auth:"noauth",udp:false}}],
     outbounds:[($outbound | .tag="reality-probe-out" | .mux={enabled:false} |
       .settings.vnext[0].address=$address | .settings.vnext[0].port=$port)]}'
}

# 对照实例沿用原节点、路由和出站，只调整本机监听与诊断日志。
# 日志写入私有临时目录，避免原配置中的日志路径造成权限错误或混淆结果。
make_reality_probe_server_config() {
  local tag="$1" port
  port="$(normalize_port "$2")" || return 1
  jq -e --arg t "$tag" --argjson port "$port" '
    [.inbounds[] | select(.tag==$t and .protocol=="vless" and .streamSettings.security=="reality")] as $nodes |
    select($nodes|length==1) |
    .log={loglevel:"debug"} |
    .inbounds=[($nodes[0] | .listen="127.0.0.1" | .port=$port | .streamSettings.realitySettings.show=true)]' "$CONFIG"
}

# 只显示失败相关日志，先隐藏当前配置中的凭据，再隐藏日志里可能来自旧配置的凭据。
print_reality_probe_errors() {
  local probe_dir="$1" since="$2" kind heading lines
  if [[ -f "$probe_dir/server.json" ]]; then
    : # 临时实例的日志已经写入 server.log，不能被其他实例的日志覆盖。
  elif [[ -r "$LOG_FILE" ]] && jq -e --arg path "$LOG_FILE" '.log.error==$path' "$CONFIG" >/dev/null; then
    tail -n 40 "$LOG_FILE" > "$probe_dir/server.log" 2>/dev/null || true
  elif [[ "$INIT_SYSTEM" == systemd ]] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$SERVICE" --since "@$since" -n 40 --no-pager -o cat > "$probe_dir/server.log" 2>/dev/null || true
  elif [[ -r "$LOG_FILE" ]]; then
    tail -n 40 "$LOG_FILE" > "$probe_dir/server.log" 2>/dev/null || true
  fi
  if ! jq -n --slurpfile server "$CONFIG" --slurpfile client "$probe_dir/client.json" '
      [$server[], $client[]] |
      [.. | objects | (.id?, .password?, .privateKey?, .publicKey?, .shortId?, .shortIds[]?, .reality_public_key?)] |
      map(select(type=="string" and length>0)) | unique' > "$probe_dir/redactions.json" 2>/dev/null; then
    warn '无法安全提取诊断日志，已隐藏原始错误内容。'
    return 0
  fi
  if [[ -f "$probe_dir/server.json" && -s "$probe_dir/server.log" ]] &&
     awk '/len\(s2cSaved\):/ && /[[:space:]](Server Hello|Change Cipher Spec|Encrypted Extensions|Certificate|Certificate Verify|Finished|New Session Ticket): [0-9]+$/ && ($NF+0)>8192 {found=1} END {exit !found}' "$probe_dir/server.log"; then
    warn '检测到超过 8192 字节的 TLS 握手记录，可能触发 Xray v26.6.1 的 Reality 握手限制。请更换伪装域名后重新测试，或在高级设置中手动选择兼容的较新官方内核。'
  fi
  for kind in curl client server check; do
    [[ -s "$probe_dir/$kind.log" ]] || continue
    case "$kind" in
      curl) heading='HTTPS 请求错误' ;;
      client) heading='自检客户端错误' ;;
      server)
        if [[ -f "$probe_dir/server.json" ]]; then heading='临时服务端握手错误'
        else heading='服务端最近错误'; fi ;;
      check) heading='自检配置校验错误' ;;
    esac
    if ! lines="$(jq -Rr --slurpfile secrets "$probe_dir/redactions.json" '
        gsub("\u001b\\[[0-9;]*[A-Za-z]"; "") |
        select(test("(?i)(curl:|error|failed|failure|invalid|rejected|refused|reset by peer|timeout|timed out|unreachable|unexpected|handshake|certificate|eof|panic|fatal)")) |
        reduce $secrets[0][] as $secret (.; split($secret) | join("[已隐藏]")) |
        gsub("(?i)(vless|vmess|ss|trojan)://[^[:space:]]+"; "[分享链接已隐藏]") |
        gsub("[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}"; "[UUID已隐藏]") |
        gsub("\\[(0x[0-9a-fA-F]+|[0-9a-fA-F]{1,3})([ ,]+(0x[0-9a-fA-F]+|[0-9a-fA-F]{1,3}))+\\]"; "[字节值已隐藏]") |
        gsub("[A-Za-z0-9_+/-]{43,}={0,2}"; "[长串已隐藏]") |
        gsub("[a-fA-F0-9]{16,}"; "[十六进制值已隐藏]")
      ' "$probe_dir/$kind.log" 2>/dev/null | tail -n 6)"; then
      continue
    fi
    [[ -n "$lines" ]] || continue
    say "  $heading（连接凭据已隐藏）："
    printf '%s\n' "$lines"
  done
}

# 只等待当前临时进程的监听；进程退出时立即结束等待。
wait_reality_probe_ready() {
  local pid="$1" port="$2" tries
  for ((tries=0; tries<30; tries++)); do
    kill -0 "$pid" 2>/dev/null || return 1
    if tcp_port_is_listening "$port"; then return 0; fi
    sleep 0.1
  done
  return 1
}

# 临时启动一个仅监听本机的客户端，让 HTTPS 请求实际通过 Reality + Vision。
# 配置和日志只存放在私有临时目录，结束时停止客户端并删除临时凭据。
probe_reality_connection() (
  local tag="$1" mode="${2:-service}" proxy_port probe_dir probe_pid='' server_pid='' server_port='' tries sni tls_result curl_status started
  proxy_port="$(choose_port auto)" || { fail '无法为 Reality 自检找到空闲本机端口。'; return 1; }
  probe_dir="$(mktemp -d)" || { fail '无法创建 Reality 自检临时目录。'; return 1; }
  trap 'for pid in "${probe_pid:-}" "${server_pid:-}"; do [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; done; for pid in "${probe_pid:-}" "${server_pid:-}"; do [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true; done; rm -rf "$probe_dir"' EXIT
  trap 'exit 1' HUP INT TERM
  if [[ "$mode" == isolated ]]; then
    for ((tries=0; tries<10; tries++)); do
      server_port="$(choose_port auto)" || return 1
      [[ "$server_port" == "$proxy_port" ]] || break
    done
    [[ "$server_port" != "$proxy_port" ]] || { fail '无法为临时 Reality 服务端找到独立空闲端口。'; return 1; }
    if ! make_reality_probe_server_config "$tag" "$server_port" > "$probe_dir/server.json"; then
      fail '无法生成临时 Reality 服务端配置。'; return 1
    fi
  fi
  if ! make_reality_probe_config "$tag" "$proxy_port" "$server_port" > "$probe_dir/client.json"; then
    fail '无法生成 Reality 自检客户端配置。'; return 1
  fi
  sni="$(jq -er '.outbounds[0].streamSettings.realitySettings.serverName' "$probe_dir/client.json")" || return 1
  valid_domain "$sni" || { fail 'Reality 自检的伪装域名无效。'; return 1; }
  started="$(date +%s)"
  if ! "$CORE_LINK" run -test -format json -config "$probe_dir/client.json" > "$probe_dir/check.log" 2>&1; then
    warn '当前内核不接受导出的 Reality 客户端配置。'
    print_reality_probe_errors "$probe_dir" "$started"; return 1
  fi
  if [[ "$mode" == isolated ]]; then
    if ! "$CORE_LINK" run -test -format json -config "$probe_dir/server.json" >> "$probe_dir/check.log" 2>&1; then
      warn '当前内核不接受临时 Reality 服务端配置。'
      print_reality_probe_errors "$probe_dir" "$started"; return 1
    fi
    "$CORE_LINK" run -format json -config "$probe_dir/server.json" > "$probe_dir/server.log" 2>&1 &
    server_pid=$!
    if ! wait_reality_probe_ready "$server_pid" "$server_port"; then
      warn '临时 Reality 服务端未能建立本机监听。'
      print_reality_probe_errors "$probe_dir" "$started"; return 1
    fi
  fi
  "$CORE_LINK" run -format json -config "$probe_dir/client.json" > "$probe_dir/client.log" 2>&1 &
  probe_pid=$!
  if ! wait_reality_probe_ready "$probe_pid" "$proxy_port"; then
    warn 'Reality 自检客户端未能建立本机代理监听。'
    print_reality_probe_errors "$probe_dir" "$started"; return 1
  fi
  # Reality 启动时的目标探测约需 5 秒，临时实例的连接超时必须留出余量。
  if tls_result="$(curl --silent --show-error --noproxy '' --proxy "socks5h://127.0.0.1:$proxy_port" \
    --connect-timeout 15 --max-time 25 --tlsv1.3 --tls-max 1.3 --head --output /dev/null \
    --write-out '%{ssl_verify_result} %{time_appconnect}' "https://$sni/" 2> "$probe_dir/curl.log")"; then
    return 0
  else
    curl_status=$?
  fi
  # 有效 HTTPS 握手也能证明请求已通过隧道，后续 HTTP 空响应不影响此结论。
  if awk 'NF==2 && $1=="0" && $2 ~ /^[0-9]+[.][0-9]+$/ && ($2+0)>0 {ok=1} END {exit !ok}' <<< "$tls_result"; then
    return 0
  fi
  warn "本机 Reality 隧道请求失败（curl 状态 $curl_status）。"
  print_reality_probe_errors "$probe_dir" "$started"
  return 1
)

diagnose_reality_nodes() {
  need_core || return 1
  [[ -f "$CONFIG" ]] || { fail '尚未创建节点配置。'; return 1; }
  local tag node port public_port host sni target private output derived cached state failed=0 active=1 node_ready
  local -a tags=()
  if [[ -n "${1:-}" ]]; then
    tag="$(resolve_node_tag "$1")" || return 1
    tags=("$tag")
  else
    while IFS= read -r tag; do tags+=("$tag"); done < <(jq -r '.inbounds[]?|select(.protocol=="vless" and .streamSettings.security=="reality")|.tag' "$CONFIG" 2>/dev/null)
  fi
  ((${#tags[@]})) || { say '当前没有 VLESS + Reality 节点。'; return 0; }
  ui_title 'Reality 连接诊断（不显示 UUID、密钥或分享链接）'
  printf '  内核：'; "$CORE_LINK" -version 2>/dev/null | awk 'NR==1 {print; exit}' || true
  if ! "$CORE_LINK" run -test -format json -config "$CONFIG" >/dev/null 2>&1; then
    fail '内核配置校验失败，请先通过服务管理查看本机运行日志。'
    return 1
  fi
  info '内核配置校验通过。'
  if service_is_active; then info 'Xray 服务正在运行。'
  else warn 'Xray 服务未运行，请先在服务管理中启动服务。'; failed=1; active=0; fi
  for tag in "${tags[@]}"; do
    node_ready=$active
    ui_section "节点：$(visible_node_name "$tag")"
    node="$(jq -ec --arg t "$tag" '.inbounds[]|select(.tag==$t and .protocol=="vless" and .streamSettings.security=="reality")' "$CONFIG" 2>/dev/null)" || {
      warn '此节点不是 VLESS + Reality 节点。'; failed=1; continue;
    }
    port="$(jq -er .port <<< "$node")" || { failed=1; continue; }
    public_port="$(node_public_port "$tag")" || { failed=1; continue; }
    host="$(node_share_host "$tag")" || { failed=1; continue; }
    say "  公网入口：$host:$public_port → 本机 TCP $port"
    sni="$(jq -r '.streamSettings.realitySettings.serverNames[0] // empty' <<< "$node")"
    target="$(jq -r '.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // empty' <<< "$node")"
    private="$(jq -r '.streamSettings.realitySettings.privateKey // empty' <<< "$node")"
    cached=''
    if [[ -f "$NODE_META_FILE" ]]; then
      cached="$(jq -r --arg t "$tag" '.[$t].reality_public_key // empty' "$NODE_META_FILE" 2>/dev/null)" || cached=''
    fi
    if [[ "$private" =~ ^[a-zA-Z0-9_-]{43}$ ]] &&
       output="$("$CORE_LINK" x25519 -i "$private" 2>&1)" && derived="$(read_reality_key public <<< "$output")"; then
      if [[ -n "$cached" && "$cached" != "$derived" ]]; then
        warn '分享链接公钥记录与服务端私钥不匹配，客户端无法用这份链接完成认证。'; failed=1; node_ready=0
      else info 'Reality 密钥一致。'; fi
    else warn '无法从服务端私钥计算公钥，请检查内核版本和私钥格式。'; failed=1; node_ready=0; fi
    if tcp_port_is_listening "$port"; then info "本机 TCP $port 已监听。"
    else
      state=$?
      if [[ "$state" == 2 ]]; then warn '无法读取监听状态，请检查 /proc/net 的访问权限，或安装 iproute2 / net-tools。'
      else warn "本机 TCP $port 未监听，请检查服务日志或重启服务。"; fi
      failed=1; node_ready=0
    fi
    if probe_reality_target "$sni" "$target"; then info "伪装站点 $target 的 TLS 1.3 访问通过（SNI：$sni）。"
    else warn "伪装站点 $target 的 TLS 1.3 访问失败（SNI：$sni），请检查出站网络或更换伪装域名。"; failed=1; node_ready=0; fi
    if ((node_ready)); then
      info '正在通过本机 Reality + Vision 节点发起 HTTPS 请求……'
      if probe_reality_connection "$tag"; then
        info '本机 Reality 握手和代理请求通过。若客户端仍失败，请检查公网 TCP 入口及客户端配置。'
      else
        failed=1
        info '正在使用相同节点配置启动临时实例，检查服务端握手错误……'
        if probe_reality_connection "$tag" isolated; then
          warn '当前配置在临时实例中通过，但现有服务连接失败。请在服务管理中重启服务后重新诊断，并检查服务加载的配置和监听进程。'
        else
          warn '临时实例也未通过，请保留上面的临时服务端握手错误；仅凭 EOF 还不能区分伪装站点兼容性与内核握手问题。'
        fi
      fi
    fi
    say "  公网入站需要从客户端验证：确认 TCP $public_port 已放行；NAT 需转发到本机 $port。"
  done
  if ((failed)); then warn '诊断发现未通过的检查，请按上面的提示处理后重试。'; return 1; fi
  info '本机检查通过。请用客户端重试，并结合客户端握手报错确认公网连接。'
}

status() {
  if [[ -x "$CORE_LINK" ]]; then
    printf 'Xray 内核：'; "$CORE_LINK" -version 2>/dev/null | head -n 1 || true
  else
    say 'Xray 内核：未安装'
  fi
  if service_is_active; then say '服务状态：运行中'; else say '服务状态：未运行'; fi
  if service_is_enabled; then say '开机自启：已启用'; else say '开机自启：未启用或无法识别'; fi
  say "Xray 日志：$(logging_status)"
  say "服务管理方式：$INIT_SYSTEM"
  say "服务名称：$SERVICE_NAME"
  case "$INIT_SYSTEM" in
    systemd) say "查看详细状态可执行：systemctl status $SERVICE" ;;
    openrc) say "查看详细状态可执行：rc-service $SERVICE_NAME status" ;;
    sysvinit) say "查看详细状态可执行：$SYSV_UNIT_FILE status" ;;
    manual) say "手动管理服务：$MANUAL_UNIT_FILE status（不支持开机自启）" ;;
    runit) say "查看详细状态可执行：sv status $RUNIT_ENABLED_DIR" ;;
    procd) say "查看详细状态可执行：ubus call service list {\"name\":\"$SERVICE_NAME\"}" ;;
  esac
}

logs() {
  case "${1:-show}" in
    show)
      say "Xray 日志：$(logging_status)（默认关闭）"
      if logging_disabled; then say '需要排障时执行 xnode logs on；清空历史日志执行 xnode logs clear。'; fi
      say '以下为已记录的日志（关闭日志后不会新增）：'
      service_logs
      ;;
    on|off) set_logging "$1" ;;
    clear) clear_logs ;;
    *) fail '用法：xnode logs [on|off|clear]，不带参数查看日志。'; return 1 ;;
  esac
}

uninstall_manager() {
  local yes
  say '将卸载本脚本管理的服务、内核版本、密钥和配置备份，不影响其他 Xray 安装。'
  read -r -p '确定完全卸载时，请输入“确认卸载”：' yes
  if [[ "$yes" != "确认卸载" ]]; then
    info '已取消卸载。'
    return 1
  fi
  local owned_service_file=''
  case "$INIT_SYSTEM" in
    systemd) owned_service_file="$UNIT_FILE" ;;
    openrc) owned_service_file="$OPENRC_UNIT_FILE" ;;
    sysvinit) owned_service_file="$SYSV_UNIT_FILE" ;;
    runit) owned_service_file="$RUNIT_SERVICE_DIR/run" ;;
    procd) owned_service_file="$PROCD_UNIT_FILE" ;;
    manual) owned_service_file="$MANUAL_UNIT_FILE" ;;
  esac
  if [[ -n "$owned_service_file" ]]; then
    check_managed_service_file "$owned_service_file" || return 1
  fi
  remove_ddns_scheduler || { fail '停止 DDNS 定时任务失败，已取消卸载。'; return 1; }
  service_disable || true
  case "$INIT_SYSTEM" in
    systemd) rm -f "$UNIT_FILE"; systemctl daemon-reload ;;
    openrc) rm -f "$OPENRC_UNIT_FILE" ;;
    sysvinit) rm -f "$SYSV_UNIT_FILE" ;;
    runit) rm -rf "$RUNIT_SERVICE_DIR" ;;
    procd) rm -f "$PROCD_UNIT_FILE" ;;
    manual) rm -f "$MANUAL_UNIT_FILE" ;;
  esac
  rm -f "$ENTRY"
  # 卸载时也清理本项目留下的旧 xss 命令，保留其他程序的同名文件。
  local old_entry
  old_entry="$(dirname "$ENTRY")/xss"
  if [[ "$old_entry" != "$ENTRY" ]]; then
    if [[ -L "$old_entry" ]]; then
      [[ "$(readlink "$old_entry")" == "$ENTRY" ]] && rm -f "$old_entry"
    elif [[ -f "$old_entry" ]] && grep -Fq '# Xray SS Manager:' "$old_entry"; then
      rm -f "$old_entry"
    fi
  fi
  if [[ -L "$CORE_LINK" ]] && [[ "$(readlink "$CORE_LINK")" == "$CORE_DIR"/* ]]; then rm -f "$CORE_LINK"; fi
  rm -rf "$ETC_DIR" "$OPT_DIR"
  rm -f "$LOG_FILE" "$PID_FILE"
  info '卸载完成，其他独立安装的 Xray 服务未受影响。'
}

menu_summary() {
  local version='未安装' state='未运行' count=0
  if [[ -x "$CORE_LINK" ]]; then
    version="$("$CORE_LINK" -version 2>/dev/null | awk 'NR==1 {print $2; exit}' || true)"
    version="${version:-已安装}"
    if service_is_active; then state='运行中'; fi
  fi
  if [[ -f "$CONFIG" ]]; then count="$(jq -r '.inbounds | length' "$CONFIG" 2>/dev/null)" || count='未知'; fi
  say "  内核：$version  ·  服务：$state  ·  节点：$count"
}

node_menu() {
  local tag ans selection_status
  if tag="$(choose_node auto)"; then :
  else
    selection_status=$?
    [[ "$selection_status" == 2 ]] && return 0
    return "$selection_status"
  fi
  while :; do
    ui_title "管理节点：$(visible_node_name "$tag")"
    ui_item 1 '查看连接信息 / 复制链接'
    ui_item 2 '导出 Xray 出站 JSON（用于 3x-ui）'
    ui_item 3 '修改本机监听端口'
    ui_item 4 '修改公网地址 / DDNS / NAT 映射'
    ui_text '31' '  5）删除当前节点'
    ui_back '返回主菜单'
    read -r -p '请选择 [1-5 / 0]：' ans || return 0
    case "$ans" in
      1) show_node_connection "$tag" || true ;;
      2) show_node_outbound_json "$tag" || true ;;
      3) change_port "$tag" || true ;;
      4) change_node_endpoint "$tag" || true ;;
      5) if delete_node "$tag"; then return 0; fi ;;
      0) return 0 ;;
      '') continue ;;
      *) warn '请输入 1～5，或输入 0 返回。' ;;
    esac
  done
}

restart_xray() {
  need_core || return 1
  if service_restart && service_is_active; then info 'Xray 服务已运行。'
  else fail 'Xray 服务启动失败，请在服务管理中查看运行日志。'; fi
}

service_menu() {
  local ans
  while :; do
    ui_title '服务管理'
    menu_summary
    say ''
    ui_item 1 '查看服务运行状态'
    ui_item 2 '重启 / 启动 Xray 服务'
    ui_item 3 '查看运行日志'
    ui_item 4 '诊断 Reality 连接问题'
    say "  日志状态：$(logging_status)（默认关闭）"
    ui_item 5 '开启日志（排障用，仅记录警告和错误）'
    ui_item 6 '关闭日志（停止写入）'
    ui_item 7 '清空本工具的历史日志'
    ui_back '返回主菜单'
    read -r -p '请选择 [1-7 / 0]：' ans || return 0
    case "$ans" in
      1) status || true ;;
      2) restart_xray || true ;;
      3) logs || true ;;
      4) diagnose_reality_nodes || true ;;
      5) set_logging on || true ;;
      6) set_logging off || true ;;
      7) clear_logs || true ;;
      0) return 0 ;;
      '') continue ;;
      *) warn '请输入 1～7，或输入 0 返回。' ;;
    esac
  done
}

advanced_menu() {
  local ans tag
  while :; do
    ui_title '高级设置'
    ui_item 1 '自定义创建节点（名称 / 加密 / 账号密码 / 端口 / 域名）'
    ui_item 2 "安装或切换 Xray 内核版本（默认 $DEFAULT_XRAY_VERSION）"
    ui_item 3 'DDNS 自动更新（Cloudflare / DuckDNS）'
    ui_item 4 '检测 Linux 系统兼容性'
    say ''
    ui_text '31' '  5）完全卸载管理脚本及受管服务'
    ui_back '返回主菜单'
    read -r -p '请选择 [1-5 / 0]：' ans || return 0
    case "$ans" in
      1) add_node || true ;;
      2) tag="$(release_menu)" && switch_version "$tag" || true ;;
      3) ddns_menu ;;
      4) check_compatibility || true ;;
      # 返回专用状态，通知主菜单一并退出，避免卸载后继续操作。
      5) if uninstall_manager; then return 10; fi ;;
      0) return 0 ;;
      '') continue ;;
      *) warn '请输入 1～5，或输入 0 返回。' ;;
    esac
  done
}

menu() {
  local ans result
  while :; do
    ui_title 'Xray 节点管理系统（SS / SS2022 / Reality / SOCKS5 / HTTP）'
    menu_summary
    ui_section '常用操作'
    ui_text '1;32' '  1）快速创建节点（SS / SS2022 / VLESS + Reality / SOCKS5 / HTTP）'
    ui_item 2 '查看 / 复制分享链接'
    ui_item 3 '查看已有节点'
    ui_section '管理与维护'
    ui_item 4 '管理节点（连接信息 / 出站 JSON / 地址与端口）'
    ui_item 5 '服务管理（状态 / 重启 / 日志）'
    ui_item 6 '高级设置（自定义创建 / 内核 / DDNS / 卸载）'
    ui_back '退出管理系统'
    say '  新手：选 1 → 选协议和网络环境 → 复制链接导入客户端'
    say '  NAT 请先查看服务商/路由器分配的端口；动态 IP 请选择 DDNS。'
    say ''
    read -r -p '请选择 [1-6 / 0]：' ans || return 0
    case "$ans" in
      1) quick_add_node || true ;;
      2) show_links || true ;;
      3) list_nodes || true ;;
      4) node_menu || true ;;
      5) service_menu ;;
      6)
        if advanced_menu; then :
        else
          result=$?
          [[ "$result" != 10 ]] || return 0
        fi
        ;;
      0) return 0 ;;
      '') continue ;;
      *) warn '请输入 1～6，或输入 0 退出。' ;;
    esac
  done
}

usage() {
  cat <<'TXT'
Xray 中文节点管理系统（SS / SS2022 / VLESS + Reality / SOCKS5 / HTTP）
用法：sudo bash xray-ss.sh    # 打开交互式中文菜单
      sudo xnode               # 首次安装后打开菜单
      sudo xnode add           # 选择协议和网络环境，快速创建节点
      sudo xnode custom        # 自定义名称、加密方式、代理账号密码、端口及域名
      sudo xnode links         # 查看所有节点分享链接
      sudo xnode list          # 查看已有节点
      sudo xnode show          # 选择节点，查看分享链接或出站 JSON
      sudo xnode status        # 查看服务状态
      sudo xnode logs          # 查看运行日志
      sudo xnode logs on       # 开启警告 / 错误日志（默认关闭）
      sudo xnode logs off      # 关闭日志
      sudo xnode logs clear    # 清空本工具的历史日志
      sudo xnode diagnose      # 诊断 Reality：服务 / 端口 / 密钥 / 伪装站点
      sudo xnode ddns          # 配置 DDNS 自动更新
      sudo xnode ddns-update   # 立即更新一次 DDNS
      sudo xnode install-default   # 安装默认 Xray 内核版本 v26.6.1
      bash xray-ss.sh check # 检测系统兼容性（无须 root）
支持多种 Linux 发行版；服务管理方式：systemd / OpenRC / SysVinit / runit / procd / 手动。
支持的 CPU 架构取决于 Xray 官方发布包；不支持的架构会在安装前提示。
TXT
}

check_compatibility() {
  [[ $(uname -s) == Linux ]] || { fail '本脚本只能在 Linux 系统运行。'; return 1; }
  detect_distribution
  detect_package_manager
  detect_architecture || return 1
  detect_init_system || return 1
  say "Linux 系统：$DISTRO_NAME"
  say "发行版标识：$DISTRO_ID"
  say "软件包管理器：${PKG_MANAGER:-未识别（需自行准备依赖）}"
  say "Xray 官方安装包架构：$XRAY_ARCH"
  say "服务管理方式：$INIT_SYSTEM"
  if [[ "$INIT_SYSTEM" == manual ]]; then
    warn '手动管理模式不支持开机自启。'
  fi
  local missing=() cmd
  for cmd in bash curl jq unzip openssl sha256sum base64; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    warn "缺少依赖：${missing[*]}（正式安装时将尝试自动安装）"
  else
    info '基础依赖已齐全。'
  fi
  info '预检查完成；内核是否可执行仍需安装所选版本后验证。'
}

main() {
  case "${1:-}" in
    --help|-h|help) usage; return 0 ;;
    check) check_compatibility; return $? ;;
    ddns-update) require_root || return 1; ddns_update; return $? ;;
    diagnose)
      require_root || return 1
      detect_init_system || return 1
      diagnose_reality_nodes "${2:-}"
      return $? ;;
  esac
  require_root
  need_env
  init_config
  migrate_default_config || return 1
  case "${1:-}" in
    links) show_links ;;
    add) quick_add_node ;;
    custom) add_node ;;
    show) view_node_connections ;;
    list) list_nodes ;;
    status) status ;;
    logs) logs "${2:-show}" ;;
    ddns) ddns_menu ;;
    install-default) switch_version "$DEFAULT_XRAY_VERSION" ;;
    '') menu ;;
    *) usage; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
