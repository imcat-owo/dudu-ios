import Foundation
import Combine

private let relayLog = AppLogger(category: "BridgeRelay")

// MARK: - 「桥」App 侧中继客户端（合并第 18(a) 条）
//
// 职责：按中继协议 v1（帧定义见 BridgeRelayProtocol.swift，一字未改）
// 把手机挂到 Cloudflare 中继后面：
//   连上 → 发 hello → 每 25s 发 ping → 收到 req 帧就把请求照搬打到
//   本地 MCP 对外服务（http://127.0.0.1:<port>/mcp），完整响应拼好后
//   以 res 帧回给中继；本地失败回 err 帧。
// 断线指数退避重连（2s→60s，RelayBackoff）；用户关开关即停、不再重连。
//
// 隔离方式与仓内同类单例一致（BackgroundKeepAliveManager / MCPStore）：
// @MainActor 统管全部状态；WS delegate 方法标 nonisolated（协议要求），
// 回调里只抓不可变快照、再 Task hop 回主 actor 改状态（Swift 6 语言
// 模式下隔离方法不能直接满足 nonisolated 的协议要求，必须这样写）；
// 真正阻塞的活（收帧等待、本地转发）放进 detached Task，回来时靠
// generation 代次号挡掉过期连接的迟到回调，不用锁。
//
// 安全口径：
//   - 口令只从钥匙串读（BridgeRelayTokenStore），拼进连接 URL 后
//     绝不进日志、不进报错文案、不进界面默认展示（日志只出现脱敏 host）。
//   - 中继地址只存 UserDefaults（BridgeRelayPreferences），同样不打日志原文。
//
// 「口令错误」的判定：协议 v1 没有定义口令错误帧，靠传输层信号——
//   中继以 WS 关闭码 4401/4403 拒绝，或握手 HTTP 401/403。
//   命中后停在 .authError 不再自动重连（拿错口令重试一万次也不会对），
//   等用户改完口令重新开开关 / 提交口令时再试。此约定需 CF 侧对齐，
//   已在回执中标注。

@MainActor
final class BridgeRelayClient: NSObject, ObservableObject {
    static let shared = BridgeRelayClient()

    /// 对外状态机（协议约定四态＋一个启动态）。界面状态行直接映射这些态。
    enum ConnectionState: Equatable {
        case offline
        /// 用户-P2-6：钥匙串暂不可读 / 启动中——不是口令错，稍后自动重试，
        /// 界面显示"启动中"而不是红色"口令错误"。
        case starting
        case connecting
        case online
        case authError
    }

    @Published private(set) var state: ConnectionState = .offline
    /// 用户开关的当前值（持久化在 UserDefaults）。用 setEnabled(_:) 改，
    /// 不要直接写这个属性——那样不会驱动连接/断开。
    @Published private(set) var isEnabled: Bool = false

    private var socket: URLSessionWebSocketTask?
    /// 连接代次：每次新建/拆毁连接都 +1。detached Task 回主线程汇报时
    /// 先对代次，过期的一律忽略——防旧连接的迟到回调搅乱新连接状态。
    private var generation = 0
    /// 握手被 HTTP 401/403 拒时由 delegate 记下，供掉线处理时归类口令错误。
    private var handshakeAuthRejected = false

    private var backoff = RelayBackoff()
    /// 口令换新标记：设置页 rotateToken 置起。换新后 CF 侧 RELAY_TOKEN
    /// 还没更新前，中继必然用 4401/401/403 拒绝新口令——这是换新中途
    /// 的必然阶段，不是口令配错，所以这期间的拒绝不进永久 .authError，
    /// 而是走 .starting＋退避重试，等她在 CF 更新完自动连上。
    /// 清标记：连上（handleDidOpen）、手动改口令/手动开关中继（reconnect/
    /// setEnabled/stopAll）、30 分钟超时兜底（expireTokenRotation）。
    private var tokenRotationPending = false
    /// 换新超时兜底计时器：30 分钟还没连上就清标记、按正常口令错误停，
    /// 防的是她一直没去 CF 更新导致无限重试。
    private var rotationTimeoutTask: Task<Void, Never>?
    /// 请求去重台账（五-1）：按 req 编号记「处理中 / 已完成＋响应帧」。
    /// 跨连接代次存活（编号本身就是幂等键，换连接不换账），
    /// 有界淘汰在台账内部。线程安全（内部加锁），detached 转发
    /// 任务可直接用，不必 hop 回主 actor 查账。
    private let requestLedger = RelayRequestLedger()
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private lazy var webSocketSession: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    /// 本地转发专用 session：不落缓存，超时给足（MCP 工具调用可能慢；
    /// SSE 长流靠 timeoutIntervalForResource 兜底）。URLSession 本身
    /// 线程安全，做成类型级单例供 detached 转发任务直接取用。
    private static let localSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    private override init() {
        super.init()
        isEnabled = BridgeRelayPreferences.relayEnabled
        syncKeepAliveDemand()
    }

