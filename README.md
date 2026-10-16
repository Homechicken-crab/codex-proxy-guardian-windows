# Codex Proxy Guardian 2.0

为部分 Windows Codex「WebSocket 超时、重连 5 次后回退 HTTP」问题提供持久代理配置。2.0 改用 Codex 自身读取的 `CODEX_HOME/.env`，替代 1.x 后台守护和重启方案。

**这是本地 HTTP 代理配置工具。** 需要已有可用的 VPN/代理客户端，以及固定的 HTTP 或 Mixed 混合端口。它不能修复不可用的节点、过期的登录状态或服务端故障。

## 安装

Windows PowerShell 5.1 / PowerShell 7。先启动 VPN，确认其 HTTP/Mixed 端口，再解压下载的发布包：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1
```

默认读取已启用的 Windows 静态系统代理。也可以明确指定端口，以下 `7890` 仅为示例，必须换成自己的 HTTP/Mixed 端口：

```powershell
.\Install.ps1 -ProxyUrl http://127.0.0.1:7890
```

仅接受无账号密码的本机 HTTP 代理。SOCKS-only 端口即使 TCP 可连接，也不能当作 HTTP 端口填写。默认探测会验证 HTTP CONNECT、TLS 证书和 Upgrade 请求的 HTTP 响应；失败时不会写入 `.env`。VPN 尚未开启时，可在确认固定端口后用 `-SkipProbe` 预配置。

安装器只设置以下变量，保留无关变量、注释和已有 `NO_PROXY` 排除项：

```dotenv
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
ALL_PROXY=http://127.0.0.1:7890
NO_PROXY=localhost,127.0.0.1,::1
```

目录优先级为 `-CodexHome`、进程中的 `CODEX_HOME`、`%USERPROFILE%\.codex`。已有 `.env` 中的同名代理变量会被替换并记录原值，供卸载恢复。不要把本机 `.env` 或恢复状态上传到仓库。

含多行引号值或续行的特殊 `.env` 会被拒绝自动修改，避免误改其他变量；这类文件需要手动合并代理配置。如果外部启动环境已设置同名代理变量，还需核对其优先级，最终以原生诊断结果为准。

**首次修改时，如果 Codex 已打开，请完整退出后重开一次。** 以后正常打开 Codex 会自动加载配置，无需专用快捷方式或额外开关。

## VPN 后开、重启与自动拨号

- VPN 可以晚于 Codex 启动。代理端口就绪后，Codex 后续连接可以使用这个端口；程序不会强制重启 Codex。
- VPN 关闭期间已经超时失败的消息，可能需要手动重试。此工具不监控或自动重发消息，也不承诺活动会话在所有网络中断后无缝恢复。
- 重启电脑不会清除配置。VPN 仍由用户或其自身启动设置控制；代理端口改变时需重新运行安装器并重新打开已运行的 Codex。
- 不创建计划任务、后台循环、开机启动项，不修改 VPN、拨号脚本、DNS、路由或系统代理。独立的开机拨号任务继续自行运行。

## 从 1.x 迁移

2.0 安装器在默认旧目录中找到有效 `.install.json` 后，只退役指向该安装的 `CodexProxyGuardian` 任务、Run 登录项、专用快捷方式及守护脚本进程。不会停止 Codex 应用或代理客户端。

旧版使用自定义目录时，显式指定：

```powershell
.\Install.ps1 -ProxyUrl http://127.0.0.1:7890 -LegacyInstallDirectory 'C:\Tools\CodexProxyGuardian'
```

旧目录文件保留供审阅，确认迁移后可以手动删除。无法验证归属的同名任务不会被删除；安装器会停止并提示。`-SkipLegacyCleanup` 可用于隔离测试或由管理员另行处理旧版时使用。

## 验证

```powershell
.\Diagnose.ps1                 # 脱敏的配置摘要
.\Diagnose.ps1 -Live           # 不携带凭据的传输检查
.\Diagnose.ps1 -Doctor         # 让 Codex 自己检查已登录的 WebSocket
.\SelfTest.ps1                 # 只操作临时目录的回归测试
```

`401` 或 `403` 等 HTTP 响应只能证明收到响应，不能等同于已登录会话成功。`-Doctor` 调用当前 Codex 的 `doctor --json`，只导出网络检查状态和耗时；不会读取或输出 `auth.json`、完整日志或原始诊断详情。旧 Codex 不支持 doctor 时会明确报错。

最终验收应查看重新打开 Codex 后的真实请求日志：WebSocket 成功，且没有新的 `responses_retry` / `falling back to HTTP`。不要只看代理端口是否监听。

## 卸载

保留解压后的程序文件，需要撤销时运行：

```powershell
.\Uninstall.ps1
```

卸载只恢复仍与安装值一致的代理变量，保留用户后来修改的变量和无关内容。缺少本工具的恢复状态时不会删除 `.env`。恢复状态 `proxy-setup-state.json` 仅保存在本机 Codex 目录，可能包含原代理值，应按私密配置保存。

## 发布与隐私

```powershell
.\Build-Release.ps1
python tools/check_public_content.py
```

发布包采用固定文件白名单，不打包运行时 `.env`、状态、日志、凭据或诊断报告。详见 [隐私说明](PRIVACY.md)、[验证范围](VALIDATION.md) 和 [更新记录](CHANGELOG.md)。
