#!/usr/bin/env bash
# Xray SS Manager: standalone Shadowsocks / Shadowsocks 2022 VPS manager.
# Supports major Linux distributions and common init systems; see README for scope.
# This is an independent implementation, not a fork of singbox-deploy.
set -Eeuo pipefail
umask 077

APP=xray-ss
SERVICE_NAME=xray-ss
SERVICE=xray-ss.service
ETC_DIR="${XSS_ETC_DIR:-/etc/xray-ss}"
OPT_DIR="${XSS_OPT_DIR:-/opt/xray-ss}"
CORE_DIR="$OPT_DIR/versions"
CORE_LINK="${XSS_CORE_LINK:-/usr/local/bin/xray-ss-core}"
ENTRY="${XSS_ENTRY:-/usr/local/bin/xss}"
CONFIG="$ETC_DIR/config.json"
HOST_FILE="$ETC_DIR/host.txt"
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
DISTRO_ID=unknown
DISTRO_NAME=unknown
DISTRO_ID_LIKE=''
PKG_MANAGER=''
INIT_SYSTEM=''
XRAY_ARCH=''

say() { printf '%s\n' "$*"; }
info() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
fail() { warn "$*"; return 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail '请使用 root 用户或 sudo 运行此脚本。'; }
need_core() { [[ -x "$CORE_LINK" ]] || fail '尚未安装 Xray 内核，请先在菜单中选择 1 安装。'; }

detect_distribution() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-${NAME:-$DISTRO_ID}}"
    DISTRO_ID_LIKE="${ID_LIKE:-}"
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
  pid1="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
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
    dnf)
      dnf install -y bash curl jq unzip openssl ca-certificates coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    microdnf)
      microdnf install -y bash curl jq unzip openssl ca-certificates coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
      ;;
    yum)
      yum install -y bash curl jq unzip openssl ca-certificates coreutils || { fail '依赖安装失败。请检查可用的软件源和网络后重试。'; return 1; }
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

init_config() {
  mkdir -p "$ETC_DIR" "$BACKUP_DIR" "$CORE_DIR"
  chmod 700 "$ETC_DIR" "$BACKUP_DIR"
  chmod 755 "$CORE_DIR"
  mkdir -p "$(dirname "$ENTRY")" "$(dirname "$CORE_LINK")"
  if [[ ! -f "$CONFIG" ]]; then
    printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}]}' > "$CONFIG"
    chmod 600 "$CONFIG"
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
Description=Xray SS / SS2022 standalone service
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
      systemctl daemon-reload
      ;;
    openrc)
      mkdir -p "$(dirname "$OPENRC_UNIT_FILE")" "$(dirname "$LOG_FILE")"
      check_managed_service_file "$OPENRC_UNIT_FILE" || return 1
      if [[ ! -e "$OPENRC_UNIT_FILE" ]]; then
        cat > "$OPENRC_UNIT_FILE" <<EOF
#!/sbin/openrc-run
# XSS-MANAGED: xray-ss
name="Xray SS / SS2022"
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
# Short-Description: Xray SS / SS2022 service
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
  valid_version "$pick" || fail '版本号格式无效。'
  printf '%s\n' "$pick"
}

