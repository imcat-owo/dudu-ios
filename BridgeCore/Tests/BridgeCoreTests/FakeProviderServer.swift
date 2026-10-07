import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// 进程内假服务商服务器（NIO）：记下收到的每个请求（方法/路径/头/体），
/// 按预设回状态码与响应体。用它验客户端的请求组装与错误透传，不连任何外网。
final class FakeProviderServer: @unchecked Sendable {
    struct RecordedRequest: Sendable {
        var method: String
        var uri: String
        var headers: [(String, String)]
        var body: String

        func header(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [RecordedRequest] = []
        private var status = 200
        private var body = ""

        func record(_ request: RecordedRequest) {
            lock.lock()
            recorded.append(request)
            lock.unlock()
        }

        func setResponse(status: Int, body: String) {
            lock.lock()
            self.status = status
            self.body = body
            lock.unlock()
        }

        func response() -> (Int, String) {
            lock.lock()
            defer { lock.unlock() }
            return (status, body)
        }

        func allRequests() -> [RecordedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    private let state = State()
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?

    func setResponse(status: Int, body: String) {
        state.setResponse(status: status, body: body)
    }

    var requests: [RecordedRequest] {
        state.allRequests()
    }

    func start() throws -> Int {
        let state = self.state
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 16)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(FakeProviderHandler(state: state))
                }
            }
        let bound = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        channel = bound
        guard let port = bound.localAddress?.port else {
            throw NSError(
                domain: "FakeProviderServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "绑定后拿不到端口"])
        }
        return port
    }

    func stop() {
        try? channel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

private final class FakeProviderHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let state: FakeProviderServer.State
    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBuffer()

    init(state: FakeProviderServer.State) {
        self.state = state
    }

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
            state.record(
                FakeProviderServer.RecordedRequest(
                    method: head.method.rawValue,
                    uri: head.uri,
                    headers: head.headers.map { ($0.name, $0.value) },
                    body: String(buffer: requestBody)))
            let (status, responseBody) = state.response()
            var buffer = context.channel.allocator.buffer(capacity: responseBody.utf8.count)
            buffer.writeString(responseBody)
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: "\(buffer.readableBytes)")
            headers.add(name: "connection", value: "close")
            let responseHead = HTTPResponseHead(
                version: .http1_1,
                status: HTTPResponseStatus(statusCode: status),
                headers: headers)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
