# SSL VPN Connect for macOS（实验版）

这是一个兼容 H3C SSL VPN 的非官方 macOS 实验客户端。它不包含 H3C 或 iNode 官方代码、图标或客户端二进制，而是把带有 H3C `--protocol=h3c` 支持的开源 OpenConnect 核心封装成图形应用和安全命令行客户端。

H3C 和 iNode 是其各自权利人的商标。SSL VPN Connect 是独立开发的兼容性工具，与 H3C 不存在关联、授权、赞助或官方分发关系。

## 图形界面安装

1. 双击 `SSLVPNConnect-macOS-arm64.dmg`。
2. 将“`SSL VPN Connect`”拖入“应用程序”。
3. 打开应用，添加 VPN 网关并自动获取或填写管理员确认的证书指纹。
4. 点击“安装服务”，完成一次 macOS 管理员授权，然后输入用户名和密码。
5. 先关闭 Shadowrocket 或其他全局 VPN，再点击“连接 SSL VPN”。
6. 后续连接和断开通过本机受限后台服务执行，不会重复弹出管理员授权；密码仅在用户主动勾选“记住密码”时保存到本机配置。

如果界面提示“后台服务版本过旧”，必须先点击“更新服务”。客户端会阻止旧服务继续使用历史路径启动连接。

图形客户端支持路由冲突检测、密码安全输入、连接/断开、实时日志和证书固定。当前安装包使用本地临时签名，未经过 Apple Developer ID 公证；首次打开时请核对安装包来源和 SHA-256 后自行决定是否允许运行。

后台服务只接受安装它的当前 macOS 用户通过本机 socket 请求，并且只调用安装包内固定的兼容连接核心和 `vpnc-script`；它不是一个可执行任意命令的 root shell。

## 图形客户端偏好

- “记住用户名”和“记住密码”均保存到权限为 `0600` 的当前用户本地偏好文件，不访问 macOS Keychain；取消勾选会删除对应本地记录；
- 网关菜单支持添加、编辑、删除和切换配置，每个网关保存独立的 `pin-sha256` 证书指纹；编辑器可自动读取网关公开证书，不发送账号密码；
- “网关出口”可选择自动路由或指定带有 IPv4 地址的本地网口；指定后，VPN 的 TLS 出站套接字会通过 macOS `IP_BOUND_IF` 绑定到该网口；
- 网关编辑窗口中的证书指纹自动获取共用当前“网关出口”，也可在探测前单独切换本地网口；
- “仍允许经过现有 utun 隧道连接”直接显示在网络路径区域；勾选后会跳过网关出口检查，并按系统当前路由直接尝试连接；
- 关闭主窗口后应用继续驻留菜单栏，连接状态、打开窗口和断开操作可从菜单栏访问。
- 连接后根据网关分配的 VPN 地址定位对应 `utun`，显示实时下载/上传速度及本次会话累计流量；菜单栏同步显示实时速度。
- 认证、SSL 或网关连接失败时自动停止残留进程；启动后 30 秒仍未获得 VPN 地址会按连接超时自动断开。

## 功能与安全性

- 只支持 H3C iNode SSL VPN 的用户名/密码认证；
- 密码通过 stdin 传给核心程序，不出现在命令行参数或环境变量；图形界面勾选“记住密码”时会按用户选择写入本机偏好文件；
- 安装包不内置网关或证书指纹；用户需添加网关并保存其公开证书 SPKI 指纹，避免使用自签名证书时被中间人替换；
- 连接前检查到网关的路由，发现经过 `utun*` 时默认拒绝，避免再次被 Shadowrocket/其他 VPN 拦截；
- 使用官方 `vpnc-scripts` 完成 macOS `utun`、路由和 DNS 设置；
- 启动器不保存或持久改写网络配置；连接期间由 OpenConnect 和脚本临时创建 `utun`、路由和 DNS，断开时恢复，因此连接通常需要 `sudo`。

## 命令行使用

```bash
# 只检查路由，不连接
./h3c-vpn --route-check --gateway HOST:PORT

# 连接（建议先关闭 Shadowrocket 等全局 VPN）
sudo ./h3c-vpn --gateway HOST:PORT --username YOUR_USER \
  --servercert 'pin-sha256:BASE64_PIN'
```

看到“密码（不保存）”后输入密码。按 `Ctrl-C` 断开。

如果你明确知道网关必须经过另一个隧道，才使用：

```bash
sudo ./h3c-vpn --allow-tunnel-route --gateway HOST:PORT --username YOUR_USER \
  --servercert 'pin-sha256:BASE64_PIN'
```

连接时必须提供管理员确认的证书指纹。图形客户端可以从网关公开证书自动获取，命令行需显式传入：

```bash
sudo ./h3c-vpn --gateway HOST:PORT --username USER \
  --servercert 'pin-sha256:BASE64_PIN'
```

## 构建

`scripts/build.sh` 会：

1. 校验并构建 OpenConnect H3C 实验分支的固定提交 `22b2218d10e9cb3fb072db7f3e65c6fda44f68c0`；
2. 校验官方 `vpnc-scripts` 固定提交 `ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101`；
3. 编译原生 C 安全启动器；
4. 生成 `dist/H3CVPN-macos-arm64/`。

`scripts/build-dmg.sh` 会进一步编译 SwiftUI 图形界面，并生成 DMG。

构建依赖：Xcode Command Line Tools、Homebrew，以及 `autoconf automake libtool pkg-config openssl@3 libxml2 lz4`。发布版 `0.9.1` 使用的具体版本记录在 `BUILD-INFO.txt`。

```bash
./scripts/build.sh
./scripts/build-dmg.sh
```

提交项目修改后，可生成与二进制 Release 对应的完整源码包：

```bash
./scripts/build-sources.sh
```

## 限制

这是非官方实验客户端。当前 OpenConnect H3C 分支的协议实现比较粗糙，未覆盖所有网关的证书、OTP、短信或定制认证流程。生产环境请保留官方客户端作为回退方案，并先让网络管理员确认允许第三方客户端。

不要把密码、iNode `.icnf` 文件或包含认证信息的日志提交到仓库。

## 开源来源

- H3C OpenConnect experimental branch: <https://gitlab.com/vimacs.hacks/openconnect>
- OpenConnect vpnc-scripts: <https://gitlab.com/openconnect/vpnc-scripts>
- OpenConnect、vpnc-scripts、OpenSSL、libxml2、LZ4 和内置 JSON 解析器的版本、版权归属与许可证见 `THIRD_PARTY_NOTICES.md`；完整许可证文本位于 `Licenses/`。
- 每个二进制 Release 同时提供对应源码压缩包。把 DMG 转发给其他人时，也必须向接收者提供该源码包。
