import AppKit
import LLMQuotaCore
import SwiftUI

@main
struct LLMQuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(model: model)
        } label: {
            // 菜单栏只有一行的空间，所以这里只放"最该被看见的那一条"。
            HStack(spacing: 3) {
                Image(systemName: model.menuIcon)
                Text(model.menuTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 常驻菜单栏，不要 Dock 图标、不要主窗口。
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Model

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var dashboard: Dashboard?
    @Published private(set) var isCollecting = false
    @Published private(set) var lastError: String?
    @Published private(set) var iCloudSync: ICloudSyncStatus = .unavailable

    private var refreshTimer: Timer?
    private var collectTimer: Timer?

    /// 读快照很便宜，可以频繁刷；采集要扫日志，间隔放长。
    private let refreshInterval: TimeInterval = 60
    private let collectInterval: TimeInterval = 600

    init() {
        reload()
        collect()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.reload() }
        }
        collectTimer = Timer.scheduledTimer(withTimeInterval: collectInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.collect() }
        }
    }

    /// 只读已有快照，不扫日志。
    func reload() {
        dashboard = LLMQuota.dashboard()
    }

    /// 扫本机日志并写快照。放后台线程 —— 首次要解析 1GB 出头。
    func collect() {
        guard !isCollecting else { return }
        isCollecting = true
        Task.detached(priority: .utility) {
            do {
                let r = try LLMQuota.collect()
                await MainActor.run {
                    self.lastError = nil
                    self.iCloudSync = r.iCloudSync
                    self.isCollecting = false
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.lastError = String(describing: error)
                    self.isCollecting = false
                }
            }
        }
    }

    /// 最紧急的一条 —— 菜单栏标题和图标都由它决定。
    var topAlert: QuotaStatus? { dashboard?.alerts.first }

    var menuTitle: String {
        guard let dashboard else { return "…" }
        guard let top = topAlert else {
            let n = dashboard.reports.filter(\.detected).count
            return n == 0 ? "无数据" : "\(n) 平台"
        }
        switch top.health {
        case .wasting:
            let pct = top.projectedUsedFraction.map { max(0, 1 - $0) }
            return "\(top.platform.tag) 废\(Format.percent(pct))"
        case .atRisk, .exhausted:
            return "\(top.platform.tag) \(Format.percent(top.usedFraction))"
        default:
            return top.platform.tag
        }
    }

    var menuIcon: String {
        switch topAlert?.health {
        case .wasting: return "arrow.down.circle"
        case .atRisk, .exhausted: return "exclamationmark.triangle"
        default: return "gauge.with.dots.needle.33percent"
        }
    }
}

