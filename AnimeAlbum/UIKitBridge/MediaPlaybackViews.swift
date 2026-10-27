import AVFoundation
import ImageIO
import PhotosUI
import UIKit

/// 查看器里的视频：叠在封面帧（ZoomableImageView 的 imageView）上、随图片一起缩放。
/// 画面上不放任何控件（用户要求平时无遮挡）：双击播放 / 暂停，单击唤出底部控制条（ViewerVideoControls），
/// 状态经 ViewerVideoState 交给控制条。原文件在 iCloud 云盘还没下载时先下载再播
final class VideoPlaybackView: UIView {
    private let url: URL
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var preparing = false
    private var pendingActions: [() -> Void] = []
    /// 导入时记下的时长：播放器建好之前进度条就能显示总时长
    private let knownDuration: Double

    private(set) var isPlaying = false
    /// 播放 / 暂停、进度变化时回调
    var onStateChange: (() -> Void)?

    var currentTime: Double {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
        return seconds
    }

    var duration: Double {
        if let seconds = player?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
            return seconds
        }
        return knownDuration
    }

    init(url: URL, duration: Double) {
        self.url = url
        knownDuration = duration
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        withPlayer { [weak self] player in
            guard let self else { return }
            // 停在结尾时从头播
            if self.duration > 0, self.currentTime >= self.duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            self.isPlaying = true
            self.onStateChange?()
        }
    }

    func pause() {
        player?.pause()
        guard isPlaying else { return }
        isPlaying = false
        onStateChange?()
    }

    /// 拖进度条：边拖边看画面（不精确对齐、快），松手时精确对齐一次
    func seek(to seconds: Double, precise: Bool) {
        withPlayer { player in
            let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
            let tolerance: CMTime = precise ? .zero : CMTime(seconds: 0.1, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    /// 第一次用到时才建播放器（先确保原文件已下载）
    private func withPlayer(_ action: @escaping (AVPlayer) -> Void) {
        if let player {
            action(player)
            return
        }
        pendingActions.append { [weak self] in
            if let player = self?.player { action(player) }
        }
        guard !preparing else { return }
        preparing = true
        spinner.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            let ready = await ImageStore.shared.ensureDownloaded(self.url)
            self.spinner.stopAnimating()
            self.preparing = false
            guard ready else {
                self.pendingActions = []
                return
            }
            let player = AVPlayer(url: self.url)
            self.player = player
            self.playerLayer.player = player
            self.timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30), queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onStateChange?() }
            }
            self.endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPlaying = false
                    self.onStateChange?()
                }
            }
            let actions = self.pendingActions
            self.pendingActions = []
            actions.forEach { $0() }
        }
    }
}

/// 查看器里的动图：逐帧换 imageView 的图，循环播放；翻走 / 关闭时停
@MainActor
final class AnimatedImagePlayer {
    private weak var imageView: UIImageView?
    private let url: URL
    private var stopped = true

    init(url: URL, imageView: UIImageView) {
        self.url = url
        self.imageView = imageView
    }

    func start() {
        guard stopped else { return }
        stopped = false
        let url = url
        Task { [weak self] in
            guard await ImageStore.shared.ensureDownloaded(url), let self, !self.stopped else { return }
            CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, image, stop in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped, let imageView = self.imageView else {
                        stop.pointee = true
                        return
                    }
                    imageView.image = UIImage(cgImage: image)
                }
            }
        }
    }

    func stop() {
        stopped = true
    }
}

/// 查看器里的实况照片：系统的 PHLivePhotoView（按住播放，与原生相册一致），左上角「实况」标记
final class LivePhotoPlaybackView: UIView {
    private let liveView = PHLivePhotoView()
    /// 「实况」标记（系统的 livePhotoBadgeImage 在这里取到的是空图，自己画）
    private let badge: UIView = {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "livephoto", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.title = "实况"
        config.imagePadding = 4
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.35)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 11, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.isUserInteractionEnabled = false
        return button
    }()

    init(photoURL: URL, videoURL: URL, placeholder: UIImage?) {
        super.init(frame: .zero)
        backgroundColor = .clear
        liveView.contentMode = .scaleAspectFit
        addSubview(liveView)
        addSubview(badge)
        Task { [weak self] in
            async let photoReady = ImageStore.shared.ensureDownloaded(photoURL)
            async let videoReady = ImageStore.shared.ensureDownloaded(videoURL)
            guard await photoReady, await videoReady else { return }
            PHLivePhoto.request(withResourceFileURLs: [photoURL, videoURL], placeholderImage: placeholder,
                                targetSize: .zero, contentMode: .aspectFit) { [weak self] live, _ in
                MainActor.assumeIsolated {
                    if let live { self?.liveView.livePhoto = live }
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        liveView.frame = bounds
        badge.sizeToFit()
        badge.frame.origin = CGPoint(x: 10, y: 10)
    }

    func stopPlayback() {
        liveView.stopPlayback()
    }
}
