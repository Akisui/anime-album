import SwiftData
import SwiftUI

/// 外观：跟随系统 / 浅色 / 深色（存 UserDefaults，App 根视图按它设 preferredColorScheme）
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearanceMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 设置（第三个 Tab）：一级页按类分组、各进二级页（与系统「设置」同样的彩色图标行）
struct SettingsView: View {
    @Environment(CloudSyncSettings.self) private var cloudSync
    @Environment(PrivacyLock.self) private var privacyLock

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CloudSyncSettingsView()
                    } label: {
                        SettingsRow(title: "iCloud 同步", systemImage: "icloud.fill", color: .blue,
                                    value: cloudSync.isEnabled ? "开" : "关")
                    }
                }

                Section {
                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        SettingsRow(title: "隐私与安全", systemImage: "lock.fill", color: .green,
                                    value: privacyLock.requiresAuthToOpen ? privacyLock.biometryName : nil)
                    }
                    NavigationLink {
                        DisplaySettingsView()
                    } label: {
                        SettingsRow(title: "外观与浏览", systemImage: "paintbrush.fill", color: .indigo)
                    }
                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        SettingsRow(title: "存储空间", systemImage: "internaldrive.fill", color: .gray)
                    }
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        SettingsRow(title: "关于\(AppInfo.name)", systemImage: "info", color: .orange)
                    }
                }

                #if DEBUG
                PushDiagnosticsSection()
                #endif
            }
            .navigationTitle("设置")
        }
    }
}

/// 一行：彩色圆角方块图标 + 标题 + 右侧当前值（系统「设置」样式）
struct SettingsRow: View {
    let title: String
    let systemImage: String
    let color: Color
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - iCloud 同步

private struct CloudSyncSettingsView: View {
    @Environment(CloudSyncSettings.self) private var cloudSync

