import AppKit
import LLMQuotaCore
import SwiftUI

/// 菜单栏 App 这一侧的 iCloud 接线：授权、书签、定时镜像。
///
/// # 为什么是 App 来干这件事
///
/// CLI（launchd 起的 worker/collector）访问 iCloud 会**永久挂起** ——
/// TCC 的 FileProviderDomain 闸门，完全磁盘访问覆盖不了，实测多次。
/// 正确的门是「用户自己选的目录」：NSOpenPanel + 书签。
/// 而书签是按客户端绑的，CLI 是另一个二进制、没有界面 —— 用不了。
///
/// 所以：**App 是唯一碰真 iCloud 的进程**。CLI 只读写本地暂存
/// `Paths.sharedRoot`，App 每 30 秒把它和真 iCloud 目录对成一致。
/// 代价（用户已接受）：App 不在跑就不同步 —— 菜单栏 App 本来常驻。
@MainActor
final class MirrorController: ObservableObject {

    enum GrantState: Equatable {
        case notGranted
        case granted(URL)
    }

    @Published private(set) var grant: GrantState = .notGranted
    @Published private(set) var lastStats: String = "还没同步过"
    @Published private(set) var lastError: String?
    @Published private(set) var lastOKAt: Date?

    private var timer: Timer?
    private var syncing = false
    private let bookmarkKey = "llmq.icloud.bookmark"

    /// 真 iCloud 目录的默认位置 —— **只用来给 NSOpenPanel 定位**，
    /// 访问永远走用户选出来的 URL，不走硬编码路径。
    private var defaultCloudDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/LLMQuotaBar",
                                    isDirectory: true)
    }

    init() {
        restoreBookmark()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.syncNow() }
        }
        // 起来先跑一轮：首轮镜像相当于全量迁移（把 iCloud 上已有的拉下来）。
        syncNow()
    }

    // MARK: - 授权

    /// 弹面板让用户选 iCloud 里的 LLMQuotaBar 文件夹。
    ///
    /// 非沙盒 App 走这条路是否真能解开 FileProviderDomain，
    /// 文档没有明说（Oakley 的实测甚至存疑）—— 所以选完立刻跑一轮镜像，
    /// 结果如实显示在弹窗里：成了就是成了，卡住就说卡住，不猜。
    func requestGrant() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 iCloud 云盘里的 LLMQuotaBar 文件夹（没有就在这里新建一个）"
        panel.prompt = "用这个文件夹"
        // 定位到默认位置。目录可能还不存在 —— 定位到上一级。
        let fm = FileManager.default
        panel.directoryURL = fm.fileExists(atPath: defaultCloudDir.path)
            ? defaultCloudDir : defaultCloudDir.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(url)
        grant = .granted(url)
        syncNow()
    }

    func revokeGrant() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        grant = .notGranted
        writeHeartbeatUnauthorized()
    }

    private func saveBookmark(_ url: URL) {
        // 非沙盒下 .withSecurityScope 在某些系统上会抛错 —— 降级成普通书签。
        // 两种在恢复时都要能用（restoreBookmark 对应处理）。
        let data = (try? url.bookmarkData(options: [.withSecurityScope],
                                          includingResourceValuesForKeys: nil,
                                          relativeTo: nil))
            ?? (try? url.bookmarkData(options: [],
                                      includingResourceValuesForKeys: nil,
                                      relativeTo: nil))
        guard let data else {
            lastError = "存不了书签 —— 授权这次有效，重启 App 后要重选"
            return
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            writeHeartbeatUnauthorized()
            return
        }
        var stale = false
        // 先按带 scope 的解；解不出来再按普通书签解 —— 存的时候就是二选一。
        let url = (try? URL(resolvingBookmarkData: data,
                            options: [.withSecurityScope],
                            relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [],
                         relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else {
            writeHeartbeatUnauthorized()
            return
        }
        // scoped 书签要开访问；普通书签这个调用返回 false，无害。
        _ = url.startAccessingSecurityScopedResource()
        if stale { saveBookmark(url) }
        grant = .granted(url)
    }

    // MARK: - 镜像

    func syncNow() {
        guard case .granted(let cloud) = grant else { return }
        guard !syncing else { return }   // 上一轮还没回来就别再派 —— 防线程堆积
        syncing = true

        let local = Paths.sharedRoot
        let selfID = Paths.machineID()
        Task.detached(priority: .utility) { [weak self] in
            // **必须在后台线程。** 镜像的云端操作每个都有看门狗，
            // 但一轮加起来可以到几十秒 —— 主线程等它就是菜单栏卡死。
            let stats = MirrorService.sync(local: local, cloud: cloud,
                                           selfMachineID: selfID)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.syncing = false
                self.lastError = stats.errors.first
                if stats.errors.isEmpty { self.lastOKAt = Date() }
                self.lastStats = "推 \(stats.pushed) · 拉 \(stats.pulled)"
                    + (stats.claimed > 0 ? " · 领 \(stats.claimed)" : "")
                    + (stats.errors.isEmpty ? "" : " · \(stats.errors.count) 个错误")
            }
        }
    }

    /// 没授权时也要把状态写进心跳 —— CLI 那侧靠它区分
    /// 「从未授权」和「App 没在跑」，两者的提示完全不同。
    private func writeHeartbeatUnauthorized() {
        let local = Paths.sharedRoot
        Task.detached(priority: .utility) {
            MirrorService.writeUnauthorizedHeartbeat(local: local)
        }
    }
}

// MARK: - 弹窗里的状态区

struct MirrorSection: View {
    @ObservedObject var mirror: MirrorController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch mirror.grant {
            case .notGranted:
                // 未授权横幅要一直在 —— 这不是一次性的引导，
                // 是「多机同步现在是断的」这个事实的常驻提示。
                HStack(spacing: 8) {
                    Image(systemName: "icloud.slash")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iCloud 同步没开").font(.callout).bold()
                        Text("快照、配置、手机端都只在本机。选一次文件夹就好。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("开启") { mirror.requestGrant() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 6))
            case .granted:
                HStack(spacing: 6) {
                    Image(systemName: mirror.lastError == nil
                          ? "icloud" : "exclamationmark.icloud")
                        .foregroundStyle(mirror.lastError == nil ? Color.secondary : Color.orange)
                    Text(mirror.lastStats).font(.caption).foregroundStyle(.secondary)
                    if let t = mirror.lastOKAt {
                        Text(Format.relative(t)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                if let e = mirror.lastError {
                    // 错误原样给，不翻译成安慰话 —— 「卡住」和「没权限」
                    // 的修法完全不同，模糊掉就没法修。
                    Text(e).font(.caption2).foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
    }
}