// MARK: - Views

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            permissionBanner

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let dash = model.dashboard {
                        WasteSection(dashboard: dash)
                        ForEach(dash.reports.filter(\.detected).sorted {
                            $0.platform.sortIndex < $1.platform.sortIndex
                        }) { report in
                            PlatformCard(report: report, now: dash.generatedAt)
                        }
                        InactiveSection(dashboard: dash)
                        MachineSection(dashboard: dash)
                    } else {
                        Text("正在读取…").foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 520)

            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("LLM 额度").font(.headline)
            if model.isCollecting {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Spacer()
            if let d = model.dashboard {
                Text(Format.relative(d.generatedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// iCloud Drive 受 macOS 隐私保护，双击启动的 App 默认读写不了。
    /// 没授权时本机统计照常，只是别的电脑的数据汇总不进来 —— 这里直接给授权入口。
    @ViewBuilder
    private var permissionBanner: some View {
        // 只有在"确实看不到其他电脑"时才提示。
        // 如果 llmq 的定时任务在跑，它会把别人的快照镜像到本地，App 照样能看到全部，
        // 这种情况下没有任何问题需要用户处理，弹提示反而是噪音。
        if model.iCloudSync.needsFullDiskAccess, (model.dashboard?.machines.count ?? 0) <= 1 {
            VStack(alignment: .leading, spacing: 5) {
                Label("多机汇总未启用", systemImage: "icloud.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("iCloud Drive 需要「完全磁盘访问权限」。本机数据不受影响，"
                     + "但其他电脑的用量汇总不进来。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("去授权") {
                        NSWorkspace.shared.open(LLMQuota.fullDiskAccessSettingsURL)
                    }
                    Button("授权后重试") { model.collect() }
                        .disabled(model.isCollecting)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            Divider()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("刷新") { model.collect() }
                .disabled(model.isCollecting)
            Button("编辑套餐") {
                NSWorkspace.shared.open(Paths.plansFile)
            }
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// 作废预警放在最上面 —— 这是用这个工具的首要理由。
struct WasteSection: View {
    let dashboard: Dashboard

    private var wasting: [QuotaStatus] {
        dashboard.reports.flatMap(\.statuses)
            .filter { $0.health == .wasting }
            .sorted { ($0.projectedWaste ?? 0) > ($1.projectedWaste ?? 0) }
    }

    private var risky: [QuotaStatus] {
        dashboard.reports.flatMap(\.statuses)
            .filter { $0.health == .atRisk || $0.health == .exhausted }
    }

    var body: some View {
        if !wasting.isEmpty || !risky.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(wasting) { s in
                    alertRow(
                        icon: "arrow.down.circle.fill", tint: .orange,
                        title: "\(s.platform.displayName) \(s.label)额度用不完",
                        detail: "按当前速度还会剩 "
                            + Format.percent(s.projectedUsedFraction.map { max(0, 1 - $0) })
                            + "，" + Format.duration(s.timeToReset) + "后清零"
                    )
                }
                ForEach(risky) { s in
                    alertRow(
                        icon: "exclamationmark.triangle.fill", tint: .red,
                        title: "\(s.platform.displayName) \(s.label)额度吃紧",
                        detail: "已用 " + Format.percent(s.usedFraction)
                            + "，预计到重置时 " + Format.percent(s.projectedUsedFraction)
                    )
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func alertRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct PlatformCard: View {
    let report: PlatformReport
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.platform.displayName).font(.system(size: 13, weight: .semibold))
                Text(report.planName).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(Format.relative(report.lastActivity, now: now))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            ForEach(report.statuses) { s in
                QuotaRow(status: s)
            }

            HStack(spacing: 10) {
                Label("\(report.last30dRequests) 次 / 30天", systemImage: "arrow.up.arrow.down")
                Label(Format.compact(report.last30dBillableTokens), systemImage: "square.stack.3d.up")
                if report.machines.count > 1 {
                    Label("\(report.machines.count) 台", systemImage: "desktopcomputer")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .labelStyle(.titleAndIcon)
        }
    }
}

struct QuotaRow: View {
    let status: QuotaStatus

    private var tint: Color {
        switch status.health {
        case .wasting: return .orange
        case .atRisk, .exhausted: return .red
        case .idle: return .secondary
        case .unconfigured: return .secondary
        case .healthy: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(status.label).font(.system(size: 11)).frame(width: 46, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.09))
                        if let f = status.usedFraction {
                            Capsule().fill(tint)
                                .frame(width: max(2, geo.size.width * min(1, max(0, f))))
                        }
                    }
                }
                .frame(height: 6)

                Text(status.usedFraction.map { Format.percent($0) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 42, alignment: .trailing)
                    .foregroundStyle(status.usedFraction == nil ? .secondary : .primary)
            }

            HStack(spacing: 6) {
                Text(Format.metricValue(status.used, metric: status.metric))
                if status.isOfficial {
                    Text("平台直报")
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 3))
                }
                if status.limit == nil {
                    Text("未配上限").foregroundStyle(.orange)
                }
                Spacer()
                if let t = status.timeToReset {
                    Text(Format.duration(t) + "后重置")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.leading, 52)
        }
    }
}

/// 长期没用的平台 —— 这是"该退订了"的信号。
///
/// "装了却没用" 和 "压根没装" 要分开：前者才是在白烧订阅费。
struct InactiveSection: View {
    let dashboard: Dashboard

    private var idle: [PlatformReport] {
        dashboard.reports.filter(\.installedButIdle)
    }

    private var absent: [PlatformReport] {
        dashboard.reports.filter { !$0.detected && !$0.installed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !idle.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("装了但没在用", systemImage: "zzz")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple)
                    ForEach(idle) { r in
                        HStack(spacing: 4) {
                            Text(r.platform.displayName).font(.system(size: 10))
                            if let c = r.monthlyCost {
                                Text("每月 \(Format.compact(c)) \(r.currency) 在空烧")
                                    .font(.system(size: 10)).foregroundStyle(.purple)
                            } else {
                                Text("最近 32 天无用量")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            if !absent.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("未检测到").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(absent.map(\.platform.displayName).joined(separator: "、"))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct MachineSection: View {
    let dashboard: Dashboard

    var body: some View {
        if !dashboard.machines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("接入的电脑").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(dashboard.machines) { m in
                    HStack(spacing: 5) {
                        Circle().fill(m.isStale ? Color.orange : Color.green).frame(width: 5)
                        Text(m.machineName).font(.system(size: 10))
                        Spacer()
                        Text(Format.relative(m.lastSeen, now: dashboard.generatedAt))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
