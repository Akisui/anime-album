import SwiftData
import SwiftUI

enum RootTab: String, Hashable {
    case library
    case albums
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewerPresenter = ViewerPresenter()
    @State private var selectionBarPresenter = SelectionBarPresenter()
    @State private var selectedTab: RootTab = {
        #if DEBUG
        // 调试辅助：INITIAL_TAB=albums 直接落在相簿页，方便自动化截图
        if ProcessInfo.processInfo.environment["INITIAL_TAB"] == "albums" {
            return .albums
        }
        #endif
        return .library
    }()

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("图库", systemImage: "photo.on.rectangle.angled", value: RootTab.library) {
                LibraryView()
            }
            Tab("相簿", systemImage: "rectangle.stack", value: RootTab.albums) {
                AlbumsView()
            }
        }
        // iPad 上自动转为侧栏（与原生相册的双形态一致）
        .tabViewStyle(.sidebarAdaptable)
        // 图库选择模式的底部栏：覆盖在 Tab 栏之上（不隐藏 Tab 栏、安全区零变化，
        // 照片流不会动 —— 原因见 SelectionBar.swift 注释）
        .overlay(alignment: .bottom) {
            if let session = selectionBarPresenter.session {
                SelectionBarOverlay(session: session)
            }
        }
        // 查看器：顶层 overlay 自绘过渡，不走系统呈现（见 PhotoViewer.swift 注释）
        .overlay {
            if let session = viewerPresenter.session {
                PhotoViewerOverlay(session: session)
            }
        }
        .statusBarHidden(viewerPresenter.session != nil && viewerPresenter.chromeHidden)
        .environment(viewerPresenter)
        .environment(selectionBarPresenter)
        .task {
            #if DEBUG
            DebugSeeder.applyLaunchTweaks()
            await DebugSeeder.seedIfRequested(context: modelContext)
            #endif
        }
    }
}