    /// PM-P1-2：把中继连接注册成保活要保的对象——开关开着就保，
    /// 不管有没有聊天会话。关开关 / App 侧停掉时撤回。
    private func syncKeepAliveDemand() {
        BackgroundKeepAliveManager.shared.relayKeepAliveNeeded = isEnabled
    }

    // MARK: - 对外开关与生命周期

    /// 设置页开关入口：持久化后期望状态，开→连，关→停（且不再重连）。
    /// 手动开关中继时清掉"换新中"标记——用户亲自接管了，就不再按
    /// 换新语义宽限口令拒绝（见 beginTokenRotation）。
    func setEnabled(_ on: Bool) {
        clearTokenRotation()
        BridgeRelayPreferences.relayEnabled = on
        isEnabled = on
        syncKeepAliveDemand()
        if on {
            startConnecting()
        } else {
            stopAll()
        }
    }

    /// 主动连接（开关已开时调用；重复调用无副作用）。
    func connect() {
        startConnecting()
    }

    /// 主动断开并停止一切重连（不改持久化的开关值，setEnabled 负责那部分）。
    func disconnect() {
        stopAll()
    }

    /// 配置变了（地址/口令改完提交）时调用：开着就用新配置重连，
    /// 停在口令错误时也借此再试一次；关着则什么都不做。
    /// 手动改配置时清掉"换新中"标记（见 setEnabled 注释）。
    func reconnect() {
        clearTokenRotation()
        guard isEnabled else { return }
        teardownSocket()
        startConnecting()
    }

    /// 口令换新入口（设置页 rotateToken 调）：置"换新中"标记＋断开
    /// 旧通道用新口令重连。标记起效期间，4401/4403/401/403 不进
    /// 永久 .authError，而是 .starting＋退避重试——CF 侧更新完立刻
    /// 自动连上，不用她手动开关中继。
    func beginTokenRotation() {
        tokenRotationPending = true
        armRotationTimeout()
        guard isEnabled else { return }
        teardownSocket()
        startConnecting()
    }

    /// 清"换新中"标记＋掐掉超时计时器。手动改口令、手动开关中继时
    /// 调用——用户亲自接管后不再按换新语义宽限。
    private func clearTokenRotation() {
        tokenRotationPending = false
        rotationTimeoutTask?.cancel()
        rotationTimeoutTask = nil
    }

