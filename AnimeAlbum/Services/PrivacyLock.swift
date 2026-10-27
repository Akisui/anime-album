import LocalAuthentication
import SwiftUI

/// 隐私：打开 App 时验证、查看隐藏内容时验证（设置里两个开关），以及本次运行中「App 已解锁」「隐藏内容已解锁」的状态。
/// 验证用 `.deviceOwnerAuthentication`：面容 ID / 触控 ID，不可用或失败多次时退回设备密码。
/// App 进入后台时两种解锁都失效：回来时（开了开关的话）重新验证 App，显示选项回到「不显示隐藏的」
@MainActor
@Observable
final class PrivacyLock {
    nonisolated static let appLockKey = "requireAuthToOpen"
    nonisolated static let hiddenLockKey = "requireAuthForHidden"

    var requiresAuthToOpen: Bool {
        didSet { UserDefaults.standard.set(requiresAuthToOpen, forKey: Self.appLockKey) }
    }

    var requiresAuthForHidden: Bool {
        didSet { UserDefaults.standard.set(requiresAuthForHidden, forKey: Self.hiddenLockKey) }
    }

    /// App 已解锁（没开「打开时验证」时始终为 true）
    private(set) var isAppUnlocked: Bool
    /// 隐藏内容已解锁：某页切到「只显示隐藏的 / 全部显示」时置上，进入后台时清掉
    private(set) var isHiddenUnlocked = false
    nonisolated static let globalFilterKey = "hiddenFilterIsGlobal"
    nonisolated static let hiddenAlbumsHidePhotosKey = "hiddenAlbumsHidePhotos"

    /// 隐藏相簿里是否仍按照片各自的隐藏标记显示（设置里选，默认否）：
    /// 否 = 看得到隐藏相簿就看得到里面全部照片（相簿的隐藏作用于其中全部照片，用户要求），相簿里没有显示选项
    var hiddenAlbumsHidePhotos: Bool {
        didSet { UserDefaults.standard.set(hiddenAlbumsHidePhotos, forKey: Self.hiddenAlbumsHidePhotosKey) }
    }

    /// 显示选项用在哪：图库、相簿列表、各个相簿
    enum FilterPage: Hashable {
        case library
        case albums
        case album(UUID)
    }

    /// 显示选项的作用范围（设置里选）：true = 全局一份，在哪里切都处处生效；false = 图库、相簿列表、每个相簿各自记
    var filtersAreGlobal: Bool {
        didSet {
            UserDefaults.standard.set(filtersAreGlobal, forKey: Self.globalFilterKey)
            resetFilters()
        }
    }

    private var globalFilter: HiddenFilter = .visible
    private var pageFilters: [FilterPage: HiddenFilter] = [:]

    func filter(for page: FilterPage) -> HiddenFilter {
        filtersAreGlobal ? globalFilter : pageFilters[page] ?? .visible
    }

    func setFilter(_ filter: HiddenFilter, for page: FilterPage) {
        if filtersAreGlobal {
            globalFilter = filter
        } else {
            pageFilters[page] = filter
        }
    }

    func filterBinding(for page: FilterPage) -> Binding<HiddenFilter> {
        Binding(get: { self.filter(for: page) }, set: { self.setFilter($0, for: page) })
    }

    /// 当前有没有哪一页在显示隐藏内容（「添加到相簿」菜单据此决定是否列出隐藏的相簿）
    var showsHiddenAnywhere: Bool {
        filtersAreGlobal ? globalFilter.showsHidden : pageFilters.values.contains(where: \.showsHidden)
    }

    private func resetFilters() {
        globalFilter = .visible
        pageFilters = [:]
    }
    /// 正在弹系统验证（期间场景会变成 inactive，不能当成离开 App）
    private(set) var isAuthenticating = false
    /// 每次上锁只自动弹一次验证：取消后场景回到 active，若再自动弹就会循环，之后靠锁屏上的按钮
    @ObservationIgnored private var autoPromptPending: Bool

    init() {
        #if DEBUG
        // APP_LOCK=1 / HIDDEN_LOCK=1：当作对应开关已打开启动（验证锁屏与隐藏内容验证）
        let env = ProcessInfo.processInfo.environment
        if let raw = env["APP_LOCK"] { UserDefaults.standard.set(raw == "1", forKey: Self.appLockKey) }
        if let raw = env["HIDDEN_LOCK"] { UserDefaults.standard.set(raw == "1", forKey: Self.hiddenLockKey) }
        #endif
        let appLock = UserDefaults.standard.bool(forKey: Self.appLockKey)
        requiresAuthToOpen = appLock
        requiresAuthForHidden = UserDefaults.standard.bool(forKey: Self.hiddenLockKey)
        filtersAreGlobal = UserDefaults.standard.object(forKey: Self.globalFilterKey) as? Bool ?? true
        hiddenAlbumsHidePhotos = UserDefaults.standard.bool(forKey: Self.hiddenAlbumsHidePhotosKey)
        isAppUnlocked = !appLock
        autoPromptPending = appLock
    }

