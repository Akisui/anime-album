import SwiftData
import SwiftUI

enum RootTab: Hashable {
    case library
    case albums
    /// iPad 侧栏里的单个相簿（DESIGN.md §6.6：侧栏列出图库 / 各相簿）
    case album(UUID)
    case settings
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppCommandCenter.self) private var commandCenter
    @Query(sort: \Album.sortIndex) private var albums: [Album]
    @State private var newAlbumName = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewerPresenter = ViewerPresenter()
    @State private var selectionBarPresenter = SelectionBarPresenter()
    /// 启动后在屏幕外预先搭一遍相簿页（见 albumPagePrewarm）
    @State private var prewarmAlbum: Album?
    /// 打开 App 默认落在相簿页（用户要求）
    @State private var selectedTab: RootTab = {
        #if DEBUG
        // 调试辅助：INITIAL_TAB=library|albums|settings 指定启动页；没指定时，图库专用的调试开关（自动打开查看器等）从图库启动
        let env = ProcessInfo.processInfo.environment
        switch env["INITIAL_TAB"] {
        case "library": return .library
        case "albums": return .albums
        case "settings": return .settings
        default:
            let libraryKeys = ["OPEN_VIEWER", "OPEN_INDEX", "OPEN_PDF", "PDF_PAGE", "AUTO_SELECT", "AUTO_CYCLES", "SWITCH_TO_ALBUMS"]
            if libraryKeys.contains(where: { env[$0] != nil }) {
                return .library
            }
        }
        #endif
        return .albums
    }()

    var body: some View {
        tabs
            .background { albumPagePrewarm }
            .environment(viewerPresenter)
            .environment(selectionBarPresenter)
            .task { await launchTasks() }
            #if DEBUG
            .onChange(of: scenePhase, initial: true) { _, phase in
                PushDiagnostics.shared.note("scenePhase \(phase)")
            }
            .onChange(of: selectedTab) { _, tab in
                PushDiagnostics.shared.note("切到 Tab \(tab)")
            }
            #endif
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            Tab("图库", systemImage: "photo.on.rectangle.angled", value: RootTab.library) {
                LibraryView()
            }
            Tab("相簿", systemImage: "rectangle.stack", value: RootTab.albums) {
                AlbumsView()
            }
            // 各相簿只出现在 iPad 侧栏。紧凑宽度（iPhone）下整组不加：.tabPlacement(.sidebarOnly) /
            // .defaultVisibility(.hidden, for: .tabBar) 在 iPhone 底部 Tab 栏上都不生效，相簿会变成一个个 Tab（实测）
            if horizontalSizeClass == .regular {
                TabSection("我的相簿") {
                    ForEach(albums) { album in
                        Tab(album.name, systemImage: "rectangle.stack", value: RootTab.album(album.id)) {
                            NavigationStack {
                                AlbumDetailView(album: album)
                            }
                        }
                        .tabPlacement(.sidebarOnly)
                    }
                }
                .defaultVisibility(.hidden, for: .tabBar)
            }
            Tab("设置", systemImage: "gearshape", value: RootTab.settings) {
                SettingsView()
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
        // ⌘N：命名框由这里弹（相簿页可能还没创建），存储后切到相簿页
        .alert("新建相簿", isPresented: newAlbumAlertPresented) {
            TextField("相簿名称", text: $newAlbumName)
            Button("取消", role: .cancel) {}
            Button("存储") {
                let trimmed = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                AlbumOperations.createAlbum(named: trimmed.isEmpty ? "未命名相簿" : trimmed, in: modelContext)
                try? modelContext.save()
                selectedTab = .albums
            }
        } message: {
            Text("为此相簿输入一个名称。")
        }
        // 分屏变窄后侧栏相簿不复存在：退回相簿页
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            if sizeClass != .regular, case .album = selectedTab {
                selectedTab = .albums
            }
        }
        // 侧栏里选中的相簿被删除：退回相簿页
        .onChange(of: albums.map(\.id)) { _, ids in
            if case .album(let id) = selectedTab, !ids.contains(id) {
                selectedTab = .albums
            }
        }
        .statusBarHidden(viewerPresenter.session != nil && viewerPresenter.chromeHidden)
    }

    private func launchTasks() async {
        // 旧规则拆页的 PDF 在后台按新规则重做
        let pdfs = (try? modelContext.fetch(FetchDescriptor<Photo>()))?.filter(\.isPDF).map(\.id) ?? []
        PDFPageStore.shared.upgrade(photoIDs: pdfs) { photoID, width, height in
            Task { @MainActor in
                let id = photoID
                var descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.id == id })
                descriptor.fetchLimit = 1
                guard let photo = (try? modelContext.fetch(descriptor))?.first else { return }
                photo.width = width
                photo.height = height
                // 版本号变了：网格 / 封面 / 查看器重新加载缩略图
                photo.editRevision += 1
                ThumbnailCache.shared.evict(photoID: photoID)
                try? modelContext.save()
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard prewarmAlbum == nil, let first = albums.first else { return }
            prewarmAlbum = first
            #if DEBUG
            PushDiagnostics.shared.note("预搭相簿页开始")
            #endif
            try? await Task.sleep(for: .seconds(0.5))
            prewarmAlbum = nil
            #if DEBUG
            PushDiagnostics.shared.note("预搭相簿页结束")
            #endif
        }
        #if DEBUG
        DebugSeeder.applyLaunchTweaks()
        await DebugSeeder.seedIfRequested(context: modelContext)
        let env = ProcessInfo.processInfo.environment
        // SIDEBAR_ALBUM=1：直接选中侧栏第一个相簿（iPad）；AUTO_NEW_ALBUM=1：1.5s 后模拟按下 ⌘N
        if env["SIDEBAR_ALBUM"] == "1", let first = albums.first {
            selectedTab = .album(first.id)
        }
        // SWITCH_TO_ALBUMS=秒：从图库启动，等这么久后切到相簿页（模拟手动切 Tab；配合 TAP_ALBUM 复现首次进相簿）
        if let raw = env["SWITCH_TO_ALBUMS"], let delay = Double(raw) {
            try? await Task.sleep(for: .seconds(delay))
            selectedTab = .albums
        }
        if env["AUTO_NEW_ALBUM"] == "1" {
            try? await Task.sleep(for: .seconds(1.5))
            commandCenter.newAlbumRequested = true
        }
        #endif
    }

    /// 启动后第一次进相簿要现场搭相簿页（SwiftUI 第一次建导航栏按钮 / 菜单、UIKit 第一次建网格），
    /// 主线程卡 140～180ms（模拟器实测，第二次进 0 掉帧），手机刚启动时更久，推入动画被吃掉、相簿页直接出现（用户反馈）。
    /// 启动 1s 后在屏幕外不可见地搭一遍再拆掉，之后点进相簿就和第二次进入一样
    @ViewBuilder
    private var albumPagePrewarm: some View {
        if let prewarmAlbum {
            NavigationStack {
                AlbumDetailView(album: prewarmAlbum)
            }
            .environment(\.isPrewarmCopy, true)
            .frame(width: 390, height: 700)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var newAlbumAlertPresented: Binding<Bool> {
        Binding(
            get: { commandCenter.newAlbumRequested },
            set: { presented in
                if presented {
                    newAlbumName = ""
                }
                commandCenter.newAlbumRequested = presented
            })
    }
}

extension EnvironmentValues {
    /// 屏幕外预搭的页面（见 RootView.albumPagePrewarm）：只为提前搭好视图，不该产生任何副作用
    @Entry var isPrewarmCopy = false
}
