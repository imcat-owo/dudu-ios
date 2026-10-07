# 内核复核：MCP Swift SDK 0.12.1 Streamable HTTP 行为

复核日期：2026-09-30
复核对象：`modelcontextprotocol/swift-sdk` **0.12.1**（tag 提交 `a0ae212ebf6eab5f754c3129608bc5557637e605`），桥的 `Package.swift` 精确 pin 此版本。
复核方法：① 通读该版本源码（`Sources/MCP/Base/Transports/HTTPServer/`、`Sources/MCP/Server/`、`Sources/MCP/Client/`）；② 在 Linux CI（Swift 6.1 容器）里用原始 socket 探针 + 线级端到端实测，探针测试在 `BridgeCore/Tests/BridgeCoreTests/RawHTTPProbeTests.swift`、`WireEndToEndTests.swift`；官方 Client 版端到端在 `HostEndToEndTests.swift`（仅非 Linux 平台，原因见第 8 条）。

## 结论一览

| # | 说法 | 结论 | 依据 |
|---|------|------|------|
| 1 | POST 请求的响应是 SSE 流 | 成立 | 源码 + 探针 01 |
| 2 | 流开头有 priming 事件 | 成立（带条件） | 源码 + 探针 01/09 |
| 3 | Last-Event-ID 断线续传可回放 | 成立 | 源码 + 探针 10/11 |
| 4 | DELETE 终止会话 | 成立 | 源码 + 探针 07 |
| 5 | 不支持的方法回 405 | 成立 | 源码 + 探针 06 |
| 6 | 客户端 disconnect 会发 DELETE 终止会话 | **不成立** | 源码（见下） |
| 7 | Stateless 传输在并发下安全 | **不成立（上游未修）** | issue #254/#255 |
| 8 | SDK Client 在 Linux 上能连有状态 SSE 服务端 | **不成立（上游 Linux 限制）** | 源码 + 实测（见下） |

## 逐条

### 1. POST 响应形状——成立

`StatefulHTTPServerTransport.handleJSONRPCRequest` 对普通请求一律返回 `.stream`：状态 200、`Content-Type: text/event-stream`、带 `Mcp-Session-Id`、`Cache-Control: no-cache, no-transform`、`Connection: keep-alive`。initialize 的响应同样是流（先发 priming，再发 initialize 结果）。只有通知/响应类消息回 `.accepted`（202 空体）。
实测：探针 01（initialize 的 Content-Type、会话头、结果内容）。

### 2. Priming 事件——成立，条件：协议版本 ≥ 2025-03-26

`sendPrimingEvent` 仅当协商版本（字符串比较）≥ "2025-03-26" 时发送；事件 `data` 为**空字符串**，线上形状是 `id: <流id>_<计数>\ndata: \n\n`。流 id：POST 请求用其 JSON-RPC id（如 `7_2`），独立 GET 流固定 `_GET_stream`。priming 与业务消息一样被 `storeEvent` 存下，可参与回放。
实测：探针 01（priming 在 initialize 结果之前、data 为空）、探针 09（GET 流 priming 的 id 前缀）。

### 3. Last-Event-ID 续传——成立

GET 带 `Last-Event-ID` 时走 `handleResumeRequest`：id 找不到 → 400 `Invalid Last-Event-ID`；找到 → 在同一条流上按存储顺序回放其后的事件，重新登记续流，再补发一个新 priming。事件按「流」隔离存储：别的流的事件不在此回放。
实测：探针 10（假 id → 400）、探针 11（POST 发起 1.2 秒的工具调用，只读到 priming 就断线；1.8 秒后用该 priming 的 id 发 GET，结果事件被回放，含工具输出原文）。

### 4. DELETE 终止会话——成立

DELETE 通过校验后 `terminate()`：结束全部流、清存储事件、入站流关闭，回 `.ok`（200 空体）。其后同一传输再收请求回 404 `Session has been terminated`；在桥的会话管理层，该会话已被摘除，后续请求走「未知会话」404。
实测：探针 07（DELETE 200 空体 → 同 id POST 404）。

### 5. 405 兜底——成立

POST/GET/DELETE 之外的方法回 `.error(405)` 并带 `Allow: GET, POST, DELETE`。
实测：探针 06（PUT → 405，Allow 含 POST）。

### 6. 客户端 disconnect 不发 DELETE——不成立（重要差异）

