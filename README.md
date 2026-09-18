

你是否在为codex思考总是重连5次而烦恼？解决方法他来了！

# Codex Proxy Guardian

面向 Windows 11 Codex 桌面端的轻量代理守护器。它持续读取并验证当前代理，在代理端点稳定变化后，以进程级代理环境和 Chromium 启动参数重新启动 Codex，避免 WebSocket 多次超时后退回 HTTP。

## 主要能力

- 默认读取当前用户的 Windows 静态系统代理，也可使用明确指定的代理。
- 对候选代理依次执行 TCP、HTTP CONNECT、TLS 证书和 Codex WebSocket Upgrade 路径探测。
- 只接受回环代理，除非显式启用 `allowRemoteProxy`。
- 仅向新启动的 Codex 进程树注入 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 及小写形式，并附加 `--proxy-server`。
- 端点变化防抖、故障恢复宽限、重启限速和熔断，避免代理抖动引发重启循环。
- 命名互斥锁保证单实例；计划任务在用户登录后静默运行。
- JSON Lines 日志、状态查询、只读诊断和安全卸载。
- 不写 WinINET、WinHTTP、PAC、DNS、路由、防火墙、证书或代理软件配置。

## 系统要求

- Windows 11
- Windows PowerShell 5.1
- Microsoft Store/MSIX 版 Codex 桌面端（包名 `OpenAI.Codex`）
- 可用的 HTTP CONNECT 或 SOCKS5 代理

## 安装

下载并解压发布包，在 Windows PowerShell 中运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1 -StartNow
```

默认安装到 `%LOCALAPPDATA%\CodexProxyGuardian`，并创建当前用户级计划任务 `CodexProxyGuardian`。任务使用交互用户的有限权限，在登录后延迟启动，不需要管理员权限。

更新时从新版本目录再次运行相同命令。已有 `config.json` 会保留，新默认配置写入 `config.default.json` 供比较。

## 验证与运维

运行静态自测：

```powershell
.\SelfTest.ps1
```

连同当前系统代理执行真实网络探测：

```powershell
.\SelfTest.ps1 -Live
```

查看已安装实例状态和最近日志：

```powershell
& "$env:LOCALAPPDATA\CodexProxyGuardian\Status.ps1" -TailLog
```

生成只读诊断报告：

```powershell
& "$env:LOCALAPPDATA\CodexProxyGuardian\Diagnose.ps1" -Json
```

诊断结果包含用户名、代理端点和 Codex 安装位置，分享前请自行审阅。

## 配置

默认 `sourceMode` 为 `SystemProxy`。守护器读取：

`HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`

若要固定代理，请在保留其他配置项的前提下，把安装目录中 `config.json` 的字段改为：

```json
{
  "sourceMode": "SpecifiedProxy",
  "specifiedProxy": "http://127.0.0.1:7890"
}
```

支持 `http://`、`socks5://` 和 `socks5h://`。默认拒绝非回环地址。

WebSocket 探测未携带登录凭据，因此来自目标服务的 `101`、`400`、`401`、`403`、`404` 或 `426` 都可证明代理、TLS 和 HTTP Upgrade 路径可达；连接超时、TLS 校验失败或非 HTTP 响应会判为失败。

## 安全卸载

```powershell
& "$env:LOCALAPPDATA\CodexProxyGuardian\Uninstall.ps1" -Confirm:$false
```

可使用 `-KeepLogs` 或 `-KeepConfig` 将相应内容归档到 `%LOCALAPPDATA%`。卸载器只删除带有效安装标记的守护目录及其计划任务，不会更改系统代理或关闭 Codex。

## 构建发布包

```powershell
.\Build-Release.ps1
```

加入 `-LiveTest` 可在打包前执行真实代理链路探测。产物和 SHA-256 校验文件位于 `dist`。

## 设计说明

Codex 桌面端由 Chromium 外壳和原生 `codex.exe` 子进程组成。仅依赖 Windows 系统代理可能出现普通 HTTP 可用、原生 WebSocket 超时的差异。守护器因此在确认端点健康后，为同一进程树同时提供代理环境变量与 `--proxy-server`，同时保持系统网络配置不变。

更完整的安全边界和实机验证结果见 [VALIDATION.md](VALIDATION.md)。
