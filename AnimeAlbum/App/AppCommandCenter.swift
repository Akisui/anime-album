import SwiftUI

/// 菜单栏命令 / 键盘快捷键（iPad 外接键盘，DESIGN.md §6.6）与页面之间的桥：
/// 命令只置一个请求标记，由负责的页面消费（页面可能还没创建，标记会等到它出现）
@MainActor
@Observable
final class AppCommandCenter {
    /// ⌘N 新建相簿：RootView 据此弹出命名框（关闭时清掉）
    var newAlbumRequested = false
}

struct AppCommands: Commands {
    let center: AppCommandCenter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建相簿") {
                center.newAlbumRequested = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}
