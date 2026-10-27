import SwiftUI
import UIKit

/// 导航栏右侧按钮跟着所在页面一起移动：列表页和相簿页的按钮不是同一层级，推入 / 返回时各自随页面滑动
/// （新页面的按钮随页面从右侧滑入，旧页面的按钮随页面往左退 / 往右滑走），而不是系统默认的原地交叉淡化（用户要求）。
///
/// 系统过渡里（iOS 18 实测）：新页面的按钮在过渡开始后、关着动画时才放进导航栏，`animate(alongsideTransition:)`
/// 的动画块执行时它还不存在；旧页面的按钮被换成快照（私有的 `_UIReplicantView`）只做淡出。页面本身由挂在外层视图上的
/// 叠加式弹簧 position 动画移动。所以：
/// - 点按推入 / 返回：把页面那段弹簧动画原样复制（同参数、同开始时刻）到新按钮和旧按钮快照上，与页面严格同步；
/// - 手势划回（交互式）：动画按手指进度推进，复制的动画跟不上 —— 改为逐帧读页面实际位置（presentation）跟随。
///
/// 用法：页面内容 `.background { NavBarItemsMotion.PageProbe(motion:) }`，
/// 导航栏那一项 `.background { NavBarItemsMotion.ItemProbe(motion:) }`
@MainActor
final class NavBarItemsMotion {
    private struct Transition {
        /// 新按钮的起点（相对最终位置）、旧按钮快照的终点
        let start: CGFloat
        let oldEnd: CGFloat
        let interactive: Bool
        weak var toView: UIView?
        weak var fromView: UIView?
        weak var bar: UINavigationBar?
    }

    private static let animationKey = "navBarItemsMotion"

    private var transition: Transition?
    private weak var itemProbe: UIView?
    private weak var item: UIView?
    private var snapshots: [UIView] = []
    private var link: CADisplayLink?
    private var installed = false

