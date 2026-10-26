import AVFoundation
import ImageIO
import PhotosUI
import UIKit

/// 查看器里的视频：叠在封面帧（ZoomableImageView 的 imageView）上，中间一个播放按钮；
/// 点按钮播放 / 暂停，播完回到开头。原文件在 iCloud 云盘还没下载时先下载再播
final class VideoPlaybackView: UIView {
    private let url: URL
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private let button = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var endObserver: NSObjectProtocol?
    private var isPlaying = false

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22))
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 16)
        button.configuration = config
        button.accessibilityLabel = "播放"
        button.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .touchUpInside)
        addSubview(button)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        button.sizeToFit()
        button.center = CGPoint(x: bounds.midX, y: bounds.midY)
        spinner.center = button.center
    }

    /// 只让播放按钮接收触摸，其余交给查看器（单击切换顶部栏、下拉关闭等）
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func pause() {
        player?.pause()
        setPlaying(false)
    }

    private func togglePlayback() {
        if isPlaying {
            pause()
            return
        }
        if let player {
            player.play()
            setPlaying(true)
            return
        }
        button.isHidden = true
        spinner.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            let ready = await ImageStore.shared.ensureDownloaded(self.url)
            self.spinner.stopAnimating()
            guard ready else {
                self.button.isHidden = false
                return
            }
            let player = AVPlayer(url: self.url)
            self.player = player
            self.playerLayer.player = player
            self.endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.player?.seek(to: .zero)
                    self?.setPlaying(false)
                }
            }
            player.play()
            self.setPlaying(true)
        }
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        button.isHidden = false
        var config = button.configuration
        config?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22))
        config?.contentInsets = playing
            ? NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
            : NSDirectionalEdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 16)
        button.configuration = config
        button.accessibilityLabel = playing ? "暂停" : "播放"
        // 播放中按钮淡到半透明，不挡画面；按下仍可暂停
        UIView.animate(withDuration: 0.2) { self.button.alpha = playing ? 0.35 : 1 }
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
