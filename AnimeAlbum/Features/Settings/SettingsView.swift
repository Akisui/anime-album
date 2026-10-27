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

/// 设置（第三个 Tab）：iCloud 同步 / 外观 / 关于
struct SettingsView: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @Environment(CloudSyncSettings.self) private var cloudSync
    @Environment(PrivacyLock.self) private var privacyLock

    var body: some View {
        NavigationStack {
            Form {
                iCloudSection

                privacySection

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
                    NavigationLink("关于角色相册") {
                        AboutView()
                    }
                }

                #if DEBUG
                PushDiagnosticsSection()
                #endif
            }
            .navigationTitle("设置")
        }
    }

    /// 两个开关改动（开或关）都要先验证，验证通过才生效
    private var privacySection: some View {
        let biometry = privacyLock.biometryName
        let available = privacyLock.canAuthenticate
        return Section {
            Toggle("打开 App 时需要\(biometry)", isOn: Binding(
                get: { privacyLock.requiresAuthToOpen },
                set: { enabled in Task { await privacyLock.setRequiresAuthToOpen(enabled) } }))
            Toggle("查看隐藏内容时需要\(biometry)", isOn: Binding(
                get: { privacyLock.requiresAuthForHidden },
                set: { enabled in Task { await privacyLock.setRequiresAuthForHidden(enabled) } }))
        } header: {
            Text("隐私")
        } footer: {
            if available {
                Text("「查看隐藏内容」指在图库、相簿列表或相簿里把显示选项切到「只显示隐藏的」或「全部显示」。离开 App 后，隐藏内容会重新收起。")
            } else {
                Text("这台设备没有设置密码，无法开启。")
            }
        }
        .disabled(!available)
    }

    @ViewBuilder
    private var iCloudSection: some View {
        @Bindable var cloudSync = cloudSync
        Section {
            Toggle("iCloud 同步", isOn: $cloudSync.isEnabled)
            if cloudSync.isEnabled {
                LabeledContent("状态", value: cloudSync.statusText)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(cloudSync.footerText)
        }
    }
}

/// 关于：图标、版本，隐私声明 / 免责声明
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short)（\(build)）"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("角色相册")
                        .font(.title2.weight(.semibold))
                    Text("版本 \(version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section {
                NavigationLink("隐私声明") { PrivacyPolicyView() }
                NavigationLink("免责声明") { DisclaimerView() }
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 隐私声明
struct PrivacyPolicyView: View {
    var body: some View {
        LegalTextView(title: "隐私声明", sections: [
            ("概述", "角色相册（以下简称「本 App」）尊重并保护你的隐私。本 App 不设账号体系，不收集、不上传、不出售任何个人信息，也不包含任何广告或第三方统计、分析 SDK。"),
            ("照片与文件", "你导入的照片、视频、PDF 等内容只保存在本机的 App 沙盒中。本 App 通过系统提供的照片选择器和文件选择器读取你主动选中的项目，不会请求访问你的整个照片图库，也不会读取你未选择的任何内容。"),
            ("iCloud 同步", "开启 iCloud 同步后，你的图库、相簿及其中的文件会通过 Apple 的 iCloud（CloudKit 私有数据库与 iCloud 云盘）在你登录同一 Apple 账户的设备之间同步。这些数据存储在你本人的 iCloud 空间中，受 Apple 隐私政策约束，开发者无法访问。你可以随时在「设置」中关闭同步。"),
            ("网络", "除 iCloud 同步外，本 App 不会发起任何网络请求。"),
            ("数据删除", "在本 App 中删除照片或相簿会同时删除本机上的对应文件；开启同步时也会从你的 iCloud 中删除。卸载本 App 会删除本机上的全部数据（iCloud 中的数据需在系统「设置 › Apple 账户 › iCloud」中管理）。"),
            ("变更", "如本声明有更新，会随 App 版本一并发布。"),
        ])
    }
}

/// 免责声明
struct DisclaimerView: View {
    var body: some View {
        LegalTextView(title: "免责声明", sections: [
            ("内容版权", "本 App 是一个本地相册工具，本身不提供、不分发任何图片或其他内容。你导入的内容由你自行提供，请确保你拥有或已获得相应授权，并遵守所在地的法律法规。因导入、保存或分享内容产生的任何版权或其他纠纷，由使用者自行承担。"),
            ("角色与商标", "App 中出现的任何作品、角色名称及形象，其著作权和商标权归各自权利人所有。本 App 与这些权利人不存在任何关联、授权或背书关系。"),
            ("数据安全", "本 App 按「现状」提供。尽管我们尽力保证数据安全，但因设备故障、系统更新、误操作、卸载或 iCloud 服务异常等原因造成的数据丢失，开发者不承担责任。请定期备份重要内容。"),
            ("服务变更", "开发者可能根据需要更新、调整或停止本 App 的部分功能，恕不另行通知。"),
        ])
    }
}

private struct LegalTextView: View {
    let title: String
    let sections: [(String, String)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections, id: \.0) { heading, body in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(heading)
                            .font(.headline)
                        Text(body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
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
