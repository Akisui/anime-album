import SwiftUI

/// 查看器里当前这段视频的播放状态：当前页的 VideoPlaybackView 接上来（翻走时断开），底部控制条读它。进度每秒刷新 30 次 —— 只有读它的控制条重算，查看器本身不读进度
@MainActor
@Observable
final class ViewerVideoState {
    @ObservationIgnored private weak var view: VideoPlaybackView?
    private(set) var activeID: ViewerItem.ID?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false

    func attach(_ view: VideoPlaybackView, id: ViewerItem.ID) {
        self.view = view
        activeID = id
        view.onStateChange = { [weak self, weak view] in
            guard let self, let view, view === self.view else { return }
            self.sync(from: view)
        }
        sync(from: view)
    }

    func detach(_ view: VideoPlaybackView) {
        view.onStateChange = nil
        guard view === self.view else { return }
        self.view = nil
        activeID = nil
        isPlaying = false
    }

    func toggle() {
        view?.toggle()
    }

    func play() {
        view?.play()
    }

    /// 拖进度条（0…1）：拖动期间暂停，边拖边换画面
    func scrub(to fraction: Double) {
        guard let view, duration > 0 else { return }
        if !isScrubbing {
            isScrubbing = true
            resumeAfterScrub = isPlaying
            view.pause()
        }
        currentTime = min(max(fraction, 0), 1) * duration
        view.seek(to: currentTime, precise: false)
    }

    /// 松手：精确对齐，拖之前在播就接着播
    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        view?.seek(to: currentTime, precise: true)
        if resumeAfterScrub {
            view?.play()
        }
    }

    private func sync(from view: VideoPlaybackView) {
        if isPlaying != view.isPlaying {
            isPlaying = view.isPlaying
        }
        if !isScrubbing {
            currentTime = view.currentTime
        }
        if duration != view.duration {
            duration = view.duration
        }
    }
}

/// 底部控制条：左边播放 / 暂停，右边进度条与时间。随顶部 bar / 胶片条一起显隐（单击唤出）。
/// 控制条收起时画面上什么都不显示 —— 双击暂停后也不出暂停标识（用户要求）
struct ViewerVideoControls: View {
    static let height: CGFloat = 44

    let state: ViewerVideoState

    var body: some View {
        HStack(spacing: 10) {
            Button {
                state.toggle()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(state.isPlaying ? "暂停" : "播放")

            Text(Self.format(state.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            VideoScrubber(state: state)

            Text("-" + Self.format(max(state.duration - state.currentTime, 0)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: Self.height)
        .background(.regularMaterial, in: Capsule())
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 细进度条：按住任意位置即跳到那里，拖动连续换画面
private struct VideoScrubber: View {
    let state: ViewerVideoState
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let fraction = state.duration > 0 ? min(max(state.currentTime / state.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                Capsule()
                    .fill(Color.primary)
                    .frame(width: proxy.size.width * fraction)
            }
            .frame(height: dragging ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            withAnimation(.easeOut(duration: 0.15)) { dragging = true }
                        }
                        state.scrub(to: value.location.x / max(proxy.size.width, 1))
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.15)) { dragging = false }
                        state.endScrub()
                    }
            )
        }
        .frame(height: ViewerVideoControls.height)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue(ViewerVideoControls.format(state.currentTime))
    }
}
