import CoreData
import Foundation
import Observation

/// iCloud 同步开关与状态（DESIGN.md §8.1）。
/// 数据库是否走 CloudKit 在启动时决定（ModelContainer 建好后不能热切换），所以开关改动在下次打开 App 时生效。
/// 同步内容：图库 / 相簿的记录走 CloudKit 私有数据库（SwiftData 自带镜像），原图文件放 iCloud 云盘的 App 容器
/// （见 ImageStore 的 ubiquity 路径），缩略图、PDF 拆页等派生文件各设备本地重建
@MainActor
@Observable
final class CloudSyncSettings {
    nonisolated static let containerIdentifier = "iCloud.dev.akisui.AnimeAlbum"
    nonisolated static let enabledKey = "iCloudSyncEnabled"

    /// 启动时读一次：本次运行数据库是否以 CloudKit 模式打开
    nonisolated static var enabledAtLaunch: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// 本次运行实际是否在同步（开关打开且数据库成功以 CloudKit 模式打开）
    let isActive: Bool

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// 最近一次同步事件（SwiftData 底层的 NSPersistentCloudKitContainer 发出）
    private(set) var lastEvent: (kind: String, date: Date, succeeded: Bool)?
    private(set) var isSyncing = false

    @ObservationIgnored private var observer: NSObjectProtocol?

    init(isActive: Bool) {
        self.isActive = isActive
        isEnabled = Self.enabledAtLaunch
        guard isActive else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
            else {
                return
            }
            let kind: String
            switch event.type {
            case .setup: kind = "准备"
            case .import: kind = "下载"
            case .export: kind = "上传"
            @unknown default: kind = "同步"
            }
            MainActor.assumeIsolated {
                self?.isSyncing = event.endDate == nil
                if let end = event.endDate {
                    self?.lastEvent = (kind, end, event.succeeded)
                }
            }
        }
    }

    var accountAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var statusText: String {
        if !accountAvailable {
            return "未登录 iCloud"
        }
        if isEnabled != isActive {
            return isEnabled ? "下次打开 App 时开始同步" : "下次打开 App 时停止同步"
        }
        if isSyncing {
            return "正在同步…"
        }
        if let lastEvent {
            let time = lastEvent.date.formatted(date: .omitted, time: .shortened)
            return lastEvent.succeeded ? "已同步（\(time)）" : "同步出错（\(time)），稍后重试"
        }
        return "已开启"
    }

    var footerText: String {
        if !accountAvailable {
            return "请先在系统「设置」中登录 Apple 账户并打开 iCloud 云盘。"
        }
        return "开启后，图库、相簿和其中的照片、视频、PDF 会在登录同一 Apple 账户的设备之间同步，占用你的 iCloud 空间。开关改动在下次打开 App 时生效。"
    }
}
