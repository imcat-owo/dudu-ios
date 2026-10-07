import Foundation

/// 敏感工具的手机侧审批裁决。
///
/// 安全铁律：放行只能由手机侧签发。外部 AI 经「命令」传进来的任何标记
/// （如旧版 `sensitiveApproved` 参数）一律不认——内核里不再保留这类字段，
/// 免得将来有人又把它当凭证读。
public enum SensitiveApprovalDecision: Sendable {
    /// 主人在手机上点了允许。
    case approved
    /// 主人点了拒绝，或超时未点（默认拒绝）。
    case denied
    /// App 不在前台，弹不出框：直接拒绝，并回"主人未在手机旁"专属文案。
    case ownerAway
}

/// 敏感审批门：BridgeCore 只定义接口，实现由宿主 App 提供。
///
/// 弹框是 UIKit 的活，只能在 App 侧做，内核保持平台无关。
/// 没装门（nil）的 Steward 对敏感工具一律按拒绝处理——默认安全。
public protocol SensitiveApprovalGate: Sendable {
    /// 请主人在手机上确认是否执行敏感工具。
    /// - Parameters:
    ///   - toolName: 敏感工具名。
    ///   - instruction: 外部 AI 下达的原始指令（给主人看上下文）。
    /// - Returns: 主人的裁决；超时未点、App 在后台都按拒绝回。
    func requestApproval(toolName: String, instruction: String) async -> SensitiveApprovalDecision
}
