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
    }

    private(set) var session: Session?

    func beginPhotos(
        excludingAlbum albumID: UUID? = nil,
        onDelete: @escaping () -> Void,
        onNewAlbum: @escaping ([Photo]) -> Void,
        onAdded: @escaping () -> Void
    ) {
        session = Session(
            kind: .photos(excludedAlbumID: albumID),
            onDelete: onDelete, onNewAlbum: onNewAlbum, onAdded: onAdded)
    }

    func beginAlbums(onDelete: @escaping () -> Void) {
        session = Session(kind: .albums, onDelete: onDelete)
    }

    func update(photos: [Photo]) {
        session?.photos = photos
        session?.count = photos.count
    }

    func update(count: Int) {
        session?.count = count
    }

    func end() {
        session = nil
    }
}

/// 选择模式底部栏（覆盖在 Tab 栏之上）：左分享（仅选照片时）/ 中计数 / 右加入相簿（仅选照片时）+ 删除。
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
                if case .photos(let excludedAlbumID) = session.kind {
                    Menu {
                        AddToAlbumMenuContent(photos: session.photos, excludingAlbumID: excludedAlbumID) {
                            session.onNewAlbum(session.photos)
                        } onAdded: {
                            session.onAdded()
                        }
                    } label: {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("添加到相簿")
                    .disabled(session.count == 0)
                }
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
