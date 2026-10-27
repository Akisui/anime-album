import UIKit

/// UIKit 照片网格共用的单元：正方形 aspectFill 缩略图 + 可选的勾选态
/// （相簿详情的排序网格、「添加到相簿」选择器）
final class PhotoCollectionCell: UICollectionViewCell {
    private let imageView = UIImageView()
    /// 当前显示的缩略图（长按菜单的预览先用它占位）
    var currentImage: UIImage? { imageView.image }
    private let tintOverlay = UIView()
    /// 勾选徽标：第一次被勾选时才创建 —— 进出最密档时一帧要新建几百个格子，
    /// 每格都带一个 Auto Layout 搭的徽标会明显卡顿
    private var badge: SelectionBadgeView?
    /// PDF 标记（左下角「PDF · 页数」）：同样懒创建
    private var documentBadge: UILabel?
    private var loadTask: Task<Void, Never>?
    /// 徽标随格子缩小的比例：最密档（~25pt 的格子）上原尺寸 22pt 的徽标几乎盖满整格
    private var badgeScale: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground

        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        tintOverlay.frame = contentView.bounds
        tintOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tintOverlay.backgroundColor = UIColor.white.withAlphaComponent(SelectionStyle.overlayOpacity)
        tintOverlay.isHidden = true
        contentView.addSubview(tintOverlay)