    /// 「面容 ID」「触控 ID」或「密码」（设置页文案用）
    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "面容 ID"
        case .touchID: return "触控 ID"
        case .opticID: return "视控 ID"
        default: return "密码"
        }
    }

    /// 设备能否验证（设了密码；没设密码时这两个开关不能打开）
    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            #if DEBUG
            print("PRIVACY cannot evaluate: \(String(describing: error))")
            #endif
            return false
        }
        #if DEBUG
        print("PRIVACY authenticate: \(reason)")
        #endif
        isAuthenticating = true
        defer { isAuthenticating = false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// 锁屏出现 / 回到前台时自动弹一次
    func autoUnlockApp() async {
        guard autoPromptPending else { return }
        autoPromptPending = false
        await unlockApp()
    }

    func unlockApp() async {
        guard !isAppUnlocked, !isAuthenticating else { return }
        if await authenticate(reason: "解锁\(AppInfo.name)") {
            isAppUnlocked = true
        }
    }

    /// 要看隐藏内容：已解锁或不要求验证时直接通过，否则验证
    func unlockHidden() async -> Bool {
        if isHiddenUnlocked || !requiresAuthForHidden {
            isHiddenUnlocked = true
            return true
        }
        guard await authenticate(reason: "查看隐藏的照片和相簿") else { return false }
        isHiddenUnlocked = true
        return true
    }

    /// App 进入后台
    func didEnterBackground() {
        guard !isAuthenticating else { return }
        isHiddenUnlocked = false
        resetFilters()
        if requiresAuthToOpen {
            isAppUnlocked = false
            autoPromptPending = true
        }
    }

    /// 改这两个开关（开或关）都要先验证：防止别人拿着已解锁的手机把锁关掉
    func setRequiresAuthToOpen(_ enabled: Bool) async {
        guard enabled != requiresAuthToOpen else { return }
        if await authenticate(reason: enabled ? "开启打开时验证" : "关闭打开时验证") {
            requiresAuthToOpen = enabled
            isAppUnlocked = true
        }
    }

    func setRequiresAuthForHidden(_ enabled: Bool) async {
        guard enabled != requiresAuthForHidden else { return }
        if await authenticate(reason: enabled ? "开启查看隐藏内容时验证" : "关闭查看隐藏内容时验证") {
            requiresAuthForHidden = enabled
        }
    }
}

/// 图库 / 相簿列表 / 相簿里的显示选项
enum HiddenFilter: String, CaseIterable, Identifiable {
    /// 不显示隐藏的（默认）
    case visible
    /// 只显示隐藏的
    case hiddenOnly
    /// 全部显示
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .visible: "不显示隐藏的"
        case .hiddenOnly: "只显示隐藏的"
        case .all: "全部显示"
        }
    }

    var systemImage: String {
        switch self {
        case .visible: "eye.slash"
        case .hiddenOnly: "eye.trianglebadge.exclamationmark"
        case .all: "eye"
        }
    }

    /// 是否看得到隐藏内容（隐藏照片可出现在相簿封面 / 计数里）
    var showsHidden: Bool {
        self != .visible
    }

    func includes(isHidden: Bool) -> Bool {
        switch self {
        case .visible: !isHidden
        case .hiddenOnly: isHidden
        case .all: true
        }
    }
}

/// 「…」菜单里的「显示」一组（三选一）：切到看得到隐藏内容的选项前先解锁（可能要验证）
struct HiddenFilterSection: View {
    @Binding var filter: HiddenFilter
    @Environment(PrivacyLock.self) private var privacyLock

    var body: some View {
        Section("显示") {
            Picker("显示", selection: Binding(get: { filter }, set: { choose($0) })) {
                ForEach(HiddenFilter.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.inline)
        }
    }

    private func choose(_ option: HiddenFilter) {
        guard option.showsHidden else {
            apply(option)
            return
        }
        Task {
            if await privacyLock.unlockHidden() {
                apply(option)
            }
        }
    }

    /// 带动画切换：相簿列表逐张淡入淡出补位，空状态与网格交叉淡化（照片网格自己整块交叉淡化，见 contentKey）
    private func apply(_ option: HiddenFilter) {
        withAnimation(.easeInOut(duration: 0.3)) {
            filter = option
        }
    }
}

/// 导航栏右上角的「…」：页面自己的操作在上，「显示」选项在下。
/// 显示选项不是默认时图标实心，提醒正在看隐藏内容
struct PageMoreMenu<Actions: View>: View {
    @Binding var filter: HiddenFilter
    /// 没有显示选项的页面（隐藏相簿里照片全部显示时）
    var showsFilter = true
    @ViewBuilder var actions: Actions

    var body: some View {
        Menu {
            Section {
                actions
            }
            if showsFilter {
                HiddenFilterSection(filter: $filter)
            }
        } label: {
            if GlassSymbols.isGlass {
                // iOS 26：按钮自带玻璃圆底，用不带圈的符号；正在显示隐藏内容时右上角一个强调色小点
                Image(systemName: GlassSymbols.more)
                    .overlay(alignment: .topTrailing) {
                        if filter != .visible && showsFilter {
                            Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 5, y: -5)
                        }
                    }
                    .accessibilityLabel("更多")
            } else {
                Label("更多", systemImage: filter == .visible || !showsFilter ? GlassSymbols.more : GlassSymbols.moreFilled)
            }
        }
    }
}

/// 打开 App 时的锁屏：盖住全部内容，出现时自动弹验证
struct AppLockScreen: View {
    @Environment(PrivacyLock.self) private var privacyLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 18) {
            Image("BrandIcon")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.gradient, in: Circle())
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                        .offset(x: 8, y: 8)
                }
            Text("\(AppInfo.name)已锁定")
                .font(.title2.weight(.semibold))
            Button("使用\(privacyLock.biometryName)解锁") {
                Task { await privacyLock.unlockApp() }
            }
            .prominentButtonStyle()
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task(id: scenePhase) {
            if scenePhase == .active {
                await privacyLock.autoUnlockApp()
            }
        }
    }
}
