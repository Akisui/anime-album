import SwiftUI

/// 图库选择模式的底部栏状态：由 LibraryView 驱动、RootView 顶层渲染。
///
/// bar 画在 Tab 栏**上方**（覆盖而非替换）：安全区全程零变化，照片流不会动。
/// 不能用「隐藏 Tab 栏 + safeAreaInset 等高替换」—— UIKit 桥接的 Tab 栏隐藏/恢复
/// 与 SwiftUI 的 inset 插入不在同一帧生效，中间会出现一帧底部安全区不一致，
/// 表现为照片流单帧跳动 49pt（见 CLAUDE.md 已知坑）。
@MainActor
@Observable
final class SelectionBarPresenter {
    struct Session {
        var photos: [Photo]
        let onDelete: ([Photo]) -> Void
        let onNewAlbum: ([Photo]) -> Void
        let onAdded: () -> Void
    }

    private(set) var session: Session?

    func begin(
        onDelete: @escaping ([Photo]) -> Void,
        onNewAlbum: @escaping ([Photo]) -> Void,
        onAdded: @escaping () -> Void
    ) {
        session = Session(photos: [], onDelete: onDelete, onNewAlbum: onNewAlbum, onAdded: onAdded)
    }

    func update(photos: [Photo]) {
        session?.photos = photos
    }

    func end() {
        session = nil
    }
}

/// 选择模式底部栏（覆盖在 Tab 栏之上）：左删除 / 中计数 / 右加入相簿。
/// 高度与 Tab 栏图标区一致（49pt），背景延伸进 Home 指示条区域；
/// 底层铺不透明系统背景色盖住下面的 Tab 图标（材质是半透明的）。
struct SelectionBarOverlay: View {
    let session: SelectionBarPresenter.Session

    var body: some View {
        ZStack {
            Text(session.photos.isEmpty ? "选择图片" : "选中 \(session.photos.count) 张照片")
                .font(.subheadline.weight(.semibold))
            HStack {
                Button {
                    session.onDelete(session.photos)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(session.photos.isEmpty)
                Spacer()
                Menu {
                    AddToAlbumMenuContent(photos: session.photos) {
                        session.onNewAlbum(session.photos)
                    } onAdded: {
                        session.onAdded()
                    }
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(session.photos.isEmpty)
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 49)
        .background(.bar)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider() }
    }
}