        // iPad 指针悬停高亮
        hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 0))

        isAccessibilityElement = true
        accessibilityLabel = "照片"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// kind：格子尺寸对应的缩略图（最密档用 tiny，其余 small）
    func configure(photoID: UUID, kind: ThumbnailKind = .small) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLOSE_PROBE"] == "1" {
            print("CELL_CONFIGURE \(photoID.uuidString.prefix(4)) cached=\(ThumbnailCache.shared.cachedImage(for: photoID, kind: kind) != nil)")
        }
        #endif
        loadTask?.cancel()
        // 内存缓存命中时同步显示：换布局 / 快速滚动时新出现的格子不先闪灰
        if let cached = ThumbnailCache.shared.cachedImage(for: photoID, kind: kind) {
            imageView.image = cached
            return
        }
        // 目标尺寸未缓存时先拿另一种尺寸的缓存图顶上（如进出最密档时 tiny ↔ small），加载完再换
        imageView.image = [ThumbnailKind.small, .tiny].lazy
            .compactMap { ThumbnailCache.shared.cachedImage(for: photoID, kind: $0) }
            .first
        loadTask = Task { [weak self] in
            let image = await ThumbnailCache.shared.image(for: photoID, kind: kind)
            guard let self, !Task.isCancelled, let image else { return }
            self.imageView.image = image
        }
    }

    /// 角标：PDF / 动图在左下角标「PDF · 页数」「GIF」，视频在右下角标时长（原生相册样式）；普通图片传 nil
    func setBadge(_ badge: CellBadge?) {
        // PDF 页面多为白底，与网格背景融在一起：加一圈细边
        var isPDF = false
        if case .pdf = badge { isPDF = true }
        contentView.layer.borderWidth = isPDF ? 1 / max(traitCollection.displayScale, 1) : 0
        contentView.layer.borderColor = UIColor.separator.cgColor
        switch badge {
        case .pdf(let pages):
            showChip(pages > 1 ? "PDF · \(pages)" : "PDF")
            durationLabel?.isHidden = true
        case .gif:
            showChip("GIF")
            durationLabel?.isHidden = true
        case .video(let duration):
            documentBadge?.isHidden = true
            let label = durationLabel ?? makeDurationLabel()
            label.text = CellBadge.durationText(duration)
            label.isHidden = false
        case nil:
            documentBadge?.isHidden = true
            durationLabel?.isHidden = true
        }
        setNeedsLayout()
    }

    /// 隐藏照片的标记（「全部显示」时用）：左上角一个划掉的眼睛，懒创建
    private var hiddenMark: UIImageView?

    func setHiddenMark(_ marked: Bool) {
        guard marked || hiddenMark != nil else { return }
        let mark = hiddenMark ?? {
            let view = UIImageView(image: UIImage(
                systemName: "eye.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
            view.tintColor = .white
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.5
            view.layer.shadowRadius = 1.5
            view.layer.shadowOffset = .zero
            contentView.addSubview(view)
            hiddenMark = view
            return view
        }()
        mark.isHidden = !marked
        setNeedsLayout()
    }

    private func showChip(_ text: String) {
        let label = documentBadge ?? makeDocumentBadge()
        label.text = text
        label.isHidden = false
    }

    /// 视频时长（右下角，白字带阴影）：懒创建
    private var durationLabel: UILabel?

    private func makeDurationLabel() -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        contentView.insertSubview(label, belowSubview: tintOverlay)
        durationLabel = label
        return label
    }

    /// 从查看器落回格子时：照片与过渡图层逐像素一致、无缝衔接；PDF 的细边与页数标记是格子独有的，
    /// 直接出现会闪一下 —— 淡入
    func fadeInDecorations(duration: TimeInterval = 0.25) {
        let border = contentView.layer
        if border.borderWidth > 0 {
            let animation = CABasicAnimation(keyPath: "borderColor")
            animation.fromValue = UIColor.clear.cgColor
            animation.toValue = border.borderColor
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            border.add(animation, forKey: "fadeInBorder")
        }
        if let documentBadge, !documentBadge.isHidden {
            let target = documentBadge.alpha
            documentBadge.alpha = 0
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                documentBadge.alpha = target
            }
        }
    }

    private func makeDocumentBadge() -> UILabel {
        let label = UILabel()
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 4
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        contentView.insertSubview(label, belowSubview: tintOverlay)
        documentBadge = label
        return label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = contentView.bounds.size
        if let durationLabel, !durationLabel.isHidden {
            durationLabel.alpha = size.width >= 48 ? 1 : 0
            let textSize = durationLabel.intrinsicContentSize
            durationLabel.frame = CGRect(x: size.width - 5 - textSize.width, y: size.height - 4 - textSize.height,
                                         width: textSize.width, height: textSize.height)
        }
        if let documentBadge, !documentBadge.isHidden {
            // 最密档格子太小，不显示
            documentBadge.alpha = size.width >= 48 ? 1 : 0
            let textSize = documentBadge.intrinsicContentSize
            documentBadge.frame = CGRect(x: 4, y: size.height - 4 - 16, width: textSize.width + 10, height: 16)
        }
        if let hiddenMark, !hiddenMark.isHidden {
            hiddenMark.alpha = size.width >= 48 ? 1 : 0
            hiddenMark.sizeToFit()
            hiddenMark.frame.origin = CGPoint(x: 5, y: 5)
        }
        badgeScale = min(1, max(0.5, size.width / 72))
        guard let badge else { return }
        let diameter = SelectionStyle.badgeDiameter
        let inset = SelectionStyle.badgeInset * badgeScale
        badge.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        badge.center = CGPoint(
            x: size.width - inset - diameter * badgeScale / 2,
            y: size.height - inset - diameter * badgeScale / 2)
        if badge.layer.animationKeys()?.isEmpty ?? true {
            badge.transform = CGAffineTransform(scaleX: badgeScale, y: badgeScale)
        }
    }

    private func makeBadgeIfNeeded() -> SelectionBadgeView {
        if let badge {
            return badge
        }
        let badge = SelectionBadgeView()
        contentView.addSubview(badge)
        self.badge = badge
        setNeedsLayout()
        layoutIfNeeded()
        return badge
    }

    /// 勾选态：白色薄罩 + 右下角徽标。选中时徽标从 0.6 倍弹到原大（临界阻尼、无回弹），
    /// 「减弱动态效果」开启时直接切换
    func setChecked(_ checked: Bool, animated: Bool) {
        accessibilityTraits = checked ? [.image, .selected] : .image
        let wasChecked = !tintOverlay.isHidden
        guard checked != wasChecked else { return }

        tintOverlay.isHidden = !checked
        guard checked || badge != nil else { return }
        let badge = makeBadgeIfNeeded()
        badge.isHidden = !checked
        let resting = CGAffineTransform(scaleX: badgeScale, y: badgeScale)
        guard checked, animated, !UIAccessibility.isReduceMotionEnabled else {
            badge.transform = resting
            return
        }
        badge.transform = resting.scaledBy(x: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) {
            badge.transform = resting
        }
    }

    // MARK: 浮起

    /// 长按按下后的浮起（震动前就开始、落回动画结束前）：状态存在格子上，期间布局刷新（apply）不会把它冲掉 ——
    /// 否则投影被按 zIndex 清零、zPosition 被重设为 0 而被邻格盖住，下一次置顶时又闪出来（真机实测）
    private var isPressLifted = false
    /// 浮起到落回动画结束：期间保持置顶
    private var isElevated = false
    static let liftedScale: CGFloat = 1.1
    private static let liftedShadowOpacity: Float = 0.3

    /// 浮起期间的放大全部走格子 layer 的 sublayerTransform（浮起 → 按住等菜单 → 拖动时的 1.1 倍），格子自身 transform 保持不变：
    /// 交互式移动开始时布局属性会直接设 transform、冲掉进行中的动画（震动那一帧跳一下，实测）；
    /// 也不能缩放 contentView —— 格子布局时会把它的 frame 重设回格子大小，带缩放时 bounds 被改小、画面先缩一下再放大（实测）
    /// 浮起：放大到 scale（相簿里一条曲线直接放大到按住结束的大小，见 PressCurve）+ 投影；落回：回到原大小
    func setPressLifted(_ lifted: Bool, scale: CGFloat = PhotoCollectionCell.liftedScale, duration: TimeInterval,
                        timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        isPressLifted = lifted
        if lifted {
            isElevated = true
            layer.zPosition = CGFloat(PhotoGridCompositionalLayout.liftedZIndex)
            transform = .identity
        }
        let animated = duration > 0 && !UIAccessibility.isReduceMotionEnabled
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.isPressLifted else { return }
            self.isElevated = false
            self.layer.zPosition = 0
        }
        setShadowOpacity(lifted ? Self.liftedShadowOpacity : 0, duration: animated ? duration : 0, timing: timing)
        setPressScale(lifted ? scale : 1, duration: animated ? duration : 0, timing: timing)
        CATransaction.commit()
    }

    /// 当前显示的放大倍数（菜单预览从这个大小接着放大）
    var displayedPressScale: CGFloat {
        (layer.presentation() ?? layer).sublayerTransform.m11
    }

    /// 从当前显示的大小渐变到 scale（如拖动开始时从按住的大小退回 1.1 倍），投影跟着缩放
    func setPressScale(_ scale: CGFloat, duration: TimeInterval,
                       timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        let target = CATransform3DMakeScale(scale, scale, 1)
        let shadowRect = bounds.insetBy(dx: bounds.width * (1 - scale) / 2, dy: bounds.height * (1 - scale) / 2)
        let shadowPath = UIBezierPath(rect: shadowRect).cgPath
        let fromTransform = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        let fromPath = layer.presentation()?.shadowPath ?? layer.shadowPath
        layer.removeAnimation(forKey: "pressScale")
        layer.removeAnimation(forKey: "pressShadowPath")
        layer.sublayerTransform = target
        layer.shadowPath = shadowPath
        guard duration > 0, !UIAccessibility.isReduceMotionEnabled else { return }
        func add(_ keyPath: String, from: Any?, to: Any, key: String) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = timing
            layer.add(animation, forKey: key)
        }
        add("sublayerTransform", from: NSValue(caTransform3D: fromTransform), to: NSValue(caTransform3D: target), key: "pressScale")
        if let fromPath {
            add("shadowPath", from: fromPath, to: shadowPath, key: "pressShadowPath")
        }
    }

    /// 菜单显示期间格子隐藏（照片「离开」了格子）：布局刷新会按布局属性把 alpha 设回 1，要在 apply 里压住
    var isHiddenForMenu = false {
        didSet { alpha = isHiddenForMenu ? 0 : 1 }
    }

    /// 投影从当前显示值渐变到目标值（layer 属性不随 UIView 动画块变化，显式加动画）
    private func setShadowOpacity(_ opacity: Float, duration: TimeInterval, timing: CAMediaTimingFunction) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.shadowRadius = 12
        let from = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        layer.removeAnimation(forKey: "liftShadow")
        layer.shadowOpacity = opacity
        guard duration > 0, from != opacity else { return }
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: "liftShadow")
    }

    /// 长按排序被拖起时（布局给的 zIndex 置顶）显示投影，落下恢复；手动浮起期间以浮起状态为准
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if isHiddenForMenu {
            alpha = 0
        }
        if isElevated {
            // 放大由 sublayerTransform 负责（交互式移动的布局属性给的 1.1 倍不叠加）
            layer.zPosition = CGFloat(PhotoGridCompositionalLayout.liftedZIndex)
            transform = .identity
            return
        }
        let lifted = layoutAttributes.zIndex >= PhotoGridCompositionalLayout.liftedZIndex
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.shadowRadius = 12
        layer.shadowOpacity = lifted ? Self.liftedShadowOpacity : 0
        layer.shadowPath = lifted ? UIBezierPath(rect: bounds).cgPath : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        imageView.image = nil
        tintOverlay.isHidden = true
        badge?.isHidden = true
        badge?.transform = CGAffineTransform(scaleX: badgeScale, y: badgeScale)
        isPressLifted = false
        isElevated = false
        layer.removeAnimation(forKey: "liftShadow")
        layer.removeAnimation(forKey: "pressScale")
        layer.removeAnimation(forKey: "pressShadowPath")
        layer.sublayerTransform = CATransform3DIdentity
        layer.shadowOpacity = 0
        layer.zPosition = 0
        transform = .identity
        isHiddenForMenu = false
    }
}

/// 右下角选中徽标（UIKit 版，与 SwiftUI 的 SelectionBadge 同一套尺寸/配色）
final class SelectionBadgeView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        let diameter = SelectionStyle.badgeDiameter
        backgroundColor = .tintColor
        layer.cornerRadius = diameter / 2
        layer.borderWidth = SelectionStyle.badgeRingWidth
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        let check = UIImageView(
            image: UIImage(
                systemName: "checkmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter * 0.45, weight: .bold)))
        check.tintColor = .white
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            check.centerXAnchor.constraint(equalTo: centerXAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// 网格格子的角标
enum CellBadge: Equatable {
    case pdf(pages: Int)
    case video(duration: Double)
    case gif

    static func of(_ photo: Photo) -> CellBadge? {
        switch photo.kind {
        case .pdf: .pdf(pages: photo.pageCount)
        case .video: .video(duration: photo.duration)
        case .gif: .gif
        case .image, .live: nil
        }
    }

    /// 0:15 / 12:03 / 1:02:03
    static func durationText(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
