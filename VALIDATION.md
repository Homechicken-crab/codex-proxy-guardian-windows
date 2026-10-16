# 验证范围

## 方案实机依据

在 Windows 11、Windows PowerShell 5.1、Codex CLI 0.162.0-alpha.17.2 上验证过：

- 隔离 `CODEX_HOME` 中的 `.env` 代理变量能被原生 Codex 自动读取。
- 使用现有登录状态的 `codex doctor --json` 返回 Responses WebSocket `HTTP 101 Switching Protocols`。
- 桌面端完整退出重开后，真实聊天日志出现 `successfully connected to websocket`；观察窗口内没有新的采样重试或 HTTP 回退。

本仓库只记录上述结果摘要，不包含用户日志、身份、本机路径、实际端口或账号资料。此验证支持配置方法，不代表所有 Codex 版本、VPN 或网络故障均可无缝恢复。

## 自动化测试

`SelfTest.ps1` 在临时目录中检查脚本语法、代理地址约束、WhatIf 无副作用、已有配置保留、大小写重复变量处理、排除项合并、重复安装、端口更新后的原值恢复、用户后续修改保留、无状态卸载、未知状态拒绝和 HTTP 头解析边界。

自动化测试始终使用 `-SkipProbe -SkipLegacyCleanup`，不读取登录凭据、不访问模型、不改动真实配置或启动项。CI 分别使用 Windows PowerShell 5.1 和 PowerShell 7 运行。

## 限制

- 未在所有旧版安装目录和系统策略组合上执行自动迁移实机测试；迁移会核验产品标记和启动参数，不匹配时保留并报错。
- 未验证运行中重启 VPN 后的每一种消息恢复情形；失败消息可能需要用户重试。
- 不验证 VPN 开机自启，不自动启动 VPN 或 Codex。
- `-Live` 不携带账号凭据，其 HTTP 响应不能证明已认证 WebSocket 会话成功。
- 首次修改 `.env` 后，已运行的 Codex 必须重开一次加载配置。
