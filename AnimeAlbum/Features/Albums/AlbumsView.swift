import SwiftData
import SwiftUI

struct AlbumsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SelectionBarPresenter.self) private var selectionBarPresenter
    @Query(sort: \Album.sortIndex) private var albums: [Album]

    @State private var showingNewAlbum = false
    @State private var newAlbumName = ""
    @State private var renamingAlbum: Album?
    @State private var renameText = ""
    @State private var albumsPendingDeletion: [Album] = []
    @State private var navigationPath = NavigationPath()
    @State private var appearanceGate = AppearanceGate()

    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []

    // iPhone 竖屏两列，iPad / 横屏按宽度自适应（DESIGN.md §6.6）
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)]

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if albums.isEmpty {
                    ContentUnavailableView {
                        Label("没有相簿", systemImage: "rectangle.stack")
                    } description: {
                        Text("用相簿把喜欢的角色图片分门别类。")
                    } actions: {
                        Button("新建相簿") { promptNewAlbum() }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                    }
                } else {
                    albumsGrid
                }
            }
            .navigationTitle("相簿")
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
            }
            .toolbar { toolbarContent }
            .onChange(of: selectedIDs) {
                selectionBarPresenter.update(count: selectedIDs.count)
            }
            .onChange(of: albums.isEmpty) { _, isEmpty in
                if isEmpty, isSelecting {
                    exitSelectionMode()
                }
            }
            .alert("新建相簿", isPresented: $showingNewAlbum) {
                TextField("相簿名称", text: $newAlbumName)
                Button("取消", role: .cancel) {}
                Button("存储") {
                    AlbumOperations.createAlbum(named: normalizedName(newAlbumName), in: modelContext)
                }
            } message: {
                Text("为此相簿输入一个名称。")
            }
            .alert("重命名相簿", isPresented: renameAlertPresented) {
                TextField("相簿名称", text: $renameText)
                Button("取消", role: .cancel) { renamingAlbum = nil }
                Button("存储") {
                    renamingAlbum?.name = normalizedName(renameText)
                    renamingAlbum = nil
                }
            }
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: deleteDialogPresented,
                titleVisibility: .visible
            ) {
                Button(albumsPendingDeletion.count > 1 ? "删除 \(albumsPendingDeletion.count) 个相簿" : "删除相簿",
                       role: .destructive) {
                    deletePendingAlbums()
                }
            } message: {
                Text("相簿中的照片不会被删除，仍保留在图库中。")
            }
            .task {
                #if DEBUG
                let env = ProcessInfo.processInfo.environment
                // 调试辅助：OPEN_ALBUM=1 直接进入第一个相簿，方便自动化截图
                if env["OPEN_ALBUM"] == "1", let first = albums.first {
                    navigationPath.append(first)
                }
                // TAP_ALBUM=秒：等这么久后按点按同一套逻辑打开第一个相簿，并逐帧记录推入期间的掉帧
                // 放在独立 Task 里：推入后根页面消失、.task 被取消，`try? await Task.sleep` 会立即返回，后续步骤全挤在一起
                if let raw = env["TAP_ALBUM"], let delay = Double(raw), let first = albums.first { Task {
                    try? await Task.sleep(for: .seconds(delay))
                    var last = CACurrentMediaTime()
                    var gaps: [Int] = []
                    let monitor = DebugDisplayLink { _ in
                        let now = CACurrentMediaTime()
                        if now - last > 0.020 { gaps.append(Int((now - last) * 1000)) }
                        last = now
                    }
                    monitor.start()
                    open(first)
                    try? await Task.sleep(for: .seconds(1))
                    monitor.stop()
                    print("PUSH_HITCHES first \(gaps)")
                    // 返回再进一次，对比第二次
                    navigationPath.removeLast()
                    try? await Task.sleep(for: .seconds(1))
                    gaps = []
                    last = CACurrentMediaTime()
                    let monitor2 = DebugDisplayLink { _ in
                        let now = CACurrentMediaTime()
                        if now - last > 0.020 { gaps.append(Int((now - last) * 1000)) }
                        last = now
                    }
                    monitor2.start()
                    open(first)
                    try? await Task.sleep(for: .seconds(1))
                    monitor2.stop()
                    print("PUSH_HITCHES second \(gaps)")
                } }
                // ALBUMS_SELECT=n 自动进入相簿列表的选择模式并预选前 n 个
                if let raw = env["ALBUMS_SELECT"], let count = Int(raw) {
                    try? await Task.sleep(for: .seconds(0.6))
                    enterSelectionMode()
                    selectedIDs = Set(albums.prefix(count).map(\.id))
                }
                #endif
            }
        }
    }

    private var albumsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(albums) { album in
                    // 普通模式点按进入相簿；选择模式点按切换选中（不导航）
                    Button {
                        if isSelecting {
                            toggleSelection(album)
                        } else {
                            open(album)
                        }
                    } label: {
                        AlbumCard(album: album, isSelected: isSelecting && selectedIDs.contains(album.id))
                    }
                    .buttonStyle(PressableCardStyle())
                    .hoverEffect(.highlight)
                    // 长按预览只抬起封面（与原生一致），不连带下方文字
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: AlbumCoverView.cornerRadius, style: .continuous))
                    .contextMenu {
                        if !isSelecting {
                            Button("重命名", systemImage: "pencil") {
                                renameText = album.name
                                renamingAlbum = album
                            }
                            Button("删除相簿", systemImage: "trash", role: .destructive) {
                                albumsPendingDeletion = [album]
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background { AppearanceGateView(gate: appearanceGate).frame(width: 0, height: 0) }
    }

    private func open(_ album: Album) {
        #if DEBUG
        PushDiagnostics.shared.albumTapped(album.name)
        if !appearanceGate.hasAppeared {
            PushDiagnostics.shared.note("  相簿列表还没出现完成，推入排到出现完成时")
        }
        #endif
        // 第一次切到相簿 Tab 后约 0.7s 内，相簿列表还没「出现完成」，这时推入系统不加动画、相簿页直接出现（真机诊断 + 模拟器复现）。
        // 这段时间里点的先排着，出现完成时再推入
        appearanceGate.run {
            // 明确带动画推入
            var transaction = Transaction(animation: .default)
            transaction.disablesAnimations = false
            #if DEBUG
            // PUSH_NO_ANIM=1：故意不带动画推入（验证推入诊断能分辨出来）
            if ProcessInfo.processInfo.environment["PUSH_NO_ANIM"] == "1" {
                transaction = Transaction()
                transaction.disablesAnimations = true
            }
            #endif
            withTransaction(transaction) {
                navigationPath.append(album)
            }
        }
    }

    /// 两种模式各用一套独立的工具栏项、整组替换（原因见 LibraryView.toolbarContent）
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarTrailing) {
                Button("取消") { exitSelectionMode() }
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !albums.isEmpty {
                    Button("选择") { enterSelectionMode() }
                }
                Button("新建相簿", systemImage: "plus") { promptNewAlbum() }
            }
        }
    }

    private func promptNewAlbum() {
        newAlbumName = ""
        showingNewAlbum = true
    }

    // MARK: 选择模式

    private func enterSelectionMode() {
        isSelecting = true
        // 底部栏由 RootView 顶层渲染（覆盖 Tab 栏）；选相簿时只有删除
        selectionBarPresenter.beginAlbums {
            albumsPendingDeletion = albums.filter { selectedIDs.contains($0.id) }
        }
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedIDs = []
        selectionBarPresenter.end()
    }

    private func toggleSelection(_ album: Album) {
        if selectedIDs.contains(album.id) {
            selectedIDs.remove(album.id)
        } else {
            selectedIDs.insert(album.id)
        }
    }

    private var deleteDialogTitle: String {
        if albumsPendingDeletion.count == 1, let album = albumsPendingDeletion.first {
            return "删除相簿「\(album.name)」？"
        }
        return "删除 \(albumsPendingDeletion.count) 个相簿？"
    }

    private func deletePendingAlbums() {
        for album in albumsPendingDeletion {
            modelContext.delete(album)
        }
        albumsPendingDeletion = []
        if isSelecting {
            exitSelectionMode()
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(get: { renamingAlbum != nil }, set: { if !$0 { renamingAlbum = nil } })
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(get: { !albumsPendingDeletion.isEmpty }, set: { if !$0 { albumsPendingDeletion = [] } })
    }

    private func normalizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名相簿" : trimmed
    }
}

