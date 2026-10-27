#if DEBUG
import Observation
import SwiftUI
import UIKit

/// 「刚启动第一次点进相簿没有推入动画」只在真机出现、模拟器复现不了（各种卡顿位置 / 按住时长都试过）。
/// 调试版记下每次点进相簿时：系统是否以动画推入（推入时的 transitionCoordinator）、导航栈深度、
/// 点按后 1.2s 内的掉帧、App 状态，以及启动 / 前后台 / 切 Tab 的时间点。
/// 显示在设置页「推入诊断」（截图即可），同时写到 Application Support/push-diagnostics.log
@MainActor
@Observable
final class PushDiagnostics {
    static let shared = PushDiagnostics()

    private(set) var lines: [String] = []

    @ObservationIgnored private let start = CACurrentMediaTime()
    @ObservationIgnored private var monitor: DebugDisplayLink?
    @ObservationIgnored private var gaps: [Int] = []
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored private let fileURL: URL? = {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("push-diagnostics.log")
    }()

    private init() {
        if let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = Array(text.split(separator: "\n").map(String.init).suffix(60))
        }
        note("—— 启动")
    }

    func note(_ text: String) {
        let elapsed = CACurrentMediaTime() - start
        let line = String(format: "%@ +%.2fs %@",
                          Date().formatted(date: .omitted, time: .standard), elapsed, text)
        print("PUSH_DIAG \(line)")
        lines.append(line)
        if lines.count > 60 {
            lines.removeFirst(lines.count - 60)
        }
        if let fileURL {
            try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// 点按相簿：记录并开始统计之后 1.2s 的掉帧
    func albumTapped(_ name: String) {
        note("点相簿「\(name)」")
        monitor?.stop()
        gaps = []
        lastFrame = CACurrentMediaTime()
        let monitor = DebugDisplayLink { [weak self] _ in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if now - self.lastFrame > 0.025 {
                self.gaps.append(Int((now - self.lastFrame) * 1000))
            }
            self.lastFrame = now
        }
        monitor.start()
        self.monitor = monitor
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            monitor.stop()
            let total = gaps.reduce(0, +)
            note("  点按后 1.2s 掉帧 \(gaps.count) 次，最长 \(gaps.max() ?? 0)ms，合计 \(total)ms \(gaps.prefix(8))")
        }
    }

    func clear() {
        lines = []
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

/// 放在相簿页里：页面进入窗口（推入过渡开始）时查当时的过渡是否带动画
struct PushProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        private var reported = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !reported else { return }
            reported = true
            var responder: UIResponder? = self
            while let current = responder, !(current is UIViewController) {
                responder = current.next
            }
            let controller = responder as? UIViewController
            let coordinator = controller?.transitionCoordinator
            let animated = coordinator.map { $0.isAnimated ? "有动画" : "无动画" } ?? "无过渡"
            let depth = controller?.navigationController?.viewControllers.count ?? -1
            let state = switch UIApplication.shared.applicationState {
            case .active: "active"
            case .inactive: "inactive"
            case .background: "background"
            @unknown default: "?"
            }
            PushDiagnostics.shared.note(
                "  相簿页进入窗口：\(animated)，栈深 \(depth)，UIView 动画\(UIView.areAnimationsEnabled ? "开" : "关")，\(state)，减弱动态\(UIAccessibility.isReduceMotionEnabled ? "开" : "关")")
        }
    }
}
#endif
