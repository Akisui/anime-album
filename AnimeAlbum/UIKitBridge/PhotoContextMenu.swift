import UIKit

/// 照片长按菜单的项。菜单自绘、不用系统 UIContextMenuInteraction：系统菜单的内部手势会压住
/// 长按排序手势（真机日志实测），与系统拖放联动时又要「浮起后再等一下」才能拖 ——
/// 用户要的是「按下即逐渐浮起、一震动就能拖，继续按住不动才进菜单」，只能自己掌控节奏
struct GridMenuItem {
    var title: String
    var systemImage: String?
    var isDestructive = false
    var action: (() -> Void)?
    /// 子菜单（如「添加到相簿」→ 各相簿）：点进去在原处换成子项列表
    var children: [GridMenuItem] = []
    /// 选了之后照片会从当前页消失（如默认显示下「隐藏」）：预览原地缩小淡出、不飞回格子，同时其余照片补位
    var removesPhoto = false
}

/// 能报告「手指按下」与「手势复位」的长按：按下后照片开始逐渐浮起（震动前就有被拿起的迹象），
/// 手势失败 / 结束复位时由调用方把没拿起的照片落回
final class PressLiftGestureRecognizer: UILongPressGestureRecognizer {
    var onTouchDown: (CGPoint) -> Void = { _ in }
    var onReset: () -> Void = {}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first, numberOfTouches == 1 {
            onTouchDown(touch.location(in: view))
        }
    }

    override func reset() {
        super.reset()
        onReset()
    }
}

/// 自绘长按菜单：背景模糊，照片从格子位置放大到原始比例的预览，下方是选项列表。
/// 点空白处收起（照片缩回格子），点选项先收起再执行
final class PhotoContextMenuController: UIViewController {
    private let photoID: UUID
    private let aspectRatio: CGFloat
    private let sourceFrame: CGRect
    private let startFrame: CGRect
    private let placeholderImage: UIImage?
    private var items: [GridMenuItem]
    private var parentTitle: String?
    /// 收起后回调；参数：照片是否被移走（是则格子保持隐藏，由网格删除）
    private let onDismiss: (Bool) -> Void

    private let blurView = UIVisualEffectView(effect: nil)
    private let previewView = UIImageView()
    private let menuView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let stack = UIStackView()
    private var loadTask: Task<Void, Never>?
    private var isDismissing = false

    private static let rowHeight: CGFloat = 46
    private static let menuWidth: CGFloat = 250

