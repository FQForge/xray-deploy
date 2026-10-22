# Xray 中文节点管理工具

在 Linux VPS 上创建 **SS、SS2022、VLESS + Reality** 节点，提供中文菜单，支持普通公网、NAT 端口映射和动态 IP / DDNS。

## 安装

登录 VPS 后执行：

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/FQForge/xray-deploy/main/install-xray-ss.sh)"
```

安装后自动打开菜单。以后输入 `xnode` 即可；普通用户使用 `sudo xnode`。首次创建会自动安装 Xray 内核和所需依赖。

如果提示找不到 `curl`，请先安装它；Debian / Ubuntu 可执行 `apt-get update && apt-get install -y curl`。没有 root / sudo 权限时，请切换到 root 用户。

## 第一次创建节点

1. 主菜单选择 **1 · 快速创建节点**。
2. 选择 **SS、SS2022 或 VLESS + Reality**，客户端需支持相应协议。
3. 普通 VPS 的网络环境直接回车，使用 **1 · 独立公网 / 固定 IP**。
4. 创建成功后，复制完整的 `ss://` 或 `vless://` 链接，在客户端选择“从剪贴板导入”并启用代理。

名称、端口、密码和密钥会自动生成。Reality 使用 **TCP + Vision**，从 **10 个已实测通过的非 Cloudflare 域名**中随机选择，并在创建前检查真实连接；无需自己购买域名或申请证书。

**记得放行节点端口：** 在 VPS 防火墙和服务商安全组中，Reality 放行 **TCP**；SS / SS2022 放行 **TCP + UDP**。具体端口会在创建结果中显示。

## NAT 或动态 IP 怎么选

| 你的网络 | 创建时选择 | 需要准备 |
| --- | --- | --- |
| 普通公网 VPS | 1 · 独立公网 / 固定 IP | 通常直接回车即可 |
| NAT 服务器 / 路由器端口映射 | 2 · NAT / 端口映射 | 已分配的公网地址、公网端口和本机端口 |
| IP 会变化 | 3 · 动态公网 IP + DDNS | 指向该服务器的 DDNS 域名 |
| 同时是 NAT 和动态 IP | 4 · NAT + 动态 IP + DDNS | 端口映射信息和 DDNS 域名 |

**NAT 示例：** 服务商给你 `nat.example.com:31415 → 本机 27001`，就填写公网地址 `nat.example.com`、公网端口 `31415`、本机端口 `27001`。脚本不会替你创建上游映射；没有分配入站端口的 NAT 不能直接连接。

**DDNS：** 可以使用已有 DDNS，也可在向导中配置 Cloudflare 或 DuckDNS 自动更新。Cloudflare Token 需有区域读取和 DNS 编辑权限，连接域名使用“仅 DNS”。非 systemd 系统需安装并启动 cron，才能每 5 分钟自动更新。

Reality 的伪装域名和自己的连接 / DDNS 域名是两个地址，按向导分别设置即可。

## 常用操作

| 操作 | 菜单位置 |
| --- | --- |
| 复制已有节点链接 | 主菜单 **2** |
| 修改地址、端口，导出 3x-ui 出站 JSON，删除节点 | 主菜单 **4** |
| 查看服务状态、重启、日志、Reality 诊断 | 主菜单 **5** |
| 自定义名称、加密方式或 Reality 域名 | **6 → 1** |
| 切换内核 / 配置 DDNS / 检测系统 / 完全卸载 | **6 → 2 / 3 / 4 / 5** |

菜单输入 **0** 返回或退出。修改连接信息后，请重新复制链接导入客户端。导出的 3x-ui JSON 是单个出站对象，应加入 `outbounds` 数组。

## 连接失败、更新和备份

先确认客户端协议正确、公网端口已放行；NAT 还要确认映射有效。Reality 可运行：

```bash
sudo xnode diagnose
```

**更新工具：** 重新执行上面的安装命令，保留现有节点。旧版 Reality 无法使用时，更新后执行：

```bash
sudo xnode install-default
sudo xnode diagnose
```

默认内核为 **v26.10.10**；新建 Reality 会自动升级低于该版本的旧内核。

**备份：** 保存 `/etc/xray-ss`。**卸载：** 选择 **6 → 5**，按提示输入 `确认卸载`。

## 系统支持

推荐使用 **Ubuntu 22.04 / 24.04 或 Debian 12 / 13**。脚本也适配 Alpine、Rocky / AlmaLinux / Fedora、openSUSE、Arch、Void、Gentoo 和 OpenWrt 的常见包管理与服务方式，但不能保证所有历史版本、定制固件和 CPU 都可用。

本次验证包括 Ubuntu 22.04 VPS 实际部署，以及 Ubuntu 20.04 / 24.04、Debian 12 / 13、Alpine 3.22、Rocky 9 的 amd64 隔离环境；后六项的三种协议 HTTPS 测试全部通过。隔离环境共用本机内核，其他内核和 CPU 架构未逐一实测。

支持 systemd、OpenRC、SysVinit、runit 和 procd；未识别到服务管理器时使用手动模式，**手动模式不支持开机自启**。CPU 必须有对应的 Xray 官方 Linux 安装包，系统软件源应可用，Reality 需要 curl 支持 TLS 1.3。

安装后运行 `xnode check` 查看当前系统的检查结果；检查通过不等于所有旧内核和网络环境都已实测。