    /// 30 分钟超时兜底计时器。超时时若还没连上：清标记、停掉退避、
    /// 按正常口令错误停（大概率她忘了去 CF 更新，不许无限重试）。
    private func armRotationTimeout() {
        rotationTimeoutTask?.cancel()
        rotationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.expireTokenRotation()
        }
    }

    private func expireTokenRotation() {
        guard tokenRotationPending else { return }
        clearTokenRotation()
        // P2-6 的 .starting 是钥匙串暂不可读（标记为 false），和换新
        // 场景互斥；能到这里的 .starting 就是换新重试中。把它停成
        // 正常口令错误，让她去对口令。
        if isEnabled, state == .starting {
            reconnectTask?.cancel()
            reconnectTask = nil
            relayLog.error("relay token rotation timed out without reconnect; treating as auth error")
            publish(.authError)
        }
    }

    /// 用户-P2-6：可恢复的失败（钥匙串暂不可读）按退避稍后自动重试。
    /// 关开关 / stopAll 会取消这个待重试任务；连上后退避清零（见 handleDidOpen）。
    private func scheduleRetry() {
        reconnectTask?.cancel()
        let delay = backoff.nextDelay()
        relayLog.info("relay retrying in \(Int(delay))s")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // 先自清再发起——startConnecting 以「无待重连任务」为前提。
            self.reconnectTask = nil
            self.startConnecting()
        }
    }

    /// 设置页出现时调用：把持久化的开关值同步进来，开着且离线就连上。
    func restoreFromPreferences() {
        isEnabled = BridgeRelayPreferences.relayEnabled
        syncKeepAliveDemand()
        if isEnabled, state == .offline {
            startConnecting()
        }
    }

    /// App 冷启动接线（五-2）：MinisApp 启动时调一次，按上次保存的
    /// 两个开关恢复现场，不必等用户打开「桥·对外连接」设置页：
    /// 对外服务开关（externalMCPEnabled）或中继开关（relayEnabled）
    /// 任一开着，就先把本地对外服务补起来（中继转发靠它干活）；
    /// 然后中继按它自己的开关恢复连接。两步都幂等，重复调用无
    /// 副作用；本地服务补起失败不拦中继连接（转发路径自己会再拉）。
    func restoreOnLaunch() {
        if BridgeRelayPreferences.externalMCPEnabled || BridgeRelayPreferences.relayEnabled,
           !BridgeExternalMCPService.shared.isRunning {
            do {
                try BridgeExternalMCPService.shared.ensureRunning()
            } catch {
                relayLog.error("relay launch restore: local MCP service failed to start: \(error.localizedDescription)")
            }
        }
        restoreFromPreferences()
    }

    // MARK: - 连接状态机（@MainActor 内执行）

    private func startConnecting() {
        guard isEnabled else { return }
        // 已在连/在线就不重复发起；退避中的重连任务由它自己的闭包
        // 先自清 reconnectTask 再走进来（见 handleConnectionLost），
        // 这里统一把残留的待重连任务取消掉防双发。
        guard socket == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        publish(.connecting)

        // 用户-P2-6：区分"没配口令"和"钥匙串暂不可读"。后者不是口令错，
        // 显示"启动中"并按退避自动重试——别让她去改一个没错的口令。
        let token: String
        switch BridgeRelayTokenStore.loadDetailed() {
        case .configured(let t):
            token = t
        case .notConfigured:
            // 没填口令：连上去也必然被拒，直接落口令错误，停。
            relayLog.error("relay token missing in keychain; not connecting")
            publish(.authError)
            return
        case .readFailed:
            relayLog.warning("relay token keychain temporarily unreadable; will retry")
            publish(.starting)
            scheduleRetry()
            return
        }
        let host = BridgeRelayPreferences.host
        guard let url = RelayEndpoint.deviceURL(host: host, token: token) else {
            // 地址没填/不合法：离线停住，等用户在设置页补齐（日志只记脱敏值）。
            relayLog.error("relay host not configured or invalid (host=\(RelayEndpoint.maskedHost(host)))")
            publish(.offline)
            return
        }

        generation += 1
        let gen = generation
        handshakeAuthRejected = false
        let task = webSocketSession.webSocketTask(with: url)
        socket = task

        relayLog.info("relay connecting (host=\(RelayEndpoint.maskedHost(host)))")
        task.resume()
        startReceiveLoop(task: task, generation: gen)
    }

    /// hello 发出且成功后才算正式在线（在 didOpen 回调里调）。
    private func handleDidOpen(generation gen: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.send(frame: .hello, generation: gen)
                // await 期间连接可能已被换掉，对完代次才许落在线。
                guard self.generation == gen, self.state == .connecting else { return }
                self.backoff.reset()
                // 口令换新成功：CF 侧已认新口令，清"换新中"标记。
                self.clearTokenRotation()
                self.publish(.online)
                relayLog.info("relay online")
                self.startPingLoop(generation: gen)
            } catch {
                self.handleConnectionLost(generation: gen, closeCode: nil)
            }
        }
    }

    private func startPingLoop(generation gen: Int) {
        pingTask?.cancel()
        pingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(RelayFrame.pingInterval * 1_000_000_000))
                    guard let self else { return }
                    try await self.send(frame: .ping, generation: gen)
                } catch {
                    break // 发送失败/被取消：掉线处理由收帧循环统一归口，这里只停心跳。
                }
            }
        }
    }

    private func startReceiveLoop(task: URLSessionWebSocketTask, generation gen: Int) {
        receiveTask?.cancel()
        receiveTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        self?.handleIncomingText(text, generation: gen)
                    case .data:
                        // 协议帧都是 JSON 文本；二进制帧不在协议内，忽略但记一笔。
                        relayLog.warning("relay received unexpected binary frame; ignored")
                    @unknown default:
                        break
                    }
                } catch {
                    await self?.handleConnectionLost(generation: gen, closeCode: task.closeCode)
                    return
                }
            }
        }
    }

    /// 在 detached 收帧任务里跑：只做纯解码与分发，不碰 @Published。
    private nonisolated func handleIncomingText(_ text: String, generation gen: Int) {
        let frame: RelayFrame
        do {
            frame = try RelayFrame.decode(text)
        } catch {
            // 只记错误类型，不记帧原文（body 可能含用户数据）。
            relayLog.warning("relay frame decode failed: \(error)")
            return
        }
        switch frame {
        case .request(let id, let headers, let bodyBase64):
            // 五-1 去重：同号重投不许让手机干第二遍活。还在处理中的
            // 直接丢弃（第一份的响应会正常回去）；已处理完的把上次
            // 响应按原编号回放；只有新号才真正转发到本地服务。
            switch requestLedger.begin(id: id) {
            case .newRequest:
                Task.detached { [weak self] in
                    await self?.forwardToLocalMCP(id: id, headers: headers, bodyBase64: bodyBase64, generation: gen)
                }
            case .duplicateInFlight:
                relayLog.warning("relay dropped duplicate in-flight req id=\(id)")
            case .replay(let cachedFrame):
                relayLog.info("relay replaying cached response for duplicate req id=\(id)")
                Task.detached { [weak self] in
                    // 回放失败（连接又换了）也不再补 err：帧还在台账里，
                    // 下次同号重投会再回放一次。
                    try? await self?.send(frame: cachedFrame, generation: gen)
                }
            }
        case .hello, .ping, .response, .error:
            // 这四种是手机→中继方向的帧，中继不该发回来；收到只记日志不断开。
            relayLog.warning("relay received outbound-direction frame; ignored")
        }
    }

    /// 连接丢失：归类口令错误则停；否则按退避重连。
    private func handleConnectionLost(generation gen: Int, closeCode: URLSessionWebSocketTask.CloseCode?) {
        guard gen == generation else { return }
        // 拆 socket 之前先把口令被拒的证据取全：delegate 记下的标志 +
        // 失败握手留在 task.response 上的 HTTP 状态（同步读，无竞态）。
        let handshakeStatus = (socket?.response as? HTTPURLResponse)?.statusCode
        let authRejected = handshakeAuthRejected || handshakeStatus == 401 || handshakeStatus == 403
        teardownSocket()

        let code = closeCode?.rawValue ?? 0
        if authRejected || code == 4401 || code == 4403 {
            // 口令换新中：CF 侧还没更新到新口令，拒绝是必然阶段——
            // 不进永久 .authError，走 .starting＋退避重试（和 P2-6 的
            // 钥匙串暂不可读同一套），CF 更新完立刻自动连上。
            // 非换新场景的口令拒绝：照常停在 .authError 不再重试。
            if tokenRotationPending {
                relayLog.warning("relay rejected during token rotation (closeCode=\(code)); retrying with backoff")
                publish(.starting)
                scheduleRetry()
                return
            }
            relayLog.error("relay rejected credentials (closeCode=\(code)); stopping until token is fixed")
            publish(.authError)
            return
        }
        guard isEnabled else {
            publish(.offline)
            return
        }
        let delay = backoff.nextDelay()
        relayLog.warning("relay connection lost; reconnecting in \(Int(delay))s")
        publish(.connecting)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // 先自清再发起——startConnecting 以「无待重连任务」为前提。
            self.reconnectTask = nil
            self.startConnecting()
        }
    }

    /// 用户关开关 / 主动断开：拆掉一切，落离线，退避清零，
    /// 顺带清"换新中"标记（见 setEnabled 注释）。
    private func stopAll() {
        clearTokenRotation()
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownSocket()
        backoff.reset()
        publish(.offline)
    }

    private func teardownSocket() {
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        generation += 1 // 让在途的收发 Task 全部过期
        let task = socket
        socket = nil
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - 发帧

    /// 代次不匹配（连接已被新连接取代）时抛错，让调用方自然收尾。
    private enum SendError: Error { case staleConnection }

    private func send(frame: RelayFrame, generation gen: Int) async throws {
        let text = try frame.encode()
        guard gen == generation, let task = socket else { throw SendError.staleConnection }
        try await task.send(.string(text))
    }

    /// 在当前连接上发一帧，代次在调用瞬间（主 actor 上）取最新值。
    /// 给「请求到达后连接被换过」的转发收尾补发用：中继按帧编号认
    /// 响应、不认是哪条连接送来的（pending 表按编号索引），所以把
    /// 已记账的响应送上当前连接，重投挂在中继那头的等待者立刻能
    /// 拿到，不必等它超时后再投一次才触发台账回放。
    private func sendOnCurrentConnection(frame: RelayFrame) async throws {
        try await send(frame: frame, generation: generation)
    }

    // MARK: - 本地转发（req → 127.0.0.1:<port>/mcp → res/err）

    private enum LocalForwardError: Error {
        case serviceUnavailable
        case nonHTTPResponse
        var message: String {
            switch self {
            case .serviceUnavailable: return "local MCP service unavailable"
            case .nonHTTPResponse: return "local MCP service returned a non-HTTP response"
            }
        }
    }

    /// 在 detached 任务里跑：网络等待不占主线程；只有最后发帧时
    /// 经 send() 回 @MainActor 对代次、取 socket。
    /// 产出的响应帧（res / err 都算）先记进，去重台账再发送——发送途中
    /// 连接被换掉也不丢帧，同号重投时台账会把这一帧回放出去（五-1）。
    /// 因此发送失败不再补发 err 帧：活已经干完，补 err 只会让中继
    /// 把「其实成功了」误报成失败，回放才是正解。
    /// 一个时序补丁（s2-r1fix）：请求到达后连接被换掉、本地活还没
    /// 干完时，中继会在新连接上同号重投，台账按「处理中」把重投丢弃
    /// （对——活只干一遍）；等活干完，原代次发送必然过期。若就这样
    /// 静默收尾，响应只能躺在台账里等中继那头超时后再投第三次才被
    /// 回放，调用方白等一整轮中继超时。所以原代次发送因过期失败时，
    /// 在当前连接把这份已记账的响应补发一次：中继按编号认响应，
    /// 挂在新连接背后的等待者立刻能拿到。补发再失败（新连接也断了）
    /// 就收尾，帧在账里，下次同号重投照常回放。补发的是原响应帧
    /// 本身，不是新编的 err 帧，「干成的活不许误报失败」不变。
    private nonisolated func forwardToLocalMCP(id: String, headers: [String: String], bodyBase64: String, generation gen: Int) async {
        let frame: RelayFrame
        do {
            let (status, responseHeaders, body) = try await Self.performLocalRequest(headers: headers, bodyBase64: bodyBase64)
            frame = RelayFrame.response(
                id: id,
                status: status,
                headers: RelayHeaderFilter.headersForRelayResponse(responseHeaders),
                bodyBase64: body.base64EncodedString())
        } catch let error as LocalForwardError {
            relayLog.warning("relay forward failed for req id=\(id): \(error.message)")
            frame = .error(id: id, message: error.message)
        } catch {
            // URLError 等：文案只带系统错误描述，不带任何 URL/口令。
            let message = "local request failed: \(error.localizedDescription)"
            relayLog.warning("relay forward failed for req id=\(id): \(message)")
            frame = .error(id: id, message: message)
        }
        requestLedger.complete(id: id, frame: frame)
        do {
            try await send(frame: frame, generation: gen)
        } catch is SendError {
            // 连接已被新连接取代，原代次发不出去（s2-r1fix）：帧已
            // 入账，在当前连接补发一次原帧，让新连接上同号重投的
            // 等待者直接拿到，别白等一轮中继超时。补发再失败就
            // 靠台账回放兜底（下次同号重投），只记一笔。
            do {
                try await sendOnCurrentConnection(frame: frame)
                relayLog.info("relay response for req id=\(id) delivered on current connection after reconnect")
            } catch {
                relayLog.warning("relay response resend on current connection failed for req id=\(id): \(error.localizedDescription)")
            }
        } catch {
            // 其他发送失败同样靠台账回放兜底（帧已入账），只记一笔。
            relayLog.warning("relay response send failed for req id=\(id): \(error.localizedDescription)")
        }
    }

    /// 把 req 照搬打到本地 MCP 服务，等完整响应。
    /// SSE（text/event-stream）流逐字节拼接：流自然结束即完整；
    /// 若流中先出现 JSON-RPC 响应事件（带 result/error 的那条），
    /// 视为该请求已答完，提前收尾——防的是服务器答完后挂着长流不关，
    /// 让中继那头干等到超时。
    private nonisolated static func performLocalRequest(headers: [String: String], bodyBase64: String) async throws -> (status: Int, headers: [String: String], body: Data) {
        let service = BridgeExternalMCPService.shared
        if !service.isRunning {
            try service.ensureRunning()
        }
        guard let port = service.boundPort else {
            throw LocalForwardError.serviceUnavailable
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        for (key, value) in RelayHeaderFilter.headersForLocalRequest(headers) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = Data(base64Encoded: bodyBase64) ?? Data()

        let (bytes, response) = try await localSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalForwardError.nonHTTPResponse
        }
        var headerDict: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let stringValue = value as? String {
                headerDict[String(describing: key)] = stringValue
            }
        }

        let isEventStream = (http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream")) ?? false
        // 统一逐字节收进 [UInt8]（Data 没有单字节 append API），最后一次成型。
        var byteBuffer: [UInt8] = []
        byteBuffer.reserveCapacity(16 * 1024)
        if !isEventStream {
            for try await byte in bytes {
                byteBuffer.append(byte)
            }
            return (http.statusCode, headerDict, Data(byteBuffer))
        }

        // SSE：按事件边界（空行）切分，边拼边看有没有 JSON-RPC 响应事件。
        var eventBuffer: [UInt8] = []
        for try await byte in bytes {
            byteBuffer.append(byte)
            eventBuffer.append(byte)
            guard byte == 0x0A else { continue }
            let endsWithBlankLine = eventBuffer.count >= 2
                && (Array(eventBuffer.suffix(2)) == [0x0A, 0x0A]
                    || Array(eventBuffer.suffix(4)) == [0x0D, 0x0A, 0x0D, 0x0A])
            guard endsWithBlankLine else { continue }
            if sseEventIsJSONRPCResponse(Data(eventBuffer)) {
                break
            }
            eventBuffer.removeAll(keepingCapacity: true)
        }
        return (http.statusCode, headerDict, Data(byteBuffer))
    }

    /// 判断一个完整 SSE 事件的 data 是否是 JSON-RPC 响应（含 result 或 error）。
    private nonisolated static func sseEventIsJSONRPCResponse(_ eventData: Data) -> Bool {
        guard let text = String(data: eventData, encoding: .utf8) else { return false }
        var payload = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("data:") {
                payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["result"] != nil || object["error"] != nil
    }

    // MARK: - 状态发布

    private func publish(_ newState: ConnectionState) {
        if state != newState { state = newState }
    }
}

// MARK: - URLSessionWebSocketDelegate（口令错误信号采集）
//
// delegate 方法是协议的 nonisolated 要求：方法体只做不可变快照，
// 状态判断一律 hop 回 @MainActor 做。回调来自 URLSession 的串行
// delegate 队列，hop 后的先后顺序与回调顺序一致。

extension BridgeRelayClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.socket else { return }
            self.handleDidOpen(generation: self.generation)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self, webSocketTask === self.socket else { return }
            // 我们自己 teardown 的关闭代次已被推进，handleConnectionLost
            // 里的代次校验会挡掉；走到里面的都是服务器侧异常关闭。
            self.handleConnectionLost(generation: self.generation, closeCode: closeCode)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        // 握手被拒（HTTP 401/403）时 WS 任务以错误结束、且 task.response
        // 留着那次响应——记下来，掉线处理时据此归类口令错误
        // （handleConnectionLost 也会同步直读 socket.response，这里是双保险）。
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor [weak self] in
            guard let self, task === self.socket,
                  statusCode == 401 || statusCode == 403 else { return }
            self.handshakeAuthRejected = true
        }
    }
}