    /// sourceFrame：格子在窗口坐标里的位置（收起时回到这里）；startFrame：弹出时照片所在位置
    /// （已浮起放大的格子，预览从这里接着放大，不先缩回再放大）
    init(photoID: UUID, aspectRatio: CGFloat, sourceFrame: CGRect, startFrame: CGRect? = nil,
         placeholderImage: UIImage?, items: [GridMenuItem], onDismiss: @escaping (Bool) -> Void) {
        self.photoID = photoID
        self.aspectRatio = aspectRatio > 0 ? aspectRatio : 1
        self.sourceFrame = sourceFrame
        self.startFrame = startFrame ?? sourceFrame
        self.placeholderImage = placeholderImage
        self.items = items
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        blurView.frame = view.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blurView)
        blurView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backgroundTapped)))

        previewView.contentMode = .scaleAspectFill
        previewView.clipsToBounds = true
        previewView.layer.cornerCurve = .continuous
        previewView.backgroundColor = .secondarySystemBackground
        previewView.image = placeholderImage
        previewView.frame = startFrame
        view.addSubview(previewView)

        menuView.layer.cornerRadius = 14
        menuView.layer.cornerCurve = .continuous
        menuView.clipsToBounds = true
        stack.axis = .vertical
        menuView.contentView.addSubview(stack)
        view.addSubview(menuView)
        rebuildRows()
        menuView.alpha = 0

        loadLargeImage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let layout = targetLayout()
        menuView.frame = layout.menu
        menuView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85).translatedBy(x: 0, y: -20)
        animate {
            self.blurView.effect = UIBlurEffect(style: .systemThinMaterial)
            self.previewView.frame = layout.preview
            self.previewView.layer.cornerRadius = 12
            self.menuView.alpha = 1
            self.menuView.transform = .identity
        }
    }

    // MARK: 布局

    /// 预览按原始比例取最大（宽 ≤ 屏宽 − 32、高 ≤ 可用高度），与菜单整体在安全区内竖直居中
    private func targetLayout() -> (preview: CGRect, menu: CGRect) {
        let safe = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 16, dy: 12)
        let menuHeight = CGFloat(stack.arrangedSubviews.count) * Self.rowHeight
        let gap: CGFloat = 12
        let maxWidth = min(safe.width, 500)
        let maxHeight = max(safe.height - menuHeight - gap, 120)
        let size = aspectRatio >= maxWidth / maxHeight
            ? CGSize(width: maxWidth, height: maxWidth / aspectRatio)
            : CGSize(width: maxHeight * aspectRatio, height: maxHeight)
        let total = size.height + gap + menuHeight
        let top = safe.minY + (safe.height - total) / 2
        let preview = CGRect(x: safe.midX - size.width / 2, y: top, width: size.width, height: size.height)
        // 菜单与预览左对齐（预览很窄时居中）
        let menuX = size.width >= Self.menuWidth ? preview.minX : safe.midX - Self.menuWidth / 2
        let menu = CGRect(x: menuX, y: preview.maxY + gap, width: Self.menuWidth, height: menuHeight)
        return (preview, menu)
    }

    private func rebuildRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let parentTitle {
            stack.addArrangedSubview(makeRow(title: parentTitle, systemImage: "chevron.backward",
                                             isDestructive: false, isHeader: true) { [weak self] in
                self?.showRootItems()
            })
        }
        for item in items {
            stack.addArrangedSubview(makeRow(title: item.title, systemImage: item.children.isEmpty ? item.systemImage : "chevron.forward",
                                             isDestructive: item.isDestructive, isHeader: false) { [weak self] in
                self?.select(item)
            })
        }
        let height = CGFloat(stack.arrangedSubviews.count) * Self.rowHeight
        stack.frame = CGRect(x: 0, y: 0, width: Self.menuWidth, height: height)
    }

    private func makeRow(title: String, systemImage: String?, isDestructive: Bool, isHeader: Bool,
                         action: @escaping () -> Void) -> UIView {
        let row = MenuRowControl(title: title, systemImage: systemImage, isDestructive: isDestructive, isHeader: isHeader)
        row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        row.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return row
    }

    private var rootItems: [GridMenuItem] = []

    private func select(_ item: GridMenuItem) {
        if !item.children.isEmpty {
            rootItems = items
            parentTitle = item.title
            items = item.children
            relayoutMenu()
            return
        }
        if item.removesPhoto {
            dismissRemoving(then: item.action)
        } else {
            dismissMenu(then: item.action)
        }
    }

    private func showRootItems() {
        items = rootItems
        parentTitle = nil
        relayoutMenu()
    }

    private func relayoutMenu() {
        rebuildRows()
        let layout = targetLayout()
        animate {
            self.previewView.frame = layout.preview
            self.menuView.frame = layout.menu
        }
    }

    // MARK: 收起

    @objc private func backgroundTapped() {
        dismissMenu(then: nil)
    }

    private func dismissMenu(then action: (() -> Void)?) {
        guard !isDismissing else { return }
        isDismissing = true
        loadTask?.cancel()
        animate {
            self.blurView.effect = nil
            self.previewView.frame = self.sourceFrame
            self.previewView.layer.cornerRadius = 0
            self.menuView.alpha = 0
            self.menuView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        } completion: {
            self.onDismiss(false)
            self.dismiss(animated: false) {
                action?()
            }
        }
    }

    /// 照片要从当前页消失：预览在原处缩小淡出（格子那里留着空位），消失后才执行动作，其余照片再补位 ——
    /// 两件事同时做时几十个格子一起斜着移动，看不出是哪张没了（录屏实测）
    private func dismissRemoving(then action: (() -> Void)?) {
        guard !isDismissing else { return }
        isDismissing = true
        loadTask?.cancel()
        let finish = {
            action?()
            self.onDismiss(true)
            self.dismiss(animated: false)
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            finish()
            return
        }
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseIn]) {
            self.blurView.effect = nil
            self.previewView.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            self.previewView.alpha = 0
            self.menuView.alpha = 0
            self.menuView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        } completion: { _ in
            finish()
        }
    }

    private func animate(_ animations: @escaping () -> Void, completion: (() -> Void)? = nil) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            animations()
            completion?()
            return
        }
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState],
                       animations: animations) { _ in completion?() }
    }

    // MARK: 图

    private func loadLargeImage() {
        if let large = ThumbnailCache.shared.cachedImage(for: photoID, kind: .large) {
            previewView.image = large
            return
        }
        let photoID = photoID
        loadTask = Task { [weak self] in
            let image = await ThumbnailCache.shared.image(for: photoID, kind: .large)
            guard let self, !Task.isCancelled, let image else { return }
            self.previewView.image = image
        }
    }
}

/// 菜单的一行：左标题、右图标，按下高亮；破坏性操作红色；子菜单头部为次级色
private final class MenuRowControl: UIControl {
    private let highlightView = UIView()

    init(title: String, systemImage: String?, isDestructive: Bool, isHeader: Bool) {
        super.init(frame: .zero)
        let color: UIColor = isDestructive ? .systemRed : (isHeader ? .secondaryLabel : .label)

        highlightView.backgroundColor = UIColor.label.withAlphaComponent(0.08)
        highlightView.alpha = 0
        highlightView.isUserInteractionEnabled = false
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlightView)

        let label = UILabel()
        label.text = title
        label.font = isHeader ? .preferredFont(forTextStyle: .subheadline) : .preferredFont(forTextStyle: .body)
        label.textColor = color
        label.isUserInteractionEnabled = false

        let icon = UIImageView(image: systemImage.flatMap { UIImage(systemName: $0) })
        icon.tintColor = color
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.isUserInteractionEnabled = false

        for subview in [label, icon, separator] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        let isHeaderIconLeading = isHeader
        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlightView.topAnchor.constraint(equalTo: topAnchor),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        if isHeaderIconLeading {
            // 返回行：图标在左
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(lessThanOrEqualTo: icon.leadingAnchor, constant: -8),
                icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { highlightView.alpha = isHighlighted ? 1 : 0 }
    }
}
