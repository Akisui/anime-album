import Foundation

/// App 的名称、版本与条款版本（首次启动的同意页、关于页、法律文本共用）
enum AppInfo {
    static let name = "推し箱"
    static let englishName = "Oshibako"

    /// 用户协议 / 隐私政策的版本：内容有实质变化时 +1，用户下次打开 App 时重新确认
    static let termsVersion = 1
    static let termsEffectiveDate = "2026 年 10 月 28 日"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short)（\(build)）"
    }
}