# Download and verify the release asset and install it without replacing live binaries.
download_version() (
  set -euo pipefail
  local tag="$1" dest="$CORE_DIR/$1" tmp archive url expected actual
  [[ -x "$dest/xray" ]] && exit 0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  archive="Xray-linux-${XRAY_ARCH}.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/$tag/$archive"
  info "正在下载 Xray $tag，处理器架构：$XRAY_ARCH……" >&2
  curl -fL --retry 3 --connect-timeout 15 --max-time 240 -o "$tmp/$archive" "$url"
  curl -fL --retry 3 --connect-timeout 15 --max-time 60 -o "$tmp/$archive.dgst" "$url.dgst"
  expected="$(awk -F '=' '/^[[:space:]]*SHA(2-)?256[[:space:]]*=/{v=$2;gsub(/[[:space:]]/,"",v);print tolower(v);exit}' "$tmp/$archive.dgst")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { warn '未找到有效的 SHA256 校验值。'; exit 1; }
  actual="$(sha256sum "$tmp/$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { warn 'SHA256 校验失败，下载文件与官方校验值不一致。'; exit 1; }
  mkdir -p "$dest"
  if ! unzip -joq "$tmp/$archive" xray -d "$dest"; then
    rm -rf "$dest"
    exit 1
  fi
  chmod 755 "$dest/xray"
  if ! "$dest/xray" -version >/dev/null 2>&1; then
    if [[ "$XRAY_ARCH" == mips32* ]]; then
      # Prefer the in-archive soft-float binary where available (older releases).
      if unzip -joq "$tmp/$archive" xray_softfloat -d "$dest" >/dev/null 2>&1 &&
         chmod 755 "$dest/xray_softfloat" &&
         "$dest/xray_softfloat" -version >/dev/null 2>&1; then
        mv -f "$dest/xray_softfloat" "$dest/xray"
      else
        # Newer releases may publish a dedicated mips32-softfloat archive.
        local soft_archive="Xray-linux-${XRAY_ARCH}-softfloat.zip"
        local soft_url="https://github.com/XTLS/Xray-core/releases/download/$tag/$soft_archive"
        if curl -fL --retry 2 --connect-timeout 15 --max-time 240 -o "$tmp/$soft_archive" "$soft_url" &&
           curl -fL --retry 2 --connect-timeout 15 --max-time 60 -o "$tmp/$soft_archive.dgst" "$soft_url.dgst"; then
          expected="$(awk -F '=' '/^[[:space:]]*SHA(2-)?256[[:space:]]*=/{v=$2;gsub(/[[:space:]]/,"",v);print tolower(v);exit}' "$tmp/$soft_archive.dgst")"
          actual="$(sha256sum "$tmp/$soft_archive" | awk '{print $1}')"
          if [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]]; then
            unzip -joqo "$tmp/$soft_archive" xray -d "$dest" || true
            chmod 755 "$dest/xray"
          fi
        fi
      fi
      if "$dest/xray" -version >/dev/null 2>&1; then
        info '当前 MIPS 设备已自动使用软浮点内核。' >&2
      fi
    fi
    if ! "$dest/xray" -version >/dev/null 2>&1; then
      rm -rf "$dest"
      warn '下载的内核无法执行。请检查 CPU 架构、系统内核和官方发布包兼容性。'
      exit 1
    fi
  fi
  info "校验通过，Xray $tag 安装完成。" >&2
)

switch_version() {
  local tag="$1" target="$CORE_DIR/$1/xray" old='' link_tmp
  valid_version "$tag" || fail '版本号格式无效。'
  need_env
  init_config
  install_service_unit || return 1
  download_version "$tag" || return 1
  "$target" run -test -format json -config "$CONFIG" || fail "当前节点配置与 Xray $tag 不兼容，已取消切换。"
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
  return 1
}

choose_port() {
  local proposed='' tries=0
  read -r -p '请输入节点端口（直接回车随机生成 10000～60000）：' proposed
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
  [[ "$proposed" =~ ^[0-9]+$ ]] && ((proposed>=1 && proposed<=65535)) || { fail '端口号无效，请输入 1～65535 之间的数字。'; return 1; }
  port_in_use "$proposed" && { fail "端口 $proposed 已被占用。"; return 1; }
  printf '%s\n' "$proposed"
}

choose_method() {
  local -a methods=(
    aes-128-gcm aes-256-gcm chacha20-poly1305 xchacha20-poly1305
    2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305
  )
  local n sel
  for ((n=0;n<${#methods[@]};n++)); do printf '%d） %s\n' "$((n+1))" "${methods[n]}" >&2; done
  read -r -p '请选择加密方式（1～7）：' sel
  [[ "$sel" =~ ^[1-7]$ ]] || { fail '请输入 1～7 的序号。'; return 1; }
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
    xss-*) choices=("$input" "ss-${input#xss-}") ;;
    *) choices=("$input" "ss-$input" "xss-$input") ;;
  esac
  for tag in "${choices[@]}"; do
    if [[ -f "$CONFIG" ]] && jq -e --arg t "$tag" '.inbounds[]? | select(.tag==$t)' "$CONFIG" >/dev/null; then
      printf '%s\n' "$tag"
      return 0
    fi
  done
  fail '未找到指定节点。'
}

# 首次从添加节点入口进入时，询问是否安装默认内核；菜单 1 仍可自由选版本。
ensure_core_for_new_node() {
  [[ -x "$CORE_LINK" ]] && return 0
  local answer
  read -r -p "Xray 尚未安装。是否安装默认版本 $DEFAULT_XRAY_VERSION？[Y/n]：" answer || return 1
  case "$answer" in
    ''|y|Y|yes|YES|是) switch_version "$DEFAULT_XRAY_VERSION" ;;
    *) fail '已取消默认安装。可选择菜单 1 手动安装其他版本。' ;;
  esac
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

