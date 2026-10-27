import SwiftData
import SwiftUI

@main
struct AnimeAlbumApp: App {
    let container: ModelContainer
    @State private var commandCenter = AppCommandCenter()
    @State private var cloudSync: CloudSyncSettings
    @State private var privacyLock = PrivacyLock()
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    init() {
        #if DEBUG
        _ = PushDiagnostics.shared
        // ONBOARDING=1：当作第一次打开（显示介绍与同意页）；ONBOARDING=old：当作同意过旧版条款（-1）
        if let raw = ProcessInfo.processInfo.environment["ONBOARDING"] {
            UserDefaults.standard.set(raw == "old" ? -1 : 0, forKey: "acceptedTermsVersion")
        }
        // ICLOUD_ON=1：当作同步开关已打开启动（验证 iCloud 不可用时退回纯本地）
        if ProcessInfo.processInfo.environment["ICLOUD_ON"] == "1" {
            UserDefaults.standard.set(true, forKey: CloudSyncSettings.enabledKey)
        }
        #endif
        let schema = Schema([Photo.self, Album.self, AlbumEntry.self])
        // iCloud 同步：开关打开时数据库以 CloudKit 模式打开（私有数据库，SwiftData 自动镜像）；
        // 打不开（未登录、权限缺失等）就退回纯本地，不让 App 因此起不来
        var syncing = false
        var made: ModelContainer?
        // 先确认这台设备当前能用 iCloud（已登录、iCloud 云盘打开、App 有权限）：缺权限时 CloudKit 会直接中断程序
        //（模拟器不签名的版本实测），未登录时没法同步 —— 都退回纯本地
        if CloudSyncSettings.enabledAtLaunch, FileManager.default.ubiquityIdentityToken != nil {
            let cloud = ModelConfiguration(schema: schema,
                                           cloudKitDatabase: .private(CloudSyncSettings.containerIdentifier))
            made = try? ModelContainer(for: schema, configurations: cloud)
            syncing = made != nil
        }
        do {
            container = try made ?? ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        } catch {
            fatalError("无法初始化数据库: \(error)")
        }
        ImageStore.shared.configureCloudOriginals(enabled: syncing)
        _cloudSync = State(initialValue: CloudSyncSettings(isActive: syncing))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(commandCenter)
                .environment(cloudSync)
                .environment(privacyLock)
                .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
        }
        .modelContainer(container)
        .commands { AppCommands(center: commandCenter) }
    }
}
