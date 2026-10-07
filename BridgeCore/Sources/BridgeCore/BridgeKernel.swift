import MCP

/// 「桥」内核门面。
///
/// 第 2 步（心脏）已落地：调度状态机（`Steward`）、工具注册中心
/// （`ToolRegistry`）、会话工厂（`MCPSessionManager`，一会话一 `Server`）、
/// 薄 NIO 宿主（`BridgeHTTPHost`）、对外两个元工具（`BridgeMetaTools` 的
/// 「搜」/「命令」）、服务商层（`Provider/`）都在本包内，平台无关、Linux CI 可测。
/// 传输只用 `StatefulHTTPServerTransport`，不用 Stateless（上游 #254/#255 未修，
/// 复核记录见 Docs/kernel-recheck-0.12.1.md）。
public enum BridgeKernel {
    /// App 显示名。
    public static let displayName = "桥"

    /// 内核依赖的 MCP Swift SDK 精确版本，与 Package.swift 中的 exact pin 保持一致。
    public static let sdkVersion = "0.12.1"

    /// 内核对外标识（用于 MCP Server 的 name 字段）。
    public static let serverName = "bridge"

    /// 桥自身的服务版本（用于 MCP Server 的 version 字段）。
    public static let serverVersion = "0.2.0"
}