/// 相簿卡片：方形圆角封面 + 名称 + 数量（原生相册样式）
struct AlbumCard: View {
    let album: Album
    var isSelected = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlbumCoverView(photo: album.coverPhoto)
                // 勾选态与照片网格一致：白色薄罩 + 右下角徽标
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: AlbumCoverView.cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(SelectionStyle.overlayOpacity))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        SelectionBadge()
                            .padding(SelectionStyle.badgeInset + 3)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1), value: isSelected)
            Text(album.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 8)
            Text("\(album.photoCount) 张")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.top, 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AlbumCoverView: View {
    static let cornerRadius: CGFloat = 10

    let photo: Photo?

    @State private var image: UIImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Color(.secondarySystemBackground))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(shape)
            // 发丝描边：浅色封面贴在白底上时也有清晰边界
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            // 裁剪后（editRevision 变了）重新加载
            .task(id: "\(photo?.id.uuidString ?? "")#\(photo?.editRevision ?? 0)") {
                guard let photo else {
                    image = nil
                    return
                }
                image = await ThumbnailCache.shared.image(for: photo.id, kind: .small)
            }
    }
}

/// 卡片按压反馈：按下即刻轻微缩小、松手回弹（临界阻尼，不过冲）；
/// 「减弱动态效果」开启时改为降低不透明度
struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// 页面第一次「出现完成」（viewDidAppear）之前要做的事排到那时再做。
/// 第一次切到某个 Tab 时，iOS 18 的 Tab 切换过渡里才现搭这一页的导航，到它出现完成（约 0.7s，比看得见的交叉淡化长得多）之前
/// 推入会被系统直接跳过动画；第二次以后切过去没有这个问题（实测）
@MainActor
final class AppearanceGate {
    private(set) var hasAppeared = false
    private var pending: (() -> Void)?

    /// 已出现完成就立即执行；否则排着（只留最后一次），出现完成时执行，最晚 1s 后兜底执行
    func run(_ action: @escaping () -> Void) {
        if hasAppeared {
            action()
            return
        }
        pending = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.flush()
        }
    }

    fileprivate func didAppear() {
        hasAppeared = true
        flush()
    }

    private func flush() {
        let action = pending
        pending = nil
        action?()
    }
}

/// 把所在页面的 viewDidAppear 转给 AppearanceGate（作为子控制器，随所在页面一起收到出现回调）
struct AppearanceGateView: UIViewControllerRepresentable {
    let gate: AppearanceGate

    func makeUIViewController(context: Context) -> Controller {
        Controller(gate: gate)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private let gate: AppearanceGate

        init(gate: AppearanceGate) {
            self.gate = gate
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            gate.didAppear()
        }
    }
}