    fileprivate func pageWillAppear(_ probe: UIViewController) {
        // iOS 26：导航栏按钮在玻璃胶囊里原地形变过渡（系统 Liquid Glass 设计），不再按页面滑动；
        // 那边导航栏的视图结构也不一样，这里的处理不适用
        if #available(iOS 26.0, *) { return }
        // 这一页的控制器：往上找到直接挂在导航控制器下的那一层
        var page: UIViewController? = probe
        while let current = page, !(current.parent is UINavigationController) {
            page = current.parent
        }
        guard let page, let nav = page.navigationController,
              let coordinator = page.transitionCoordinator, coordinator.isAnimated,
              let from = coordinator.viewController(forKey: .from),
              coordinator.viewController(forKey: .to) === page
        else {
            return
        }
        cleanUp()
        // 返回时 from 已经不在栈里（手势取消后系统再放回去）
        let isPush = nav.viewControllers.contains(from)
        let width = nav.view.bounds.width
        // 底下那页退到约 30% 处（与系统推入时底下页面的视差位移一致）
        let behind = -width * 0.3
        var interactive = coordinator.isInteractive
        #if DEBUG
        // NAV_MOTION=follow：点按也走逐帧跟随（模拟器做不出边缘划回手势，借此验证交互式那条路）
        if ProcessInfo.processInfo.environment["NAV_MOTION"] == "follow" {
            interactive = true
        }
        #endif
        transition = Transition(
            start: isPush ? width : behind, oldEnd: isPush ? behind : width, interactive: interactive,
            toView: page.view, fromView: from.view, bar: nav.navigationBar)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.cleanUp()
        }
        // 过渡的动画都装好之后（下一轮主循环）再接上；按钮这时一般已经放进导航栏
        DispatchQueue.main.async { [weak self] in
            self?.install()
        }
    }

    /// 这一页的按钮被放进导航栏（系统在关着动画时放）：先放到起点，免得第一帧在终点闪一下
    fileprivate func itemAttached(_ probe: UIView) {
        itemProbe = probe
        guard let transition, !installed, let item = barItem(containing: probe) else { return }
        self.item = item
        item.transform = CGAffineTransform(translationX: transition.start, y: 0)
    }

    private func install() {
        guard let transition, !installed, let bar = transition.bar else { return }
        installed = true
        item = item ?? itemProbe.flatMap(barItem(containing:))
        // 旧页面右侧按钮的快照
        snapshots = replicants(in: bar).filter { $0.frame.midX > bar.bounds.midX }
        if !transition.interactive, let template = pageAnimation(from: transition.toView) {
            if let item {
                item.transform = .identity
                add(template.animation, from: transition.start, to: 0, on: item, templateLayer: template.layer)
            }
            for snapshot in snapshots {
                snapshot.transform = CGAffineTransform(translationX: transition.oldEnd, y: 0)
                add(template.animation, from: 0, to: transition.oldEnd, on: snapshot, templateLayer: template.layer)
            }
        } else {
            let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.follow() },
                                     selector: #selector(DisplayLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            self.link = link
            follow()
        }
    }

    /// 交互式：按页面此刻的实际位置摆放按钮
    private func follow() {
        guard let transition else { return }
        if let item, let x = presentedMinX(transition.toView) {
            item.transform = CGAffineTransform(translationX: x, y: 0)
        }
        if let x = presentedMinX(transition.fromView) {
            for snapshot in snapshots {
                snapshot.transform = CGAffineTransform(translationX: x, y: 0)
            }
        }
    }

    private func cleanUp() {
        link?.invalidate()
        link = nil
        for view in [item].compactMap({ $0 }) + snapshots {
            view.layer.removeAnimation(forKey: Self.animationKey)
            view.transform = .identity
        }
        item = nil
        snapshots = []
        transition = nil
        installed = false
    }

    // MARK: - 工具

    /// 页面（或它外层的过渡容器）上系统加的 position 动画
    private func pageAnimation(from view: UIView?) -> (animation: CAPropertyAnimation, layer: CALayer)? {
        var current = view
        while let view = current, !(view is UIWindow) {
            for key in view.layer.animationKeys() ?? [] {
                if let animation = view.layer.animation(forKey: key) as? CAPropertyAnimation,
                   animation.keyPath == "position" {
                    return (animation, view.layer)
                }
            }
            current = view.superview
        }
        return nil
    }

    /// 同参数、同开始时刻的叠加式位移动画：模型值已是终点，动画从（起点 − 终点）回到 0
    private func add(_ template: CAPropertyAnimation, from start: CGFloat, to end: CGFloat,
                     on view: UIView, templateLayer: CALayer) {
        guard let animation = template.copy() as? CAPropertyAnimation else { return }
        animation.keyPath = "position"
        animation.isAdditive = true
        if let basic = animation as? CABasicAnimation {
            basic.fromValue = NSValue(cgPoint: CGPoint(x: start - end, y: 0))
            basic.toValue = NSValue(cgPoint: .zero)
            basic.byValue = nil
        }
        animation.beginTime = view.layer.convertTime(template.beginTime, from: templateLayer)
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = true
        view.layer.add(animation, forKey: Self.animationKey)
    }

    private func presentedMinX(_ view: UIView?) -> CGFloat? {
        guard let view, let window = view.window,
              let layer = view.layer.presentation(), let windowLayer = window.layer.presentation()
        else {
            return nil
        }
        return layer.convert(layer.bounds, to: windowLayer).minX
    }

    /// ItemProbe 往上找到导航栏按钮栈里属于这一项的那一层
    private func barItem(containing probe: UIView) -> UIView? {
        var view: UIView? = probe
        while let current = view, let superview = current.superview {
            if superview is UIStackView {
                return current
            }
            view = superview
        }
        return nil
    }

    private func replicants(in view: UIView) -> [UIView] {
        view.subviews.flatMap { subview -> [UIView] in
            String(describing: type(of: subview)).contains("Replicant") ? [subview] : replicants(in: subview)
        }
    }

    private final class DisplayLinkTarget: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func tick() { action() }
    }

    // MARK: - 探针

    /// 放在页面内容里：作为子控制器随页面收到出现回调
    struct PageProbe: UIViewControllerRepresentable {
        let motion: NavBarItemsMotion

        func makeUIViewController(context: Context) -> Controller {
            Controller(motion: motion)
        }

        func updateUIViewController(_ controller: Controller, context: Context) {}

        final class Controller: UIViewController {
            private let motion: NavBarItemsMotion

            init(motion: NavBarItemsMotion) {
                self.motion = motion
                super.init(nibName: nil, bundle: nil)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError() }

            override func viewWillAppear(_ animated: Bool) {
                super.viewWillAppear(animated)
                motion.pageWillAppear(self)
            }
        }
    }

    /// 放在导航栏那一项里：按钮进入导航栏时通知 NavBarItemsMotion（SwiftUI 还会建不在屏幕上的副本，只认进了窗口的）
    struct ItemProbe: UIViewRepresentable {
        let motion: NavBarItemsMotion

        func makeUIView(context: Context) -> ProbeView {
            let view = ProbeView()
            view.isUserInteractionEnabled = false
            view.motion = motion
            return view
        }

        func updateUIView(_ view: ProbeView, context: Context) {
            view.motion = motion
        }

        final class ProbeView: UIView {
            weak var motion: NavBarItemsMotion?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                if window != nil {
                    motion?.itemAttached(self)
                }
            }
        }
    }
}
