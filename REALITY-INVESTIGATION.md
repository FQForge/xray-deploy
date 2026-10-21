# Reality 无法连接：VPS 实测结论

排查时间：2026-10-20 至 2026-10-21（America/Los_Angeles），系统为 Ubuntu 22.04.5。

**已确认根因是脚本固定使用的旧服务端内核 v26.6.1 对较大 TLS 握手记录的处理限制。升级到与 3x-ui v3.10.2 相同的 Xray v26.10.10 后，原失败目标恢复成功，10 个非 Cloudflare 随机候选全部通过。** 更换域名可以绕过旧版限制，但完整修复需要升级服务端内核。

## 与 3x-ui 的同条件对照

从 [3x-ui v3.10.2 官方发布包](https://github.com/MHSanaei/3x-ui/releases/tag/v3.10.2) 中提取内核，未安装面板。它包含 Xray **v26.10.10**（`701af60`，Go 1.27.2）；脚本原默认是 **v26.6.1**（`94ffd50`，Go 1.26.3）。

同一 VPS、同一 UUID / Reality 密钥 / short ID、相同 TCP + Vision 配置，伪装目标和 SNI 均使用 `www.microsoft.com:443`，只切换服务端或客户端二进制：

| 服务端 | 客户端 | Reality + Vision / 独立 HTTPS 请求 |
| --- | --- | --- |
| 脚本旧版 v26.6.1 | v26.6.1 | 失败，EOF / curl 连接被重置 |
| 脚本旧版 v26.6.1 | 3x-ui 所带 v26.10.10 | 失败，curl 状态 35 |
| 3x-ui 所带 v26.10.10 | 旧版 v26.6.1 | 成功，204；微软 HTTPS 200 |
| 3x-ui 所带 v26.10.10 | v26.10.10 | 成功，204；微软 HTTPS 200 |
| Xray 官方下载的 v26.10.10 | v26.10.10 | 成功，204；微软 HTTPS 200 |

独立 HTTPS 测试地址为 `https://www.gstatic.com/generate_204`，请求实际经过对应 Reality + Vision 节点。交叉测试说明故障来自旧服务端；升级客户端无法修复，升级服务端后旧客户端也可以使用。

生产安装使用 [Xray v26.10.10 官方下载包](https://github.com/XTLS/Xray-core/releases/tag/v26.10.10)，通过官方 `.dgst` 的 SHA256 校验。安装后的二进制与 3x-ui 包内二进制 SHA256 完全相同：

```text
4cca4de3ab8c16b3803a70e9ebe0570d2a72480c716d89aa91603ec568bf0f44
```

## 具体失败位置

本 VPS 访问微软目标时收到 **8273 字节的 Certificate 记录**，超过旧 v26.6.1 中 Reality 的 **8192 字节**限制。旧服务端正确完成客户端认证后，在处理目标握手记录时中断；本机回环连接即可复现。

旧服务端关键日志（省略连接凭据）：

```text
len(s2cSaved): 4262  Certificate: 8273
hs.c.isHandshakeComplete.Load(): false
REALITY: processed invalid connection ...: handshake did not complete successfully
```

对应 Xray v26.6.1 使用的 `github.com/xtls/reality` 提交 `9234c772ba8f`：

- [tls.go:140](https://github.com/XTLS/REALITY/blob/9234c772ba8f/tls.go#L140) 定义 `size = 8192`。
- [tls.go:334](https://github.com/XTLS/REALITY/blob/9234c772ba8f/tls.go#L334) 在 `handshakeLen > size` 时中止处理。

新版官方服务端处理同样的 **8273 字节记录**时：

```text
len(s2cSaved): 8273  Certificate: 8273
hs.handshake() err: <nil>
hs.c.isHandshakeComplete.Load(): true
```

客户端显示 `uConn.Verified: true`，独立 HTTPS 返回 204，微软 HTTPS 返回 200。8192 字节限制属于上述旧内核，不能据此认定当前新版或微软域名不可用。

另一个已修复的问题是临时实例自检的 **5 秒连接超时**。Reality 冷启动目标探测通常消耗约 5 秒，旧自检可能在认证成功时误报超时。现在连接超时为 15 秒、请求总超时为 25 秒；本次新版池测试全部在约 5 秒完成冷启动 HTTPS 握手。

## 非 Cloudflare 随机池：新版下 10 / 10 成功

以下每项均使用官方 Xray **v26.10.10** 在本 VPS 上重新测试，逐个通过直连 TLS 1.3、Reality + Vision、隧道内独立 HTTPS 请求，以及隧道内以自身域名为 SNI 的 TLS 1.3 请求与证书校验。

| 候选域名 | 当前解析网络 | Reality + Vision | 独立 HTTPS | 冷启动 HTTPS 握手 |
| --- | --- | --- | --- | --- |
| `www.bing.com` | Akamai | 通过 | 204 | 5.108 秒 |
| `www.amazon.com` | Amazon | 通过 | 204 | 5.054 秒 |
| `www.samsung.com` | Akamai | 通过 | 204 | 5.032 秒 |
| `www.nvidia.com` | Akamai | 通过 | 204 | 5.026 秒 |
| `www.sony.com` | Akamai | 通过 | 204 | 5.038 秒 |
| `www.oracle.com` | Akamai | 通过 | 204 | 5.041 秒 |
| `www.intel.com` | Akamai | 通过 | 204 | 5.028 秒 |
| `www.adobe.com` | Akamai | 通过 | 204 | 5.032 秒 |
| `www.yahoo.com` | Yahoo | 通过 | 204 | 5.322 秒 |
| `www.ebay.com` | Akamai | 通过 | 204 | 5.045 秒 |

每个目标的 DNS 别名、IPv4 / IPv6 地址与 Cloudflare 公布的代理网段，以及 HTTP 响应头中的 `server: cloudflare` / `cf-ray` 均已检查，未发现 Cloudflare 代理特征。这反映本次测试时 VPS 所见的 CDN 路径。

目标站首页可能返回 301、403、429 或 503；这些响应均完成 TLS 1.3 和证书校验。独立测试地址的 **10 次 204** 证明所有候选都可用于代理其他 HTTPS 网站。

## 脚本修复与实际创建验证

- 默认内核改为 **v26.10.10**。创建 Reality 时检查已安装版本，低于该版本或无法识别时先升级；较新的内核继续使用。更新工具后创建节点不会再静默沿用旧 v26.6.1。
- 保留上述 10 项随机池，每次创建随机排列。自定义创建直接回车也随机选择，填写域名则使用指定目标。
- 新节点先用真实参数启动本机临时服务端和客户端，完成 Reality + Vision 与 HTTPS 代理检查，再应用正式配置并显示链接。候选临时不可达时可以尝试其他候选。
- 修正版本切换的错误处理：即使调用方处于 Bash 条件分支中，配置校验失败也会立即取消切换。

新版修复的实际流程验证：

| 验证 | 实测结果 |
| --- | --- |
| 独立测试环境从旧 v26.6.1 执行真实快速创建 | 自动升级至 v26.10.10，随机选中 Oracle；创建前自检、正式服务 HTTPS 均成功 |
| 真实自定义创建，指定原失败的微软目标 | 创建前自检、正式服务 HTTPS 和节点诊断均成功 |
| 不兼容配置下调用版本切换 | 返回失败；内核链接和运行中的服务进程均未改变 |
| 从 VPS 当前正式节点分享链接独立解析客户端，经公网 IPv4 连接 | HTTPS 返回 204，握手 0.044562 秒；目标 HTTPS 证书校验通过 |
| 数字版本比较、Bash / sh 语法与 `git diff --check` | 通过 |

临时测试服务均已停止。外部 TCP 探测此前确认正式节点 TCP **44827** 可从伊朗、塞尔维亚、越南连通，见[端口报告](https://check-host.net/check-report/5265fe9ak5eb)。该报告仅验证 TCP；完整 Reality + Vision 由上述独立客户端请求验证，未测试用户设备上的客户端软件。

## 本机使用与证据

VPS 正式服务已升级到 **v26.10.10**，当前保留测试节点 `vless-节点1`，TCP **44827**，伪装域名 `www.intel.com`。执行 `xnode links` 可复制完整链接；`xnode diagnose` 可重新诊断。升级内核不需要更改该节点的 UUID、密钥或分享链接。

已有旧节点的修复方法：按 README 重新运行安装命令更新管理工具，再执行 `sudo xnode install-default` 和 `sudo xnode diagnose`。使用本地仓库安装可执行：

```bash
sudo sh /root/xray-deploy/install.sh install-default
```

详细原始证据保存在 `/tmp/xray-reality-investigation/`：

- `3xui-microsoft-both/`、`3xui-server-old-client-microsoft/`、`old-server-3xui-client-microsoft/`：新旧服务端、客户端交叉实验。
- `official-v26.10.10-microsoft/`：官方内核处理原 8273 字节记录成功的日志及请求结果。
- `v26.10.10-pool-results.json`、`v26.10.10-pool-www.域名/`：10 个随机候选的新版完整测试与 DNS / HTTP 检查。
- `core-upgrade.bKJgJQ/`：旧内核自动升级、快速创建、自定义创建与拒绝不兼容配置的测试记录。
- `official-v26.10.10-live-uri/`：正式节点分享链接解析后的实际 HTTPS 请求。
- `3x-ui/`：官方发布包、已校验的 SHA256 和提取的内核；未安装管理面板。

证据目录仅 root 可访问；它属于临时存储，可能被系统清理。
