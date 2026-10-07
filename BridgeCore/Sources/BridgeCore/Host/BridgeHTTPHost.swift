import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix

/// 桥的薄 HTTP 宿主：只做「监听 + 字节搬运」，不碰协议本体。
///
/// - 默认监听 127.0.0.1（本机模式）；端口 0 = 系统分配，实际端口读 `boundPort`；
/// - 请求聚合后转成 SDK 的 `HTTPRequest` 交给会话管理器路由；
/// - 响应写回全走 `channel.eventLoop.execute`（任务书 §7 铁律，不在 event loop
///   外碰 channel）；SSE 流逐块写、看 `isWritable` 做背压、客户端断开即取消
///   流消费并回收；处理任务用普通 Task，绝不 @MainActor。
public final class BridgeHTTPHost: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var endpoint: String

        public init(host: String = "127.0.0.1", port: Int = 0, endpoint: String = "/mcp") {
            self.host = host
            self.port = port
            self.endpoint = endpoint
        }
    }

    public enum HostError: Error, CustomStringConvertible {
        case alreadyStarted
        case bindFailed(String)

        public var description: String {
            switch self {
            case .alreadyStarted: return "宿主已在运行"
            case .bindFailed(let detail): return "监听绑定失败：\(detail)"
            }
        }
    }

    private let configuration: Configuration
    private let sessionManager: MCPSessionManager
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let stateLock = NSLock()

    /// 实际绑定到的端口（start 后有效；配置端口为 0 时这是唯一真值）。
    public private(set) var boundPort: Int?

    public init(configuration: Configuration = Configuration(), sessionManager: MCPSessionManager) {
        self.configuration = configuration
        self.sessionManager = sessionManager
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard channel == nil else { throw HostError.alreadyStarted }
        let manager = sessionManager
        let endpoint = configuration.endpoint
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 128)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(
                        BridgeHTTPHandler(sessionManager: manager, endpoint: endpoint))
                }
            }
        do {
            let bound = try bootstrap.bind(host: configuration.host, port: configuration.port).wait()
            channel = bound
            boundPort = bound.localAddress?.port
        } catch {
            throw HostError.bindFailed("\(error)")
        }
    }

    public func stop() {
        stateLock.lock()
        let bound = channel
        channel = nil
        stateLock.unlock()
        try? bound?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

/// 每连接一个的请求处理器。同一连接上的响应严格串行（一台在写完前
/// 后到的请求先排队），避免 SSE 流与后续响应在同一 channel 上交错写坏帧。
private final class BridgeHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let sessionManager: MCPSessionManager
    private let endpoint: String

    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBuffer()
    private var pending: [(head: HTTPRequestHead, body: ByteBuffer)] = []
    private var responseInFlight = false
    private var streamingTask: Task<Void, Never>?
    private var writeWaiter: CheckedContinuation<Void, Never>?

    init(sessionManager: MCPSessionManager, endpoint: String) {
        self.sessionManager = sessionManager
        self.endpoint = endpoint
    }

    // MARK: - 入站

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            requestBody.clear()
        case .body(var chunk):
            requestBody.writeBuffer(&chunk)
        case .end:
            guard let head = requestHead else {
                context.close(promise: nil)
                return
            }
            requestHead = nil
            let body = requestBody
            requestBody.clear()
            pending.append((head: head, body: body))
            drainPending(on: context.channel)
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            resumeWriteWaiter()
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        streamingTask?.cancel()
        resumeWriteWaiter()
        pending.removeAll()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        streamingTask?.cancel()
        resumeWriteWaiter()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        streamingTask?.cancel()
        context.close(promise: nil)
    }

    // MARK: - 派发

    private func drainPending(on channel: Channel) {
        guard !responseInFlight, let next = pending.first else { return }
        pending.removeFirst()
        responseInFlight = true
        let (head, body) = next

        guard Self.pathOnly(head.uri) == endpoint else {
            write(
                response: .error(
                    statusCode: 404,
                    MCPError.invalidRequest("Not Found: endpoint is \(endpoint)")),
                on: channel)
            return
        }

        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = value
        }
        let bodyBytes = body.getBytes(at: body.readerIndex, length: body.readableBytes)
        let request = HTTPRequest(
            method: head.method.rawValue,
            headers: headers,
            body: bodyBytes.map { Data($0) },
            path: Self.pathOnly(head.uri))
        let manager = sessionManager
        Task {
            let response = await manager.handle(request: request)
            self.write(response: response, on: channel)
        }
    }

    // MARK: - 写回（全部经 eventLoop.execute）

    private func write(response: HTTPResponse, on channel: Channel) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        let status = HTTPResponseStatus(statusCode: response.statusCode)

        switch response {
        case .stream(let stream, _):
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            channel.eventLoop.execute {
                channel.write(self.wrapOutboundOut(.head(head)), promise: nil)
                channel.flush()
            }
            streamingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        await self.writeChunk(chunk, on: channel)
                    }
                } catch {
                    // 流中途出错：没有别的通道可报错，结束响应即信号，不假装成功。
                }
                self.completeResponse(on: channel, writeEnd: true)
            }

        default:
            var bodyBuffer: ByteBuffer?
            if let data = response.bodyData {
                var buffer = channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                bodyBuffer = buffer
                if !headers.contains(name: "content-length") {
                    headers.add(name: "content-length", value: "\(data.count)")
                }
            } else if !headers.contains(name: "content-length") {
                headers.add(name: "content-length", value: "0")
            }
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            let body = bodyBuffer
            channel.eventLoop.execute {
                channel.write(self.wrapOutboundOut(.head(head)), promise: nil)
                if let body {
                    channel.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
                }
                channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
            completeResponse(on: channel, writeEnd: false)
        }
    }

    /// 写一块 SSE 数据并等背压放行：channel 不可写时挂起，
    /// 由 writabilityChanged / 连接断开 / 任务取消三条路之一唤醒。
    private func writeChunk(_ data: Data, on channel: Channel) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                channel.eventLoop.execute {
                    var buffer = channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    channel.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    channel.flush()
                    if channel.isWritable {
                        continuation.resume()
                    } else {
                        self.writeWaiter = continuation
                    }
                }
            }
        } onCancel: {
            channel.eventLoop.execute {
                self.resumeWriteWaiter()
            }
        }
    }

    private func completeResponse(on channel: Channel, writeEnd: Bool) {
        if writeEnd {
            channel.eventLoop.execute {
                channel.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
        streamingTask = nil
        responseInFlight = false
        drainPending(on: channel)
    }

    private func resumeWriteWaiter() {
        let waiter = writeWaiter
        writeWaiter = nil
        waiter?.resume()
    }

    private static func pathOnly(_ uri: String) -> String {
        if let index = uri.firstIndex(of: "?") {
            return String(uri[..<index])
        }
        return uri
    }
}
