#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' "请使用 root 用户或 sudo 运行此安装脚本。" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
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

# 对外只提供 xnode 管理命令；内部 XSS_ENTRY 仍用于测试自定义安装位置。
TARGET="${XSS_ENTRY:-/usr/local/bin/xnode}"
OLD_ENTRY="$(dirname "$TARGET")/xss"

authentic_manager() {
  [ -f "$1" ] && grep -Fq '# Xray SS Manager:' "$1"
}

# 任何覆盖操作之前，先检查新脚本可用、安装路径未被其他程序占据。
if ! bash -n "$SCRIPT"; then
  printf '%s\n' '新版本脚本语法检查未通过，没有覆盖现有命令。' >&2
  exit 1
fi
if [ -L "$TARGET" ]; then
  printf '%s\n' "发现 $TARGET 是符号链接，为防止误覆盖已停止安装。" >&2
  exit 1
fi
if [ -e "$TARGET" ] && ! authentic_manager "$TARGET"; then
  printf '%s\n' "发现同名但并非本脚本创建的管理命令：$TARGET。已停止安装。" >&2
  exit 1
fi

if [ ! -e "$TARGET" ] || ! command -v cmp >/dev/null 2>&1 || ! cmp -s "$TARGET" "$SCRIPT"; then
  target_dir=$(dirname "$TARGET")
  mkdir -p "$target_dir"
  temp_target=$(mktemp "$target_dir/.xnode-update.XXXXXX") || exit 1
  trap 'rm -f "$temp_target"' EXIT HUP INT TERM
  cat "$SCRIPT" > "$temp_target"
  chmod 700 "$temp_target"
  mv -f "$temp_target" "$TARGET"
  trap - EXIT HUP INT TERM
  printf '%s\n' "[+] Xray 管理命令已安装：$TARGET。"
else
  printf '%s\n' "[+] Xray 管理命令已经是最新版：$TARGET。"
fi

# 不再保留旧版 xss 命令。仅删除本项目创建的旧脚本/旧符号链接，
# 不碰属于其他程序的同名文件。
if [ "$OLD_ENTRY" != "$TARGET" ]; then
  if [ -L "$OLD_ENTRY" ]; then
    if [ "$(readlink "$OLD_ENTRY")" = "$TARGET" ]; then
      rm -f "$OLD_ENTRY"
      printf '%s\n' '[+] 已清理旧版 xss 命令。'
    fi
  elif [ -f "$OLD_ENTRY" ] && authentic_manager "$OLD_ENTRY"; then
    rm -f "$OLD_ENTRY"
    printf '%s\n' '[+] 已清理旧版 xss 命令。'
  fi
fi

printf '%s\n' '今后输入 xnode 即可打开中文管理菜单。'
exec bash "$SCRIPT" "$@"
