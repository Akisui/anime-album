import SwiftUI

/// 用户协议 / 隐私政策 / 免责声明（首次启动同意页、设置 › 关于共用）。
/// 上架用的网页版在 AppStore/ 目录（内容与这里一致，改一处要同步另一处）
enum LegalDocument: String, Identifiable, CaseIterable {
    case terms
    case privacy
    case disclaimer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terms: "用户协议"
        case .privacy: "隐私政策"
        case .disclaimer: "免责声明"
        }
    }

    var sections: [(heading: String, body: String)] {
        let name = AppInfo.name
        switch self {
        case .privacy:
            return [
                ("概述", "\(name)（以下简称「本 App」）尊重并保护你的隐私。本 App 不设账号体系，不收集、不上传、不出售任何个人信息，不包含广告，也不接入任何第三方统计、分析或广告 SDK。"),
                ("我们处理的信息", "你导入的照片、视频、实况照片、PDF 等内容，以及你创建的相簿、排序、隐藏标记和设置，只保存在你的设备上（开启 iCloud 同步时也保存在你本人的 iCloud 中）。开发者无法访问这些内容。"),
                ("照片与文件访问", "本 App 通过系统提供的照片选择器和文件选择器，只读取你主动选中的项目，不会读取你未选择的任何内容。从照片图库导入后，如果你选择「从系统相册删除原图」，本 App 会在这时请求照片图库权限，并且只删除你刚导入、确认已保存到本 App 中的那些项目；被删除的项目会先移到系统「照片」的「最近删除」中。"),
                ("面容 ID / 触控 ID", "开启「打开 App 时验证」或「查看隐藏内容时验证」后，验证由 iOS 系统完成。本 App 只获得「验证是否通过」的结果，不会接触、保存或上传你的面部或指纹数据。"),
                ("iCloud 同步", "开启 iCloud 同步后，你的图库、相簿及其中的文件会通过 Apple 的 iCloud（CloudKit 私有数据库与 iCloud 云盘）在你登录同一 Apple 账户的设备之间同步。这些数据存储在你本人的 iCloud 空间中，受 Apple 隐私政策约束，开发者无法访问。你可以随时在设置中关闭同步。"),
                ("网络", "除 iCloud 同步外，本 App 不会发起任何网络请求。"),
                ("数据删除", "在本 App 中删除照片或相簿会同时删除设备上的对应文件；开启同步时也会从你的 iCloud 中删除。卸载本 App 会删除设备上的全部数据（iCloud 中的数据可在系统「设置 › Apple 账户 › iCloud」中管理）。"),
                ("未成年人", "本 App 不面向特定年龄群体收集任何信息。未成年人请在监护人指导下使用。"),
                ("政策更新", "本政策如有更新，会随 App 版本发布，并在你下次打开 App 时请你重新确认。生效日期：\(AppInfo.termsEffectiveDate)。"),
            ]
        case .terms:
            return [
                ("协议的接受", "欢迎使用\(name)。在使用本 App 前，请仔细阅读本协议。你点击「同意」或开始使用本 App，即表示你已阅读、理解并同意本协议及《隐私政策》的全部内容。"),
                ("服务内容", "本 App 是一款在设备本地运行的相册工具，用于导入、整理、浏览和隐藏你的照片、视频、实况照片与 PDF 文件，并可选通过你本人的 iCloud 在设备之间同步。本 App 本身不提供、不分发任何图片或其他内容。"),
                ("你的内容", "你导入的全部内容归你所有，由你自行负责。请确保你拥有或已获得相应授权，并遵守所在地的法律法规，不得利用本 App 存储或传播违法内容。"),
                ("隐藏与验证", "「隐藏」功能用于在日常浏览中收起指定的照片和相簿，面容 ID / 触控 ID 验证由 iOS 系统提供。它们能降低他人随手看到的可能，但不能替代设备密码等系统安全措施，请妥善保管你的设备与密码。"),
                ("数据与备份", "你的数据存储在设备本地以及（如开启）你本人的 iCloud 中。因设备故障、系统更新、误操作、卸载 App 或 iCloud 服务异常等原因可能造成数据丢失，请定期备份重要内容。"),
                ("知识产权", "本 App 的软件、界面设计、图标与名称等知识产权归开发者所有。未经许可，不得对本 App 进行反向工程、复制、修改或用于商业用途。"),
                ("协议的变更与终止", "开发者可能根据需要更新本协议，更新后的协议会随 App 版本发布，并在你下次打开 App 时请你重新确认。你可以随时停止使用并卸载本 App。"),
                ("其他", "本协议未尽事宜，适用相关法律法规的规定。生效日期：\(AppInfo.termsEffectiveDate)。"),
            ]
        case .disclaimer:
            return [
                ("内容版权", "本 App 是一个本地相册工具，本身不提供、不分发任何图片或其他内容。你导入的内容由你自行提供，请确保你拥有或已获得相应授权。因导入、保存或分享内容产生的任何版权或其他纠纷，由使用者自行承担。"),
                ("第三方内容与商标", "你导入的内容中出现的任何作品、人物、名称、商标及形象，其权利归各自权利人所有。本 App 与这些权利人不存在任何关联、授权或背书关系。"),
                ("数据安全", "本 App 按「现状」提供。尽管我们尽力保证数据安全，但因设备故障、系统更新、误操作、卸载或 iCloud 服务异常等原因造成的数据丢失，开发者不承担责任。请定期备份重要内容。"),
                ("服务变更", "开发者可能根据需要更新、调整或停止本 App 的部分功能，恕不另行通知。"),
            ]
        }
    }
}

/// 法律文本页
struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(document.sections, id: \.heading) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.heading)
                            .font(.headline)
                        Text(section.body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
