#!/bin/sh
# GitHub 一键安装入口：与 `sh -c "$(curl -fsSL URL)"` 兼容。
# 默认使用 fengqi0216/xray-deploy，支持环境变量临时覆盖仓库。
# 可通过环境变量 XSS_GITHUB_OWNER / XSS_GITHUB_REPO / XSS_GITHUB_REF 临时覆盖。
set -eu

GITHUB_OWNER="${XSS_GITHUB_OWNER:-fengqi0216}"
GITHUB_REPO="${XSS_GITHUB_REPO:-xray-deploy}"
GITHUB_REF="${XSS_GITHUB_REF:-main}"

say() { printf '%s\n' "$*"; }
error() { printf '[错误] %s\n' "$*" >&2; exit 1; }

case "$GITHUB_OWNER" in
  '') error '未填写 GitHub 用户名。' ;;
  *[!a-zA-Z0-9-]*) error 'GitHub 用户名包含非法字符。' ;;
esac
case "$GITHUB_REPO" in
  ''|*[!a-zA-Z0-9_.-]*) error 'GitHub 仓库名包含非法字符。' ;;
esac
case "$GITHUB_REF" in
  ''|*[!a-zA-Z0-9._/-]*) error 'GitHub 分支名包含非法字符。' ;;
esac

if [ "$(uname -s)" != Linux ]; then
  error '当前不是 Linux，无法使用本安装脚本。'
fi

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  error '未找到 curl 或 wget，请先安装其中一个下载工具。'
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/xray-ss-install.XXXXXX")" || error '无法创建临时目录。'
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

base="https://raw.githubusercontent.com/$GITHUB_OWNER/$GITHUB_REPO/$GITHUB_REF"
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fLsS --retry 2 --connect-timeout 10 --max-time 90 -o "$2" "$1"
  else
    wget -q -T 90 -O "$2" "$1"
  fi
}

say "[+] 正在从 GitHub 下载：$GITHUB_OWNER/$GITHUB_REPO（$GITHUB_REF）"
fetch "$base/install.sh" "$tmp/install.sh" || error '下载 install.sh 失败，请检查仓库是否公开、分支名称和网络连接。'
fetch "$base/xray-ss.sh" "$tmp/xray-ss.sh" || error '下载 xray-ss.sh 失败，请检查仓库中是否存在该文件。'

[ -s "$tmp/install.sh" ] || error '下载到的 install.sh 文件为空。'
[ -s "$tmp/xray-ss.sh" ] || error '下载到的 xray-ss.sh 文件为空。'
# 防止 GitHub 返回 HTML、错误页等内容后直接以 root 执行。
grep -Fq 'SCRIPT_DIR=' "$tmp/install.sh" || error 'install.sh 内容不符合预期，已停止执行。'
grep -Fq '# Xray SS Manager:' "$tmp/xray-ss.sh" || error 'xray-ss.sh 内容不符合预期，已停止执行。'
chmod 700 "$tmp/install.sh" "$tmp/xray-ss.sh"

say '[+] 下载成功，正在启动 Xray 中文管理系统（SS / SS2022 / VLESS + Reality）。'
if [ "$(id -u)" -eq 0 ]; then
  sh "$tmp/install.sh" "$@"
elif command -v sudo >/dev/null 2>&1; then
  sudo sh "$tmp/install.sh" "$@"
else
  error '当前不是 root，也未安装 sudo。请先运行 su - 切换 root，再执行一键安装命令。'
fi
