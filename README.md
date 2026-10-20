# Xray 节点管理工具使用方法

## 一、一键安装

在 Linux VPS 中，以 root 身份执行：

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/fengqi0216/xray-deploy/main/install-xray-ss.sh)"
```

普通用户可以先切换到 root，或确认拥有 sudo 权限后运行。当前版本支持 SS 和 SS2022 协议。

## 二、打开管理菜单

安装完成后输入：

```bash
xnode
```

普通用户需执行 `sudo xnode`。

进入菜单后，选择 **1** 安装 Xray 内核（默认 `v26.6.1`，可自由选择版本）；选择 **2** 添加节点，填写中文节点名称、加密方式与端口。节点默认同时启用 TCP + UDP，创建完成后会自动显示 `ss://` 分享链接，无须选择单用户或多用户模式，也不显示二维码。

如连接地址不正确，可通过菜单 **7** 修改公网 IP 或域名；通过菜单 **4** 重新查看节点连接信息。

## 三、常用命令

```bash
xnode                  # 打开中文管理菜单
xnode list             # 查看所有节点
xnode show             # 查看指定节点的连接信息
xnode links            # 查看全部节点分享链接
xnode status           # 查看运行状态
xnode logs             # 查看运行日志
xnode install-default  # 安装默认内核 v26.6.1
```

普通用户在命令前添加 `sudo`。

## 四、更新与卸载

**更新：** 重新执行上面的一键安装命令。更新管理脚本不会主动删除已有节点或切换当前 Xray 内核版本。

**卸载：** 输入 `xnode`，选择菜单 **11**，按提示确认。卸载会删除由此脚本管理的节点、密码与内核，请提前备份。

