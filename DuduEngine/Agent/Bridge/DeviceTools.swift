import Foundation
import BridgeCore

/// 设备能力工具组（合并第 19 条）：把 OpenMinis 已有的 apple-* 能力
/// 注册进桥的工具注册中心，对外经「搜」「命令」调度。
///
/// 一项能力一个文件（BluetoothDeviceTool / PhotosDeviceTool /
/// LocationDeviceTool / NotificationDeviceTool / ClipboardDeviceTool），
/// 每个文件的 `register(into:)` 照 FakeTools 的声明格式写；
/// 执行统一走 OffloadToolRunner 落到 NativeOffloads 的现成实现。
enum DeviceTools {
    /// 全部工具注册名：重试注册前先逐个注销已注册的，避免"上次注册到一半
    /// 失败"时 duplicateName 把重试堵死（unregister 不存在的名直接返回 false）。
    static let toolNames: [String] = [
        ClipboardDeviceTool.toolName,
        ClipboardDeviceTool.readToolName,
        LocationDeviceTool.toolName,
        LocationDeviceTool.currentToolName,
        NotificationDeviceTool.toolName,
        NotificationDeviceTool.scheduleToolName,
        PhotosDeviceTool.toolName,
        PhotosDeviceTool.writeToolName,
        PhotosDeviceTool.deleteToolName,
        BluetoothDeviceTool.toolName,
    ]

    static func registerAll(into registry: ToolRegistry) async throws {
        try await ClipboardDeviceTool.register(into: registry)
        try await LocationDeviceTool.register(into: registry)
        try await NotificationDeviceTool.register(into: registry)
        try await PhotosDeviceTool.register(into: registry)
        try await BluetoothDeviceTool.register(into: registry)
    }
}
