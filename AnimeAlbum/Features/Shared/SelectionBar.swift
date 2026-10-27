import SwiftUI

/// 选择模式的底部栏状态：由图库 / 相簿详情 / 相簿列表驱动、RootView 顶层渲染。
///
/// bar 画在 Tab 栏**上方**（覆盖而非替换）：安全区全程零变化，照片流不会动。
/// 不能用「隐藏 Tab 栏 + safeAreaInset 等高替换」—— UIKit 桥接的 Tab 栏隐藏/恢复
/// 与 SwiftUI 的 inset 插入不在同一帧生效，中间会出现一帧底部安全区不一致，
/// 表现为照片流单帧跳动 49pt（见 CLAUDE.md 已知坑）。
@MainActor
@Observable
final class SelectionBarPresenter {
    struct Session {
        enum Kind {
            /// 选照片：左删除 / 右「添加到相簿」（excludedAlbumID：相簿内选择时排除自身）
            case photos(excludedAlbumID: UUID?)
            /// 选相簿：只有删除
            case albums
        }

        let kind: Kind
        var count = 0
        /// 选中的照片（.photos 时供「添加到相簿」使用）
        var photos: [Photo] = []
        let onDelete: () -> Void
        var onNewAlbum: ([Photo]) -> Void = { _ in }
        var onAdded: () -> Void = {}
        /// 隐藏 / 取消隐藏选中的（全部已隐藏时为取消隐藏）
        var onToggleHidden: () -> Void = {}
        var allHidden = false
    }

    private(set) var session: Session?

    func beginPhotos(
        excludingAlbum albumID: UUID? = nil,
        onDelete: @escaping () -> Void,
        onNewAlbum: @escaping ([Photo]) -> Void,
        onAdded: @escaping () -> Void,
        onToggleHidden: @escaping () -> Void
    ) {
        session = Session(
            kind: .photos(excludedAlbumID: albumID),
            onDelete: onDelete, onNewAlbum: onNewAlbum, onAdded: onAdded, onToggleHidden: onToggleHidden)
    }

    func beginAlbums(onDelete: @escaping () -> Void, onToggleHidden: @escaping () -> Void) {
        session = Session(kind: .albums, onDelete: onDelete, onToggleHidden: onToggleHidden)
    }

    func update(photos: [Photo]) {
        session?.photos = photos
        session?.count = photos.count
        session?.allHidden = !photos.isEmpty && photos.allSatisfy(\.isHidden)
    }

    func update(count: Int, allHidden: Bool) {
        session?.count = count
        session?.allHidden = allHidden
    }

    func end() {
        session = nil
    }
}

/// 选择模式底部栏（覆盖在 Tab 栏之上）：左分享（仅选照片时）/ 中计数 / 右「…」（添加到相簿、隐藏）+ 删除。
/// 高度与 Tab 栏图标区一致（49pt），背景延伸进 Home 指示条区域；
/// 底层铺不透明系统背景色盖住下面的 Tab 图标（材质是半透明的）。
struct SelectionBarOverlay: View {
    let session: SelectionBarPresenter.Session

    private var unit: String {
        switch session.kind {
        case .photos: "张照片"
        case .albums: "个相簿"
        }
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        if case .photos(let excludedAlbumID) = session.kind {
            Menu("添加到相簿", systemImage: "rectangle.stack.badge.plus") {
                AddToAlbumMenuContent(photos: session.photos, excludingAlbumID: excludedAlbumID) {
                    session.onNewAlbum(session.photos)
                } onAdded: {
                    session.onAdded()
                }
            }
            Button(session.allHidden ? "取消隐藏" : "隐藏",
                   systemImage: session.allHidden ? "eye" : "eye.slash") {
                session.onToggleHidden()
            }
        } else {
            Button(session.allHidden ? "取消隐藏" : "隐藏相簿",
                   systemImage: session.allHidden ? "eye" : "eye.slash") {
                session.onToggleHidden()
            }
        }
    }

    var body: some View {
        ZStack {
            // 尺寸按原生相册的选择工具栏：计数 17pt 加粗，图标是工具栏的大号符号（body + .large）
            SelectionCountLabel(count: session.count, unit: unit)
                .font(.headline)
            HStack(spacing: 4) {
                if case .photos = session.kind {
                    Button {
                        PhotoSharing.share(session.photos)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("分享")
                    .disabled(session.count == 0)
                }
                Spacer()
                // 右边只放「…」和删除：添加到相簿、隐藏收进「…」（三个图标挤在一起太密，用户反馈）
                HStack(spacing: 12) {
                    Menu {
                        moreMenuItems
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("更多")
                    .disabled(session.count == 0)
                    Button {
                        session.onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("删除")
                    .disabled(session.count == 0)
                }
            }
            .font(.body)
            .imageScale(.large)
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 49)
        .background(.bar)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
        #if DEBUG
        // 调试辅助：TAP_BAR_DELETE=1 出现 2s 后自动按一次删除（配合预选，验证确认框里的数量）
        .task {
            guard ProcessInfo.processInfo.environment["TAP_BAR_DELETE"] == "1" else { return }
            try? await Task.sleep(for: .seconds(2))
            session.onDelete()
        }
        #endif
    }
}