    var body: some View {
        @Bindable var cloudSync = cloudSync
        Form {
            Section {
                Toggle("iCloud 同步", isOn: $cloudSync.isEnabled)
                if cloudSync.isEnabled {
                    LabeledContent("状态", value: cloudSync.statusText)
                }
            } footer: {
                Text(cloudSync.footerText)
            }
        }
        .navigationTitle("iCloud 同步")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 隐私与安全

private struct PrivacySettingsView: View {
    @Environment(PrivacyLock.self) private var privacyLock
    @AppStorage(OriginalDeletion.offerKey) private var offersOriginalDeletion = true

    var body: some View {
        let biometry = privacyLock.biometryName
        let available = privacyLock.canAuthenticate
        Form {
            // 两个开关改动（开或关）都要先验证，验证通过才生效
            Section {
                Toggle("打开 App 时需要\(biometry)", isOn: Binding(
                    get: { privacyLock.requiresAuthToOpen },
                    set: { enabled in Task { await privacyLock.setRequiresAuthToOpen(enabled) } }))
                Toggle("查看隐藏内容时需要\(biometry)", isOn: Binding(
                    get: { privacyLock.requiresAuthForHidden },
                    set: { enabled in Task { await privacyLock.setRequiresAuthForHidden(enabled) } }))
            } header: {
                Text("验证")
            } footer: {
                Text(available
                     ? "「查看隐藏内容」指把「…」菜单里的显示选项切到「只显示隐藏的」或「全部显示」。改动这两个开关也需要验证。"
                     : "这台设备没有设置密码，无法开启验证。")
            }
            .disabled(!available)

            Section {
                Picker("显示选项", selection: Binding(
                    get: { privacyLock.filtersAreGlobal },
                    set: { privacyLock.filtersAreGlobal = $0 })) {
                    Text("全局统一").tag(true)
                    Text("各页面分别设置").tag(false)
                }
                Toggle("隐藏相簿里也按照片单独隐藏", isOn: Binding(
                    get: { privacyLock.hiddenAlbumsHidePhotos },
                    set: { privacyLock.hiddenAlbumsHidePhotos = $0 }))
            } header: {
                Text("隐藏")
            } footer: {
                Text("显示选项「全局统一」时在任何地方切换，图库、相簿列表和所有相簿一起生效；「各页面分别设置」时各自记。隐藏相簿默认作用于其中全部照片：看得到这个相簿就看得到里面所有照片。离开 App 后，隐藏内容会自动收起。")
            }

            Section {
                Toggle("从照片图库导入后询问是否删除原图", isOn: $offersOriginalDeletion)
            } header: {
                Text("导入")
            } footer: {
                Text("放进\(AppInfo.name)的照片可以从系统相册删掉，只留在这里。删除时才会请求照片权限；删掉的先进系统「照片」的「最近删除」，30 天后彻底删除。")
            }
        }
        .navigationTitle("隐私与安全")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 外观与浏览

private struct DisplaySettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("viewerReadingOrder") private var readingOrderRaw = ViewerReadingOrder.leftToRight.rawValue

    var body: some View {
        Form {
            Section("外观") {
                Picker("外观", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Picker("查看顺序", selection: $readingOrderRaw) {
                    ForEach(ViewerReadingOrder.allCases) { order in
                        Label(order.title, systemImage: order.systemImage).tag(order.rawValue)
                    }
                }
            } header: {
                Text("浏览")
            } footer: {
                Text("查看照片和 PDF 时的翻页方式。也可以在查看器的「…」菜单里随时切换。")
            }
        }
        .navigationTitle("外观与浏览")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 存储空间

private struct StorageSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var counts: [(String, Int)] = []
    @State private var sizes: (originals: Int64, derived: Int64)?

    var body: some View {
        Form {
            Section("内容") {
                ForEach(counts, id: \.0) { title, count in
                    LabeledContent(title, value: "\(count)")
                }
            }
            Section {
                if let sizes {
                    LabeledContent("原件", value: Self.format(sizes.originals))
                    LabeledContent("缩略图与预览", value: Self.format(sizes.derived))
                } else {
                    HStack {
                        Text("正在计算…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView()
                    }
                }
            } header: {
                Text("本机占用")
            } footer: {
                Text("缩略图与预览由原件生成，用于快速浏览。开启 iCloud 同步时，原件存放在 iCloud 云盘，本机只在需要时下载。")
            }
        }
        .navigationTitle("存储空间")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            counts = countContent()
            sizes = await Task.detached(priority: .utility) { Self.measure() }.value
        }
    }

    private func countContent() -> [(String, Int)] {
        func count(_ type: Photo.MediaType...) -> Int {
            let raws = type.map(\.rawValue)
            return (try? modelContext.fetchCount(FetchDescriptor<Photo>(
                predicate: #Predicate { raws.contains($0.mediaType) }))) ?? 0
        }
        return [
            ("照片", count(.image, .gif, .live)),
            ("视频", count(.video)),
            ("PDF", count(.pdf)),
            ("相簿", (try? modelContext.fetchCount(FetchDescriptor<Album>())) ?? 0),
        ]
    }

    private nonisolated static func measure() -> (originals: Int64, derived: Int64) {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return (0, 0)
        }
        let library = support.appendingPathComponent("PhotoLibrary", isDirectory: true)
        let originals = size(of: library.appendingPathComponent("originals", isDirectory: true))
        let total = size(of: library)
        return (originals, max(total - originals, 0))
    }

    private nonisolated static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 关于

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("BrandIcon")
                        .resizable()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    Text(AppInfo.name)
                        .font(.title2.weight(.semibold))
                    Text("版本 \(AppInfo.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(LegalDocument.allCases) { document in
                    NavigationLink(document.title) {
                        LegalDocumentView(document: document)
                    }
                }
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
/// 调试版：点进相簿时的推入诊断（见 PushDiagnostics）
private struct PushDiagnosticsSection: View {
    private let diagnostics = PushDiagnostics.shared

    var body: some View {
        Section {
            NavigationLink("推入诊断（\(diagnostics.lines.count) 条）") {
                List {
                    ForEach(Array(diagnostics.lines.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                    }
                }
                .navigationTitle("推入诊断")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("清空") { diagnostics.clear() }
                }
            }
        } header: {
            Text("调试")
        }
    }
}
#endif
