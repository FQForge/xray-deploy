#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' "请使用 root 用户或 sudo 运行此安装脚本。" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
SCRIPT="$SCRIPT_DIR/xray-ss.sh"
if [ ! -f "$SCRIPT" ]; then
  printf '%s\n' "未找到 xray-ss.sh，请将 install.sh 和 xray-ss.sh 放在同一目录。" >&2
  exit 1
fi

if ! command -v bash >/dev/null 2>&1; then
  OS_ID=
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID=${ID:-}
  fi
  if command -v opkg >/dev/null 2>&1; then
    opkg update && opkg install bash
  elif [ "$OS_ID" = openwrt ] && command -v apk >/dev/null 2>&1; then
    apk update && apk add bash
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y bash
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf install -y bash
  elif command -v yum >/dev/null 2>&1; then
    yum install -y bash
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install bash
  elif command -v pacman >/dev/null 2>&1; then
    pacman -S --noconfirm --needed bash
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash
  elif command -v xbps-install >/dev/null 2>&1; then
    xbps-install -Sy bash
  elif command -v emerge >/dev/null 2>&1; then
    emerge --ask=n --noreplace app-shells/bash
  else
    printf '%s\n' "系统中没有 Bash 。且未识别到可用的软件包管理器。请先手动安装 Bash。" >&2
    exit 1
  fi
fi

if ! command -v bash >/dev/null 2>&1; then
  printf '%s\n' "仍未找到 Bash。请确认已正确安装。" >&2
  exit 1
fi

# 本地安装和 GitHub 一键安装均更新已有的受管命令；保留配置与 Xray 内核。
# 只允许覆盖本项目此前安装的脚本，避免误删用户自有的 xss 命令。
TARGET="${XSS_ENTRY:-/usr/local/bin/xss}"
if [ -L "$TARGET" ]; then
  printf '%s\n' "发现 $TARGET 是符号链接，为防止误覆盖已停止升级。" >&2
  exit 1
fi
if [ -e "$TARGET" ]; then
  if [ ! -f "$TARGET" ] || ! grep -Fq '# Xray SS Manager:' "$TARGET"; then
    printf '%s\n' "发现同名但并非本脚本创建的管理命令：$TARGET。已停止安装。" >&2
    exit 1
  fi
  if ! bash -n "$SCRIPT"; then
    printf '%s\n' '新版本脚本语法检查未通过，未覆盖现有命令。' >&2
    exit 1
  fi
  if ! command -v cmp >/dev/null 2>&1 || ! cmp -s "$TARGET" "$SCRIPT"; then
    target_dir=$(dirname "$TARGET")
    temp_target=$(mktemp "$target_dir/.xss-update.XXXXXX") || exit 1
    trap 'rm -f "$temp_target"' EXIT HUP INT TERM
    cat "$SCRIPT" > "$temp_target"
    chmod 700 "$temp_target"
    mv -f "$temp_target" "$TARGET"
    trap - EXIT HUP INT TERM
    printf '%s\n' "[+] 管理脚本已升级：$TARGET（原有节点和内核保持不变）。"
  fi
fi
exec bash "$SCRIPT" "$@"