add_node() {
  ensure_core_for_new_node || return 1
  init_config
  local name tag method port network pass node tmp
  read -r -p '请输入节点名称（支持中文、英文及常见符号，最多 48 个字符）：' name
  safe_name "$name" || { fail '节点名称无效：需为 1～48 个字符，不能包含控制字符、斜杠或首尾空格。'; return 1; }
  tag="ss-$name"
  if jq -e --arg tag "$tag" --arg legacy "xss-$name" '.inbounds[]? | select(.tag==$tag or .tag==$legacy)' "$CONFIG" >/dev/null; then
    fail '该节点名称已存在（含旧版节点），请使用不同的名称。'; return 1
  fi
  method="$(choose_method)" || return 1
  port="$(choose_port)" || return 1
  network="tcp,udp"

  # 每次仅创建一个带独立密码的节点；不再询问单用户/多用户模式。
  pass="$(new_password "$method")" || return 1
  node="$(jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" \
    --arg pass "$pass" --arg network "$network" \
    '{tag:$tag,listen:"0.0.0.0",port:$port,protocol:"shadowsocks",settings:{method:$method,password:$pass,network:$network}}')" || return 1
  tmp="$(mktemp "$ETC_DIR/.config.XXXXXX")" || return 1
  jq --argjson node "$node" '.inbounds += [$node]' "$CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
  apply_config "$tmp" || return 1
  info "已创建节点：$tag，端口 $port，加密方式 $method。"
  warn "请在 VPS 服务商安全组和服务器防火墙中放行端口 $port（$network）。"

  # 服务成功启动后立即显示该节点连接信息，而不是所有节点。
  if ! show_node_connection "$tag"; then
    warn '节点已创建且服务已启动，但显示连接信息失败。可在菜单 4 中重新查看。'
  fi
}

list_nodes() {
  [[ -f "$CONFIG" ]] || { say '尚未创建配置文件。'; return 0; }
  local rows
  rows="$(jq -r '.inbounds[]? | [(.tag | if startswith("xss-") then "ss-" + .[4:] else . end), (.port|tostring), (.settings.method // (.settings.users[0].method // "未知")), (.settings.network // "tcp")] | @tsv' "$CONFIG")" || return 1
  [[ -n "$rows" ]] || { say '当前没有任何节点。'; return 0; }
  {
    printf '节点名称\t端口\t加密方式\t传输方式\n'
    printf '%s\n' "$rows"
  } | { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }
}

choose_node() {
  list_nodes >&2
  local name
  read -r -p '请输入节点名称（例如 北京节点 或 ss-北京节点）：' name || return 1
  resolve_node_tag "$name"
}

change_port() {
  need_core
  local tag port tmp
  tag="$(choose_node)" || return 1
  port="$(choose_port)" || return 1
  tmp="$(mktemp "$ETC_DIR/.config.XXXXXX")"
  jq --arg t "$tag" --argjson p "$port" '(.inbounds[] | select(.tag==$t) | .port)=$p' "$CONFIG" > "$tmp"
  apply_config "$tmp" && warn "请在服务器防火墙和服务商安全组中放行新端口 $port（按需要放行 TCP/UDP）。"
}

delete_node() {
  need_core
  local tag tmp yes
  tag="$(choose_node)" || return 1
  read -r -p "将删除节点 $tag，请输入“确认删除”以继续：" yes
  [[ "$yes" == "确认删除" ]] || return 0
  tmp="$(mktemp "$ETC_DIR/.config.XXXXXX")"
  jq --arg t "$tag" '.inbounds |= map(select(.tag!=$t))' "$CONFIG" > "$tmp"
  apply_config "$tmp"
}

