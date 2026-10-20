# Xray SS / SS2022 中文节点管理工具（v0.7）

这是一个独立 Bash 脚本，交互体验参考 [singbox-deploy](https://github.com/caigouzi121380/singbox-deploy)，底层使用 **Xray-core**，无需 sing-box、3x-ui 或 Web 面板。


**v0.7 新增：GitHub 一键安装入口 `install-xray-ss.sh`。** 上传项目到自己公开的 GitHub 仓库后，只要一条 `curl` 命令即可拉取 `install.sh` 与 `xray-ss.sh`，安装并打开全中文菜单。旧版已经安装的 `/usr/local/bin/xss` 会在验证属于本项目后自动升级，现有节点与 Xray 内核保留。**原有 v0.6 节点功能和默认 Xray v26.6.1 不变。**

## GitHub 一键发布与安装（新增）

本项目仓库根目录有三个主要脚本：

```text
xray-ss-deploy/
├── install-xray-ss.sh   # 可被 curl 远程执行的入口（只需修改一次用户名）
├── install.sh           # 离线安装入口、依赖和旧管理脚本升级
├── xray-ss.sh           # 中文 Xray SS / SS2022 管理脚本
├── README.md
└── tests/
```

### 1. 修改一次 GitHub 用户名

用文本编辑器打开 **`install-xray-ss.sh`**，找到并修改这行：

```sh
GITHUB_OWNER="${XSS_GITHUB_OWNER:-YOUR_GITHUB_USERNAME}"
```

将 `YOUR_GITHUB_USERNAME` 换成你的 GitHub 用户名。默认仓库名是 `xray-ss-deploy`、默认分支是 `main`；如有不同也在同一个文件修改 `GITHUB_REPO`、`GITHUB_REF`。

### 2. 在 GitHub 创建一个空的 Public 仓库

建议仓库命名为 `xray-ss-deploy`，创建时不勾选自动生成 README，然后在**开发电脑的本项目目录**执行（请替换 `你的GitHub用户名`）：

```bash
git init -b main
git add .
git commit -m "发布 Xray SS Deploy v0.7"
git remote add origin https://github.com/你的GitHub用户名/xray-ss-deploy.git
git push -u origin main
```

如果已有 Git 仓库，不必重新 `git init`，按现有分支和远端上传即可。GitHub HTTPS 推送通常需要凭据或个人访问令牌（PAT），不能把 PAT 写入安装脚本。**Public 仓库才能直接用未认证的 raw.githubusercontent.com 地址下载**。

### 3. VPS 一键安装

```bash
# 最通用：适用于 Alpine 等默认只有 /bin/sh 的 Linux
sh -c "$(curl -fsSL https://raw.githubusercontent.com/你的GitHub用户名/xray-ss-deploy/main/install-xray-ss.sh)"

# 已安装 Bash 的 Linux，也支持用户喜欢的写法
bash -c "$(curl -fsSL https://raw.githubusercontent.com/你的GitHub用户名/xray-ss-deploy/main/install-xray-ss.sh)"
```

root 执行可直接安装；普通用户若有 `sudo`，安装入口会自动提权。未安装 curl 的系统，可以用 wget 下载远程脚本，例如 `sh -c "$(wget -qO- <同一下载地址>)"`。第一次进入菜单后，选择 `1` 可安装默认 Xray `v26.6.1`，或选择 `2` 创建节点。

**先检查再运行更稳妥**：

```bash
curl -fL https://raw.githubusercontent.com/你的GitHub用户名/xray-ss-deploy/main/install-xray-ss.sh -o install-xray-ss.sh
less install-xray-ss.sh
sh install-xray-ss.sh
```

一键入口只是下载公开仓库中的两份脚本到临时目录，并通过已有 `install.sh` 启动管理程序；不会要求下载 ZIP，也无需 VPS 安装 Git。再次执行可以更新受管的 `xss` 命令，不会自动把已有 Xray 内核改成其他版本。若仓库文件有误或与已安装的其他同名命令冲突，安装会停止并输出中文错误。

---

**v0.6 的主要改动（仍然保留）：**

- 完全取消二维码生成和自动安装，不再依赖 `qrencode`。
- 创建节点时不再提示选择传输方式，自动使用原选项 `1`（TCP + UDP）。
- 添加节点后依旧立即显示节点密码、服务器地址及完整 `ss://` 分享链接。

**保留 v0.5 的功能：**

- **节点名称支持中文**，如 `北京联通9929`、`香港 移动CMIN2`。最多 48 个 Unicode 码点，禁止控制字符、斜杠及首尾空格。JSON 节点标签和分享链接中的备注会正确处理中文。
- **新节点的名称前缀由 `xss-` 改为 `ss-`**。比如输入 `北京联通9929`，生成 `ss-北京联通9929`，分享链接结尾为 `#ss-%E5%8C%97%E4%BA%AC%E8%81%94%E9%80%9A9929`（中文按 URL 规则编码）。**协议本身仍是标准 `ss://` 链接。**
- **Xray 默认安装版本设置为 `v26.6.1`**。首次进菜单 `1` 直接回车即可安装该版本；如果先选择菜单 `2` 且尚未安装内核，也会询问是否安装默认版本。仍可手动选择其他版本或切换已安装版本。
- **旧节点兼容**：历史配置中的 `xss-xxx` 内部 tag 保持原样，不自动迁移配置；列表、连接信息和分享链接展示为 `ss-xxx`，可用原标签或新标签管理。
- **管理命令仍为 `sudo xss`**，为了兼容旧版安装路径；用户要求删除的 `x` 仅针对节点名称/分享备注，不影响管理命令。

继承 v0.4 的功能：一个操作生成一个独立节点，添加成功后立即打印密码和 `ss://` 分享链接；继续支持 7 种 SS/SS2022 加密方式、多种 Linux 发行版和服务管理器。

**版本说明：** Xray 官方发布页列有 `v26.6.1`，并将它标注为预发布版。本工具只是按照指定需求设为默认值，并不表示它是官方最新稳定版；生产环境可自行切换经验证的版本。

## 一、部署系统范围

目标为尽可能适配主要 Linux 发行版，依据工具链和系统环境自动探测，而非只允许 Debian/Ubuntu：

| 系统 | 依赖安装工具 | 系统服务管理 |
|---|---|---|
| Debian、Ubuntu、Mint、Kali、Devuan | APT | systemd、SysVinit 等 |
| RHEL、Rocky、AlmaLinux、CentOS Stream、Fedora | DNF / YUM / microdnf | systemd 等 |
| Arch Linux、Manjaro | Pacman | systemd 等 |
| openSUSE、SLES | Zypper | systemd 等 |
| Alpine Linux | APK | OpenRC 等 |
| Gentoo | Portage | OpenRC、systemd 等 |
| Void Linux | XBPS | runit 等 |
| OpenWrt | opkg / APK | procd（需要与架构匹配的内核） |
| NixOS、Slackware、精简容器 | 依赖需人工准备 | 有限适配 / 手动模式 |

支持自动探测 systemd、OpenRC、SysVinit、runit、procd，未识别服务管理器时使用手动模式（不保证开机自启）。CPU 架构是否可用还取决于 **所选 Xray 版本有没有对应的 Linux 官方发布包**。

**不能宣称“所有 Linux 都已真机验证”**：主要兼容流程为代码适配和本地模拟测试，不保证每个发行版、CPU 架构和容器系统都能直接运行。当前不涵盖 Android/Termux、macOS、BSD。

## 二、安装

解压后进入目录：

```bash
unzip xray-ss-deploy-v0.6-zh.zip
cd xray-ss-deploy-zh
sudo sh install.sh
```

`install.sh` 是 POSIX `sh` 入口，会检测 Bash 依赖并交给 `xray-ss.sh`。已具备 Bash 也可执行：

```bash
sudo bash xray-ss.sh
```

初次使用建议选择菜单 `1`，**直接回车默认安装 `v26.6.1`**；也可输入其他完整版本号。若直接使用菜单 `2` 创建节点，在内核未安装时会询问是否安装默认版本（需要确认）。

还可以在系统上执行下面的命令，直接安装/切换到默认内核版本：

```bash
sudo xss install-default
```

此命令不会自动更换已有节点的配置，切换前会验证已有配置能否由目标内核读取。

以后可使用：

```bash
sudo xss          # 中文交互菜单
sudo xss show     # 选择节点展示连接信息
sudo xss links    # 输出所有历史节点的分享链接
sudo xss list     # 查看节点列表
sudo xss status   # 查看服务状态
sudo xss logs     # 查看服务日志
sudo xss install-default  # 安装或切换至默认 v26.6.1
bash xray-ss.sh check  # 不需要 root 的兼容性预检查
```

**从 v0.3 / v0.4 / v0.5 升级：** 新版脚本不会覆盖原先已经复制到 `/usr/local/bin/xss` 的旧脚本。可从新版本解压目录执行：

```bash
sudo install -m 700 ./xray-ss.sh /usr/local/bin/xss
sudo xss
```

该操作**只更新管理命令，不会删除 `/etc/xray-ss/config.json` 中的已有节点、密码或内核文件**。首次升级前仍建议备份 `/etc/xray-ss/`。

## 三、中文菜单

```text
========== Xray SS / SS2022 节点管理系统 ==========
 1）安装或切换 Xray 内核版本（默认 v26.6.1）
 2）添加 SS / SS2022 节点（完成后显示连接信息）
 3）查看已有节点
 4）查看节点连接信息
 5）修改节点端口
 6）删除节点
 7）设置分享链接所用公网 IP / DDNS
 8）查看服务运行状态
 9）查看运行日志
10）重启 Xray 服务
11）完全卸载管理脚本及受管服务
12）检测 Linux 系统兼容性
 0）退出管理系统
```

## 四、支持的加密方式

每次执行「添加节点」后，只配置一个独立密钥和一个监听端口，可继续添加其他节点，并非整个系统只能创建一个节点。

| 类型 | 加密算法 |
|---|---|
| SS | `aes-128-gcm` |
| SS | `aes-256-gcm` |
| SS | `chacha20-poly1305` |
| SS | `xchacha20-poly1305` |
| SS2022 | `2022-blake3-aes-128-gcm` |
| SS2022 | `2022-blake3-aes-256-gcm` |
| SS2022 | `2022-blake3-chacha20-poly1305` |

新建节点自动启用 TCP + UDP，无需手动选择。SS2022 AES-128-GCM 密钥为 16 字节，另两种 SS2022 密钥为 32 字节，随机生成后 Base64 编码。分享链接遵循 Shadowsocks SIP002/SIP022：SS 使用 Base64URL 编码用户信息，SS2022 使用百分号编码后的明文用户信息。

## 五、添加节点后会显示什么？

以下为**格式示例**，不是可以连接的真实节点；中文名称在 URL 的 `#` 后将自动进行百分号编码：

```text
========== 节点连接信息 ==========
节点名称：ss-北京联通9929
节点端口：43888
加密方式：2022-blake3-aes-256-gcm
传输方式：TCP + UDP
连接密码：<安装时生成的密钥>
服务器地址：vps.example.com

SS / SS2022 分享链接（复制到客户端即可导入）：
ss://<真实的已编码加密信息>@vps.example.com:43888#ss-%E5%8C%97%E4%BA%AC%E8%81%94%E9%80%9A9929
==================================
```

安装后无需扫码，复制上述 `ss://` 分享链接到支持相应加密算法的客户端即可导入。如未能自动识别公网 IP，先在菜单 `7` 填写服务器 IP 或 DDNS，再通过菜单 `4` 查看链接。

## 六、兼容性与安全提醒

1. 本地通过脚本语法与模拟服务测试，**还没有在真实 VPS 上完成 Xray 连通性和所有发行版的验证**；建议先使用测试 VPS。
2. 内核下载、校验和回滚由脚本实现；切换至较旧的 Xray 版本前会验证配置，老版本不一定支持所有 SS2022 配置。
3. 脚本不会自动开放云服务商安全组和系统防火墙端口，需手动同时放行 TCP 和 UDP 端口。
4. 节点默认监听 `0.0.0.0`（IPv4）；使用 IPv6 地址分享时需自行确认 IPv6 服务监听配置。
5. 旧版多用户节点保留运行和查看链接能力，但新菜单不再提供增删用户功能。旧版 `xss-` 标签不会被直接修改，避免无谓的配置变更。
6. 连接密钥、分享链接和 `/etc/xray-ss/backups/` 配置备份含有秘密凭证，请勿把连接信息或终端截图公开传播。
7. NixOS、部分 OpenWrt、精简容器和特殊 CPU 架构属于有限兼容范畴；预检查不代表真实部署成功。

## 七、开发测试

```bash
bash -n xray-ss.sh
bash tests/test.sh
bash tests/test_zh.sh
bash tests/test_versions.sh
bash tests/test_platform.sh
bash tests/test_bootstrap.sh
bash tests/test_manual.sh
bash tests/test_github.sh
```

官方参考文档：

- Xray SS 入站配置：https://xtls.github.io/config/inbounds/shadowsocks.html
- Xray 内核版本：https://github.com/XTLS/Xray-core/releases
- Shadowsocks SIP002 分享链接：https://shadowsocks.org/doc/sip002.html