`HTTPClientTransport.disconnect()`（0.12.1 源码）只做本地清理：取消流任务、`session.invalidateAndCancel()`、结束消息流，**不发任何 HTTP 请求**，更没有 DELETE。也就是说客户端「断开」后，服务端会话不会立即消失，只能靠桥这边的闲置回收（`MCPSessionManager.reapIdleSessions`，默认闲置 3600 秒）收尾。桥的会话层因此必须自带回收，不能指望客户端配合。
实测：回收一侧由 `SessionManagerTests.testIdleReaperCollectsSession` 覆盖（闲置回收后同 id 请求 404）。「客户端 disconnect 后服务端会话仍在」这一半原拟用 `HostEndToEndTests.testConcurrentSessionsDoNotCrossTalk` 实测，但该组在 Linux CI 跑不起来（见第 8 条），**此一半在 Linux 上未核实**，待 macOS 跑该组时补。

### 7. Stateless 传输——禁用（上游 issue 未修）

2026-09-30 经 GitHub API 复核，#254（同 JSON-RPC id 并发时 waiter 互相覆盖，挂死+泄漏）与 #255（notifications/cancelled 让原 POST 挂起）**均为 open**。桥的代码里只出现 `StatefulHTTPServerTransport`，会话工厂按「一会话一 Server + 一传输」创建；任何地方不得引入 Stateless 传输，除非这两条 issue 关闭且重新复核通过。

### 8. SDK Client 在 Linux 上连不上 SSE 式服务端——上游限制（实测坐实）

`HTTPClientTransport` 的 Linux 分支用 `URLSession.data(for:)` 收响应（等整份响应结束），`processResponse` 把**整段 SSE 响应体当作一条消息**原样 `messageContinuation.yield(data)`；而 `Client` 的接收循环按「一条数据 = 一条 JSON 消息」解码，多事件的 SSE 文本（priming + 消息）解码必然失败、被当作 "Unexpected message" 丢弃——initialize 的响应永远到不了等待者，`connect()` 无限挂起。macOS/iOS 分支是逐事件流式处理（`bytes(for:)` + `processSSE`），不受影响。
实测（Linux CI）：官方 Client 连桥的宿主，`connect()` 超过 10 秒不返回（诊断运行 36691324906）；同一宿主用裸 `URLSession.data(for:)` 打 initialize，立即返回 200、485 字节完整响应体（诊断运行 36691868402）——宿主与 Linux 网络栈无问题，卡点在 SDK Client 的 Linux 接收路径。桥的应对：Linux CI 的端到端用线级全流程 `WireEndToEndTests`（原始 HTTP 穿过宿主/会话/传输/Server/管家/清洗全链路）；官方 Client 版端到端 `HostEndToEndTests` 限定非 Linux 平台编译，待 macOS 运行时验证。

## 附带坐实的行为（桥的校验流水线依赖）

- POST 的 Accept 必须同时含 `application/json` 与 `text/event-stream`，缺一 → 406（探针 03）。
- POST 的 Content-Type 必须是 `application/json`（参数后缀忽略），否则 415（探针 04）。
- Host 不在名单 → 421；Origin 不在名单 → 403。桥本机模式名单 = `OriginValidator.localhost()`，校验不整段关闭（探针 12：`Host: evil.example.com` → 421）。
- 同会话二次 initialize → 400 `Session already initialized`（探针 08）。
- 会话头对不上 → 404 `Invalid or expired session ID`；传输未初始化先来业务请求 → 400（桥的会话管理层对未知会话先行 404，探针 05）。
- 协议版本支持集：2025-11-25 / 2025-06-18 / 2025-03-26 / 2024-11-05，最新 2025-11-25。
- SDK 的 `Value` 解码对数字/布尔存在宽松转换的可能，桥的元工具参数一律走原始 HTTP body + `StrictJSON`（CFGetTypeID 分型）严格解析，见 `BridgeMetaTools.strictArguments` 与 `StrictJSONTests`。

## 实测证据

- 全量绿：GitHub Actions `linux-tests` 运行 **36693326164**（2026-09-30，Swift 6.1 容器），结论 success，日志汇总 `Executed 83 tests, with 0 failures`——含 13 条原始 socket 协议探针、线级端到端全流程、会话工厂隔离与闲置回收、管家状态机（含取消/超时）、清洗器逐条规则、注册中心搜索/开关、服务商层对本地假服务器的组装与冷却。
- 分片定位运行：逻辑套件 36683160952（success）；探针 + 会话管理 36689284519（success）；第 8 条的诊断运行 36691324906 / 36691868402（如上）。
- `Package.resolved` 已与该次运行 CI 解析出的版本逐字节核对一致（swift-nio 精确 pin 2.103.0、swift-sdk 精确 pin 0.12.1）。
- 未核实项：官方 SDK Client 在 macOS/iOS 上与桥的互通（`HostEndToEndTests`，平台所限未在 Linux 跑）；真机行为一律不在本文件结论内。