set_host() {
  init_config
  local host
  read -r -p '请输入分享链接所用的公网 IPv4、IPv6 或 DDNS 域名：' host
  host="${host#[}"
  host="${host%]}"
  if [[ ! "$host" =~ ^[a-zA-Z0-9.:-]{1,253}$ ]]; then
    fail '地址无效：请填写 IP 地址或英文 DDNS 域名，不要包含协议头和端口。'; return 1
  fi
  printf '%s\n' "$host" > "$HOST_FILE"
  chmod 600 "$HOST_FILE"
  info "已保存分享链接地址：$host"
}

ensure_host() {
  if [[ ! -s "$HOST_FILE" ]]; then
    local detected=''
    detected="$(curl -4fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    if [[ "$detected" =~ ^[0-9.]+$ ]]; then
      printf '%s\n' "$detected" > "$HOST_FILE"
      chmod 600 "$HOST_FILE"
      info "自动检测到公网 IPv4：$detected" >&2
    else
      set_host >&2
    fi
  fi
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
  local tag="$1" fields name display port method password network host uri network_zh
  [[ -s "$CONFIG" ]] || { fail '尚未创建节点配置。'; return 1; }
  # 旧版创建的多用户节点不会被转换或删除，历史链接仍可通过 links 命令获取。
  fields="$(jq -er --arg tag "$tag" '.inbounds[]? | select(.tag==$tag and .settings.users==null) | [.tag, (.port|tostring), .settings.method, .settings.password, (.settings.network // "tcp")] | @tsv' "$CONFIG")" || {
    fail '未找到可独立显示连接信息的节点；如为旧版多用户节点，请使用 xss links 查看原有链接。'
    return 1
  }
  IFS=$'\t' read -r name port method password network <<< "$fields"
  display="$(visible_node_name "$name")"
  case "$network" in
    tcp) network_zh='仅 TCP' ;;
    udp) network_zh='仅 UDP' ;;
    *) network_zh='TCP + UDP' ;;
  esac
  say ''
  say '========== 节点连接信息 =========='
  say "节点名称：$display"
  say "节点端口：$port"
  say "加密方式：$method"
  say "传输方式：$network_zh"
  say "连接密码：$password"
  if ! ensure_host; then
    warn '节点已成功创建，但公网地址尚未设置。请选择菜单 7 设置公网 IP / DDNS 后，再使用菜单 4 查看分享链接。'
    return 0
  fi
  host="$(cat "$HOST_FILE")"
  uri="$(make_ss_uri "$method" "$password" "$host" "$port" "$display")" || return 1
  say "服务器地址：$host"
  say ''
  say 'SS / SS2022 分享链接（复制到客户端即可导入）：'
  printf '%s\n' "$uri"
  say '=================================='
  warn '分享链接包含节点密码，请妥善保管。'
}

show_links() {
  [[ -f "$CONFIG" ]] || { fail '尚未创建节点配置。'; return 1; }
  ensure_host || return 1
  local host tag display port method password nickname line
  host="$(cat "$HOST_FILE")"
  while IFS=$'\t' read -r tag port method password nickname; do
    [[ -n "$tag" ]] || continue
    display="$(visible_node_name "$tag")"
    if [[ "$nickname" == '节点' ]]; then
      printf '\n%s\n' "$display"
      make_ss_uri "$method" "$password" "$host" "$port" "$display"
    else
      printf '\n%s / %s\n' "$display" "$nickname"
      make_ss_uri "$method" "$password" "$host" "$port" "$display-$nickname"
    fi
  done < <(jq -r '.inbounds[]? | . as $n | if (.settings.users | type)=="array" then .settings.users[] | [$n.tag, ($n.port|tostring), ($n.settings.method // .method), (if (($n.settings.method // "") | startswith("2022-")) then ($n.settings.password + ":" + .password) else .password end), (.email // "user")] | @tsv else [$n.tag, ($n.port|tostring), .settings.method, .settings.password, "节点"] | @tsv end' "$CONFIG")
  warn '以上链接包含节点密钥，请妥善保管，不要公开传播。'
}

