import UIKit
import BridgeCore

/// 小管家敏感工具的手机侧审批门（用户-P1：敏感放行只能由手机侧签发）。
///
/// - App 在前台：走主线程弹系统 Alert，等主人点「允许」/「拒绝」；
///   120 秒超时未点默认拒绝。
/// - App 不在前台（弹不出框）：直接按「主人不在」拒绝，不排队、不等待。
///
/// Steward 是串行调度的，同一时间最多只有一个审批在等，
/// 所以这里不用排队，一次只管一个 Alert。
///
/// 为什么不用 ToolApprovalDialog：那个 sheet 只挂在聊天流
/// （tag == "tool-approval"），steward 路径是外部 AI 触发的后台任务，
/// 聊天页不一定在前台；且 ToolSuspensionService 是 App 侧类，
/// BridgeCore 内核调不到。这里另起一条手机侧签发路径。
final class StewardSensitiveApprovalGate: SensitiveApprovalGate, Sendable {
    /// 审批超时秒数：超时未点默认拒绝。审查员复核点。
    static let approvalTimeout: TimeInterval = 120

    // 协议见证：签名必须与 SensitiveApprovalGate 一字不差（多一个默认参数
    // 也不算数），BridgeCore 的 Steward 经此调，caller 默认"外部 AI"。
    func requestApproval(toolName: String, instruction: String) async -> SensitiveApprovalDecision {
        await requestApproval(toolName: toolName, instruction: instruction, caller: "外部 AI")
    }

    /// 对话侧调这个：弹框文案写明是"对话 AI"在请示，不张冠李戴。
    func requestApproval(toolName: String, instruction: String, caller: String) async -> SensitiveApprovalDecision {
        let isActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isActive else { return .ownerAway }
        return await waitForOwnerDecision(toolName: toolName, instruction: instruction, caller: caller)
    }

    private func waitForOwnerDecision(
        toolName: String, instruction: String, caller: String
    ) async -> SensitiveApprovalDecision {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    OwnerApprovalPresenter.shared.present(
                        toolName: toolName,
                        instruction: instruction,
                        caller: caller,
                        continuation: continuation)
                }
            }
        }, onCancel: {
            // 任务被取消（如主人打断）：按拒绝收尾，不让 continuation 泄漏。
            Task { @MainActor in
                OwnerApprovalPresenter.shared.cancelPendingAsDenied()
            }
        })
    }
}

/// 主线程的 Alert 呈现器：一次只管一个审批，超时/点按/取消都收敛到 settle。
@MainActor
private final class OwnerApprovalPresenter {
    static let shared = OwnerApprovalPresenter()

    private var currentAlert: UIAlertController?
    private var currentContinuation: CheckedContinuation<SensitiveApprovalDecision, Never>?
    private var timeoutTimer: Timer?
    private var settled = false

    func present(
        toolName: String,
        instruction: String,
        caller: String,
        continuation: CheckedContinuation<SensitiveApprovalDecision, Never>
    ) {
        guard let presenter = Self.topViewController() else {
            // 极端情况拿不到呈现方：按拒绝收尾，不卡住任务。
            continuation.resume(returning: .denied)
            return
        }
        settled = false
        currentContinuation = continuation
        let shortInstruction =
            instruction.count > 200 ? String(instruction.prefix(200)) + "…" : instruction
        let alert = UIAlertController(
            title: "小管家请求执行敏感操作",
            message: """
                \(caller)请小管家执行敏感工具「\(toolName)」。

                指令：\(shortInstruction)

                \(Int(StewardSensitiveApprovalGate.approvalTimeout)) 秒内未确认将默认拒绝。
                """,
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "允许", style: .default) { [weak self] _ in
                self?.settle(.approved)
            })
        alert.addAction(
            UIAlertAction(title: "拒绝", style: .destructive) { [weak self] _ in
                self?.settle(.denied)
            })
        currentAlert = alert
        presenter.present(alert, animated: true)
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: StewardSensitiveApprovalGate.approvalTimeout,
            repeats: false
        ) { [weak self] _ in self?.settle(.denied) }
    }

    func cancelPendingAsDenied() {
        settle(.denied)
    }

    private func settle(_ decision: SensitiveApprovalDecision) {
        guard !settled else { return }
        settled = true
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        currentAlert?.dismiss(animated: true)
        currentAlert = nil
        currentContinuation?.resume(returning: decision)
        currentContinuation = nil
    }

    /// 取 keyWindow 的 rootViewController（同 MCPOAuthController 的取法），
    /// 再钻到最上层已 present 的 VC，避免 "already presenting" 被静默吞掉。
    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
