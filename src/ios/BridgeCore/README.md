# BridgeCore

「桥」的平台无关内核层：以官方 MCP Swift SDK 为协议本体，将来承载小管家的
调度中枢与对外元工具（「搜」/「命令」）。本包不依赖任何 iOS 专属框架，
在 Linux CI 上直接构建与单测。

## 依赖

- `modelcontextprotocol/swift-sdk`，精确 pin **0.12.1**（exact），只引产品 `MCP`。
  - 0.12.1 已于 2026-09-30 用仓库 releases 与 git tag 双路核实存在
    （tag 指向 commit `a0ae212ebf6eab5f754c3129608bc5557637e605`）。
  - SDK 仍是 pre-1.0，0.x 的 minor 版本可含 breaking change；升级走显式评审，
    不漂移跟随。`Package.resolved` 随仓库提交。

## SDK 已知问题复核（2026-09-30 查）

官方仓库 issue #254、#255 均为 **open** 状态，未修复：

- #254：`StatelessHTTPServerTransport` 在并发请求共用同一 JSON-RPC id 时，
  响应等待者互相覆盖，导致挂起与 continuation 泄漏。
- #255：`StatelessHTTPServerTransport` 收到 `notifications/cancelled` 后，
  原始 POST 请求悬挂不完成。

结论与架构定稿一致：桥的对外服务只用 `StatefulHTTPServerTransport`
（每会话新建 Server + transport 工厂模式），**不使用 Stateless 传输模式**，
上述两个问题不落在桥的使用路径上。