view_node_connections() {
  list_nodes || return 1
  [[ -f "$CONFIG" ]] && jq -e '.inbounds | length>0' "$CONFIG" >/dev/null || return 0
  local node_name tag
  read -r -p '请输入要显示连接信息的节点名称（直接回车返回）：' node_name || return 0
  [[ -n "$node_name" ]] || return 0
  tag="$(resolve_node_tag "$node_name")" || return 1
  show_node_connection "$tag"
}

status() {
  if [[ -x "$CORE_LINK" ]]; then
    printf 'Xray 内核：'; "$CORE_LINK" -version 2>/dev/null | head -n 1 || true
  else
    say 'Xray 内核：未安装'
  fi
  if service_is_active; then say '服务状态：运行中'; else say '服务状态：未运行'; fi
  if service_is_enabled; then say '开机自启：已启用'; else say '开机自启：未启用或无法识别'; fi
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
  say '以下为 Xray 服务日志（内核原始内容可能为英文）：'
  service_logs
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
  if [[ -L "$CORE_LINK" ]] && [[ "$(readlink "$CORE_LINK")" == "$CORE_DIR"/* ]]; then rm -f "$CORE_LINK"; fi
  rm -rf "$ETC_DIR" "$OPT_DIR"
  rm -f "$LOG_FILE" "$PID_FILE"
  info '卸载完成，其他独立安装的 Xray 服务未受影响。'
}

menu() {
  while :; do
    printf '\n========== Xray SS / SS2022 节点管理系统 ==========\n'
    say " 1）安装或切换 Xray 内核版本（默认 $DEFAULT_XRAY_VERSION）"
    say ' 2）添加 SS / SS2022 节点（完成后显示连接信息）'
    say ' 3）查看已有节点'
    say ' 4）查看节点连接信息'
    say ' 5）修改节点端口'
    say ' 6）删除节点'
    say ' 7）设置分享链接所用公网 IP / DDNS'
    say ' 8）查看服务运行状态'
    say ' 9）查看运行日志'
    say '10）重启 Xray 服务'
    say '11）完全卸载管理脚本及受管服务'
    say '12）检测 Linux 系统兼容性'
    say ' 0）退出管理系统'
    local ans tag
    read -r -p '请输入菜单序号：' ans || return 0
    case "$ans" in
      1) tag="$(release_menu)" && switch_version "$tag" || true ;;
      2) add_node || true ;;
      3) list_nodes || true ;;
      4) view_node_connections || true ;;
      5) change_port || true ;;
      6) delete_node || true ;;
      7) set_host || true ;;
      8) status || true ;;
      9) logs || true ;;
      10) if service_restart && service_is_active; then info 'Xray 服务已重启。'; else warn 'Xray 服务重启失败，请查看运行日志。'; fi ;;
      11) if uninstall_manager; then return 0; fi ;;
      12) check_compatibility || true ;;
      0) return 0 ;;
      *) warn '菜单选项无效，请重新选择。' ;;
    esac
  done
}

usage() {
  cat <<'TXT'
Xray SS / SS2022 中文节点管理系统（v0.7）
用法：sudo bash xray-ss.sh    # 打开交互式中文菜单
      sudo xss               # 首次安装后打开菜单
      sudo xss links         # 查看所有节点分享链接
      sudo xss list          # 查看已有节点
      sudo xss show          # 选择节点显示连接信息
      sudo xss status        # 查看服务状态
      sudo xss logs          # 查看运行日志
      sudo xss install-default   # 安装默认 Xray 内核版本 v26.6.1
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
  esac
  require_root
  need_env
  if [[ -z "${1:-}" ]]; then
    info "检测到系统：$DISTRO_NAME；服务管理方式：$INIT_SYSTEM；软件包管理器：${PKG_MANAGER:-未识别}"
  fi
  init_config
  case "${1:-}" in
    links) show_links ;;
    show) view_node_connections ;;
    list) list_nodes ;;
    status) status ;;
    logs) logs ;;
    install-default) switch_version "$DEFAULT_XRAY_VERSION" ;;
    '') menu ;;
    *) usage; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
