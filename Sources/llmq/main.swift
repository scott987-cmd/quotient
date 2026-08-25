import Foundation
import LLMQuotaCore

// MARK: - Terminal helpers

enum Ansi {
    /// 去掉转义色码。
    ///
    /// 落盘的东西不能带色码：写进 JSON 之后手机和别的机器读到的是
    /// 一串 `\u{1B}[32m` 垃圾，而不是「可用」。
    static func strip(_ s: String) -> String {
        var out = ""
        var inEscape = false
        for ch in s {
            if inEscape {
                if ch == "m" { inEscape = false }
                continue
            }
            if ch == "\u{1B}" { inEscape = true; continue }
            out.append(ch)
        }
        return out
    }

    static let enabled = isatty(fileno(stdout)) == 1

    static func wrap(_ s: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func blue(_ s: String) -> String { wrap(s, "34") }
    static func magenta(_ s: String) -> String { wrap(s, "35") }
    static func cyan(_ s: String) -> String { wrap(s, "36") }
}

func colorize(_ health: QuotaHealth, _ text: String) -> String {
    switch health {
    case .wasting: return Ansi.yellow(text)
    case .atRisk: return Ansi.red(text)
    case .exhausted: return Ansi.red(text)
    case .idle: return Ansi.dim(text)
    case .unconfigured: return Ansi.dim(text)
    case .healthy: return Ansi.green(text)
    }
}

/// 固定宽度左对齐。中文字符在终端占两列，直接用 count 会排不齐。
func pad(_ s: String, _ width: Int) -> String {
    let w = displayWidth(s)
    return w >= width ? s : s + String(repeating: " ", count: width - w)
}

func displayWidth(_ s: String) -> Int {
    var width = 0
    var inEscape = false
    for u in s.unicodeScalars {
        // 颜色转义序列不占终端列宽，算进去会把整张表推歪。
        if inEscape {
            if u == "m" { inEscape = false }
            continue
        }
        if u.value == 0x1B { inEscape = true; continue }

        switch u.value {
        // CJK 与全角标点按两列算。
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
             0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
            width += 2
        default:
            width += 1
        }
    }
    return width
}

// MARK: - Commands

/// 镜像心跳的三态输出。collect 和 doctor 共用 —— 措辞必须区分
/// 「从未授权 / App 没在跑 / 镜像在报错」，三者的修法完全不同。
func printMirrorHealth(indent: String) {
    let status = MirrorHealth.check()
    let text = MirrorHealth.describe(status)
    switch status {
    case .ok:
        print(indent + Ansi.green("✓ ") + Ansi.dim(text))
    case .neverSynced, .appNotRunning:
        print(indent + Ansi.yellow("⚠ " + text))
    case .failing:
        print(indent + Ansi.red("✗ " + text))
    }
}

func cmdCollect(verbose: Bool) throws {
    let result = try LLMQuota.collect()
    let snap = result.snapshot

    print(Ansi.bold("采集完成") + " · \(snap.machineName) · 耗时 \(String(format: "%.1f", result.duration))s")

    // **顺手学一遍额度打满信号。**
    //
    // 光数请求数和 token 判断不出「用完没有」——GLM 按积分计费、
    // 工作日下午还是 3 倍，口径根本对不上。唯一可靠的地面真相是服务端
    // 自己说的那句 429，而它就写在会话日志里。人在终端里手工跑掉的额度，
    // 系统只能从这里知道。
    for hit in QuotaSignal.learnFromLogs() {
        let when = hit.resetsAt.map { "，" + Format.duration($0.timeIntervalSinceNow) + "后重置" }
            ?? "，没给重置时间（按退避冷却）"
        print(Ansi.yellow("  额度打满：") + hit.platform.displayName + when)
        print(Ansi.dim("    来源：" + hit.message.prefix(90)))
    }

    // **撞顶的那一刻是估上限唯一的已知点，别学完就扔。**
    //
    // 冷却台账每个平台只留最新一条，撞过几次全被覆盖 —— 最硬的证据保留
    // 时间最短。这里在采集后补一次快照：此刻处于「打满」冷却中的平台，
    // 窗口用量就是它的上限。撞顶后请求全被拒、用量不再涨，所以事后采样
    // 反而比抢在那一毫秒更干净。
    for ob in QuotaCeiling.capture(dashboard: LLMQuota.dashboard()) {
        print(Ansi.cyan("  撞顶采样：") + ob.platform.displayName
              + " " + ob.windowLabel
              + Ansi.dim("  \(ob.usage.first?.key ?? "")≈\(Int(ob.usage.first?.value ?? 0))"))
    }

    let detected = snap.platforms.filter(\.detected)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    print("检测到 \(detected.count) 个平台的数据源，快照已写入：")
    print("  " + Paths.localSnapshotsDir.path.replacingOccurrences(of: home, with: "~"))

    switch result.iCloudSync {
    case .synced:
        print("  " + Ansi.green("已写入共享暂存")
            + Ansi.dim(" " + (Paths.iCloudSnapshotsDir?.path
                .replacingOccurrences(of: home, with: "~") ?? "")))
        // 写进暂存 ≠ 到了 iCloud —— 搬运是菜单栏 App 的镜像干的，读心跳说实话。
        printMirrorHealth(indent: "  ")
    case .unavailable:
        print(Ansi.yellow("  未检测到 iCloud Drive，快照只存在本地，其他电脑看不到"))
    case .stalled(let why):
        // 这条要显眼。iCloud 卡住不是「同步慢一点」，是它有能力把
        // `llmq work loop` 整个冻住 —— 实测发生过，四次重启四次停在同一行。
        print(Ansi.red("  iCloud 写入卡住了：") + why)
        print(Ansi.dim("  不是慢，是不返回。看门狗已经放行，不会拖住后面的流程。"))
        print(Ansi.dim("  常见原因：跑它的是 launchd 常驻进程，"
            + "而 iCloud Drive 和 ~/Documents 一样受访问授权闸门保护 ——"))
        print(Ansi.dim("  待决的授权是**无限期阻塞**，不是报错，所以看起来就像卡死。"
            + "跑 llmq doctor 看那条检查。"))
    case .permissionDenied:
        print(Ansi.yellow("  iCloud 同步被系统拒绝 —— 多机汇总暂未启用"))
        for line in LLMQuota.fullDiskAccessHint.split(separator: "\n") {
            print(Ansi.dim("  " + line))
        }
    }

    if !result.staleBinaryWarning.isEmpty {
        print(Ansi.red("  ⚠ 版本漂移：上一份快照由一个认识 "
            + result.staleBinaryWarning.joined(separator: "、")
            + " 的二进制写入，当前这个不认识它们。"))
        print(Ansi.dim("  两个二进制在轮流覆盖同一份快照，数据会来回跳。"))
        print(Ansi.dim("  修复：cd ~/Documents/LLMQuotaBar && ./build-app.sh --install"))
    }

    if result.mirroredMachines > 0 {
        print("  " + Ansi.green("已镜像 \(result.mirroredMachines) 台其他电脑的快照到本地")
            + Ansi.dim("（菜单栏 App 读本地即可看到全部）"))
    }

    if verbose {
        print("\n" + Ansi.bold("各采集器明细"))
        print(Ansi.dim(pad("采集器", 22) + pad("状态", 10) + pad("文件", 8)
            + pad("重解析", 9) + pad("复用", 8) + "解析字节"))
        for s in result.stats {
            let status = s.installed ? Ansi.green("已安装") : Ansi.dim("未安装")
            print(pad(s.adapterID, 22) + pad(status, 10) + pad("\(s.filesSeen)", 8)
                + pad("\(s.filesParsed)", 9) + pad("\(s.filesReused)", 8)
                + Format.bytes(s.bytesParsed))
        }
    }

    for ps in detected {
        let req = ps.buckets.reduce(0) { $0 + $1.requests }
        let tok = ps.buckets.reduce(0) { $0 + $1.billableTokens }
        var line = "  " + pad(ps.platform.displayName, 12)
            + pad("\(req) 次", 12) + pad(Format.compact(tok) + " token", 16)
        if !ps.officialQuotas.isEmpty {
            line += Ansi.cyan("含官方额度 \(ps.officialQuotas.count) 条")
        }
        print(line)
    }
}

func cmdReport(json: Bool) throws {
    let dash = LLMQuota.dashboard()

    if json {
        let data = try SnapshotCoding.prettyEncoder().encode(dash)
        print(String(decoding: data, as: UTF8.self))
        return
    }

    // 机器状态
    print(Ansi.bold("接入的电脑"))
    if dash.machines.isEmpty {
        print(Ansi.yellow("  还没有任何快照，先跑一次 llmq collect"))
    }
    for m in dash.machines {
        let mark = m.isStale ? Ansi.yellow("○ 快照较旧") : Ansi.green("● 活跃")
        print("  \(mark)  " + pad(m.machineName, 24)
            + Ansi.dim("更新于 " + Format.relative(m.lastSeen, now: dash.generatedAt)))
    }

    // 作废预警 —— 这是整个工具的重点，放最前面
    let wasting = dash.reports.flatMap(\.statuses).filter { $0.health == .wasting }
    print("\n" + Ansi.bold("额度作废预警"))
    if wasting.isEmpty {
        print(Ansi.dim("  没有检测到明显浪费。（配置了上限的额度才能算作废量）"))
    }
    for s in wasting.sorted(by: { ($0.projectedWaste ?? 0) > ($1.projectedWaste ?? 0) }) {
        let waste = s.projectedWaste.map { Format.metricValue($0, metric: s.metric) } ?? "—"
        print("  " + Ansi.yellow("⚠︎ ") + Ansi.bold(pad(s.platform.displayName, 10))
            + pad(s.label, 8)
            + "按当前速度，重置时会剩 " + Ansi.yellow(waste)
            + " 未用，" + Format.duration(s.timeToReset) + "后清零")
    }

    let atRisk = dash.reports.flatMap(\.statuses)
        .filter { $0.health == .atRisk || $0.health == .exhausted }
    if !atRisk.isEmpty {
        print("\n" + Ansi.bold("超额风险"))
        for s in atRisk {
            let detail: String
            if s.health == .exhausted {
                // 已经用尽了，再报"预计到重置时 202%"没有意义。
                detail = Ansi.red("已用尽") + "，" + Format.duration(s.timeToReset) + "后重置"
            } else {
                detail = "已用 " + Ansi.red(Format.percent(s.usedFraction))
                    + "，预计到重置时 " + Format.percent(s.projectedUsedFraction)
            }
            print("  " + Ansi.red("▲ ") + Ansi.bold(pad(s.platform.displayName, 10))
                + pad(s.label, 8) + detail)
        }
    }

    // 装了却没在用 —— 直接对应"是不是该退订了"
    let idle = dash.reports.filter(\.installedButIdle)
    if !idle.isEmpty {
        print("\n" + Ansi.bold("装了但没在用"))
        for r in idle {
            var line = "  " + Ansi.magenta("◇ ") + pad(r.platform.displayName, 10)
                + "已安装，但所有电脑上最近 32 天都没有用量"
            if let c = r.monthlyCost {
                line += Ansi.magenta("（每月 \(c) \(r.currency) 在空烧）")
            }
            print(line)
        }
        print(Ansi.dim("  在 plans.json 里填上月费，这里就能直接算出每月白花多少钱。"))
    }

    // 各平台明细
    print("\n" + Ansi.bold("各平台明细"))
    for r in dash.reports.sorted(by: { $0.platform.sortIndex < $1.platform.sortIndex }) {
        let title = Ansi.bold(r.platform.displayName) + Ansi.dim(" · \(r.planName)")
        if !r.detected {
            let why = r.installed
                ? Ansi.magenta("已安装，但最近 32 天无用量")
                : Ansi.dim("未检测到数据源")
            print("\n" + title + "  " + why)
            continue
        }

        print("\n" + title + "  " + Ansi.dim(
            "最近活动 " + Format.relative(r.lastActivity, now: dash.generatedAt)
            + " · 30天 \(r.last30dRequests) 次 / "
            + Format.compact(r.last30dBillableTokens) + " token"
            + (r.machines.isEmpty ? "" : " · " + r.machines.joined(separator: ", "))
        ))

        for s in r.statuses {
            let bar = Format.bar(s.usedFraction, width: 16)
            let pct = s.usedFraction.map { Format.percent($0) } ?? Ansi.dim("未配上限")
            var line = "    " + pad(s.label, 8) + colorize(s.health, bar) + "  "
                + pad(pct, 10)
                + pad(Format.metricValue(s.used, metric: s.metric), 14)
            if let reset = s.timeToReset {
                line += Ansi.dim(Format.duration(reset) + "后重置")
            }
            print(line)

            var note = "        " + colorize(s.health, s.health.displayName)
            note += Ansi.dim(" · " + s.sourceNote)
            if s.isOfficial { note += Ansi.cyan(" [平台直报]") }
            print(note)

            if s.byMachine.count > 1 {
                let split = s.byMachine.sorted { $0.value > $1.value }
                    .map { "\($0.key) \(Format.metricValue($0.value, metric: s.metric))" }
                    .joined(separator: " / ")
                print(Ansi.dim("        按电脑：" + split))
            }
        }

        if !r.topModels.isEmpty {
            let models = r.topModels.prefix(3)
                .map { "\($0.model) \(Format.compact($0.billableTokens))" }
                .joined(separator: "  ")
            print(Ansi.dim("        主要模型：" + models))
        }
    }

    print("\n" + Ansi.dim("配置文件：" + Paths.plansFile.path.replacingOccurrences(
        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")))
    print(Ansi.dim("填上各套餐的 limit 之后，剩余百分比和作废预警才会生效。"))
}

/// 生成「数字员工看板」HTML 并可选直接打开。
func cmdDashboard(_ args: [String]) throws {
    var output = Paths.appSupport.appendingPathComponent("dashboard.html")
    var fragment = false
    var shouldOpen = true
    var include3D = true

    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o", "--output":
            i += 1
            if i < args.count {
                output = URL(fileURLWithPath: NSString(string: args[i]).expandingTildeInPath)
            }
        case "--fragment":
            // 只输出片段（style + 内容 + script），供嵌进别的页面。
            fragment = true
        case "--no-open":
            shouldOpen = false
        case "--no-3d":
            // 省掉内联的 three.js，页面从 ~560KB 降到 ~35KB。
            include3D = false
        default:
            break
        }
        i += 1
    }

    let dash = LLMQuota.dashboard()
    let html = try DashboardHTML.render(dash, standalone: !fragment, include3D: include3D)
    try Paths.ensureDirectories()
    try html.write(to: output, atomically: true, encoding: .utf8)

    let staff = dash.reports.filter { $0.detected || $0.installed }
    let working = dash.reports.filter(\.detected)
    print(Ansi.bold("已生成数字员工看板") + Ansi.dim(" · \(staff.count) 名在编 / \(working.count) 名在岗"))
    print("  " + output.path.replacingOccurrences(
        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))

    if shouldOpen && !fragment {
        _ = shell("/usr/bin/open", [output.path])
    }
}

/// 从真实用量反解各平台的额度上限。
func cmdLearn(_ args: [String]) throws {
    let apply = args.contains("--apply")
    let scan = try Collector().scanRaw()
    let estimates = LimitLearner.learn(from: scan)

    // 先报矛盾。配错的上限比没配更有害 —— 配低了工具会一直喊"快满了"，
    // 你就不敢用，正好制造这个工具要防的浪费。
    let conflicts = LimitLearner.contradictions(scan: scan, config: PlansStore.load())
    if !conflicts.isEmpty {
        print(Ansi.red("配置的上限与实测矛盾") + Ansi.dim("（实际用出去过、且没被拒，说明真实上限更高）"))
        for c in conflicts {
            print("  " + Ansi.bold(pad(c.platform.displayName, 10)) + pad(c.windowLabel, 8)
                + "配置 " + Ansi.red(Format.metricValue(c.configured, metric: c.metric))
                + "，实测峰值 " + Ansi.green(Format.metricValue(c.observed, metric: c.metric)))
        }
        print(Ansi.dim("  这些数字多半来自第三方整理的「约数」。按实测峰值往上调，或去官方控制台核对。"))
        print()
    }

    guard !estimates.isEmpty else {
        print(Ansi.yellow("数据还不够。反解需要平台回报过百分比，下限估计需要至少两个完整窗口的历史。"))
        return
    }

    print(Ansi.bold("额度上限反解"))
    print(Ansi.dim(pad("平台", 10) + pad("窗口", 9) + pad("口径", 14)
        + pad("估计上限", 14) + pad("依据", 10) + pad("样本", 7) + "离散度"))

    for e in estimates {
        let method = e.method == .calibrated
            ? Ansi.green("官方反解") : Ansi.dim("下限")
        let spread = e.spread.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        print(pad(e.platform.displayName, 10)
            + pad(e.windowLabel, 9)
            + pad(e.metric.displayName, 14)
            + pad(Format.metricValue(e.value, metric: e.metric), 14)
            + pad(method, 10)
            + pad("\(e.samples)", 7)
            + spread)
        if e.method == .calibrated {
            print(Ansi.dim("      " + e.note)
                + (e.isTrustworthy ? Ansi.green("  拟合可信")
                                   : Ansi.yellow("  拟合不可信，不会自动写入")))
            // 把四个候选口径的拟合优度全摊开。只看最优值没法判断它是真的显著更好，
            // 还是四个都不像 —— 后者说明平台的计费口径压根不在候选集里。
            for f in e.alternatives {
                let mark = f.metric == e.metric ? Ansi.green(" ←最优") : ""
                print(Ansi.dim(String(format: "        %@  上限≈%@  离散度 %.1f%%",
                    pad(f.metric.displayName, 12),
                    pad(Format.metricValue(f.value, metric: f.metric), 12),
                    f.spread * 100)) + mark)
            }
        }
    }

    let calibrated = estimates.filter { $0.method == .calibrated }
    print()
    if calibrated.isEmpty {
        print(Ansi.yellow("还没有任何一条能反解 —— 只有平台把已用百分比写进本地日志才行，目前只有 Codex 会。"))
        print(Ansi.dim("其余平台显示的是下限：真实上限一定不低于这个数，但可能高得多。"))
    } else {
        print(Ansi.dim("「离散度」是同一口径下多次反解结果的变异系数。越小说明这个计量单位越可能"))
        print(Ansi.dim("就是平台真正的计费口径 —— 表里每个窗口只留了离散度最小的那个口径。"))
    }
    if calibrated.contains(where: { !$0.isTrustworthy }) {
        print()
        print(Ansi.yellow("有反解结果拟合不佳。常见原因（按可能性排序）："))
        print(Ansi.dim("  1. 额度在本地看不见的地方也被消耗了 —— 比如 ChatGPT 网页版和 Codex"))
        print(Ansi.dim("     共用同一份订阅额度，网页上聊天照样扣，但本地不留日志。"))
        print(Ansi.dim("  2. 平台按模型加权计费，不是简单数次数或数 token。"))
        print(Ansi.dim("  3. 同一账号在别的电脑上也用过，本地只看得到这一台。"))
        print(Ansi.dim("  拟合不佳时反解值一律不采用。好在会回报百分比的平台（目前只有 Codex）"))
        print(Ansi.dim("  本来就直接用官方数字，不依赖反解 —— 学习器真正的用武之地是其他平台。"))
    }

    guard apply else {
        print("\n" + Ansi.dim("确认没问题后用 llmq learn --apply 写进 plans.json（只写反解出来的，不写下限）。"))
        return
    }

    let trustworthy = calibrated.filter(\.isTrustworthy)
    guard !trustworthy.isEmpty else {
        print("\n" + Ansi.yellow("没有一条拟合到可以直接写入的程度，什么都没改。"))
        print(Ansi.dim("拟合差通常说明平台的计费口径不在候选集里（比如按模型加权、"))
        print(Ansi.dim("或输入输出混合计价），这时写进去只是制造假精度。"))
        print(Ansi.dim("要么等样本更多，要么直接把官方公布的数字填进 plans.json。"))
        return
    }

    var cfg = PlansStore.load()
    var written = 0
    for e in trustworthy {
        guard let pi = cfg.plans.firstIndex(where: { $0.platform == e.platform }) else { continue }
        guard let li = cfg.plans[pi].limits.firstIndex(where: {
            $0.windowMinutes == e.windowMinutes
        }) else { continue }
        cfg.plans[pi].limits[li].limit = (e.value / 10).rounded() * 10
        cfg.plans[pi].limits[li].metric = e.metric
        cfg.plans[pi].limits[li].hint = "由 llmq learn 反解，样本 \(e.samples) 条"
        written += 1
    }
    try PlansStore.save(cfg)
    print("\n" + Ansi.green("已写入 \(written) 条上限") + Ansi.dim(" → " + Paths.plansFile.path))
    if written < trustworthy.count {
        print(Ansi.yellow("有 \(trustworthy.count - written) 条没写进去：plans.json 里没有对应窗口长度的条目。"))
    }
}

/// 「浪费了多少」在没有上限时唯一能站住的口径：完整过去的额度窗口里，
/// 一次都没用的有多少。取数和聚合在 WasteMeter.assessAll（纯函数），
/// 这里只负责打印。
/// `llmq archive [--to <目录>] [--keep-days N] [--dry-run]`
///
/// 干完的活归档到 NAS，本地只留还用得着的。默认目标从配置读
/// （`archiveTarget`），也可以 --to 临时指定。
func cmdArchive(_ args: [String]) throws {
    var target: URL?
    if let i = args.firstIndex(of: "--to"), i + 1 < args.count {
        target = URL(fileURLWithPath: NSString(string: args[i + 1]).expandingTildeInPath)
    } else if let saved = ArchiveConfig.target() {
        target = saved
    }
    var keep = 14
    if let i = args.firstIndex(of: "--keep-days"), i + 1 < args.count,
       let v = Int(args[i + 1]) { keep = v }
    let dry = args.contains("--dry-run")

    if target == nil {
        print(Ansi.yellow("没有归档目标 —— 只清理本地，不备份。"))
        print(Ansi.dim("  设一次：llmq archive --to /Volumes/<NAS>/llmq-archive --save"))
    } else {
        print(Ansi.dim("归档到 " + target!.path))
    }
    let r = try Archive.run(target: target, keepDays: keep, dryRun: dry)
    if dry { print(Ansi.yellow("（--dry-run，什么都没动）")) }
    print("  日志归档 \(r.archivedLogs) 个"
          + " · 任务记录归档 \(r.archivedTaskLines) 条"
          + " · worktree 清掉 \(r.removedWorktrees) 个")
    let mb = Double(r.freedBytes) / 1024 / 1024
    print(Ansi.green(String(format: "  本地腾出 %.0f MB", mb)))
    for n in r.notes { print(Ansi.dim("  " + n)) }

    if args.contains("--save"), let t = target {
        ArchiveConfig.save(t)
        print(Ansi.dim("  已记住这个归档目标，以后直接 llmq archive"))
    }
}

/// 归档目标存本机（不进 iCloud 共享配置）—— 每台机器的挂载点不一样，
/// 而且 NAS 路径属于这台机器的环境，不该跟着配置同步到别的机器上。
enum ArchiveConfig {
    static var file: URL { Paths.appSupport.appendingPathComponent("archive-target.txt") }
    static func target() -> URL? {
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let p = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? nil : URL(fileURLWithPath: p)
    }
    static func save(_ url: URL) {
        try? url.path.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// `llmq brief [--since <小时数>]` —— 两个会话共享事实的入口。
///
/// 派活会话和改代码会话各开一个，谁都不必读对方的对话：
/// 状态存储是同一份，这条命令把它压成三十秒能读完的一页。
func cmdBrief(_ args: [String]) {
    var hours = 2.0
    if let i = args.firstIndex(of: "--since"), i + 1 < args.count,
       let v = Double(args[i + 1]) { hours = v }
    let since = Date().addingTimeInterval(-hours * 3600)
    let tasks = TaskStore.all()

    print(Ansi.bold("== 最近 \(Int(hours)) 小时发生了什么 =="))
    let changes = Brief.changes(since: since, tasks: tasks)
    if changes.isEmpty {
        print(Ansi.dim("  （没有状态变化）"))
    }
    for c in changes.suffix(25) {
        let mark: String
        switch c.kind {
        case "完成", "落地": mark = Ansi.green(c.kind)
        case "失败", "卡住": mark = Ansi.red(c.kind)
        case "丢弃": mark = Ansi.dim(c.kind)
        default: mark = Ansi.cyan(c.kind)
        }
        var row = "  " + Format.dateTime(c.at) + "  " + mark + "  " + c.taskID
        row += Ansi.dim("  " + c.title)
        if let pl = c.platform { row += Ansi.dim(" · " + pl) }
        print(row)
        if let n = c.note, c.kind == "失败" || c.kind == "卡住" {
            print(Ansi.dim("        " + n))
        }
    }

    let s = Brief.snapshot(tasks: tasks)
    print("")
    print(Ansi.bold("== 此刻 =="))
    // 拆成几段拼：整串三元 + 插值在一个表达式里会让类型检查器超时（实测）。
    var line = "  在跑 \(s.running.count) · 排队 \(s.queued.count) · "
    line += s.blocked.isEmpty ? "卡住 0" : Ansi.yellow("卡住 \(s.blocked.count)")
    if s.pendingAsks > 0 { line += Ansi.yellow(" · 等你回话 \(s.pendingAsks)") }
    print(line)
    for t in s.running.prefix(5) {
        let mins = t.startedAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        let who = t.platform?.displayName ?? "?"
        let head = String(t.prompt.prefix(40))
        print(Ansi.dim("    跑着 " + t.id + " · \(mins) 分钟 · " + who + " · " + head))
    }
    for t in s.blocked.prefix(5) {
        print(Ansi.yellow("    卡住 " + t.id) + Ansi.dim(" · "
            + String((t.note ?? t.prompt).prefix(70))))
    }
    if !s.pendingReview.isEmpty {
        print("  待审：" + s.pendingReview
            .map { "\($0.repo) \($0.branches) 条" }.joined(separator: " · "))
    }
    // 平台在**某台机器上**坏了。冷却是「额度用完了，等等就好」，
    // 这个是「那台机器上它根本跑不了」—— 两回事，分开报。
    for line in s.platformProblems {
        print(Ansi.red("  平台异常：") + line)
    }
    if !s.cooling.isEmpty {
        let cool = s.cooling.map { c -> String in
            let left = Format.duration(c.until.timeIntervalSinceNow)
            return c.platform + "（" + c.reason + "，" + left + "后）"
        }
        print("  冷却：" + cool.joined(separator: " · "))
    }
    // 空窗只在这里报，不推送（见 Nudge.nothingToFill 的说明）。
    // 报的是**七天的次数**：单次「现在闲着」没意义，
    // 持续闲着才说明清单该添东西了。
    if !s.idleWindows.isEmpty {
        let idle = s.idleWindows.map { "\($0.platform) \($0.times) 次" }
        print(Ansi.dim("  空窗没活可填（近 7 天）：" + idle.joined(separator: " · ")))
    }
}

func cmdWaste() throws {
    let snapshots = SnapshotStore.loadAll()
    guard !snapshots.isEmpty else {
        print(Ansi.yellow("还没有任何快照，先跑一次 llmq collect。"))
        return
    }

    let results = WasteMeter.assessAll(snapshots: snapshots, config: PlansStore.load())
    guard !results.isEmpty else {
        // 空状态必须自证：有快照但一个平台都没探测到，要明说，
        // 不能一声不吭地输出一张空表。
        print(Ansi.yellow("快照里没有探测到任何平台的用量数据。"))
        print(Ansi.dim("先跑 llmq doctor 看本机认出了哪些数据源，再跑 llmq collect。"))
        return
    }

    print(Ansi.bold("空窗统计")
        + Ansi.dim(" · 完整过去的额度窗口里一次都没用的有多少（不需要知道上限）"))

    for pw in results {
        print("\n" + Ansi.bold(pw.platform.displayName))
        switch pw.verdict {
        case .measured(let reports):
            for r in reports { print("  " + WasteMeter.sentence(r)) }
        case .noBuckets:
            // **绝不能把这种情况输出成「100% 空窗」。**
            // 零个桶说明本地这条路子测不了它（比如不产生本地用量日志），
            // 不代表它没在被用。
            print("  " + Ansi.yellow("算不出来：所有电脑加起来都没有这个平台的一个用量桶。"))
            print(Ansi.dim("  没有本地日志 ≠ 没用过 —— 有的平台不产生本地用量记录，"))
            print(Ansi.dim("  也可能是采集还没覆盖到。这里不能报「窗口全空」。"))
        case .noWindowConfigured:
            print("  " + Ansi.yellow("算不出来：plans.json 里没有这个平台的任何窗口长度。"))
            print(Ansi.dim("  用 llmq plan edit 在 limits 里补上 windowMinutes。"))
        case .noRetentionStart:
            print("  " + Ansi.yellow("算不出来：快照里拿不到数据保留起点（retentionStart）。"))
            print(Ansi.dim("  重新跑一次 llmq collect 生成新快照。"))
        }
    }
}

// MARK: - work

func cmdWork(_ args: [String]) throws {
    let sub = args.first ?? "list"
    let rest = Array(args.dropFirst())

    switch sub {
    // llmq work plan —— 计划清单：排好顺序、由人放行的任务。
    //
    //   llmq work plan                     看清单（顺便报储备池还有多少）
    //   llmq work plan add "<任务>" [--repo <别名>] [--first]
    //   llmq work plan rm <序号>
    //   llmq work plan up|down <序号>
    //   llmq work plan go [<序号>]         放进执行队列（走查重和分诊）
    case "plan":
        let sub2 = rest.first ?? "list"
        let rest2 = Array(rest.dropFirst())
        switch sub2 {
        case "list", "":
            let list = PlannedStore.all()
            if list.isEmpty {
                print(Ansi.dim("计划清单是空的。llmq work plan add \"<任务>\" --repo <别名>"))
            } else {
                print(Ansi.bold("计划清单") + Ansi.dim("  按顺序放行，放着不动就不跑"))
                for (i, t) in list.enumerated() {
                    let repo = t.repoAlias.map { Ansi.cyan("[\($0)] ") } ?? ""
                    print("  \(i + 1). " + repo
                        + t.prompt.replacingOccurrences(of: "\n", with: " ").prefix(76))
                }
                print(Ansi.dim("  放行第一个：llmq work plan go"))
            }
            // 「还有哪些可以安排」的另一半：机器自己扫出来的储备活。
            let facts = ReservePool.facts(repo: RepoRegistry.resolve(nil)
                ?? FileManager.default.currentDirectoryPath)
            if !facts.isEmpty {
                print(Ansi.dim("储备池还有 \(facts.count) 条可安排（llmq work reserve）"))
            }

        case "add":
            guard let prompt = rest2.first(where: { !$0.hasPrefix("--") }) else {
                print("用法：llmq work plan add \"<任务>\" [--repo <别名>] [--first]"); exit(2)
            }
            var alias: String? = nil
            if let i = rest2.firstIndex(of: "--repo"), i + 1 < rest2.count {
                alias = rest2[i + 1]
                guard RepoRegistry.all().contains(where: { $0.alias == alias }) else {
                    print(Ansi.red("不认识别名 \(alias!)。已登记："))
                    for r in RepoRegistry.all() { print("  " + r.alias) }
                    exit(1)
                }
            }
            let t = try PlannedStore.add(prompt: prompt, repoAlias: alias,
                                         first: rest2.contains("--first"))
            let pos = rest2.contains("--first") ? 1 : PlannedStore.all().count
            print(Ansi.green("已加进计划 ") + "第 \(pos) 位  " + Ansi.dim(t.id))

        case "rm":
            guard let n = rest2.first.flatMap({ Int($0) }) else {
                print("用法：llmq work plan rm <序号>"); exit(2)
            }
            if let t = try PlannedStore.remove(at: n) {
                print(Ansi.green("已移除 ") + t.prompt.prefix(60))
            } else {
                print(Ansi.red("没有第 \(n) 条"))
            }

        case "up", "down":
            guard let n = rest2.first.flatMap({ Int($0) }) else {
                print("用法：llmq work plan \(sub2) <序号>"); exit(2)
            }
            try PlannedStore.move(position: n, up: sub2 == "up")
            try cmdWork(["plan"])

        case "go":
            let n = rest2.first.flatMap { Int($0) } ?? 1
            let list = PlannedStore.all()
            guard n >= 1, n <= list.count else {
                print(list.isEmpty ? Ansi.dim("计划清单是空的")
                                   : Ansi.red("没有第 \(n) 条")); exit(list.isEmpty ? 0 : 2)
            }
            let t = list[n - 1]
            guard let repoPath = RepoRegistry.resolve(t.repoAlias) else {
                print(Ansi.red("别名 \(t.repoAlias ?? "（默认）") 解析不了")); exit(1)
            }
            // 走 work add 的完整入口：查重、分诊、拆解一个不少。
            // 查重拦下时它会 exit(3)，计划条目原地保留 —— 那正是想要的。
            var fwd = ["add", t.prompt, "--repo", repoPath]
            fwd.append(contentsOf: rest2.filter { $0.hasPrefix("--") && $0 != "--first" })
            try cmdWork(fwd)
            _ = try PlannedStore.remove(at: n)
            print(Ansi.dim("已从计划清单移除（第 \(n) 位）"))

        default:
            print("用法：llmq work plan [add|rm|up|down|go]")
        }
        return

    case "add":
        guard let prompt = rest.first(where: { !$0.hasPrefix("--") }) else {
            print("用法：llmq work add \"<任务描述>\" [--repo <路径>] "
                + "[--deliverable-kind <类型> (--golden-sample <ID>|--fan-out-from <任务ID>)]")
            exit(2)
        }
        var repo = FileManager.default.currentDirectoryPath
        if let i = rest.firstIndex(of: "--repo"), i + 1 < rest.count {
            // 先按别名解析（resolve 认别名也认路径），再退回按路径展开。
            // 少了这一步的真实翻车：`--repo eap` 在 SSH 会话里被 isRepo
            // 靠 cwd（家目录）撞对放行、原样存进任务 —— 而 worker 的
            // cwd 是 `/`，建 worktree 时变成了 `/eap`，秒败。
            repo = RepoRegistry.resolve(rest[i + 1])
                ?? NSString(string: rest[i + 1]).expandingTildeInPath
        }
        // 存绝对路径：相对路径的含义随进程 cwd 漂移，入库前钉死。
        repo = URL(fileURLWithPath: repo).standardizedFileURL.path
        guard GitWorkspace.isRepo(repo) else {
            print(Ansi.red("\(repo) 不是 git 仓库。agent 需要在 worktree 里干活。"))
            exit(1)
        }
        // **查重：这活是不是已经有人在做、或者刚做完。**
        //
        // 这个工具的全部理由是「一分不浪费」，而它自己一直没有查重。
        // 实测代价（同一晚）：b6aa5e7f 和 42266d0fs1 两条任务提示词几乎一样，
        // 都跑到 done，改的是同样四个文件 —— 两份额度、两份实现，
        // 最后还得有人挑一个丢一个。
        //
        // **拦下来问，不是替你决定。** 误判会拦住真活，
        // 所以给出证据、给出放行开关，判断权留给人。
        if !rest.contains("--force") {
            let dups = DuplicateGuard.matches(prompt: prompt, repo: repo, in: TaskStore.all())
            if !dups.isEmpty {
                print(Ansi.yellow("⚠ 这活可能已经有人在做了"))
                for d in dups.prefix(3) {
                    let mark = d.state == .done
                        ? Ansi.dim("刚做完") : Ansi.cyan(d.state.rawValue)
                    print("  \(mark)  \(d.taskID)  " + Ansi.dim(d.why))
                    print(Ansi.dim("      " + d.prompt.replacingOccurrences(of: "\n", with: " ")
                        .prefix(72)))
                }
                print(Ansi.dim("  看它改了什么：git diff main...<分支>"))
                print(Ansi.dim("  确认不是同一件事就加 --force 再来一次"))
                exit(3)
            }
        }

        // 入队流程收口在 TaskIntake —— 手机放行计划任务走的也是它。
        // 两个入口共用一份流程，才不会漂移出「一边过查重一边不过」这种事。
        if !args.contains("--no-classify") { print(Ansi.dim("分诊中…")) }
        // --platform <名>：点名谁干（优先不是命令，闸门照常生效）。
        var preferred: Platform?
        if let i = rest.firstIndex(of: "--platform"), i + 1 < rest.count {
            preferred = Platform(rawValue: rest[i + 1].lowercased())
            if preferred == nil {
                print(Ansi.red("不认识的平台「\(rest[i + 1])」；可选：")
                    + Platform.allCases.map(\.rawValue).joined(separator: " "))
                exit(2)
            }
        }
        func option(_ name: String) -> String? {
            guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
            return rest[i + 1]
        }
        let deliverableKind = option("--deliverable-kind")
        let goldenSampleID = option("--golden-sample")
        let fanOutSource = option("--fan-out-from")
        var production: ProductionContext?
        if deliverableKind != nil || goldenSampleID != nil || fanOutSource != nil {
            guard let kind = deliverableKind, !kind.isEmpty else {
                print(Ansi.red("生产任务必须提供 --deliverable-kind <类型>")); exit(2)
            }
            guard (goldenSampleID == nil) != (fanOutSource == nil) else {
                print(Ansi.red("--golden-sample 和 --fan-out-from 必须且只能选一个")); exit(2)
            }
            if let sampleID = goldenSampleID {
                production = ProductionContext(
                    stage: .goldenSample, deliverableKind: kind,
                    goldenSampleID: sampleID)
            } else if let sourcePrefix = fanOutSource {
                let matches = TaskStore.all().filter {
                    $0.id == sourcePrefix || $0.id.hasPrefix(sourcePrefix)
                }
                guard matches.count == 1, let source = matches.first else {
                    print(Ansi.red(matches.isEmpty
                        ? "找不到黄金样板任务 \(sourcePrefix)"
                        : "任务前缀 \(sourcePrefix) 不唯一")); exit(2)
                }
                production = ProductionContext(
                    stage: .fanOut, deliverableKind: kind,
                    goldenSampleID: "", fanOutFromTaskID: source.id)
            }
        }
        let outcome = try TaskIntake.enqueue(
            prompt: prompt, repo: repo,
            classify: !args.contains("--no-classify"),
            split: !args.contains("--no-split"),
            force: true,   // 上面已经查过重（带打印），这里别查第二遍
            origin: nil,
            preferredPlatform: preferred,
            production: production)
        switch outcome {
        case .graph(let nodes):
            print(Ansi.green("已拆成 \(nodes.count) 步 ")
                + Ansi.dim("图 " + (nodes.first?.graphID ?? "")))
            for n in nodes {
                let dep = n.dependsOn.isEmpty ? "可立即开始"
                    : "依赖 " + n.dependsOn.map { String($0.suffix(2)) }.joined(separator: "、")
                print("  " + Ansi.bold(String(n.id.suffix(2))) + " "
                      + (n.stepTitle ?? "") + Ansi.dim("  \(dep)")
                      + Ansi.dim(n.profile.map { "  [\($0.risk.displayName)]" } ?? ""))
            }
        case .single(let t):
            if t.state == .blocked, let reason = t.production?.blockedReason {
                print(Ansi.yellow("已登记，暂不扩张 ") + t.id
                    + Ansi.dim("  " + reason))
            } else {
                print(Ansi.green("已入队 ") + t.id + Ansi.dim("  仓库 " + repo))
            }
            if let p = t.production {
                print(Ansi.dim("  生产阶段 " + p.stage.displayName + " · "
                    + p.deliverableKind + " · 样板 " + p.goldenSampleID))
            }
            printProfile(t.profile)
        case .duplicate:
            break   // force: true 之下不会出现
        }

    case "approve-sample":
        guard let id = rest.first else {
            print("用法：llmq work approve-sample <任务id> [说明]"); exit(2)
        }
        let all = TaskStore.all()
        let matches = all.filter { $0.id == id || $0.id.hasPrefix(id) }
        guard matches.count == 1, var sample = matches.first else {
            print(Ansi.red(matches.isEmpty ? "找不到任务 " + id : "任务前缀不唯一")); exit(1)
        }
        guard var context = sample.production, context.stage == .goldenSample else {
            print(Ansi.red("这不是黄金样板任务")); exit(1)
        }
        guard sample.state == .done else {
            print(Ansi.red("黄金样板尚未完成，不能提前批准")); exit(1)
        }
        context.approvedAt = Date()
        let approvalText = rest.dropFirst().joined(separator: " ")
        context.approvalNote = approvalText.isEmpty
            ? "人工确认黄金样板达标" : approvalText
        sample.production = context
        try TaskStore.append(sample)
        let updates = TaskGraph.reconcile(TaskStore.all())
        for task in updates { try? TaskStore.append(task) }
        _ = TaskBoardStore.publishNow()
        print(Ansi.green("已批准黄金样板 ") + sample.id
            + Ansi.dim(sample.landedAt == nil
                ? "  尚未合入主线，fan-out 会继续等待落地"
                : "  已重新核对批量任务"))

    case "retry":
        // **failed 必须有一条回得去的路。**
        //
        // 审查抓到的：全仓库没有任何地方把 .failed 推回 .queued，
        // 而 isReady 要求上游 .done —— 一个节点失败就永久冻死它的全部下游，
        // 唯一恢复手段是手工编辑 tasks.jsonl。
        // 而 TaskGraph 的注释里还写着「失败允许换个平台重试」，那是句假话。
        guard let id = rest.first else {
            print("用法：llmq work retry <任务id> [--same-platform]"); exit(2)
        }
        let allT = TaskStore.all()
        guard var t = allT.first(where: { $0.id == id || $0.id.hasSuffix(id) }) else {
            print(Ansi.red("找不到任务 " + id)); exit(1)
        }
        guard t.state == .failed || t.state == .blocked else {
            print(Ansi.red("只有失败或被拦下的任务能重试，这个是 \(t.state.rawValue)")); exit(1)
        }
        if let ask = t.pendingAsk {
            AskStore.retract(taskID: t.id,
                             machine: ask.machineID.isEmpty ? Paths.machineID() : ask.machineID)
        }
        t.state = .queued
        t.pendingAsk = nil
        t.frozenBy = nil
        t.endedAt = nil
        t.runnerPID = nil
        t.discardedAt = nil
        t.discardReason = nil
        // 默认清空「试过谁」，否则换平台重试第一道硬排除就把它们全挡了。
        // 想让它在同一个平台上再试一次就加 --same-platform。
        if !rest.contains("--same-platform") { t.triedPlatforms = [] }
        t.note = "人工重新入队"
        try TaskStore.append(t)
        print(Ansi.green("已重新入队 ") + t.id)
        // 重新入队之后要立刻对账 —— 被它冻住的下游该解冻了。
        for x in TaskGraph.reconcile(TaskStore.all()) {
            try? TaskStore.append(x)
            print(Ansi.dim("  解冻 " + x.id + "  " + (x.note ?? "")))
        }

    case "progress":
        // Agent 在同一个会话里交里程碑：既给执行租约续期，也立刻发到手机。
        // 不回写 WorkTask，避免 agent 子进程和 worker 并发覆盖任务主状态。
        var optionArgs = rest
        let explicitID: String?
        if let first = optionArgs.first, !first.hasPrefix("--") {
            explicitID = first
            optionArgs.removeFirst()
        } else {
            explicitID = nil
        }
        func option(_ name: String) -> String? {
            guard let i = optionArgs.firstIndex(of: name), i + 1 < optionArgs.count else {
                return nil
            }
            return optionArgs[i + 1]
        }
        let progressEnv = ProcessInfo.processInfo.environment
        guard let taskID = explicitID ?? progressEnv["LLMQ_TASK_ID"], !taskID.isEmpty else {
            print("用法：llmq work progress [任务id] --phase <阶段> --summary <完成事实> "
                  + "[--next <下一步>] [--evidence <路径>] [--request-minutes 20]")
            exit(2)
        }
        guard let phase = option("--phase"), !phase.trimmingCharacters(in: .whitespaces).isEmpty,
              let summary = option("--summary"),
              !summary.trimmingCharacters(in: .whitespaces).isEmpty else {
            print(Ansi.red("--phase 和 --summary 不能为空")); exit(2)
        }
        guard let progressTask = TaskStore.all().first(where: { $0.id == taskID }),
              progressTask.state == .running else {
            print(Ansi.red("任务 \(taskID) 不存在或已不在运行，拒绝写入伪进度")); exit(1)
        }
        var evidence: [String] = []
        for i in optionArgs.indices where optionArgs[i] == "--evidence"
            && i + 1 < optionArgs.count {
            evidence.append(optionArgs[i + 1])
        }
        let requested = option("--request-minutes").flatMap(Int.init) ?? 20
        let workspace = progressEnv["LLMQ_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath
        guard GitWorkspace.isRepo(workspace) else {
            print(Ansi.red("进度必须从任务的 git 工作区汇报")); exit(1)
        }
        let item = try WorkProgressStore.record(
            taskID: taskID, phase: phase, summary: summary,
            nextStep: option("--next"), evidence: evidence,
            requestedMinutes: requested, repo: workspace)
        _ = Watchdog.run("progress.publish", timeout: 8) { TaskBoardStore.publishNow() }
        print(Ansi.green("已汇报里程碑 #\(item.sequence) ")
              + Ansi.dim("\(item.phase)：\(item.summary)"))

    case "done":
        // **人在系统外把活办了，系统得能知道。**
        //
        // 原来只有 retry / discard / approve —— 全都假设「工作要么由 agent
        // 完成，要么不做了」。但现实里第三种情况天天发生：人手动合了分支、
        // 人自己把 bug 修了、或者上游卡死时人绕过去解决了。
        //
        // 这时候图节点会永远冻在 blocked，而且理由具有误导性：
        // 「上游『生成 Assets.xcassets』失败了」—— 可那个活早就完成并
        // 合进主干了，只是我合的时候没走任务系统。看板上五个「卡住」全是
        // 这种僵尸，人得挨个回忆才知道哪些是真卡、哪些已经办完了。
        //
        // discard 不能替代它：丢弃的语义是「这活不做了」，会污染落地率统计，
        // 下游也不会解冻。done 才是对的语义 —— 活办完了，接着往下走。
        guard let id = rest.first else {
            print("用法：llmq work done <任务id|图id> [说明]")
            print(Ansi.dim("  人在系统外办完的活（手动合并/自己修好/绕过去了）标完成，"))
            print(Ansi.dim("  下游节点会自动解冻。别用 discard —— 那是「不做了」的意思。"))
            exit(2)
        }
        let why = rest.count > 1 ? rest[1...].joined(separator: " ") : "人工确认已完成"
        let allDone = TaskStore.all()
        let hits = allDone.filter { $0.id == id || $0.graphID == id }
        guard !hits.isEmpty else { print(Ansi.red("找不到 " + id)); exit(1) }
        var n = 0
        for var t in hits where t.state != .done {
            if let ask = t.pendingAsk {
                AskStore.retract(taskID: t.id,
                                 machine: ask.machineID.isEmpty ? Paths.machineID() : ask.machineID)
            }
            t.state = .done
            t.endedAt = Date()
            t.pendingAsk = nil          // 挂着的提问一起收掉，别留在手机上
            t.note = "人工标完成：" + why
            try? TaskStore.append(t)
            n += 1
            print(Ansi.green("已标完成 ") + t.id + Ansi.dim("  " + String(t.prompt.prefix(50))))
        }
        if n == 0 { print(Ansi.dim("这些任务本来就是 done，没动。")) }
        // 标完立刻对账：下游该解冻的解冻，省得人再敲一条命令。
        let thawed = TaskGraph.reconcile(TaskStore.all())
        for t in thawed where t.state == .queued {
            print(Ansi.dim("  解冻 " + t.id + "  上游办完了，重新排队"))
            try? TaskStore.append(t)
        }

    case "discard":
        // 丢弃原来只能从手机的审批界面走 —— 而那个界面只覆盖
        // 「跑完了、碰到高危路径、在等你点」这一种情况。
        // 队列里一个还没跑的任务、一个失败后不想再试的任务，
        // 在命令行里都没有办法处理，只能去手改 tasks.jsonl。
        guard let id = rest.first else {
            print("用法：llmq work discard <任务id|图id> [理由]"); exit(2)
        }
        let reason = rest.count > 1 ? rest[1...].joined(separator: " ") : "人工丢弃"
        let allD = TaskStore.all()

        // 图按整张丢。**半张图没有意义** —— 留下的那几步既落不了地
        //（review 要求整张图终态），也没人会去跑（上游被丢了）。
        let inGraph = allD.filter { $0.graphID == id }
        let targets = inGraph.isEmpty
            ? allD.filter { $0.id == id || $0.id.hasSuffix(id) }
            : inGraph
        guard !targets.isEmpty else {
            print(Ansi.red("找不到任务或图 " + id)); exit(1)
        }
        if !inGraph.isEmpty {
            print(Ansi.yellow("这是一张图，整张丢（\(inGraph.count) 步）"))
        }

        var wipedWorktrees: Set<String> = []
        for var t in targets {
            // 正在跑的不能丢：进程还在写那个工作区，
            // 这时候删掉它等于把一个活着的 agent 的 cwd 抽走。
            if t.state == .running, let pid = t.runnerPID, pid > 0, kill(pid, 0) == 0 {
                print(Ansi.red("跳过 \(t.id)：还在跑（进程 \(pid)）。"
                               + "要停它先 kill，再 discard。"))
                continue
            }
            if let b = t.branch, !wipedWorktrees.contains(b) {
                wipedWorktrees.insert(b)
                Review.discard(repo: t.repo, branch: b, reason: reason)
            }
            if let ask = t.pendingAsk {
                AskStore.retract(taskID: t.id,
                                 machine: ask.machineID.isEmpty ? Paths.machineID() : ask.machineID)
            }
            t.state = .failed
            t.pendingAsk = nil
            t.discardedAt = Date()
            t.discardReason = reason
            t.frozenBy = nil
            t.note = "人工丢弃：" + reason
            try TaskStore.append(t)
            print(Ansi.green("已丢弃 ") + t.id + Ansi.dim("  " + (t.stepTitle ?? "")))
        }
        if let g = targets.first?.graphID { GraphSession.forgetGraph(g) }
        // 丢完要对账：被它冻住的下游现在该跟着变了。
        for x in TaskGraph.reconcile(TaskStore.all()) { try? TaskStore.append(x) }

    case "attempts":
        let taskID = rest.first(where: { !$0.hasPrefix("--") })
        let all = WorkAttemptStore.all()
        let attempts = taskID.map { id in
            all.filter { $0.taskID == id || $0.taskID.hasSuffix(id) }
        } ?? all
        guard !attempts.isEmpty else {
            print(Ansi.dim(taskID == nil ? "还没有 WorkAttempt 记录。"
                : "这个任务没有 WorkAttempt 记录。"))
            return
        }
        let summary = WorkAttemptMetrics.summarize(attempts)
        print(Ansi.bold("执行事实") + Ansi.dim("  按平台 / 任务档位；数据来自 append-only WorkAttempt"))
        print(Ansi.dim(pad("平台", 12) + pad("档位", 10) + pad("尝试", 8)
            + pad("超时", 8) + pad("超时率", 10) + "成功"))
        for group in summary.groups {
            let rate = group.attempts == 0 ? 0
                : Double(group.timeouts) / Double(group.attempts) * 100
            print(pad(group.platform.displayName, 12)
                + pad(group.tier?.displayName ?? "未知", 10)
                + pad("\(group.attempts)", 8)
                + pad("\(group.timeouts)", 8)
                + pad(String(format: "%.0f%%", rate), 10)
                + "\(group.successes)")
        }
        let recovery = summary.recovery
        print(Ansi.bold("超时后的下一次尝试"))
        print("  同 owner：\(recovery.sameOwnerSuccesses)/\(recovery.sameOwnerAttempts) 成功"
            + "  换人：\(recovery.handoffSuccesses)/\(recovery.handoffAttempts) 成功")
        print(Ansi.dim("  llmq work attempts <任务id> 可只看一条任务"))

    case "log":
        // 进度是自动算出来的，不靠谁记得去写 —— 任务库里本来就有全部素材。
        var repo = FileManager.default.currentDirectoryPath
        if let p = rest.first(where: { !$0.hasPrefix("--") }) {
            repo = RepoRegistry.all().first { $0.alias == p }?.localPath
                ?? NSString(string: p).expandingTildeInPath
        }
        if rest.contains("--write") {
            // 平时靠合并时自动写。这个开关是给「现在就想把 STATUS.md 刷新一下」
            // 用的 —— 比如刚接手一个仓库，想先看看它的自动段长什么样。
            let wrote = ProgressLog.recordLanding(repo: repo, branch: nil)
            print(wrote ? Ansi.green("已更新 ") + repo + "/STATUS.md"
                        : Ansi.dim("内容没变，没动文件"))
            return
        }
        print(Ansi.dim(repo))
        print(ProgressLog.render(repo: repo, tasks: TaskStore.all())
            .replacingOccurrences(of: ProgressLog.begin, with: "")
            .replacingOccurrences(of: ProgressLog.end, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines))

    case "list":
        let tasks = TaskStore.all()
        if tasks.isEmpty { print(Ansi.dim("任务队列是空的。llmq work add \"...\" 加一个。")); return }
        print(Ansi.dim(pad("ID", 10) + pad("状态", 8) + pad("档次", 6)
            + pad("平台", 10) + pad("耗时", 9) + pad("改动", 7) + "任务"))

        func stateColor(_ st: WorkTask.State) -> (String) -> String {
            switch st {
            case .done: return Ansi.green
            case .failed: return Ansi.red
            case .running: return Ansi.yellow
            case .queued: return Ansi.dim
            case .blocked: return Ansi.cyan
            }
        }

        /// 一行任务。`indent` 用来把图内节点缩进到图标题下面。
        func row(_ t: WorkTask, indent: String = "", all: [WorkTask]) {
            var title = indent + (t.stepTitle ?? String(t.prompt.prefix(46)))
            // 依赖关系直接写在标题后面。**看不出先后的图等于没有图** ——
            // 一个 queued 的节点到底是「马上要跑」还是「在等第三步」，
            // 平铺列表里完全看不出来，而这两者的处理方式完全不同。
            if !t.dependsOn.isEmpty {
                let names = t.dependsOn.map { d -> String in
                    let up = all.first { $0.id == d }
                    let ok = up?.state == .done
                    return (ok ? "✓" : "·") + (up?.stepTitle.map { String($0.prefix(10)) }
                                               ?? String(d.suffix(2)))
                }
                title += Ansi.dim("  ← " + names.joined(separator: " "))
            }
            print(pad(t.id, 10)
                + pad(stateColor(t.state)(t.state.rawValue), 8)
                + pad(t.profile?.tier.displayName ?? "—", 6)
                + pad(t.platform?.displayName ?? "—", 10)
                + pad(t.duration.map { String(format: "%.0fs", $0) } ?? "—", 9)
                + pad(t.changedFiles.map { "\($0)" } ?? "—", 7)
                + title)
            if let n = t.note {
                print(Ansi.dim("          " + indent + n.replacingOccurrences(
                    of: "\n", with: "\n          " + indent)))
            }
            if let b = t.branch { print(Ansi.dim("          " + indent + "分支 " + b)) }
        }

        // 图内节点归到一起，按 stepIndex 排；散任务按原顺序。
        var printedGraphs: Set<String> = []
        for t in tasks {
            guard let g = t.graphID else { row(t, all: tasks); continue }
            if printedGraphs.contains(g) { continue }
            printedGraphs.insert(g)

            let nodes = tasks.filter { $0.graphID == g }
                .sorted { ($0.stepIndex ?? 0, $0.createdAt) < ($1.stepIndex ?? 0, $1.createdAt) }
            let done = nodes.filter { $0.state == .done }.count
            let left = TaskGraph.remaining(graphID: g, in: tasks)
            let head = TaskGraph.isComplete(graphID: g, in: tasks)
                ? Ansi.green("跑完了，等审")
                : (left > 0 ? Ansi.dim("还差 \(left) 步") : Ansi.red("全都没成"))
            print(Ansi.bold("图 " + g) + Ansi.dim("  \(done)/\(nodes.count) 步完成  ") + head)
            for n in nodes { row(n, indent: "  ", all: tasks) }
        }

    case "run":
        try runOneTask(dryRun: rest.contains("--dry-run"))

    case "loop":
        try cmdWorkLoop(rest)

    // llmq work autoland on|off|status —— 授权/收回「验收通过的安全产出自动合入」
    // llmq work evidence <分支> —— 把 agent 交的证据截图抽出来直接看。
    //
    // 图在分支里躺着，人要看得先 checkout 或 git show，麻烦到宁可自己重跑 ——
    // 而「宁可自己重跑」正是产出积压的根源（56% 的完成产出没人来得及审）。
    // 抽到一个临时目录、打印路径，两秒钟的事。
    case "evidence":
        guard let branch = rest.first else {
            print("用法：llmq work evidence <分支>")
            print(Ansi.dim("  把该分支里的验收截图抽到临时目录并打印路径"))
            exit(2)
        }
        let repoE = RepoRegistry.resolveForCommand(
            rest.firstIndex(of: "--repo").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil },
            cwd: FileManager.default.currentDirectoryPath)
            ?? FileManager.default.currentDirectoryPath
        let itemsE = Review.list(repo: repoE)
        guard let hit = itemsE.first(where: { $0.branch == branch || $0.branch.hasSuffix(branch) })
        else {
            print(Ansi.red("待审名单里没有 " + branch))
            print(Ansi.dim("  先看看有哪些：llmq work review --repo <别名>"))
            exit(1)
        }
        guard !hit.evidence.isEmpty else {
            print(Ansi.yellow("这条分支没有证据截图。"))
            print(Ansi.dim("  它交活时该自己跑一遍并截图（见仓库 AGENTS.md 的质量门槛）。"))
            print(Ansi.dim("  只能自己下场：git checkout " + hit.branch))
            exit(1)
        }
        let outDir = NSTemporaryDirectory() + "llmq-evidence-" + hit.taskID
        try? FileManager.default.createDirectory(
            atPath: outDir, withIntermediateDirectories: true)
        var got = 0
        for f in hit.evidence {
            let dest = outDir + "/" + (f as NSString).lastPathComponent
            // **重定向到文件，别让字节过 String。**
            // PNG 是二进制，经过 String 转换必然损坏（试过：图打不开）。
            // 用 shell 重定向，git 直接把字节写进文件。
            let esc = { (x: String) in "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let cmd = "git show " + esc(hit.branch + ":" + f) + " > " + esc(dest)
            let r = Proc.run("/bin/sh", ["-c", cmd], cwd: repoE, env: [:], timeout: 30)
            if r.exitCode == 0,
               (try? FileManager.default.attributesOfItem(atPath: dest)[.size] as? Int) ?? 0 > 0 {
                got += 1
            }
        }
        print(Ansi.green("抽出 \(got) 张证据 → ") + outDir)
        print(Ansi.dim("  open " + outDir))

    case "autoland":
        switch rest.first ?? "status" {
        case "on":
            Review.setAutoLand(enabled: true)
            print(Ansi.green("自动落地已开启。")
                + "循环每轮会把满足全部条件的产出合进 main："
                + "任务 done、非高危、能干净合入、不碰敏感路径、"
                + "且合并前验收通过。改同一个文件的分支排队合（一轮一条，"
                + "先合最老的）。其余照旧留给 work review。")
        case "off":
            Review.setAutoLand(enabled: false)
            print("自动落地已关闭，产出全部回到人工 work review。")
        default:
            print("自动落地：" + (Review.autoLandEnabled()
                ? Ansi.green("开") : "关（llmq work autoland on 开启）"))
        }

    case "stale":
        // llmq work stale [--dispatch] —— 看哪些分支过期了；加 --dispatch 才真派活
        let doDispatch = rest.contains("--dispatch")
        var any = false
        for repo in RepoRegistry.all() {
            let path = NSString(string: repo.localPath).expandingTildeInPath
            let cs = StaleBranch.candidates(repo: path)
            let sk = StaleBranch.skipped(repo: path)
            guard !cs.isEmpty || !sk.isEmpty else { continue }
            any = true
            print(Ansi.bold(repo.alias) + Ansi.dim("  " + path))
            for c in cs {
                print("  " + Ansi.yellow(c.branch)
                    + Ansi.dim("  落后 \(c.commitsBehind) 个提交，\(c.files) 个文件，"
                        + "当初是 \(c.platform?.rawValue ?? "?") 做的"))
                print(Ansi.dim("    " + c.subject.prefix(70)))
            }
            for s in StaleBranch.skipped(repo: path) {
                print("  " + Ansi.dim(s.branch + "  \(s.files) 个文件 —— 不自动刷"))
                print(Ansi.dim("    原因：" + s.reason))
            }
            if doDispatch {
                for o in StaleBranch.dispatchRefresh(repo: path) {
                    print((o.enqueued ? Ansi.green("  ↻ 已派 ") : Ansi.yellow("  ⚠︎ 没派 "))
                        + o.branch + Ansi.dim("  " + o.note))
                }
            }
        }
        if !any {
            print("没有过期分支。")
        } else if !doDispatch {
            print(Ansi.dim("加 --dispatch 派刷新任务回给原平台（它还留着当时的会话）"))
        }

    // llmq work restart-worker —— **原子地**「没人在跑才踢 worker」。
    //
    // 装机脚本原来自己判:`llmq brief | grep -oE '在跑 [0-9]+'` —— 两个毛病,
    // 2026-08-22 凌晨同时发作,把一个刚跑 32 秒的任务连人带活杀了:
    //  ① 拿人类可读输出当接口(这个仓库反复栽的那个形状),排版一变就失灵;
    //  ② 判断和 kickstart 分在两个进程、隔着几十秒的编译,中间新任务开跑。
    // 收成一条命令:同一个进程里先看后踢,数据直接读 TaskStore,没有文本契约。
    // llmq work restart-app —— 拉起菜单栏 App 并**核实它真的起来了**。
    //
    // 第三次踩同一个形状了(2026-08-22):`open <刚删又建的 bundle>` 会
    // 静默失败(LaunchServices 注册过期),而调用方照样宣布「已重新启动」。
    // App 一死,iCloud 镜像就停 —— 手机上看到的是几十分钟前的快照,
    // 老板两次报「任务停了」,其实系统一直在跑。
    // 更新路径(ReleaseChannel.install)已经修过一次,装机脚本是另一份实现:
    // 收成这一条命令,不再有第二份。
    // llmq work blocked —— **归 Claude 处置的拦截**,一眼看完。
    //
    // 老板 2026-08-22 常设指示:技术性拦截我处置,只有风险类和验收类
    // 才推给他。那就得有个地方让我看见它们 —— 否则「归我」等于「没人管」。
    case "blocked":
        var latest: [String: WorkTask] = [:]
        for t in TaskStore.all() { latest[t.id] = t }
        let all = latest.values.filter { $0.state == .blocked }
        let mine = all.filter { ($0.note ?? "").contains("等 Claude 处置") }
        let boss = all.filter { ($0.note ?? "").contains("等你确认") }
        let frozen = all.count - mine.count - boss.count
        // **搁浅链也要算进「有没有东西」。** 原来这里 mine/boss 都空就提前
        // return —— 而纯搁浅场景(某步 failed + 下游冻住)恰恰 mine/boss 都空,
        // 于是 :1189 的搁浅段永远到不了,还打印「没有等人处置的拦截」。
        // 这正好架空了本轮「搁浅归 Claude 看」的迁移(2026-08-23 复审逮到)。
        let strandsNow = TaskGraph.stranded(TaskStore.all())
        if mine.isEmpty && boss.isEmpty && strandsNow.isEmpty {
            print(Ansi.green("没有等人处置的拦截。")
                + (frozen > 0 ? Ansi.dim("（另有 \(frozen) 条在等上游，会自动解冻）") : ""))
            return
        }
        if !mine.isEmpty {
            print(Ansi.bold("该我处置（\(mine.count)）"))
            for t in mine.sorted(by: { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }) {
                print("  " + Ansi.yellow(t.id) + "  "
                    + URL(fileURLWithPath: t.repo).lastPathComponent
                    + Ansi.dim("  " + (t.note ?? "")))
                print(Ansi.dim("    " + t.prompt.prefix(72).replacingOccurrences(of: "\n", with: " ")))
            }
            print(Ansi.dim("  看改动：llmq work log <id>；放行：llmq work approve <id>"))
        }
        if !boss.isEmpty {
            print(Ansi.bold("\n要老板拍板（\(boss.count)）") + Ansi.dim("  已推到他手机"))
            for t in boss { print("  " + t.id + Ansi.dim("  " + (t.note ?? ""))) }
        }
        if frozen > 0 { print(Ansi.dim("\n另有 \(frozen) 条在等上游，会自动解冻。")) }
        // 搁浅的任务图也归我 —— 它不再推给老板(纯技术问题,见 Nudge 里那段),
        // 那就必须在这里看得见,否则「归我」等于「没人管」。
        let strands = strandsNow
        if !strands.isEmpty {
            print(Ansi.bold("\n搁浅的任务链（\(strands.count)）")
                + Ansi.dim("  跑挂一步就不会自己恢复"))
            for st in strands.prefix(6) {
                print("  " + Ansi.yellow(st.graphID)
                    + Ansi.dim("  已完成 \(st.doneCount) 步的产出还没落地"))
            }
            print(Ansi.dim("  处置：llmq work retry <挂掉的那步>，或让它走搁浅捞回的审核"))
        }
        return

    case "restart-app":
        func appAlive() -> Bool {
            Proc.run("/usr/bin/pgrep", ["-f", "LLMQuotaBar.app/Contents/MacOS"],
                     cwd: "/", env: [:], timeout: 5).exitCode == 0
        }
        _ = Proc.run("/usr/bin/open", ["/Applications/LLMQuotaBar.app"],
                     cwd: "/", env: [:], timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        if !appAlive() {
            // 按名字开走的是另一条路,不吃刚失效的路径缓存。
            _ = Proc.run("/usr/bin/open", ["-a", "LLMQuotaBar"],
                         cwd: "/", env: [:], timeout: 20)
            Thread.sleep(forTimeInterval: 3)
        }
        if appAlive() {
            print(Ansi.green("   菜单栏 App 已启动"))
        } else {
            print(Ansi.red("   ⚠︎ 菜单栏 App 没能启动 —— 这台机器的镜像同步会停,"))
            print(Ansi.dim("      手机上会看到过时的快照。手动试：open -a LLMQuotaBar"))
            exit(1)
        }
        return

    case "restart-worker":
        // 在飞判定只有一份(inFlightAgent):这里原来是自己写的一份 `?? false`,
        // 和 restartResidentServices 的 `?? true` 不一致 —— 任务刚起、PID 还没落盘
        // 的那一小段窗口里,这条命令会把它踢死。同一件事两处判,必出这种事。
        if let busy = inFlightAgent() {
            let ran = busy.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            print(Ansi.yellow("没重启 worker：") + Ansi.dim(
                "\(busy.id) 正在跑（已 \(ran) 秒）。新二进制等它干完自然生效。"))
            exit(3)   // 3 = 有活在跑,调用方据此决定要不要等
        }
        let kick = Proc.run("/bin/launchctl",
                            ["kickstart", "-k", "gui/\(getuid())/com.llmquotabar.worker"],
                            cwd: "/tmp", env: [:], timeout: 30)
        if kick.exitCode == 0 {
            print(Ansi.green("已重启工作循环（换了二进制）"))
        } else {
            print(Ansi.red("踢 worker 失败（退出码 \(kick.exitCode)）：")
                + (kick.stderr + " " + kick.stdout)
                    .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            exit(1)
        }
        return

    case "land":
        // llmq work land —— **手动跑一轮落地。**
        //
        // 存在的理由：落地原先只能靠常驻循环跑，人既不能手动触发、
        // 也看不到它的判断过程。2026-08-20 排查「该合而没合」时，
        // 我连着四次想前台跑一轮循环来观察，全被防重入拦下
        //（launchd 的 KeepAlive 比 pkill 快）—— 而 `work why` 只是**模拟**
        // 一遍闸序，它说「所有闸都过了」时，真正的 autoLand 仍然什么都不做。
        //
        // 模拟和实跑对不上时，只有实跑说了算。这个命令就是那个实跑入口。
        for repo in RepoRegistry.all() {
            let path = NSString(string: repo.localPath).expandingTildeInPath
            guard GitWorkspace.isRepo(path) else { continue }
            if let only = rest.first, only != repo.alias, only != path { continue }
            let outcomes = Review.autoLand(repo: path)
            print(Ansi.bold(repo.alias) + Ansi.dim("  " + path))
            if outcomes.isEmpty {
                print(Ansi.yellow("  一条都没动 ") + Ansi.dim(
                    "—— 跑 llmq work why " + repo.alias + " 看每条卡在哪"))
                continue
            }
            for o in outcomes {
                let mark = o.landed ? Ansi.green("  ✓ 落地 ") : Ansi.yellow("  ⚠︎ 没落 ")
                print(mark + o.branch + Ansi.dim("  " + o.note))
            }
        }

    case "why":
        // llmq work why —— 每条待审分支为什么没落地。
        // 存在的理由见 Review.whyNotLanding：autoLand 的闸全是静默 continue，
        // 「一条都不合」和「没有待审」在日志里长得一模一样。
        for repo in RepoRegistry.all() {
            let path = NSString(string: repo.localPath).expandingTildeInPath
            guard GitWorkspace.isRepo(path) else { continue }
            let blocked = Review.whyNotLanding(repo: path)
            guard !blocked.isEmpty else { continue }
            print(Ansi.bold(repo.alias) + Ansi.dim("  " + path))
            for b in blocked {
                print("  " + Ansi.yellow(b.branch))
                print(Ansi.dim("    " + b.reason))
            }
        }

    case "install-loop":
        try cmdInstallLoop()

    case "probe":
        try probePlatforms()

    // llmq work reserve [--limit N] [--commit]
    //
    // 储备任务池：额度快作废时拿来填窗口的低危维护任务。
    // 默认只看不写 —— 生成任务是会烧额度的动作，不该是敲错一个词的后果。
    // llmq work idle
    //
    // 空窗填活的**决策可视化**：现在有哪些窗口快过期、会不会填、填什么。
    // 只看不做 —— 一个会自动花钱的东西，必须有办法在它花钱之前看清它想干嘛。
    case "idle":
        let dash = LLMQuota.dashboard()
        let opps = IdleFiller.opportunities(dashboard: dash)
        if opps.isEmpty {
            print(Ansi.dim("此刻没有「快过期又没用够」的窗口。"))
            print(Ansi.dim("判据：窗口剩不到 "
                           + Format.duration(IdleFiller.Policy.fillWithin)
                           + "、已用低于 \(Int(IdleFiller.Policy.idleBelow * 100))%、"
                           + "且平台不在冷却/静音/指挥岗。"))
            break
        }
        for o in opps {
            print(Ansi.bold(o.platform.displayName) + Ansi.dim("  " + o.reason))
            if let w = IdleFiller.findWork(for: o) {
                print(Ansi.green("  会填：") + w.prefix(90) + "…")
            } else {
                print(Ansi.dim("  不填：没有现成的真需求。"
                               + "（储备池空 or 队列里还有活 —— 绝不为了填窗口编任务）"))
            }
        }

    case "reserve":
        let repoArg = rest.firstIndex(of: "--repo").flatMap { i -> String? in
            let j = rest.index(after: i)
            return j < rest.endIndex ? rest[j] : nil
        }
        let repoPath = RepoRegistry.resolveForCommand(
            repoArg, cwd: FileManager.default.currentDirectoryPath)
            ?? NSString(string: repoArg ?? FileManager.default.currentDirectoryPath)
                .expandingTildeInPath
        let limit = rest.firstIndex(of: "--limit").flatMap { i -> Int? in
            let j = rest.index(after: i)
            return j < rest.endIndex ? Int(rest[j]) : nil
        } ?? 3
        let commit = rest.contains("--commit")

        let all = ReservePool.facts(repo: repoPath)
        let tasks = TaskStore.all()
        let todo = ReservePool.pending(all, tasks: tasks)

        print(Ansi.dim("仓库 \(repoPath)"))
        print(Ansi.dim("扫出 \(all.count) 条事实，其中 \(todo.count) 条还没人做"))
        var byRule: [String: Int] = [:]
        for f in todo { byRule[f.rule.title, default: 0] += 1 }
        if !byRule.isEmpty {
            print(Ansi.dim("  " + byRule.sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: "、")))
        }
        guard !todo.isEmpty else { return }

        // **排队里还有活就不生成。**
        //
        // 储备池是用来填空窗的，不是用来加塞的。队列非空说明真实工作
        // 还没做完，这时候再灌进去只会跟真活抢额度 —— 而真活的价值
        // 永远高于「补个文档注释」。
        let queued = tasks.filter { $0.state == .queued }.count
        if queued > 0 {
            print(Ansi.yellow("队列里还有 \(queued) 个任务在排，不生成。")
                + Ansi.dim("储备池是填空窗的，不跟真活抢。"))
            return
        }

        let picked = Array(todo.prefix(limit))
        for f in picked {
            print("\n" + Ansi.bold(f.rule.title) + Ansi.dim("  \(f.file):\(f.line)  \(f.symbol)"))
            print(Ansi.dim("   " + ReservePool.prompt(for: f).prefix(72) + "…"))
        }
        guard commit else {
            print("\n" + Ansi.dim("这是预演。真要生成加 --commit"))
            return
        }
        var made = 0
        for f in picked {
            var t = WorkTask(id: String(UUID().uuidString.prefix(8)).lowercased(),
                             prompt: ReservePool.prompt(for: f), repo: repoPath)
            t.origin = f.key
            try TaskStore.append(t)
            made += 1
        }
        print("\n" + Ansi.green("生成了 \(made) 个储备任务"))

    // llmq work approve <任务id> [--reject] —— 放行/丢弃一个卡在高危路径闸上的任务
    //
    // 和手机上点按钮走的是**同一个函数**（Approval.settle）。
    // 两条路各写一份的话，迟早会出现一边提交、一边只改状态的分歧，
    // 那时候任务显示 done 而分支上什么都没有。
    case "approve":
        // rest 已经去掉子命令了（cmdWork 开头就 dropFirst 过），
        // 这里再 dropFirst 会把任务 id 一起丢掉 —— 犯过一次。
        let id = rest.first(where: { !$0.hasPrefix("--") }) ?? ""
        guard !id.isEmpty, let t0 = TaskStore.all().first(where: { $0.id.hasPrefix(id) }) else {
            print(Ansi.red("要给任务 id：llmq work approve <id> [--reject]")); exit(2)
        }
        guard t0.state == .blocked else {
            print(Ansi.yellow("任务 \(t0.id) 现在是 \(t0.state)，不是等确认的状态")); exit(1)
        }
        let r = Approval.settle(task: t0, approve: !rest.contains("--reject"))
        try TaskStore.append(r.task)
        AskStore.retract(taskID: t0.id, machine: Paths.machineID())
        print((r.task.state == .done ? Ansi.green : Ansi.yellow)(r.note))
        if r.task.state == .done {
            print(Ansi.dim("接下来：llmq work review --auto 走验证合并"))
        }

    case "cooldowns":
        let active = CooldownLedger.active()
        if active.isEmpty { print(Ansi.dim("没有平台处于冷却中。")); return }
        print(Ansi.dim(pad("平台", 10) + pad("原因", 12) + pad("剩余", 12)
            + pad("连续", 6) + "详情"))
        for cd in active.values.sorted(by: { $0.platform.sortIndex < $1.platform.sortIndex }) {
            let remain = cd.cause.needsHumanFix
                ? Ansi.red("需人工处理")
                : Format.duration(cd.remaining)
            print(pad(cd.platform.displayName, 10) + pad(cd.cause.displayName, 12)
                + pad(remain, 12) + pad("\(cd.strikes)", 6)
                + String(cd.detail.prefix(60)).replacingOccurrences(of: "\n", with: " "))
        }
        print(Ansi.dim("\n处理完之后用 llmq work resume <平台> 解除，比如 llmq work resume kimi"))

    // llmq work asks —— 看有哪些任务在等回答，顺便收一次答复
    case "asks":
        let mid = Paths.machineID()
        for r in AskIngest.run(machineID: mid,
                               load: { TaskStore.all() },
                               save: { try TaskStore.append($0) }) {
            print((r.accepted ? Ansi.green("✓ ") : Ansi.yellow("⚠︎ "))
                  + r.taskID + Ansi.dim("  " + r.note))
        }
        let pending = AskStore.pending(machine: mid)
        if pending.isEmpty {
            print(Ansi.dim("没有在等回答的任务。"))
        } else {
            print(Ansi.bold("\n\(pending.count) 个任务在等你回答") + Ansi.dim("（手机上「问题」那一栏）"))
            for a in pending {
                print("\n" + Ansi.bold(a.taskID) + Ansi.dim("  第 \(a.round) 轮 · "
                    + (a.platform?.displayName ?? "?") + " · " + a.repoName))
                print(Ansi.dim("  任务：" + a.taskPrompt.prefix(50)))
                for q in a.questions {
                    print("  · " + q.text)
                    if let o = q.options { print(Ansi.dim("      " + o.joined(separator: " / "))) }
                }
            }
        }

    // llmq work review [--repo <别名>] [--merge <分支>] [--discard <分支>] [--prune]
    case "review":
        // 没给 --repo 就用当前目录（详见 RepoRegistry.resolveForCommand）。
        let repoPath = RepoRegistry.resolveForCommand(
            rest.firstIndex(of: "--repo").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil },
            cwd: FileManager.default.currentDirectoryPath)
            ?? FileManager.default.currentDirectoryPath
        guard GitWorkspace.isRepo(repoPath) else {
            print(Ansi.red("\(repoPath) 不是 git 仓库")); exit(1)
        }

        if let i = rest.firstIndex(of: "--merge"), i + 1 < rest.count {
            switch Review.merge(
                repo: repoPath, branch: rest[i + 1],
                allowQualityOverride: rest.contains("--override-quality")) {
            case .success:
                print(Ansi.green("已合并 ") + rest[i + 1] + Ansi.dim("（分支和工作区已清理）"))
            case .failure(let e):
                print(Ansi.red(e.localizedDescription)); exit(1)
            }
            return
        }
        if let i = rest.firstIndex(of: "--discard"), i + 1 < rest.count {
            var reason: String?
            if let j = rest.firstIndex(of: "--reason"), j + 1 < rest.count { reason = rest[j + 1] }
            Review.discard(repo: repoPath, branch: rest[i + 1], reason: reason)
            print(Ansi.green("已丢弃 ") + rest[i + 1]
                + (reason.map { Ansi.dim("  " + $0) } ?? ""))
            return
        }
        if rest.contains("--prune") {
            let cleaned = Review.pruneMerged(repo: repoPath)
            print(cleaned.isEmpty ? Ansi.dim("没有可清理的已合并分支")
                  : Ansi.green("清理了 \(cleaned.count) 个：") + cleaned.joined(separator: "、"))
            return
        }

        // 「跑完了」和「有人要」是两回事。这一行才是真正的积压数字：
        // 烧了额度、产出了东西、但至今没进 main —— 那份额度和浪费掉没区别。
        let all = TaskStore.all()
        let done = all.filter { $0.state == .done && ($0.changedFiles ?? 0) > 0 }
        let landed = done.filter { $0.landedAt != nil }
        let dropped = all.filter { $0.discardedAt != nil }

        // llmq work review --auto —— 能干净合、验证也过的，直接落地
        //
        // 这个开关存在的理由：这套系统的产出是**无人值守**生成的，
        // 而消化端只要还需要人手工敲命令，积压就是必然的 ——
        // 实测跑了 8 个任务、产出 8 份、落地 0 份，不是产出不行，
        // 是根本没人走评审那一步。
        //
        // 但「自动」不等于「不看」：只有仓库配了验证命令、而且合并结果
        // 真的通过了验证，才会落地。没配验证命令的仓库一律不自动合 ——
        // 不验证就自动落地，等于把无人值守的产出直接推进主干。
        if rest.contains("--auto") {
            let cands = Review.list(repo: repoPath).filter(\.mergesCleanly)
            guard !cands.isEmpty else {
                print(Ansi.dim("没有能干净合入的分支。")); return
            }
            let reg = RepoRegistry.all().first {
                NSString(string: $0.localPath).expandingTildeInPath
                    == NSString(string: repoPath).expandingTildeInPath
            }
            guard let cmd = reg?.verifyCommand, !cmd.isEmpty else {
                print(Ansi.red("这个仓库没配验证命令，不自动合。"))
                print(Ansi.dim("先配上：llmq repo verify <别名> \"swift build && swift test\""))
                exit(1)
            }
            print(Ansi.dim("验证命令：\(cmd)"))
            // 不能自己再循环调用裸 merge。那条旧路径只验构建，绕过 agent 票、
            // 视觉票、任务状态、重叠顺序和否决名单；名字叫 --auto，实际比
            // 常驻自动落地少了大半安全条件。统一走唯一的 autoLand 策略。
            let outcomes = Review.autoLand(
                repo: repoPath, tasks: TaskStore.all(), maxPerCall: cands.count)
            let ok = outcomes.filter(\.landed).count
            for outcome in outcomes {
                print((outcome.landed ? Ansi.green("  ✓ ") : Ansi.red("  ✗ "))
                      + outcome.branch + Ansi.dim("  " + outcome.note))
            }
            if outcomes.isEmpty {
                let reasons = Review.whyNotLanding(repo: repoPath)
                for blocked in reasons.prefix(8) {
                    print(Ansi.yellow("  等待 ") + blocked.branch
                          + Ansi.dim("  " + blocked.reason))
                }
            }
            print("\n" + Ansi.bold("落地 \(ok) 份")
                  + (ok < cands.count ? Ansi.dim("，其余仍受统一质量策略约束") : ""))
            return
        }

        let items = Review.list(repo: repoPath)
        if !done.isEmpty {
            let rate = done.isEmpty ? 0 : Double(landed.count) / Double(done.count)
            print(Ansi.dim("产出 \(done.count) 份，落地 \(landed.count) 份"
                + (dropped.isEmpty ? "" : "，丢弃 \(dropped.count) 份")
                + String(format: "  落地率 %.0f%%", rate * 100)))
        }
        // 顺手发给手机 —— 人看得见才谈得上验收。
        //
        // **空清单也要发。** 只在有内容时才写文件的话，最后一份被合掉之后
        // 手机上会一直挂着上一批的旧数据，人点进去看到的是幽灵。
        let published = Review.publishDigests()
        guard !items.isEmpty else {
            print(Ansi.dim("这个仓库没有待审的 agent 分支。"))
            if !published.isEmpty {
                print(Ansi.dim("（别的仓库还有 \(published.count) 份，已发给手机）"))
            }
            return
        }
        let clean = items.filter(\.mergesCleanly).count
        print(Ansi.bold("\(items.count) 个待审产出")
            + Ansi.dim("  \(clean) 个能干净合入，\(items.count - clean) 个有冲突"))

        // 提醒而不是断言。实测发现改同一个文件、但改的是不同段落时，
        // git 的三方合并能处理，合完第一个之后第二个照样干净。
        // 但改到同一段就会冲突 —— 所以值得点出来让人先看一眼，
        // 而不是替它下结论。
        let grouped = items.filter { !$0.overlapsWith.isEmpty }
        if !grouped.isEmpty {
            print(Ansi.yellow("\n注意：\(grouped.count) 个分支和别的分支改了同一个文件。")
                + Ansi.dim("改的是不同段落就没事，改到同一段合第二个时会冲突。"))
        }

        for it in items {
            let mark = it.mergesCleanly ? Ansi.green("✓") : Ansi.red("✗")
            print("\n" + mark + " " + Ansi.bold(it.branch))
            if let p = it.prompt { print(Ansi.dim("   任务：" + p.prefix(56))) }
            print(Ansi.dim("   \(it.files.count) 个文件 +\(it.insertions)/-\(it.deletions)  "
                + it.files.prefix(3).joined(separator: " ")
                + (it.files.count > 3 ? " …" : "")))
            if !it.overlapsWith.isEmpty {
                print(Ansi.yellow("   和 \(it.overlapsWith.count) 个分支改了同一个文件"))
            }
            // **证据优先于代码。**
            //
            // 终审最贵的不是判断，是自己重跑一遍（构建+装模拟器+截图，五分钟起）。
            // agent 收工前本来就该自己跑一遍并截图，那些图就在分支里躺着 ——
            // 列出来，看图就能判。这是 56% 产出积压的头号解法。
            if it.evidence.isEmpty {
                print(Ansi.dim("   （没交证据截图 —— 得自己下场跑一遍才能判）"))
            } else {
                print(Ansi.green("   证据 \(it.evidence.count) 张：")
                      + Ansi.dim(it.evidence.prefix(4).joined(separator: "  ")))
                print(Ansi.dim("   看图：llmq work evidence " + it.branch))
            }
        }
        print("\n" + Ansi.dim("看改动：git diff main...<分支>"))
        print(Ansi.dim("合：llmq work review --merge <分支>"))
        print(Ansi.dim("丢：llmq work review --discard <分支> [--reason \"为什么\"]"))
        print(Ansi.dim("清理已合并的残留 worktree：llmq work review --prune"))

    case "resume":
        guard let name = rest.first, let p = Platform(rawValue: name) else {
            print("用法：llmq work resume <平台>   可选："
                + Platform.allCases.map(\.rawValue).joined(separator: " "))
            exit(2)
        }
        print(CooldownLedger.resume(p)
            ? Ansi.green("已解除 \(p.displayName) 的冷却")
            : Ansi.dim("\(p.displayName) 本来就不在冷却中"))

    default:
        print("用法：llmq work [add|list|run|loop|install-loop|probe|cooldowns|resume|review|reserve|stale|idle|land|why|approve|approve-sample|retry|discard|progress|attempts|log]")
        exit(2)
    }
}

/// 用最小的 prompt 试每个平台，只为回答「这个平台现在能不能用」。
///
/// 存在的理由：判断认证问题不该靠跑一个完整任务 —— 那要几十秒到十分钟，
/// 还会真的改代码。而且调度器把任务派给一个认证坏掉的平台时，
/// 已经白建了 worktree、白占了时间。探针几秒就能给出答案。
func probePlatforms() throws {
    let probeDir = NSTemporaryDirectory() + "llmq-probe"
    try? FileManager.default.createDirectory(
        atPath: probeDir, withIntermediateDirectories: true)
    // **探针目录必须是个 git 仓库 —— 真活就跑在 git 仓库里。**
    //
    // 真实干活跑在 worktree（那当然是 git 仓库），探针却跑在一个光秃秃的
    // 临时目录。于是 codex 这种「不在 git 仓库里就拒绝启动」的 CLI
    // 被判成不可用 —— 探的不是它能不能干活，是它在一个**不会出现的环境**
    // 里能不能干活。
    //
    // 实测（2026-08-19）：同一条命令，在 ~/dev/Maw 里正常返回「可用」，
    // 在临时目录里报 `Not inside a trusted directory and
    // --skip-git-repo-check was not specified.`
    //
    // 代价：codex 连续 **18 天**一轮没跑过，白扔一整个套餐周期的额度。
    // 更糟的是这个失败**没有任何人看得见** —— 填活器把它记成
    // 「空窗没活可填」（两天 249 次），坏掉的平台伪装成闲着。
    if !GitWorkspace.isRepo(probeDir) {
        _ = GitWorkspace.git(["init", "--initial-branch=main"], in: probeDir)
        _ = GitWorkspace.git(["config", "user.email", "probe@llmq.local"], in: probeDir)
        _ = GitWorkspace.git(["config", "user.name", "llmq-probe"], in: probeDir)
    }

    print(Ansi.bold("平台可用性探针") + Ansi.dim("  每个平台发一句最短的话，只看认证通不通"))
    print(Ansi.dim(pad("平台", 10) + pad("结果", 12) + pad("耗时", 8) + "说明"))

    // 结果要落盘共享 —— 见 PlatformHealth。只打在终端上的话，
    // 别的机器（和手机）永远不知道这台机器上哪个平台坏了。
    var health: [PlatformHealth.Entry] = []

    for runner in RunnerRegistry.all {
        guard runner.isAvailable else {
            // **诊断不能说谎。** 原来一律报「不在 PATH 上」——而 ZCode 装了、
            // 路径也对,缺的是 CLI 配置或凭据;照着这句去找 PATH 永远找不出问题
            // (2026-08-23 实际耽误了一轮排查)。执行器能说清就让它说。
            let why: String
            if runner is ZcodeRunner, !ZcodeRunner.missingPieces().isEmpty {
                why = ZcodeRunner.missingPieces().joined(separator: "；")
            } else {
                why = runner.binaryName + " 不在 PATH 上"
            }
            print(pad(runner.platform.displayName, 10) + pad(Ansi.dim("未安装"), 12)
                + pad("—", 8) + why)
            health.append(.init(platform: runner.platform.displayName,
                                status: "未安装", detail: why, seconds: 0))
            continue
        }
        let cmd = runner.command(prompt: "回复两个字：可用", cwd: probeDir)
        let t0 = Date()
        let r = Proc.run(cmd.launchPath, cmd.args, cwd: probeDir, env: cmd.env, timeout: 90)
        let dt = Date().timeIntervalSince(t0)

        let verdict: String
        var detail = ""
        if let f = FailureClassifier.classify(
            exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr, timedOut: r.timedOut) {
            verdict = Ansi.red("不可用")
            detail = f.describe
            // 探测超时同理不判额度：90 秒没答上来说明它慢或者卡了，
            // 不说明额度打满。
            if case .timedOut = f {
                detail += Ansi.dim("  超时，不记冷却")
            } else if let cause = CooldownLedger.classify(r.stdout + " " + r.stderr) {
                let cd = CooldownLedger.record(
                    platform: runner.platform, cause: cause, detail: f.describe,
                    knownResetAt: CooldownLedger.parseResetTime(r.stdout + " " + r.stderr))
                detail += Ansi.dim("  →冷却 " + Format.duration(cd.remaining))
            }
        } else {
            CooldownLedger.clear(runner.platform)
            verdict = Ansi.green("可用")
            detail = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            detail = String(detail.prefix(60))
        }
        print(pad(runner.platform.displayName, 10) + pad(verdict, 12)
            + pad(String(format: "%.0fs", dt), 8) + detail)
        health.append(.init(
            platform: runner.platform.displayName,
            status: verdict.contains("不可用") ? "不可用" : "可用",
            detail: Ansi.strip(detail), seconds: dt))
    }
    PlatformHealth.record(health)
    print(Ansi.dim("  结果已记入共享目录，别的机器和 brief 都看得到"))
    print()
    print(Ansi.dim("在你自己的终端里跑这个命令，和从别的进程里跑，结果可能不一样 ——"))
    print(Ansi.dim("凭据存在 Keychain 里，访问权限按调用方的代码签名授权。"))
    print(Ansi.dim("这一点对后面装 launchd 常驻很关键：那也是个没有你终端上下文的进程。"))
}

enum RunOutcome {
    case noTask
    case noPlatform
    case succeeded
    case failed
    /// agent 提了问题，任务转去等回答。
    ///
    /// **必须和 failed 分开**。混在一起的话：一批任务共享同一个缺失前提，
    /// 连续 5 个都提问，就触发「连续失败 5 次」把整个循环停机，
    /// 还推一条「多半是所有平台都出问题了」—— 而平台全是好的，
    /// 额度从此整段作废，正好是这套东西要解决的问题的反面。
    case blocked
}

@discardableResult
/// **队列空了就按专注仓库的主线补活。**
///
/// 老板 2026-08-22:「总不能跑一步卡一步就需要你介入」;2026-08-23:
/// 「不要瞎续活」「专注于项目去派活」「确保活的连续性」。
///
/// **必须从主循环直接调,不能只藏在 runOneTask 里。** 实锤(2026-08-23):
/// 原来续活写在 runOneTask 开头,而主循环只在 `nextQueued() != nil` 时才调
/// runOneTask —— 队列一空,续活永远执行不到。手动 `llmq work run` 会触发
/// (所以我手跑时续过 assetpacks),worker 自己跑时**从不**续活。Flint 专注了
/// 半天、续活任务数 0,老板反复看到「进行中的任务没有了」,根子在这。
/// 只对显式 focus 的仓库续;真闲才补;两小时最多一次;一轮只补一个仓库。
func refillIfIdle(quiet: Bool = false) {
    guard TaskStore.readyQueue().isEmpty else { return }
    let all = TaskStore.all()
    for repo in RepoRegistry.all() {
        guard repo.autoRefill else { continue }
        let path = NSString(string: repo.localPath).expandingTildeInPath
        guard GitWorkspace.isRepo(path) else { continue }
        if let o = AutoRefill.refill(repo: path, alias: repo.alias, tasks: all) {
            let mark = o.enqueued ? Ansi.green("  ↺ 续活 ") : Ansi.dim("  · 没补 ")
            if !quiet || o.enqueued { print(mark + repo.alias + Ansi.dim("  " + o.note)) }
            if o.enqueued { break }
        }
    }
}

/// WorkAttempt 不阻断主流程，但写失败必须显眼：静默丢账会让后续指标看起来正常。
@discardableResult
func appendWorkAttempt(_ attempt: WorkAttempt) -> Bool {
    do {
        try WorkAttemptStore.append(attempt)
        return true
    } catch {
        print(Ansi.red("  ⚠︎ WorkAttempt 记录失败：" + error.localizedDescription))
        return false
    }
}

func runOneTask(dryRun: Bool, quiet: Bool = false) throws -> RunOutcome {
    // **修队头阻塞：不再只看队头。**
    //
    // 老版只取 nextQueued() 一个：排头那个没人能接（比如常规风险
    // 而在场的只剩 safe 档审查员），整条队伍就地冻住 —— 排在后面的
    // 【媒体】任务明明 MiniMax 闲着也永远轮不到。真实现场：
    // Qwen/Kimi 双双冷却的晚上，Greed 的媒体批在队里干等了两小时。
    // 现在按队列顺序逐个试，谁先凑齐候选谁上；
    // 「没人能接」的照旧标 blocked（顺手也不再堵队了）。
    // 家务先行:扫过期的验收残留;磁盘见底就别派了 —— 派了也只会失败。
    // 2026-08-21 晚磁盘 99% 时整条流水线无声烂掉,没有一层说「磁盘满了」。
    let hk = Housekeeping.roundCheck()
    if let n = hk.note, !quiet { print(Ansi.yellow("  家务 ") + n) }
    if hk.skipDispatch {
        return noteIdle(IdleReason.explain(
            queued: 0, blockedByDeps: 0, deferredByLease: 0, platformRejections: [],
            rateLimited: false, lowDisk: true, pendingLanding: 0), quiet: quiet)
    }

    refillIfIdle()

    let rawQueue = TaskStore.readyQueue()
    guard !rawQueue.isEmpty else {
        let all = TaskStore.all()
        let queuedTotal = all.filter { $0.state == .queued }.count
        let stuck = RepoRegistry.all().reduce(0) {
            $0 + Review.list(repo: NSString(string: $1.localPath).expandingTildeInPath).count
        }
        return noteIdle(IdleReason.explain(
            queued: queuedTotal, blockedByDeps: queuedTotal, deferredByLease: 0,
            platformRejections: [], rateLimited: false, lowDisk: false,
            pendingLanding: stuck), quiet: quiet)
    }

    let history = TaskStore.all()

    // **仓库级独占：一个仓库同时只让一个 agent 在改。**
    //
    // 这是架构级的取舍，不是限流。详见 RepoLease 的文档注释：
    // 盘点 238 个任务发现，未派任务的 28 个丢弃全是同一个根因 ——
    // 「基线错了」「撞同一批文件」「和整包任务重复」「前提没了」，
    // 都因为把任务当成对共享代码库的独立并行单元。
    //
    // 并行度从**仓库**来（5 个活仓库 = 5 条流），不从平台来。
    // **先核前提，后上租约。** 原来的顺序反了：租约先给每个仓库占坑，
    // 基线闸再把占坑的拒掉 —— 被拒的白白烧掉本仓库这一轮的名额，
    // 排在后面的媒体任务每轮都被「让开」，实测把 Flint 整仓饿死
    //（2026-08-20：一条基线阻塞的任务让 10 条队列冻了半小时）。
    let queue = rawQueue

    // **派活前核一遍前提。** 任务是在定义那一刻的世界里写的，执行发生在
    // 很久以后。实测浪费：13 个「基线错了：从 main 开工，而 main 上没有
    // 任何今天的改动」+ 3 个「过时：前提不在了」，全靠人一条条丢掉。
    //
    // 两种缺失的处理相反（详见 PremiseCheck）：在未合分支上有 → 等；
    // 到处都没有 → 作废。
    // **先核基线本身是不是真的**，再核任务写出来的前置。
    //
    // 顺序有讲究：基线这条不依赖任何提示词约定，对所有任务生效，
    // 而且它挡住的是最贵的一种浪费 —— agent 拿落后 28 个提交的 main
    // 当「现状」，把已经做好的东西重造一遍（详见 BaselineFreshness）。
    // 回放历史数据：PremiseCheck 当初只能挡住 17 个「基线错了」里的 1 个，
    // 剩下 16 个没写显式前置，只有这条能挡。
    var freshByRepo: [String: BaselineFreshness.Result] = [:]
    var vetted: [WorkTask] = []
    for cand in queue {
        let key = RepoLease.normalize(cand.repo)
        let fresh = freshByRepo[key]
            ?? BaselineFreshness.check(repo: cand.repo, tasks: history)
        freshByRepo[key] = fresh
        // **只有在 main 上盖东西的活才要等基线。**
        //
        // 审查 / 证据 / 刷新 / 媒体拿旧基线也不会重造任何东西
        //（见 TaskKind.needsFreshBaseline）。不放行它们就是死结：
        // 基线旧 → 挡住审查任务 → 分支等不到 agent 审核 →
        // 永远合不进去 → 基线永远旧。**解开基线的钥匙被基线锁在外面。**
        // 亲任务豁免见 BaselineFreshness.blocks：任务自己的分支不算
        // 挡它的理由 —— 它是去完成那条分支的（retry/接力），不是重造。
        let verdict = BaselineFreshness.blocks(fresh, candidateBranch: cand.branch)
        if case .stale = verdict, TaskKind.needsFreshBaseline(cand.prompt) {
            if !quiet {
                print(Ansi.dim("  等基线 " + cand.id + "："
                    + BaselineFreshness.describe(verdict)))
            }
            continue
        }
        // **自己的分支已经合进 main 的任务 = 活已经干完了。** 实锤(2026-08-21):
        // 经济任务中途提问、老板答复后被重排回队头,可它的分支早就落地了 ——
        // 一个不可派的僵尸占着仓库坑。分支合入是 git 事实,派活前核一次。
        if let own = cand.branch, !own.isEmpty {
            let repoPath = NSString(string: cand.repo).expandingTildeInPath
            let exists = GitWorkspace.git(["rev-parse", "--verify", "--quiet",
                                           "refs/heads/" + own], in: repoPath).exitCode == 0
            // **「是 main 的祖先」≠「已落地」。** 控制流 review §7b 实锤:
            // 一条 0 个提交领先 main 的分支(agent 没改文件就提问,答复后带着
            // 分支重排)对 `merge-base --is-ancestor` 恒真 —— 于是 1f8de767s5
            // 三个问题答完、一行活没干,被这里标成「产出早已落地」永不执行。
            // 图分支更糟:共享分支落地后每个解冻的后续步骤都被这样标 done。
            // 落地的唯一硬证据是 main 上有这条分支的合并提交(mergeUnverified
            // 固定写 "merge <branch>"),再要求分支已无领先提交。
            let mergedOnMain = !GitWorkspace.git(
                ["log", "--oneline", "-1", "--grep", "merge " + own, "main"],
                in: repoPath).stdout.isEmpty
            let ahead = Int(GitWorkspace.git(["rev-list", "--count", "main..\(own)"],
                                             in: repoPath).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            // 视觉否决重开的是**同一任务 ID / 同一分支名**，以便恢复原会话。
            // 它的上一版当然已经在 main；拿这个历史事实判“当前整改也做完了”
            // 会在重开后一分钟内把任务重新写回 done，Kimi 根本没有启动。
            if cand.visualRemediationReviewID == nil,
               mergedOnMain && (!exists || ahead == 0) {
                if !quiet { print(Ansi.yellow("  已完成 " + cand.id + "：") + Ansi.dim("它的分支 \(own) 已合进 main")) }
                var x = cand
                x.state = .done
                x.endedAt = Date()
                x.note = "派活前核实：分支 \(own) 已合入 main，产出早已落地"
                try? TaskStore.append(x)
                continue
            }
        }
        // **派生任务的目标分支还在吗。** 审查/证据/刷新入队时分支活着,
        // 执行时可能早合入或没了 —— 实锤一晚五例对着已合入的分支白跑,
        // 产出还把正主挤成冲突(详见 TaskKind.boundBranch)。
        // 作废方式抄 OutputExists:如实记因,不烧一分额度。
        if let bb = TaskKind.boundBranch(cand.prompt) {
            let repoPath = NSString(string: cand.repo).expandingTildeInPath
            let exists = GitWorkspace.git(
                ["rev-parse", "--verify", "--quiet", "refs/heads/" + bb],
                in: repoPath).exitCode == 0
            let merged = exists && GitWorkspace.git(
                ["merge-base", "--is-ancestor", bb, "main"],
                in: repoPath).exitCode == 0
            if !exists || merged {
                let why = exists ? "目标分支 \(bb) 已合入 main" : "目标分支 \(bb) 已不存在"
                if !quiet { print(Ansi.yellow("  作废 " + cand.id + "：") + Ansi.dim(why)) }
                var x = cand
                x.state = .failed
                x.discardedAt = Date()
                x.discardReason = "派活前核目标：" + why
                x.note = "自动作废（派生任务的目标已了结）：" + why
                x.frozenBy = nil
                try? TaskStore.append(x)
                continue
            }
        }
        // 输出侧：这一步要造的东西是不是已经在了（详见 OutputExists）。
        // 和 PremiseCheck 是两个不同的问题 —— 那条问输入，这条问输出。
        if case .alreadyDone(let paths) = OutputExists.check(
            prompt: cand.prompt, repo: cand.repo) {
            let why = OutputExists.describe(.alreadyDone(paths: paths))
            if !quiet { print(Ansi.yellow("  跳过 " + cand.id + "：") + Ansi.dim(why)) }
            var x = cand
            x.state = .failed
            x.discardedAt = Date()
            x.discardReason = "派活前核产出：" + why
            x.note = "自动跳过（产出已存在）：" + why
            x.frozenBy = nil
            try? TaskStore.append(x)
            for y in TaskGraph.reconcile(TaskStore.all()) { try? TaskStore.append(y) }
            continue
        }
        switch PremiseCheck.check(prompt: cand.prompt, repo: cand.repo) {
        case .ok:
            vetted.append(cand)
        case .notYet(let missing, let branches):
            // 派早了，不是坏任务 —— 原样留在队里等分支落地。
            if !quiet {
                print(Ansi.dim("  等前提 " + cand.id + "："
                    + PremiseCheck.describe(.notYet(missing: missing,
                                                    onBranches: branches))))
            }
        case .gone(let missing):
            // **同一张图里的下游步骤永远不作废,只等。**
            //
            // 前提核验会在上游步骤**提交之前**跑:那一刻分支上还没有那些文件,
            // 于是判成「彻底没有」→ 作废。实锤(2026-08-22):头发产线 s2–s6
            // 五步被系统自己杀光,理由是「前提不在了:Tools/README-hair.md」,
            // 而那个文件当时正躺在 s1 的分支上。老板看到的是「产线塌了」,
            // 我一度以为是 agent 没干活。
            //
            // 图里的依赖本来就由 TaskGraph 管:上游没完成,下游根本不该被派。
            // 前提核验对图内节点只有一个正确答案 —— **等**。
            if cand.graphID != nil {
                if !quiet {
                    print(Ansi.dim("  等前提 " + cand.id + "：图里的上一步还没交出 "
                        + missing.prefix(2).joined(separator: "、")))
                }
                break
            }
            // 前提真的没了。作废并写清原因 —— 这个判断是机械的、可复查的，
            // 不该占用人的注意力。
            let why = PremiseCheck.describe(.gone(missing: missing))
            if !quiet { print(Ansi.yellow("  作废 " + cand.id + "：") + Ansi.dim(why)) }
            var x = cand
            x.state = .failed
            x.discardedAt = Date()
            x.discardReason = "派活前核前提：" + why
            x.note = "自动作废（前提核验）：" + why
            x.frozenBy = nil
            try? TaskStore.append(x)
            // 丢完要对账 —— 被它冻住的下游得跟着变，
            // 不然刚修好的「假的自动解冻」又会以另一种形式出现。
            for y in TaskGraph.reconcile(TaskStore.all()) { try? TaskStore.append(y) }
        }
    }
    guard !vetted.isEmpty else {
        let stuck = RepoRegistry.all().reduce(0) {
            $0 + Review.list(repo: NSString(string: $1.localPath).expandingTildeInPath).count
        }
        return noteIdle(IdleReason.explain(
            queued: rawQueue.count, blockedByDeps: rawQueue.count, deferredByLease: 0,
            platformRejections: [], rateLimited: false, lowDisk: false,
            pendingLanding: stuck), quiet: quiet)
    }
    // 仓库级独占：**只有真在跑的任务才占坑**，而且在候选循环里逐个判。
    //
    // 原来这里用 RepoLease.filter 预过滤，它会把「本轮放行的第一个」也记成
    // 占坑 —— 可那一个接下来可能根本派不出去（没平台能接）。实锤
    // （2026-08-21 14:05）：经济任务排在队头，Kimi 失败过/Codex 触留白/
    // 火山档位不够，它派不出去却替 Flint 占了坑，后面同仓库的动捕 s3
    // 每轮「让开」—— 队头阻塞修复被租约从背后捅了一刀。
    // runOneTask 一次只派一个，同轮互斥本来就不需要预占。
    let vettedQueue = vetted
    let dash = LLMQuota.dashboard()

    var task: WorkTask! = nil
    var decision: WorkScheduler.Decision! = nil
    var ownerReleaseIsManual = false
    var leaseNoted = 0
    for (idx, candidateTask) in vettedQueue.enumerated() {
        var cand = candidateTask
        if cand.ownerRunnerID == nil,
           let inherited = TaskGraph.inheritedOwner(for: cand, in: history) {
            cand.ownerPlatform = inherited.platform
            cand.ownerRunnerID = inherited.runnerID
            cand.ownerAssignedAt = inherited.assignedAt
        }
        if let h = RepoLease.holder(repo: cand.repo, tasks: history) {
            if !quiet, leaseNoted < 3 {
                leaseNoted += 1
                print(Ansi.dim("  让开 " + cand.id + "：仓库 "
                    + URL(fileURLWithPath: RepoLease.normalize(cand.repo)).lastPathComponent
                    + " 正被 " + (h.platform?.displayName ?? "另一个 agent")
                    + " 改（任务 \(h.id)）—— 等它落地再开工"))
            }
            continue
        }
        let scheduler = WorkScheduler()
        // 仓库负责人是功能实现的硬边界，不是“多加几分”的偏好。
        // 已经形成 task owner 的任务继续尊重自己的会话；只有新任务第一次
        // 开工时按项目负责人收窄候选。审核/媒体/证据仍走专用能力泳道。
        let repoImplementationOwner = cand.ownerRunnerID == nil
            ? RepoExecutionPolicy.implementationOwner(for: cand.repo, prompt: cand.prompt)
            : nil
        if let repoImplementationOwner {
            cand.preferredPlatform = repoImplementationOwner
        }
        let eligibleRunners = repoImplementationOwner.map { fixed in
            RunnerRegistry.all.filter { $0.platform == fixed }
        } ?? RunnerRegistry.all
        var d = scheduler.decide(
            dashboard: dash, runners: eligibleRunners,
            task: cand, history: history)
        var releaseIsManual = false
        if (cand.ownerRunnerID == nil) != (cand.ownerPlatform == nil) {
            cand.state = .blocked
            cand.endedAt = Date()
            cand.note = "owner 数据不完整（runnerID/platform 必须同时存在），已停止自动猜人"
            try? TaskStore.append(cand)
            _ = StuckAsk.raise(task: cand, reason: cand.note ?? "owner 数据不完整")
            if !quiet { print(Ansi.yellow("  阻塞 \(cand.id)：" + (cand.note ?? "owner 数据不完整"))) }
            continue
        }
        if let runnerID = cand.ownerRunnerID, let platform = cand.ownerPlatform {
            guard let owner = RunnerRegistry.resolve(
                ownerRunnerID: runnerID, platform: platform, prompt: cand.prompt)
            else {
                cand.state = .blocked
                cand.endedAt = Date()
                cand.note = "原 owner \(runnerID) 已不存在，且无法唯一迁移；已停止自动猜人"
                try? TaskStore.append(cand)
                _ = StuckAsk.raise(task: cand, reason: cand.note ?? "owner 无法恢复")
                if !quiet { print(Ansi.yellow("  阻塞 \(cand.id)：" + (cand.note ?? "owner 无法恢复"))) }
                continue
            }
            let ownerDecision = scheduler.decide(
                dashboard: dash, runners: [owner], task: cand, history: history)
            if let ownerPick = ownerDecision.pick {
                // owner 仍能接就永远排第一；历史 triedPlatforms 不得把它自己挡掉。
                d.candidates.removeAll { $0.runner.runnerID == owner.runnerID }
                let fallbacks = cand.automaticHandoffCount < 1 ? d.candidates : []
                d.candidates = [ownerPick] + fallbacks
            } else if ownerDecision.rejected.contains(where: { $0.kind == .temporary }) {
                // 冷却/额度会自行恢复，等 owner，不因短暂波动换人。
                d = ownerDecision
            } else {
                releaseIsManual = AgentRoles.isMuted(platform)
                // owner 永久不可用才允许交接；故障自动交接最多一次，人工静音不占额度。
                if cand.automaticHandoffCount >= 1 && !releaseIsManual {
                    d = ownerDecision
                }
            }
        }
        if !d.candidates.isEmpty {
            if idx > 0, !quiet {
                print(Ansi.dim("  队头 \(idx) 个任务暂时没人能接，先跑后面这个"))
            }
            task = cand
            decision = d
            ownerReleaseIsManual = releaseIsManual
            break
        }
        // 只对队头打印完整排除清单，后面的压成一行 —— 否则一晚上的日志全是排除表
        if idx == 0 {
            if let disp = d.dispatcher {
                print(Ansi.dim("  指挥 " + pad(disp.displayName, 10) + "本机控制面，不参与竞选"))
            }
            for r in d.rejected {
                print(Ansi.dim("  排除 " + pad(r.platform.displayName, 10) + r.reason))
            }
        } else if !quiet {
            print(Ansi.dim("  跳过 \(cand.id)：暂时没人能接"))
        }
        let permanent = !d.rejected.isEmpty
            && d.rejected.allSatisfy { $0.kind == .permanent }
        if permanent {
            cand.state = .blocked
            cand.endedAt = Date()
            let dispatcherNote = d.dispatcher.map {
                "。注意 \($0.displayName) 是本机指挥（控制面），"
                    + "按设定不接活 —— 需要的话可以把这一步挪到别的机器"
            } ?? ""
            let alias = RepoRegistry.all()
                .first {
                    NSString(string: $0.localPath).expandingTildeInPath
                        == NSString(string: cand.repo).expandingTildeInPath
                }?.alias
            let elsewhereHint = cand.profile.flatMap {
                Elsewhere.hint(risk: $0.risk, taskPrompt: cand.prompt, repoAlias: alias)
            }
            cand.note = "没有平台能接：" + d.rejected
                .map { "\($0.platform.displayName)（\($0.reason)）" }
                .joined(separator: "；")
                + dispatcherNote
                + "。等下去不会变 —— 要么放宽某个角色的上限，要么人工处理。"
                + (elsewhereHint.map { "\n" + $0 } ?? "")
            try? TaskStore.append(cand)
            // 卡死弹窗：推一条带按钮的提问到手机（重试/放弃），
            // 而不是让它安静地在看板上变灰等人巡逻发现。
            _ = StuckAsk.raise(task: cand, reason: "没有平台能接：" + d.rejected
                .map { "\($0.platform.displayName)（\($0.reason)）" }
                .joined(separator: "；"))
            if !quiet {
                print(Ansi.yellow("没有平台**能**接 \(cand.id)，已弹窗问手机，继续看下一个。"))
            }
        }
    }
    guard task != nil, decision != nil else {
        if !quiet { print(Ansi.red("暂时没有可用平台（冷却/额度），任务留在队列里。")) }
        return .noPlatform
    }
    if let disp = decision.dispatcher {
        print(Ansi.dim("  指挥 " + pad(disp.displayName, 10) + "本机控制面，不参与竞选"))
    }
    for r in decision.rejected {
        print(Ansi.dim("  排除 " + pad(r.platform.displayName, 10) + r.reason))
    }
    print(Ansi.bold("候选顺序：") + decision.candidates.enumerated().map {
        "\($0.offset + 1). \($0.element.platform.displayName)"
    }.joined(separator: "  "))
    print(Ansi.dim("  首选理由：" + (decision.pick?.reason ?? "")))

    if dryRun {
        print(Ansi.dim("（--dry-run，不实际执行）"))
        print("  任务 \(task.id): \(task.prompt)")
        for c in decision.candidates {
            let cmd = c.runner.command(prompt: task.prompt, cwd: task.repo)
            print("  " + pad(c.platform.displayName, 10) + cmd.launchPath + " "
                + cmd.args.map { $0.count > 30 ? String($0.prefix(30)) + "…" : $0 }
                    .joined(separator: " "))
        }
        return .noTask
    }

    task.state = .running
    // 记下是谁在跑它 —— 回收孤儿时靠这个精确判断，而不是靠「跑了多久」。
    task.runnerPID = ProcessInfo.processInfo.processIdentifier
    task.startedAt = Date()
    try TaskStore.append(task)
    Inbox.writeResult(for: task)
    // **开跑就立刻重发看板，不等采集周期。**
    //
    // 看板原先只在 collect 里发（约 2 分钟一轮），而一条媒体任务只跑
    // 150–170 秒 —— 再加镜像 30 秒 + iCloud 分钟级传播，
    // 「进行中」在链路上存在的时间比看到它所需的延迟还短。
    // 老板看到的永远是「上一个跑完、下一个没开始」的间隙。
    TaskBoardStore.publishNow()

    var attempts: [String] = []
    /// 上一个平台留下的交接信息。非 nil 表示这是接力，不是新开工。
    var handoff: Handoff?
    /// 这一轮是不是「答复回来了，接着上一轮干」。
    /// 由 ingest 把答案并进任务时设上，见 WorkTask.resumeContext。
    let resumedAnswer: (AskAnswer, Ask)? = task.resumeContext
    let overallStart = Date()
    // 单个平台的上限。原来是 20 分钟，一个卡住的平台就把总预算吃光了，
    // 后面的候选根本轮不上。降到 10 分钟，三个平台都试得过来。
    let perAttemptTimeout: TimeInterval = 600
    let refillFloor: TimeInterval = task.origin == "auto-refill" ? 90 * 60 : 0
    let plannedAttemptTimeout = max(refillFloor,
        ProcessInfo.processInfo.environment["LLMQ_ATTEMPT_TIMEOUT"]
            .flatMap(Double.init) ?? task.profile?.timeout ?? perAttemptTimeout)
    // 总预算至少容得下第一次完整尝试再做一次收尾决策。旧值固定 30 分钟，
    // 任务的合法单次上限却是 45 分钟：第一次超时那一刻重试预算必然已经负数。
    let totalBudget: TimeInterval = max(1800, plannedAttemptTimeout + 5 * 60)

    // 按额度充裕度依次尝试。认证/环境类失败换下一个平台，
    // agent 真跑砸了就停 —— 换平台重试只会重复烧额度。
    var candidateQueue = decision.candidates
    var idx = 0
    var ownerRetryUsed = false
    var sessionRepairUsed = false
    enum RetryCause { case timeoutExperiment, sessionRepair }
    var retryCauseByIndex: [Int: RetryCause] = [:]
    while idx < candidateQueue.count {
        let pick = candidateQueue[idx]
        let previousPick = idx > 0 ? candidateQueue[idx - 1] : nil
        let retryCause = retryCauseByIndex[idx]
        let isSameOwnerRetry = previousPick?.runner.runnerID == pick.runner.runnerID
            && retryCause != nil
        task.platform = pick.platform
        if !task.triedPlatforms.contains(pick.platform) {
            task.triedPlatforms.append(pick.platform)
        }
        // **选定平台后立刻落盘一次,让任务板/办公室知道是谁在干。**
        //
        // 老板 2026-08-23:「办公室也不展示,我记得之前有一个会展示每个 agent
        // 在干嘛」。根因:state=.running 那次 append 发生在上面(平台还没选),
        // 落盘的 running 记录 platform 为空 → 任务板那行没有 platform 字段 →
        // 手机办公室按(机器,平台)摆桌,摆不到任何人桌上,看起来没人在干活。
        // 实锤:fa4e5eeb running 了 26 分钟,记录里 platform: None。
        try? TaskStore.append(task)
        TaskBoardStore.publishNow()
        let retryLabel: String
        switch retryCause {
        case .timeoutExperiment?: retryLabel = "（同 owner 连续恢复）"
        case .sessionRepair?: retryLabel = "（会话失效后 fresh 恢复）"
        case nil: retryLabel = ""
        }
        print(Ansi.bold("\n[\(idx + 1)/\(candidateQueue.count)] " + pick.platform.displayName)
            + (retryLabel.isEmpty ? "" : Ansi.dim(retryLabel)))
        // 记一笔给办公室画面。第一个候选是「老板派活」，之后的是「同事接手」——
        // 后者是真实的协作，不是编出来的。
        if !isSameOwnerRetry {
            OfficeLog.record(OfficeEvent(
                kind: idx == 0 ? .dispatched : .handoff,
                taskID: task.id,
                platform: idx == 0 ? pick.platform : previousPick?.platform,
                toPlatform: idx == 0 ? nil : pick.platform,
                detail: idx == 0 ? "接到新活" : (attempts.last ?? "上一位干不动了"),
                taskTitle: task.prompt,
                // 只在第一次派活时带排除名单：接力时那些理由已经过时了。
                excluded: idx == 0 ? decision.rejected.map {
                    OfficeEvent.Excluded(
                        platform: $0.platform,
                        agentName: AgentIdentity.name(for: $0.platform),
                        reason: $0.reason)
                } : []))
        }

        // 接力：前一个平台留下的工作区要保住，不能重建 ——
        // 重建等于把它已经干的活全丢掉，下一个平台得从零重走一遍。
        let ws: GitWorkspace.Workspace
        // 判据不能只看本地变量 handoff：它是 runOneTask 的局部变量，
        // 进程重启后必然是 nil，于是会走下面的 prepare —— 而 prepare 会
        // `worktree remove --force` 把上一轮的进度**铲掉**。
        // 任务记录里持久化的 handoff / pendingAsk 才是跨进程恢复的真凭据。
        let isResuming = handoff != nil || task.handoff != nil || resumedAnswer != nil
        if let existing = GitWorkspace.existingWorkspace(taskID: task.id), isResuming {
            ws = existing
            print(Ansi.cyan("  接手 ") + Ansi.dim(existing.branch + "（沿用已有工作区，不重建）"))
        } else {
            do {
                ws = try GitWorkspace.prepare(
                    repo: task.repo, taskID: task.id, platform: pick.platform,
                    graphID: task.graphID)
            } catch {
                // **把真实原因带上。**
                //
                // 原来只写「工作区创建失败」，而这一步能失败的原因差得很远：
                // 仓库路径不存在、不是 git 仓库、分支名已被占、
                // worktrees 目录建不出来、磁盘满……每一种的修法都不一样。
                // 实际排查时手动 `git worktree add` 一次就成功了，
                // 于是完全看不出 worker 为什么不行 —— 信息被这条消息吞掉了。
                attempts.append("\(pick.platform.displayName)：工作区创建失败 —— "
                    + error.localizedDescription)
                appendWorkAttempt(WorkAttempt(
                    taskID: task.id, runnerID: pick.runner.runnerID,
                    platform: pick.platform, taskTier: task.profile?.tier,
                    startedAt: Date(), endedAt: Date(), outcome: .failed,
                    failureKind: "workspaceUnavailable", workspacePrepared: false,
                    timedOut: false, sessionSupport: pick.runner.sessionSupport,
                    handoffReason: error.localizedDescription))
                let nextIndex = idx + 1
                let nextIsSame = nextIndex < candidateQueue.count
                    && candidateQueue[nextIndex].runner.runnerID == pick.runner.runnerID
                if nextIndex < candidateQueue.count
                    && (nextIsSame || task.automaticHandoffCount < 1) {
                    idx = nextIndex
                    continue
                }
                break
            }
            print(Ansi.dim("  分支 " + ws.branch))
        }
        task.branch = ws.branch

        // 接力说明只追加文件清单和中断原因，**不贴 diff** ——
        // 工作区就在 agent 眼前，让它自己看比塞进提示词便宜得多。
        var effectivePrompt = task.prompt + ((handoff ?? task.handoff)?.briefing() ?? "")
        // 仓库地图：每个任务都是全新 worktree，agent 一律从零认路。
        // 更硬的是 MiniMax 这种只能文本进出的执行器 —— 不塞进提示词它就看不见，
        // Greed 那六份评审全写「材料不足」就是这么来的。
        //
        // 两种情况不贴：
        // - 接力任务：briefing 里已经有文件清单，再来一份是浪费
        // - trivial：那种活的描述里已经点名了文件和行号（「第 34 行的 foo 补注释」），
        //   地图一个字都用不上，而 LLMQuotaBar 的地图有 7k token
        if handoff == nil, task.handoff == nil, task.profile?.tier != .trivial {
            effectivePrompt += RepoMap.briefing(repo: ws.path)
        }
        // 产品事实（AGENTS.md）：让每个 agent 知道自己在给什么产品干活、
        // 什么不能动。地图管「去哪找」，这份管「别碰什么」——
        // 不注入的话这份知识只存在于老板脑子里，agent 只能临场猜。
        // 老板（2026-08-20）：「让不同的 agent 不知道自己在干啥」说的就是这个。
        // 接力任务也要：换了平台的 agent 更不知道铁律。
        effectivePrompt += ProductBrief.briefing(repo: ws.path, registeredRepo: task.repo)
        // 证据条款（事前）：干活的 agent 在同一次执行里自己交证据，
        // 别等落地闸发现缺图再另派一个从零认路的 agent 去补 ——
        // 老板（2026-08-20）：「尽量让一个任务在一个 agent 内完成工作」。
        effectivePrompt += EvidenceGate.inlineClause(repoPath: task.repo,
                                                     prompt: task.prompt)
        effectivePrompt += WorkProgressContract.clause()
        // 图内节点要知道自己在整件事里的位置。
        //
        // 换了平台的 agent 对前面发生了什么一无所知 —— 这正是「上下文丢失」
        // 在图这一层的样子。而跨厂商的两个 CLI **不可能共享会话**，
        // 能交接的只有磁盘上的产物，所以这段必须显式拼进提示词。
        if let brief = TaskGraph.briefing(for: task, in: TaskStore.all()) {
            effectivePrompt += "\n\n" + brief
        }
        if let (ans, ask) = resumedAnswer {
            effectivePrompt += ans.briefing(for: ask)
        }
        // 提问契约只给「可能真需要澄清」的任务加。
        // trivial 是改文档改注释，本来就不该问，而且它的超时预算只有几分钟，
        // 多一段契约反而挤占正事。已经问满轮次的也不再给口子。
        let askFile = AskStore.scratchPath(taskID: task.id, round: task.askRounds + 1)
        try? FileManager.default.removeItem(at: askFile)
        let mayAsk = Ask.Policy.mayAsk(task.profile)
            && task.askRounds < Ask.Policy.maxRounds
            && resumedAnswer == nil
        if mayAsk { effectivePrompt += AskContract.clause(askFile: askFile.path) }
        // 会话跟随「稳定工作区 × Runner × 能力泳道」。同一个 Agent 在同一项目
        // 接新任务时继续已有上下文；不同 Agent/项目/泳道互不串线。
        let sessionContext = GraphSession.Context(
            taskID: task.id, graphID: task.graphID,
            capability: TaskCapabilityLane.classify(task.prompt),
            runnerID: pick.runner.runnerID, machineID: Paths.machineID())
        GraphSession.migrateLegacyProject(
            context: sessionContext, support: pick.runner.sessionSupport,
            workspace: ws.path, repo: task.repo, platform: pick.platform)
        let session = GraphSession.mode(
            context: sessionContext, support: pick.runner.sessionSupport,
            workspace: ws.path)
        switch session {
        case .resume(let id):
            print(Ansi.dim("  已请求恢复会话 " + String(id.prefix(8))))
        case .projectResume:
            print(Ansi.dim("  已请求恢复项目最近会话（CLI 不提供显式 ID）"))
        case .create(let id):
            print(Ansi.dim("  已请求新建任务会话 " + String(id.prefix(8))))
        case .fresh:
            switch pick.runner.sessionSupport {
            case .none:
                print(Ansi.dim("  Runner 不支持原生会话；沿用工作区和磁盘交接信息"))
            case .projectLatest:
                print(Ansi.dim("  没有与本任务匹配的项目会话；本次不请求恢复"))
            case .reportedID:
                print(Ansi.dim("  尚未取得可恢复的会话 ID；本次从新会话开始"))
            case .stableID:
                print(Ansi.dim("  本次从新会话开始"))
            }
        }
        let cmd = pick.runner.command(prompt: effectivePrompt, cwd: ws.path,
                                      session: session)
        // **续活任务的时限放宽到 90 分钟。**
        //
        // 续活的单位是「主线的一整块」(老板要求不拆细、一块做完),实测
        // fa4e5eeb 做头发收尾改了 14 个文件,45 分钟被掐死在半路(WIP 提交救回)。
        // 按档次算的 45 分钟上限是给「一个任务」设的,一整块理应更长。
        // 用 origin 判(结构化字段),不看提示词文本。
        let baseAttemptTimeout = plannedAttemptTimeout
        let retryMultiplier = ProcessInfo.processInfo.environment[
            "LLMQ_OWNER_RETRY_TIMEOUT_MULTIPLIER"].flatMap(Double.init) ?? 1.5
        let isTimeoutExperimentRetry: Bool
        if case .timeoutExperiment? = retryCause { isTimeoutExperimentRetry = true }
        else { isTimeoutExperimentRetry = false }
        let requestedAttemptTimeout = baseAttemptTimeout
            * (isTimeoutExperimentRetry ? max(1, retryMultiplier) : 1)
        let attemptTimeoutPreview = ContextAffinityPolicy.cappedAttemptTimeout(
            requested: requestedAttemptTimeout,
            totalBudget: totalBudget,
            elapsed: Date().timeIntervalSince(overallStart))
        print(Ansi.dim(String(format: "  执行中…（单次上限 %.0f 秒）", attemptTimeoutPreview)))
        let started = Date()
        let attemptID = UUID().uuidString.lowercased()
        // 画像估出来的超时比固定 10 分钟合理：简单任务不该占着 10 分钟的坑，
        // 那会拖垮整个候选轮转。
        // 调试开关：压低单次超时以复现「做了一半被中断」的接力场景。
        // 这类场景自然发生时很难抓，但它恰恰是接力逻辑最该被验证的路径。
        let attemptTimeout = attemptTimeoutPreview
        // **跑之前记一个基准。**
        //
        // 下面那些计数全是相对 `main` 算的**累计量** —— 接力场景里它们包含
        // 前面 agent 的成果。实测：火山方舟接手一个 Qwen 十一小时前做完的活，
        // 自己一行没动，却报「改了 1 个文件（1 个提交是 agent 自己打的）」。
        // 有了这个基准才能把「这一轮它自己干的」单独算出来。
        let headBefore = GitWorkspace.headSHA(in: ws.path)

        // 选中候选不等于形成上下文。直到真正准备启动进程，才建立/转移 owner；
        // 若连进程都没拉起，下面会把这次暂定绑定完整回滚。
        let assignmentCause: ContextAffinityPolicy.AssignmentCause
        if task.ownerRunnerID == nil { assignmentCause = .initial }
        else if idx == 0 && ownerReleaseIsManual { assignmentCause = .manualDisable }
        else { assignmentCause = .automaticFailure }
        let ownerBeforeAttempt = ContextAffinityPolicy.assign(
            task: &task, runnerID: pick.runner.runnerID,
            platform: pick.platform, cause: assignmentCause)
        if ownerBeforeAttempt.changed { try? TaskStore.append(task) }
        appendWorkAttempt(WorkAttempt(
            attemptID: attemptID, taskID: task.id,
            runnerID: pick.runner.runnerID, platform: pick.platform,
            taskTier: task.profile?.tier, startedAt: started,
            outcome: .running, workspacePrepared: true,
            headBefore: headBefore, headAfter: headBefore,
            timedOut: false, sessionSupport: pick.runner.sessionSupport,
            sessionAction: .from(session)))
        var executionEnv = cmd.env
        executionEnv["LLMQ_TASK_ID"] = task.id
        executionEnv["LLMQ_WORKSPACE"] = ws.path
        executionEnv["LLMQ_INITIAL_LEASE_SECONDS"] = String(Int(attemptTimeout))
        let baselineFingerprint = WorkProgressStore.fingerprint(repo: ws.path)
        let leaseGate = ExecutionLeaseGate(
            taskID: task.id,
            baselineFingerprint: baselineFingerprint,
            existing: WorkProgressStore.load(taskID: task.id))
        let objectiveLeaseGate = ObjectiveProgressLeaseGate(
            baselineHead: headBefore, baselineFingerprint: baselineFingerprint)
        let r = Proc.run(
            cmd.launchPath, cmd.args, cwd: ws.path, env: executionEnv,
            timeout: attemptTimeout,
            deadlineExtension: { _ in
                if let renewed = leaseGate.renewal(
                    progress: WorkProgressStore.load(taskID: task.id)) {
                    objectiveLeaseGate.observe(
                        currentHead: GitWorkspace.headSHA(in: ws.path),
                        currentFingerprint: WorkProgressStore.fingerprint(repo: ws.path))
                    let minutes = Int(renewed.seconds / 60)
                    print(Ansi.cyan("  续期 \(minutes) 分钟：")
                          + Ansi.dim("\(renewed.progress.phase) · \(renewed.progress.summary)"))
                    return Proc.DeadlineExtension(
                        seconds: renewed.seconds,
                        reason: renewed.progress.summary)
                }

                // 不能把续期完全押在 Agent 会不会记得调用 `work progress` 上。
                // 提交和未提交的真实 diff 都是客观进展；同一份指纹只消费一次。
                let currentHead = GitWorkspace.headSHA(in: ws.path)
                let currentFingerprint = WorkProgressStore.fingerprint(repo: ws.path)
                guard let automatic = objectiveLeaseGate.renewal(
                    currentHead: currentHead,
                    currentFingerprint: currentFingerprint) else { return nil }
                let changed = GitWorkspace.git(["status", "--porcelain=v1"], in: ws.path)
                    .stdout.split(separator: "\n").count
                let summary: String
                if automatic.headChanged, let currentHead {
                    summary = "检测到新提交 \(String(currentHead.prefix(8)))，服务端自动保持当前会话"
                } else {
                    summary = "检测到工作区有新改动（\(changed) 个文件），服务端自动保持当前会话"
                }
                if let item = try? WorkProgressStore.record(
                    taskID: task.id, phase: "持续实现", summary: summary,
                    nextStep: "继续当前任务", evidence: [], requestedMinutes: 20,
                    repo: ws.path),
                   let verified = leaseGate.renewal(progress: item) {
                    TaskBoardStore.publishNow()
                    print(Ansi.cyan("  自动续期 \(Int(verified.seconds / 60)) 分钟：")
                          + Ansi.dim(summary))
                    return Proc.DeadlineExtension(
                        seconds: verified.seconds, reason: summary)
                }
                // 进度文件写入失败不应反过来杀掉已有真实提交；看板稍后采集会补上。
                print(Ansi.cyan("  自动续期 \(Int(automatic.seconds / 60)) 分钟：")
                      + Ansi.dim(summary))
                return Proc.DeadlineExtension(seconds: automatic.seconds, reason: summary)
            })
        let elapsed = Date().timeIntervalSince(started)
        if r.exitCode != -1 {
            GraphSession.markLaunched(
                context: sessionContext, support: pick.runner.sessionSupport,
                workspace: ws.path)
            if pick.runner.sessionSupport == .reportedID,
               let id = pick.runner.discoveredSessionID(from: r.stdout + "\n" + r.stderr) {
                GraphSession.rememberReportedID(
                    context: sessionContext, workspace: ws.path, id: id)
            }
        } else if case .create = session {
            // 进程压根没启动，这个显式 ID 不可能真实存在；只删自己的精确映射。
            GraphSession.forget(context: sessionContext, workspace: ws.path)
        }
        if r.exitCode == -1 {
            ContextAffinityPolicy.restore(task: &task, snapshot: ownerBeforeAttempt)
            try? TaskStore.append(task)
        }
        // **有提交就不算「没改动」,绝不能连分支一起删。**
        //
        // 实锤(2026-08-23 17:06,85ace4f7):Kimi 在工作区提交了一份评审报告
        // (9201d66,1 个文件),这里却算出 0 个文件,接着下面 cleanup 把分支删了 ——
        // 成果只剩一个悬空提交,任务还记成 done。根因没抓到(同样的场景单测算出 1),
        // 但后果不能再发生:数文件和数提交两道一起判,任何一道说「有」就按有产出走
        // 正常路径(验证/保留分支),并把两个数都打进日志,下次出事有账可查。
        let changedByFiles = GitWorkspace.changedFileCount(in: ws.path)
        // 直接拿原始结果:git 本身出错/输出为空时也不能当成「0 个提交」。
        let aheadProbe = GitWorkspace.git(["rev-list", "--count", "main..HEAD"], in: ws.path)
        let aheadText = aheadProbe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitAnswered = aheadProbe.exitCode == 0 && !aheadText.isEmpty
        let aheadCommits = Int(aheadText) ?? 0
        if changedByFiles == 0 && (aheadCommits > 0 || !gitAnswered) {
            print(Ansi.yellow("  ⚠︎ 文件数算出 0 但"
                  + (gitAnswered ? "相对 main 有 \(aheadCommits) 个提交" : "git 没给出有效回答(rc \(aheadProbe.exitCode))")
                  + " —— 按有产出处理,不删分支")
                  + Ansi.dim("  diff: " + GitWorkspace.git(["diff", "--name-only", "main...HEAD"], in: ws.path).stdout.prefix(200)
                             + "  err: " + aheadProbe.stderr.prefix(120)))
        }
        let changed = changedByFiles == 0 && (aheadCommits > 0 || !gitAnswered) ? 1 : changedByFiles
        // 这一轮**这个 agent 自己**动了多少。base 用它开工时的 HEAD。
        let mine = headBefore.map { GitWorkspace.changedFileCount(in: ws.path, base: $0) }
        let myCommits = headBefore.map { GitWorkspace.commitsAhead(in: ws.path, base: $0) } ?? 0

        func recordAttempt(_ outcome: WorkAttempt.Outcome,
                           failureKind: String? = nil,
                           handoffReason: String? = nil) {
            let attemptChanged = headBefore.map {
                GitWorkspace.changedFileCount(in: ws.path, base: $0)
            } ?? changed
            let attemptCommits = headBefore.map {
                GitWorkspace.commitsAhead(in: ws.path, base: $0)
            } ?? myCommits
            appendWorkAttempt(WorkAttempt(
                attemptID: attemptID, taskID: task.id, runnerID: pick.runner.runnerID,
                platform: pick.platform, taskTier: task.profile?.tier,
                startedAt: started, endedAt: Date(), outcome: outcome,
                failureKind: failureKind, headBefore: headBefore,
                headAfter: GitWorkspace.headSHA(in: ws.path),
                changedFiles: attemptChanged, newCommits: attemptCommits,
                timedOut: r.timedOut, sessionSupport: pick.runner.sessionSupport,
                sessionAction: .from(session), handoffReason: handoffReason))
        }

        // 无论成败都留完整日志。超时那次尤其需要 —— 不然根本不知道它卡在哪。
        if let logURL = RunLog.write(
            taskID: task.id, platform: pick.platform,
            command: cmd.launchPath + " " + cmd.args.joined(separator: " "),
            result: r, elapsed: elapsed
        ) {
            print(Ansi.dim("  日志 " + logURL.path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")))
        }

        // 先看问题文件，**在判失败之前，而且不看退出码**。
        //
        // 不看退出码是刻意的：Qwen 在无头下的已知失败模式是反复重试同一个工具调用
        // 直到超时，它可能已经把问题写出来了但进程不会正常退出。只在 exitCode==0
        // 时才检查的话，这种情况会被当成纯超时失败，问题被丢掉，
        // 而下一个平台接手时又会撞上同一个歧义。
        if mayAsk, FileManager.default.fileExists(atPath: askFile.path),
           let ask = AskContract.parse(
            askFile, taskID: task.id, machineID: Paths.machineID(),
            round: task.askRounds + 1, platform: pick.platform,
            taskPrompt: task.prompt, repoName: URL(fileURLWithPath: task.repo).lastPathComponent)
        {
            let touched = GitWorkspace.touchedFiles(in: ws.path)
            let wip = GitWorkspace.commitWIP(
                in: ws.path, platform: pick.platform, reason: "等待答复")
            var stored = ask
            stored.wipCommit = ask.wipCommit ?? wip

            print(Ansi.cyan("  它提了 \(ask.questions.count) 个问题")
                + Ansi.dim(String(format: " · %.0fs", elapsed)))
            for q in ask.questions { print(Ansi.dim("    · " + q.text.prefix(60))) }
            if !touched.isEmpty {
                print(Ansi.cyan("  已保存进度：") + "\(touched.count) 个文件"
                    + (stored.wipCommit.map { "，提交 " + $0 } ?? ""))
            }

            // 提问不是失败，把这个平台从"试过"里摘掉。
            // 不摘的话，回答之后 decide 的第一道硬排除会把它挡掉，
            // 只能换个更弱的平台从头做 —— 而它其实已经干了一半。
            task.triedPlatforms.removeAll { $0 == pick.platform }
            task.handoff = Handoff(
                fromPlatform: pick.platform, reason: "在等你回答",
                touchedFiles: touched, wipCommit: stored.wipCommit,
                elapsedSeconds: Int(elapsed))
            task.pendingAsk = stored
            task.askRounds += 1
            task.state = .blocked
            task.endedAt = Date()
            task.changedFiles = changed
            task.note = "在等你回答 \(ask.questions.count) 个问题"

            // **先发布问题，再改任务状态**。反过来的话，两步之间断电会留下一个
            // state=blocked 却没有问题文件的任务：手机上看不到要回答什么，
            // 而它已经出了 queued 队列，永远不会再被调度。
            do { try AskStore.publish(stored) } catch {
                print(Ansi.red("  问题发布失败：\(error.localizedDescription)"))
                print(Ansi.dim("  任务留在队列里，下轮重试"))
                task.state = .queued
                task.pendingAsk = nil
                task.askRounds -= 1
                recordAttempt(.failed, failureKind: "askPublishFailed",
                              handoffReason: error.localizedDescription)
                try? TaskStore.append(task)
                return .noPlatform
            }
            recordAttempt(.blocked, handoffReason: "等待用户答复")
            try? FileManager.default.removeItem(at: askFile)
            try? TaskStore.append(task)
            Inbox.writeResult(for: task)
            OfficeLog.record(OfficeEvent(
                kind: .asked, taskID: task.id, platform: pick.platform,
                detail: ask.questions.first?.text ?? "有事要问",
                taskTitle: task.prompt))
            OfficeLog.publish()
            print(Ansi.cyan("  已转为等待答复") + Ansi.dim("，额度槽已让出"))
            return .blocked
        }

        if let failure = FailureClassifier.classify(
            exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr, timedOut: r.timedOut
        ) {
            print(Ansi.red("  失败") + Ansi.dim(String(format: " · %.0fs · ", elapsed))
                + failure.describe)
            attempts.append("\(pick.platform.displayName)：\(failure.describe)")

            // **会话坏了就丢掉，别让它把这个组合永久钉死。**
            //
            // 复用会话省了重读，代价是多了一个会坏的东西：会话会过期、
            // 会被 CLI 清掉、上下文会撑爆。没有作废机制的话，一个坏会话
            // 会让「这个仓库 × 这个平台」**每一次都失败**，
            // 而报错只说「会话不存在」，看不出病根在复用上。
            //
            // 只认明确的 session/conversation 失效词；普通构建失败和超时不能
            // 擅自清掉仍然有效的上下文。
            let blob = r.stdout + r.stderr
            let sessionFailed = GraphSession.shouldInvalidate(
                output: blob, timedOut: r.timedOut, wasResuming: session != .fresh)
            if sessionFailed {
                GraphSession.forget(context: sessionContext, workspace: ws.path)
                print(Ansi.dim("  会话已失效，丢掉重开（下次从零读一遍仓库）"))
            }

            // 存进度再走。哪怕只做了一半，也比让下一个平台从零开始强。
            let touched = GitWorkspace.touchedFiles(in: ws.path)
            let wip = GitWorkspace.commitWIP(
                in: ws.path, platform: pick.platform, reason: failure.describe)
            if !touched.isEmpty {
                print(Ansi.cyan("  已保存进度：")
                    + "\(touched.count) 个文件"
                    + (wip.map { "，提交 " + $0 } ?? ""))
            }
            handoff = Handoff(
                fromPlatform: pick.platform,
                reason: failure.describe,
                touchedFiles: touched,
                wipCommit: wip,
                elapsedSeconds: Int(elapsed))

            let failureName: String
            switch failure {
            case .timedOut: failureName = "timedOut"
            case .platformUnavailable: failureName = "platformUnavailable"
            case .agentFailed: failureName = "agentFailed"
            }
            recordAttempt(.failed, failureKind: sessionFailed ? "sessionInvalid" : failureName,
                          handoffReason: failure.describe)

            // 把平台侧失败记进冷却账本。下次调度直接跳过，不再白建 worktree。
            //
            // **超时不判额度。** 超时被杀时，输出是被掐断的半截内容 ——
            // 拿它做「有没有打满额度」的判断本来就不成立。实测代价：
            // 火山方舟和 Kimi 各被这么误冻过一次（一次 1 天 16 小时、
            // 一次 7 小时 45 分），两次的详情都明写着「超时被终止」，
            // 却记成额度用尽，把能干活的主力平台罚下场。
            // 超时该做的是换个平台重试（shouldTryNextPlatform 已经是 true），
            // 不是把平台冻起来。
            if case .timedOut = failure {
                print(Ansi.dim("  超时，不记冷却 —— 半截输出判不了额度，换平台重试"))
            } else if let cause = CooldownLedger.classify(r.stdout + " " + r.stderr) {
                // 报错原文里带确切重置时间就采信（「reset at 08-17 01:36 UTC」），
                // 别按退避每小时白撞一次撞到周日。
                let resetAt = CooldownLedger.parseResetTime(r.stdout + " " + r.stderr)
                let cd = CooldownLedger.record(
                    platform: pick.platform, cause: cause, detail: failure.describe,
                    knownResetAt: resetAt)
                print(Ansi.yellow("  已记入冷却：" + cd.cause.displayName
                    + "，" + Format.duration(cd.remaining) + "内不再派给它"))
                OfficeLog.record(OfficeEvent(
                    kind: .exhausted, taskID: task.id, platform: pick.platform,
                    detail: cd.cause.displayName + "，"
                        + Format.duration(cd.remaining) + "内不再派活",
                    taskTitle: task.prompt))
            } else if case .timedOut = failure {
                let cd = CooldownLedger.record(
                    platform: pick.platform, cause: .environmentBroken, detail: "超时")
                print(Ansi.yellow("  已记入冷却：超时，"
                    + Format.duration(cd.remaining) + "内不再派给它"))
            }
            // 失败的分支上什么都没提交，连分支一起删掉。
            // 默认由同一 owner 带着原会话和 WIP 再收一次尾；需要故障演练时
            // 可显式设 0 关闭。上下文亲和不该藏在实验开关后面。
            let ownerRetryEnabled = ProcessInfo.processInfo.environment[
                "LLMQ_OWNER_TIMEOUT_RETRY"] != "0"
            if sessionFailed, !sessionRepairUsed {
                sessionRepairUsed = true
                candidateQueue.insert(pick, at: idx + 1)
                retryCauseByIndex[idx + 1] = .sessionRepair
                print(Ansi.yellow("  原 owner 用 fresh 会话恢复一次"))
            } else if case .timedOut = failure,
               ContextAffinityPolicy.shouldRetryOwnerAfterTimeout(
                    enabled: ownerRetryEnabled, retryUsed: ownerRetryUsed,
                    currentRunnerID: pick.runner.runnerID,
                    ownerRunnerID: task.ownerRunnerID) {
                ownerRetryUsed = true
                candidateQueue.insert(pick, at: idx + 1)
                retryCauseByIndex[idx + 1] = .timeoutExperiment
                print(Ansi.yellow("  保留 owner 再试一次")
                    + Ansi.dim("（沿用会话、工作区和已保存进度）"))
            }
            let spent = Date().timeIntervalSince(overallStart)
            let effectiveHasNext = idx + 1 < candidateQueue.count
            let nextIsSameOwner = effectiveHasNext
                && candidateQueue[idx + 1].runner.runnerID == pick.runner.runnerID
            let mayHandoff = ContextAffinityPolicy.canProceedToNext(
                nextIsSameOwner: nextIsSameOwner,
                automaticHandoffCount: task.automaticHandoffCount)
            let mayRetryFailure = failure.shouldTryNextPlatform || sessionFailed
            if mayRetryFailure && effectiveHasNext && mayHandoff
                && spent < totalBudget {
                print(Ansi.yellow(nextIsSameOwner ? "  同 owner 重试" : "  换下一个平台重试")
                    + Ansi.dim(String(format: "（已用 %.0f 分钟 / 预算 %.0f 分钟）",
                                      spent / 60, totalBudget / 60)))
                idx += 1
                continue
            }
            if mayRetryFailure && effectiveHasNext && mayHandoff {
                print(Ansi.yellow(String(format: "  还有候选，但总时间已用 %.0f 分钟，超预算，停止重试",
                                         spent / 60)))
            }
            // 所有候选都试完了才清理。有进度就留着分支让人看，没进度才删干净。
            task.state = .failed
            task.endedAt = Date()
            task.exitCode = r.exitCode
            task.changedFiles = touched.count
            // 终局失败 = 「等下去不会变」的另一种 —— 弹窗问手机重试还是放弃，
            // 而不是安静躺平等人巡逻（用户原话：「不应该弹窗找我确认继续吗」）。
            _ = StuckAsk.raise(task: task,
                reason: "全部候选都试过仍失败：" + String((task.note ?? "无记录").prefix(160)))
            task.note = attempts.joined(separator: " | ")
            if touched.isEmpty {
                GitWorkspace.cleanup(repo: task.repo, path: ws.path, branch: ws.branch)
                task.branch = nil
            } else {
                GitWorkspace.cleanup(repo: task.repo, path: ws.path)
                print(Ansi.yellow("  保留分支 " + ws.branch
                    + "，里面有 \(touched.count) 个文件的半成品"))
            }
            break
        }

        // 跑成功了
        task.endedAt = Date()
        task.exitCode = r.exitCode
        task.changedFiles = changed

        if changed == 0 {
            task.state = .done
            task.note = "跑完了但没有产生任何改动"
            GitWorkspace.cleanup(repo: task.repo, path: ws.path, branch: ws.branch)
            task.branch = nil
        } else {
            let leaks = GitWorkspace.scanForSecrets(in: ws.path)
            // 高危路径闸。SECURITY.md 第三节第 4 条承诺了它，但代码里一直没有 ——
            // 提交前只扫密钥、跑构建。一个「补文档」的任务顺手改掉 Package.swift
            // 或 CI 配置，会一路通过所有检查直接进分支。
            //
            // 判据是**实际改到的文件**，不是任务描述里的风险分级 ——
            // 后者是派活前猜的，而 agent 真改了什么只有跑完才知道。
            let risky = GitWorkspace.riskyPathsTouched(in: ws.path)
            if !leaks.isEmpty {
                task.state = .failed
                task.note = "改动里疑似含凭据（\(leaks.joined(separator: "、"))），已拒绝提交"
            } else if !risky.isEmpty {
                // 不提交、**保留工作区** —— 改动可能完全正确，只是需要你看一眼。
                // 直接丢掉的话，一个正确的改动就白跑了。
                task.state = .blocked
                // **谁该管:后果是钱/账号/对外影响吗。**
                // 老板 2026-08-22 常设指示:「阻塞任务,你来看处理,
                // 这种问题都你来处理,给我应该就是风险类或者验收类」。
                // 高危路径闸的判据很粗(任何 .sh / Tools/ / .github/ 都算),
                // 拦下的绝大多数是纯技术活 —— 推给他只会淹掉真正要他
                // 拍板的那两类。详见 BossGate。
                let bossCall = BossGate.needsBoss(files: risky)
                task.note = "碰到高危路径（\(risky.prefix(3).joined(separator: "、"))"
                    + (risky.count > 3 ? " 等 \(risky.count) 个" : "") + "），"
                    + (bossCall ? "等你确认" : "等 Claude 处置")
                print(Ansi.yellow("  ⚠︎ 碰到高危路径，没提交，等人确认：")
                    + risky.prefix(5).joined(separator: "、"))
                print(Ansi.dim("  改动留在 " + ws.path))
                // 推到手机上等你点。
                //
                // 为什么不走飞书交互卡片：那需要一个飞书能访问的**入站回调地址**
                // （公网服务或内网穿透），和 SECURITY.md 第一节「只允许开一个端口」
                // 直接冲突 —— 那个端口是带 mTLS 的集群口，不该为了一个审批按钮
                // 再开一个。而 Ask 这条通道走 iCloud 文件，一个入站端口都不需要，
                // iOS App 已经能把带选项的问题渲染成按钮。
                // **这是审批,不是提问:kind 必须是 .approval。**
                //
                // 契约评审实锤(2026-08-23,Kimi):全仓没有一处传 kind: .approval,
                // AskIngest 的审批分支是死代码。手机「问题」页答「放行并提交」走的是
                // 提问分支 —— 重新排队、agent 从头再跑、再撞同一条高危路径、再弹一张
                // **新 id** 的问题(去重失效)。这就是老板「确认了还一直重复弹」的完整
                // 复现路径,每轮还白烧一份额度。
                //
                // **只有归老板拍板的才推手机。** 归 Claude 处置的(纯技术路径)留在
                // 本机 `llmq work blocked` 里由我处理,不推 —— 老板 2026-08-22:
                // 「给我应该就是风险类或者验收类」「minimax 咋都让人审批」。
                if bossCall {
                    let ask = Ask(
                        taskID: task.id,
                        machineID: Paths.machineID(),
                        round: task.askRounds + 1,
                        platform: task.platform,
                        taskPrompt: task.prompt,
                        repoName: (task.repo as NSString).lastPathComponent,
                        questions: [Ask.Question(
                            text: "这次改动碰到了高危路径，要放行吗？\n"
                                + risky.prefix(8).joined(separator: "\n"),
                            options: ["放行并提交", "丢弃这次改动"],
                            // 不给倾向性建议：高危改动该由人看过再定，
                            // 给了「建议放行」等于把这道闸门又软化回去。
                            suggestion: nil)],
                        progressNote: "改了 \(changed) 个文件，工作区留在 \(ws.path)",
                        kind: .approval)
                    try? AskStore.publish(ask)
                    task.pendingAsk = ask
                    task.askRounds += 1
                    print(Ansi.dim("  已推到手机等确认"))
                } else {
                    print(Ansi.dim("  归 Claude 处置,不推手机(llmq work blocked 可见)"))
                }
            } else {
                // 提交前先验一次。**在提交之前**是刻意的：提交完再验的话，
                // 坏代码已经落在分支上，还得再回滚一次；而且 work review
                // 会把它当成正常产出列出来，说「能干净合入」。
                // **纯文档改动跳过构建验收。**
                //
                // 验收命令是仓库级的（比如「整个 App 必须编译过」），
                // 而图的第一步常常只产出文档。实测被咬：s1 让 Kimi 读代码
                // 产出参数速查表（NOTES-slice.md，写得没问题），验收却要求
                // 构建通过 —— 而 App 入口要到 s3 才写，构建注定失败。
                // 一步文档任务被一个它不可能满足的验收判死，下游全部冻住，
                // 用户看到的是「Kimi 失败了」—— 它是被冤枉的。
                // 判据是「碰没碰可构建的源码」，不是枚举安全类型 ——
                // 第一版只放行 .md，紧接着媒体任务（png/mp3）就会栽进
                // 同一个坑：资产改动照样过不了「整个 App 必须编译」。
                let codeExts: Set<String> = ["swift", "yml", "yaml", "plist", "h", "m",
                                             "c", "cpp", "metal", "xcconfig",
                                             "entitlements", "sh", "json"]
                let touched = GitWorkspace.changedFileNames(in: ws.path)
                let touchedCode = touched.contains {
                    codeExts.contains(($0 as NSString).pathExtension.lowercased())
                }
                let skipVerify = !touched.isEmpty && !touchedCode
                let v = skipVerify
                    ? Verifier.Outcome(ran: false, passed: true,
                        summary: "没碰可构建源码（\(touched.count) 个文件，文档/资产类），跳过构建验收",
                        tail: "")
                    : Verifier.run(in: ws.path, repoPath: task.repo)
                if v.ran || skipVerify {
                    print(Ansi.dim("  " + v.summary))
                }
                guard !v.ran || v.passed else {
                    // 不提交，但**保留 worktree** —— 改动还在里面，
                    // 人想看能看，接力的下一个平台也能接着修。
                    task.state = .failed
                    task.note = "改了 \(changed) 个文件但 \(v.summary)，没有提交"
                    print(Ansi.red("  " + v.summary) + Ansi.dim("，改动留在工作区没提交"))
                    if !v.tail.isEmpty {
                        print(Ansi.dim("  " + v.tail.split(separator: "\n")
                            .suffix(6).joined(separator: "\n  ")))
                    }
                    recordAttempt(.failed, failureKind: "verificationFailed",
                                  handoffReason: v.summary)
                    break
                }

                // **agent 可能已经自己提交过了。**
                //
                // 实测 Qwen 跑完会自己 `git commit`（还自己跑了 build 和 test）。
                // 那时候工作区是干净的，我们再 commit 一次必然失败
                // 「nothing to commit」—— 而原来的代码把它判成「提交失败」，
                // 于是一个**完整且已提交**的产出被标成失败，
                // 下一轮还会换个平台重做一遍。
                let alreadyCommitted = GitWorkspace.commitsAhead(in: ws.path)
                let stillDirty = GitWorkspace.git(["status", "--porcelain"], in: ws.path)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

                // 工作区干净就不再提交 —— 用 `git status` 当空操作，
                // 它的退出码是 0，正好当成「这一步没问题」。
                let c = stillDirty
                    ? GitWorkspace.commit(
                        in: ws.path,
                        message: "agent(\(pick.platform.rawValue)): \(task.prompt.prefix(60))")
                    : GitWorkspace.git(["status", "--porcelain"], in: ws.path)

                if c.exitCode == 0 {
                    task.state = .done
                    // 收尾也要立刻重发：不然任务已经跑完，手机上还挂着
                    // 「正在干」直到下一次采集（约 2 分钟）。
                    // 开跑和收尾两头都发，「进行中」的显示才和事实同步。
                    defer { TaskBoardStore.publishNow() }
                    // **把执行器的 stdout 存进 outputs。**
                    //
                    // 审核执行器把结论行回显到 stdout（见 Work.swift 里
                    // `case "$l" in *结论*) echo "$l"` 那段），而
                    // `MergeReview.approvalsSoFar` 正是从 outputs + note 里
                    // 找「结论」两个字。
                    //
                    // 在此之前 **outputs 全仓库没有任何地方被赋值** ——
                    // 于是结论写在文件里、系统去空字段里读，parseVerdict
                    // 永远返回 nil，票数永远 0/N。
                    //
                    // 后果：老板要的「代码合入审核让 agent 判」这套设计
                    // **从来没生效过**。2026-08-20 实测两份合入审核报告都
                    // 白纸黑字写着「**结论**：不合入」，其中一份还明确说
                    // 「不要把它的产物推进 main」—— 系统一个字都没读到，
                    // 那条分支照旧被文书豁免放行、合进了 main。
                    //
                    // 只留尾部若干行：完整 stdout 可能几十 KB，
                    // 而结论按约定在最后一行。
                    task.outputs = r.stdout
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .suffix(20)
                        .map { String($0.prefix(500)) }
                    // **把「这一轮谁干的」和「分支上一共有什么」分开说。**
                    //
                    // 合并成一句「改了 N 个文件」会稳定地把前人的成果记到
                    // 最后一棒头上 —— 而多 agent 接力里，事后最想回答的问题
                    // 恰恰是「这段代码谁写的」。
                    let didSomething = (mine ?? changed) > 0
                    if didSomething {
                        task.note = "改了 \(mine ?? changed) 个文件"
                            + (v.ran ? "，\(v.summary)" : "")
                            + "，已提交到 \(ws.branch)"
                            + (myCommits > 0 ? "（\(myCommits) 个提交是它自己打的）" : "")
                    } else {
                        // 接手时活就已经干完了。说实话比凑一句好看的强。
                        task.note = "它自己没有产生改动"
                            + (v.ran ? "，但\(v.summary)" : "")
                            + "，分支 \(ws.branch) 上已有的成果判定为完成"
                    }
                    if changed != (mine ?? changed) {
                        task.note! += "（分支相对 main 一共 \(changed) 个文件"
                            + "、\(alreadyCommitted) 个提交，含前面几棒的）"
                    }
                    if let h = handoff {
                        task.note! += "（接手 \(h.fromPlatform.displayName)）"
                    }
                } else {
                    task.state = .failed
                    task.note = "提交失败：" + String(c.stderr.suffix(160))
                }
            }
        }
        // 跑通了就把这个平台的冷却清掉，连续失败计数归零。
        if task.state == .done { CooldownLedger.clear(pick.platform) }

        switch task.state {
        case .done:
            recordAttempt(.done)
        case .blocked:
            recordAttempt(.blocked, failureKind: "postRunGate", handoffReason: task.note)
        default:
            recordAttempt(.failed, failureKind: "postRunGate", handoffReason: task.note)
        }

        print((task.state == .done ? Ansi.green("  完成") : Ansi.red("  失败"))
            + Ansi.dim(String(format: " · %.0fs · ", elapsed)) + (task.note ?? ""))
        break
    }

    if task.state == .running {
        // 所有候选都试过了还没成
        task.state = .failed
        task.endedAt = Date()
        task.note = attempts.isEmpty ? "所有平台都不可用" : attempts.joined(separator: " | ")
    }
    // 任务跑到终态了，提问上下文用完就清。
    // 不清的话 resumeContext 一直成立，万一这个任务以后又被恢复，
    // 会把同一份旧答复再塞进提示词一遍。
    if task.state == .done || task.state == .failed {
        task.answeredAsk = nil
        task.pendingAsk = nil
        AskStore.retract(taskID: task.id, machine: Paths.machineID())
    }
    OfficeLog.record(OfficeEvent(
        kind: .finished, taskID: task.id, platform: task.platform,
        detail: task.note ?? (task.state == .done ? "干完了" : "没干成"),
        taskTitle: task.prompt))
    OfficeLog.publish()
    try TaskStore.append(task)
    Inbox.writeResult(for: task)   // 让手机端能看到结果

    // 上游被拦下之后，下游要跟着冻结。
    //
    // 不传的话它们会一直躺在 queued 里等一个永远不会 done 的上游 ——
    // 就是刚修好的那个死锁换到了图这一层。挂在这里（而不是每个转 blocked
    // 的地方）是因为路径有好几条：能力不够、人工闸门、提问超轮次。
    for x in TaskGraph.reconcile(TaskStore.all()) {
        try? TaskStore.append(x)
        print(Ansi.yellow("  对账 ") + Ansi.dim("\(x.id.prefix(8))  " + (x.note ?? "")))
    }

    let ok = task.state == .done
    let total = Date().timeIntervalSince(overallStart)
    let sent = Notifier.feishu(
        "任务 \(task.id) \(ok ? "完成" : "失败")\n"
        + "平台：\(task.platform?.displayName ?? "—")\n"
        + "耗时：\(Int(total)) 秒\n"
        + "结果：\(task.note ?? "")\n"
        + (task.branch.map { ok ? "分支：\($0)\n" : "" } ?? "")
        + "任务：\(task.prompt.prefix(120))",
        subject: "llmq 任务\(ok ? "完成" : "失败")"
    )
    print(Ansi.dim(sent ? "\n已推送飞书通知" : "\n飞书通知未发出"))
    if ok, let b = task.branch, (task.changedFiles ?? 0) > 0 {
        print(Ansi.dim("review：cd \(task.repo) && git show " + b))
    }
    return ok ? .succeeded : .failed
}

// MARK: - 常驻循环

func cmdWorkLoop(_ args: [String]) throws {
    // stdout 重定向到文件时默认是块缓冲的，日志会卡在缓冲区里不落盘 ——
    // 装成 launchd 之后表现为「日志一片空白，不知道它在干什么」。
    // 守护进程必须行缓冲。
    setvbuf(stdout, nil, _IOLBF, 0)

    var policy = LoopPolicy()
    if let i = args.firstIndex(of: "--tick"), i + 1 < args.count,
       let v = Double(args[i + 1]) { policy.tickSeconds = v }
    if let i = args.firstIndex(of: "--max-per-hour"), i + 1 < args.count,
       let v = Int(args[i + 1]) { policy.maxTasksPerHour = v }

    // 两个循环同时跑会把同一个任务派两遍。从根上只允许一个实例。
    let lock = SingleInstanceLock(name: "work-loop")
    guard lock.acquire() else {
        let who = lock.holderPID().map { "（PID \($0)）" } ?? ""
        print(Ansi.red("已经有一个循环在跑" + who + "，不重复启动。"))
        exit(1)
    }
    defer { lock.release() }

    // SIGTERM/SIGINT 要能干净退出：正在跑的 agent 得让它跑完，
    // 半路杀掉会留下脏 worktree 和状态为 running 的僵尸任务。
    var stopping = false
    for sig in [SIGTERM, SIGINT] { signal(sig, SIG_IGN) }
    let sources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler { stopping = true }
        src.resume()
        return src
    }
    defer { sources.forEach { $0.cancel() } }

    Inbox.ensureDirectories()
    Inbox.pruneResults()

    // **启动时先回收上一条命留下的 running。**
    //
    // 实测：worker 被重启（`llmq update` 每次都会重启它）时，正在执行的
    // agent 进程被一起杀掉，而任务记录永远停在 `.running` —— 没有任何机制管它。
    //
    // 对普通任务的后果是「一个任务永远不结束」；对图更致命：
    // **下游节点永远等不到上游 done，整张图静默停摆**，
    // 而且从外面完全看不出是坏了还是还在跑。
    //
    // 判据是「worker 刚启动」而不是「跑了多久」：agent 是我们的子进程，
    // 我们一死它就没了，所以启动这一刻看到的任何 running 都必然是孤儿。
    // 反过来用超时判会误杀一个正常长跑的任务。
    for t in TaskStore.all() where t.state == .running {
        // **进程还活着就别碰。**
        //
        // 同一台机器上可能同时有 launchd 起的 worker 和一个手敲的
        // `llmq work loop`。只按状态回收的话，后启动的那个会把前一个
        // 正在干的活抢过来标成失败 —— 而那个活还在跑，最后两边都写同一个
        // 任务记录，产出归属彻底乱掉。
        if let pid = t.runnerPID, pid > 0, kill(pid, 0) == 0 {
            print(Ansi.dim("跳过 " + t.id + "：进程 \(pid) 还在跑，不是孤儿"))
            continue
        }
        // **被打断 ≠ 失败，默认重新入队而不是判死。**
        //
        // 这件事已经真金白银发生过两次：一次毁掉 334 秒的 Qwen 产出，
        // 一次毁掉 1586 秒（26 分钟）的图节点 s2。两次都是 worker 被重启，
        // 任务正跑到一半，然后被回收成 `failed` 躺在那儿等人手动 retry ——
        // 而人（我）当时正忙着查别的问题，根本没注意到。
        //
        // `restartResidentServices()` 里有在飞守卫，但 `launchctl kickstart -k`
        // 从外面绕过去了，而且 launchd 自己的 KeepAlive 重启也绕过去。
        // 靠「下次小心点」是防不住的，得让它自动接上。
        //
        // 上限 2 次：真的每次跑到一半就死的任务（比如必然 OOM），
        // 不能让它无限重排把整条队列拖住。到顶了才判失败。
        let ran = t.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
        var x = t
        x.endedAt = Date()
        x.runnerPID = nil
        let interrupted = (t.interruptedCount ?? 0) + 1
        x.interruptedCount = interrupted
        if interrupted <= 2 {
            x.state = .queued
            // **别把 startedAt 抹掉。**
            //
            // 第一版这里写了 `x.startedAt = nil`，理由是「排队中的任务不该
            // 显示一个已经跑了 11 天的时长」。但那件事发看板时已经单独处理了
            // （TaskBoard 对 queued 一律不发 startedAt）——
            // 而这里抹掉它，抹掉的是**防自锁所依赖的证据**。
            //
            // 调度器判「人在用这个平台，让开」时，会把落在**我们自己执行窗口**
            // 里的用量排除掉，判据正是任务的 startedAt / endedAt。
            // 窗口没了，它就认不出那笔用量是自己烧的：
            //
            //   [23:15] 派给 Qwen 跑 s2 → 被打断 → startedAt 抹掉
            //   [23:21] 排除 Qwen「你 6 分钟前还在用它，先让着你」
            //
            // 于是唯一可用的平台被自己锁死 20 分钟。**我加的修复引入的回归。**
            // **把平台从「试过并失败」里摘掉。**
            //
            // `triedPlatforms` 是**派活那一刻**就加进去的，不是失败之后 ——
            // 所以一次中断会让那个平台永久背上「本任务已在该平台失败过」。
            //
            // 今天的实际后果：图节点 s2 被 TCC 闸门、发布重启、机器崩了十小时
            // 轮流打断七次，Qwen 和 Kimi 双双被拉黑，最后调度报
            // 「没有平台能接」把它冻住 —— 而没有任何一次是 agent 真的干不了。
            // 基础设施故障不该记成平台的能力问题。
            if let p = t.platform {
                x.triedPlatforms.removeAll { $0 == p }
            }
            x.note = "worker 重启时它正在执行（已跑 \(ran) 秒），进程随之被杀。"
                + "**被打断不算失败**，已自动重新入队（第 \(interrupted) 次）"
                + (t.platform != nil ? "，\(t.platform!.displayName) 不算试过" : "")
                + "。"
        } else {
            x.state = .failed
            x.note = "已经被打断 \(interrupted) 次（这次跑了 \(ran) 秒），不再自动重排 —— "
                + "反复跑到一半就死，多半是任务本身的问题，需要人看一眼。"
                + (t.graphID != nil ? "图内节点：下游会冻住等它。" : "")
        }
        for running in WorkAttemptStore.unresolvedRunning(taskID: t.id) {
            var terminal = running
            terminal.endedAt = Date()
            terminal.outcome = .failed
            terminal.failureKind = "interrupted"
            terminal.handoffReason = x.note
            appendWorkAttempt(terminal)
        }
        try? TaskStore.append(x)
        print(Ansi.yellow("回收孤儿任务 ") + Ansi.dim(x.id + "  " + (x.note ?? "")))
    }

    // **回收完要对账。**
    //
    // 孤儿回收把任务直接改成 failed，绕过了 runOneTask 结尾那次对账 ——
    // 于是下游停在 queued，既不就绪也没有 note，而且**压着储备池的生成闸门**。
    // 实测：s2 被回收成 failed 之后，s3 在 queued 上躺了一个多小时，
    // 每 30 分钟打印一次「空闲中」，看起来一切正常。
    for x in TaskGraph.reconcile(TaskStore.all()) {
        try? TaskStore.append(x)
        print(Ansi.dim("  对账 " + x.id + "  " + (x.note ?? "")))
    }

    print(Ansi.bold("工作循环已启动")
        + Ansi.dim("  每 \(Int(policy.tickSeconds))s 查一次队列"
            + " · 每小时最多 \(policy.maxTasksPerHour) 个任务"
            + " · 连续失败 \(policy.stopAfterConsecutiveFailures) 次就停"))

    var gate = RateGate(maxPerHour: policy.maxTasksPerHour)
    var consecutiveFailures = 0
    var lastCollect = Date.distantPast
    var lastHeartbeat = Date()
    var ranTotal = 0

    // **每个阶段都关进看门狗，而不是每个 I/O 调用。**
    //
    // 我先按调用点包了三轮，冻住了三次，每次都是一个我没想到的地方：
    //   1. `collect → publishDashboard` 的 `Data.write(.atomic)` 卡在 rename
    //   2. 包完 collect 之后 → `runOneTask → OfficeLog.publish`，另一条路径
    //   3. 又包完写操作之后 → `AskIngest.run → contentsOfDirectory`，**读也会挂**
    //
    // 每一轮我都觉得「这次扫干净了」。**手工枚举 I/O 调用点这件事，
    // 我连着三次都漏。** 而 iCloud 上的任何一次读或写都可能永久阻塞，
    // 调用点还会随着功能增加不断变多。
    //
    // 所以改在这一层：循环的每个阶段是一个整体，里面无论哪一行卡住，
    // 代价上限就是这个阶段的超时。新增的 I/O 自动被覆盖，不需要谁记得去包。
    // 底下 ICloudSafe 那层保留 —— 它给的 key 更细，跳过时更精准。
    func phase(_ name: String, _ seconds: TimeInterval, _ body: @escaping () -> Void) {
        let r = Watchdog.run("loop." + name, timeout: seconds, body)
        if r.stalled {
            print(Ansi.red("  ⚠︎ \(name) 卡住了") + Ansi.dim(
                "（超过 \(Int(seconds)) 秒没返回，本轮跳过它继续跑）"))
        }
    }

    // 派活的「静默期」截止时刻。原来 .noPlatform 睡 300s、每小时上限睡
    // 60–600s 都是 Thread.sleep —— 整轮卡住,末尾刷新/收答复/手机动作/落地
    // 派发全部跟着停,手机看起来又「没更新了」(控制流 review §1)。
    // 改成只延后**派活**这一件事,别的照常每 30s 跑。
    var dispatchHoldUntil = Date.distantPast

    // 记下「我是哪份二进制」。每轮末尾空闲时发现磁盘上换了就退出,launchd 用新的
    // 拉起来 —— 这才是「新二进制等它干完自然生效」的机制(见 BinarySwap)。
    let swapWatch = BinarySwap.watch()

    // **橱窗刷新不跟着主循环的节奏走。**
    //
    // runOneTask 是同步的,一条复杂任务能占住主线程 90 分钟;而手机看的那几页
    // 原来只在「一轮末尾」发布 —— 于是 agent 一开工,手机上就彻底静止。
    // 老板反复报的「半小时没更新」「看不到进行中的任务」「点进去就没有了」
    // 都是这一个根(见 Showcase)。这个定时器独立于主线程,照常刷。
    let showcase = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    showcase.schedule(deadline: .now() + Showcase.interval, repeating: Showcase.interval)
    showcase.setEventHandler {
        _ = Watchdog.run("showcase", timeout: 120) { _ = Showcase.refresh() }
    }
    showcase.resume()
    defer { showcase.cancel() }

    while !stopping {
        // **家务每轮开头做,不藏在 runOneTask 里。**
        //
        // 控制流 review §2:Housekeeping.roundCheck 全仓库只在 runOneTask 开头
        // 调,而 runOneTask 只在有活时被调 —— 队列空 / 限流时,菜单栏 App 死了
        // 不复活(手机停旧快照)、验收残留不清(7GB 那件事)、磁盘不查。
        // 和续活同一个形状。这里每轮先做,低磁盘时记下来让派活跳过。
        let hk = Housekeeping.roundCheck()
        if let n = hk.note { print(Ansi.yellow("  家务 ") + n) }
        let lowDisk = hk.skipDispatch
        if Date().timeIntervalSince(lastCollect) >= policy.collectSeconds {
            phase("采集", 45) { _ = try? LLMQuota.collect() }
            lastCollect = Date()
        }

        // 先看看手机往 iCloud 收件箱里丢了什么。
        // 先收答复再取任务：答复会把 blocked 的任务放回 queued，
        // 这一轮就能立刻接上，不用再等一个 tick。
        var answers: [AskIngest.Result] = []
        phase("收答复", 20) {
            answers = AskIngest.run(
                machineID: Paths.machineID(),
                load: { TaskStore.all() },
                save: { try TaskStore.append($0) })
        }
        for r in answers {
            let mark = r.accepted ? Ansi.green("  ✓ ") : Ansi.yellow("  ⚠︎ ")
            print(mark + "答复 " + r.taskID + Ansi.dim("  " + r.note))
            if r.accepted {
                OfficeLog.record(OfficeEvent(
                    kind: .answered, taskID: r.taskID,
                    detail: "老板回话了，接着干", taskTitle: ""))
                OfficeLog.publish()
            }
            if !r.accepted {
                // 让手机端看得见自己白答了，而不是石沉大海。
                Inbox.writeResult(taskID: r.taskID, state: "stale",
                                  note: "这份答复没能用上：" + r.note, prompt: "")
            }
        }

        // 手机改的配置（目前只有留白比例）。
        //
        // 放在派活**之前**：这一轮就按新的留白判，而不是等下一轮。
        // 「我把 MiniMax 调到 40% 了，它怎么还在被派活」是个很自然的疑问，
        // 而答案如果是「你再等 30 秒」，那这个设置看起来就是坏的。
        var intents: [ConfigIntentIngest.Result] = []
        phase("收配置意图", 20) { intents = ConfigIntentIngest.run() }
        for r in intents {
            let mark = r.accepted ? Ansi.green("  ✓ ") : Ansi.yellow("  ⚠︎ ")
            print(mark + "配置 " + Ansi.dim(String(r.id.prefix(8))) + "  " + r.note)
        }

        // 黄金样板落地/质量票可能由后台落地线程完成，不一定经过 runOneTask
        // 的收尾路径。每轮统一对账：视觉否决重开原会话，样板通过才放行
        // fan-out，并立刻重发手机任务板。
        phase("质量闭环", 10) {
            let updates = TaskGraph.reconcile(TaskStore.all())
            for task in updates { try? TaskStore.append(task) }
            if !updates.isEmpty { _ = TaskBoardStore.publishNow() }
        }

        // 落地环节（详见 Review.autoLand 的条件说明）。
        // 显式开关，默认关：`llmq work autoland on` 之后才生效，
        // 关着的时候产出照旧全部留在 `work review` 名单里等人工处置。
        // **落地不能挡住派活。**
        //
        // 落地里的 verifyMerge 会**同步跑整个测试套件**（LLMQuotaBar 一次
        // `swift test` 320 秒），几个仓库排下来就是十几分钟。而这一段跑在
        // 派活**之前**、同一轮里 —— 这期间一个新任务都派不出去，
        // 从外面看就是「又停了」。老板 2026-08-22 一天里问了九次。
        //
        // 落地和派活本来就没有先后依赖：落地慢一轮无所谓，派活停一分钟是
        // 实打实的产能损失。所以把它挪到后台，一次只允许一个在跑。
        // （更彻底的做法是把「跑测试」变成派给测试角色的一个任务，
        // 按 AgentRoles 调度 —— 老板 2026-08-22 定的分工。那是下一步。）
        if Review.autoLandEnabled(), !landingInFlight {
            landingInFlight = true
            DispatchQueue.global(qos: .utility).async {
                defer { landingInFlight = false }
                landingRound()
            }
        }

        // **空窗填活**：窗口快过期还没用够时，主动找个真需求干掉。
        //
        // 实测空窗率 Codex 82%、Kimi 69% —— 钱不是花在干活上浪费的，
        // 是**根本没开工**就过期了。调度只做「有活时挑谁干」是做了一半，
        // 另一半是「没活时主动找活」。三条闸管着不抢人的额度：
        // 留白线、人在用就让开、只在窗口尾声（剩 90 分钟内）动手。
        phase("空窗填活", 30) {
            let dash = LLMQuota.dashboard()
            let opps = IdleFiller.opportunities(dashboard: dash)
            guard let opp = opps.first else { return }
            guard let hit = IdleFiller.found(for: opp) else {
                // 找不到真需求就老实闲着 —— 绝不为了填窗口编任务，
                // 那只是把「窗口过期」的浪费换成「产出没人要」的浪费。
                print(Ansi.dim("  空窗 " + opp.platform.displayName
                               + "（" + opp.reason + "）但没有现成的活可填"))
                // 系统自己没辙了才打扰人 —— 填掉了就不用喊。
                Nudge.nothingToFill(platform: opp.platform, reason: opp.reason)
                return
            }
            let fallback = RepoRegistry.all().first(where: { $0.isDefault })?.localPath
                ?? RepoRegistry.all().first?.localPath
            guard let repo = hit.repo ?? fallback else { return }
            print(Ansi.cyan("  空窗填活 ") + opp.platform.displayName
                  + Ansi.dim("  " + opp.reason))
            // 会对外发布的活，任务描述里就把闸写死 —— 老板要求对外发布必须他点头。
            let prompt = hit.publishes
                ? hit.prompt + "\n\n**这条活的产出会对外可见。做完停下来交给老板确认，"
                    + "不要自己发布/上架/投稿。**"
                : hit.prompt
            if let outcome = try? TaskIntake.enqueue(
                prompt: prompt, repo: NSString(string: repo).expandingTildeInPath,
                classify: true, split: false, force: false,
                origin: hit.projectID.map { "playbook:" + $0 } ?? "idle-filler",
                preferredPlatform: opp.platform),
               case .single(let t) = outcome {
                print(Ansi.dim("    已入队 " + t.id))
                // **入队成功之后**才记取用 —— 提前记会让轮转跳过一条配方，
                // 更糟的是会白白吃掉一个方向。
                if let pid = hit.projectID {
                    Playbook.recordRun(pid, consumedTopic: hit.usedTopic)
                }
            }
        }

        // 把待审产出发给手机，并收回它们的验收结论。
        //
        // 推了「10 份产出等你验收」却没地方看，那个数字就是噪音 ——
        // 老板的原话是「显示有 94 个消息但是我也看不到」。
        // **发布降频到 5 分钟一次。** 它要对每个仓库的每个待审分支跑
        // git diff / merge-tree，四个仓库十来个分支，一轮就能超过 25 秒 ——
        // 挂在 30 秒的循环里每轮都卡住，实测日志里全是「本轮跳过它」。
        // 收结论是廉价的（读几个小 JSON），保持每轮。
        phase("同步验收", 90) {
            // **收结论要在发布之前，而且执行完立刻重发。**
            //
            // 顺序反了的话：手机点了合入 → 本地那行消失 → 15 秒后刷新
            // 读到的还是没更新的 reviews.json → 那行又冒出来。
            // 老板的原话「点击验收还是在验收列表」就是这么来的。
            let applied = Review.ingestVerdicts()
            for (v, ok) in applied {
                print((ok ? Ansi.green("  手机上") : Ansi.red("  手机上（失败）"))
                      + (v.action == "merge" ? "合了 " : "丢了 ") + v.branch)
            }
            // 执行过就必须马上重发，别等 5 分钟节流 —— 那 5 分钟里
            // 手机看到的是已经过时的清单。
            if !applied.isEmpty || Review.shouldRepublish() {
                Review.publishDigests()
            }
        }

        // 下发「现在」页 + 收手机点过的动作。
        //
        // 这一层的意义：排序规则、提示语、有哪些按钮，全在 Mac 端决定。
        // 改它们不需要重新上架 —— 而上架一次要走几天审核。
        phase("下发视图", 60) {
            // **「现在」和「看板」不下发 —— 它们的原生页更全也更好看。**
            //
            // 这两页迁早了：客户端一见到下发内容就整页交给通用渲染器，
            // 而下发只组装了「在漏的」和「等你验收」两块，于是
            // 在跑的任务、员工那一行、挡住了、冷却说明全没了 ——
            // 「为啥手机端看不到现在进行中的任务」这个问题被我重新做了一遍。
            //
            // 迁移的前提是**下发能装下这一页原来显示的全部东西**。
            // 装不下就先别迁：五种区块表达不了那张绿色的「正在干」大卡
            // 和头像行，硬迁只会把好看的页换成能用的页。
            //
            // 少发一个文件，客户端就退回原生画法 —— 这条兜底路本来就是
            // 为这种时刻留的，用它，别等发新包。
            ViewFeed.publish(ViewFeed.reviewPage())
            ViewFeed.publish(ViewFeed.blockedPage())
            ViewFeed.publish(RoadmapPage.page())
            ViewFeed.publish(ViewFeed.playbookPage())
            ViewFeed.publishMenu(ViewFeed.menu())
            for inv in ViewFeed.pendingInvocations() {
                // **试够了就别再试。** 一个必然失败的动作（比如合一条和 main
                // 有冲突的分支），重试一次和重试三百八十次得到的信息一样多，
                // 而后者每轮都跑一遍全量构建 —— 实测烧了七个小时。
                if ViewFeed.exhausted(inv) {
                    ViewFeed.markDone(inv)
                    print(Ansi.yellow("  手机上（放弃）：") + inv.id
                        + Ansi.dim("  试了 \(ViewFeed.maxAttempts) 次都没成，"
                                 + "不再重试 —— 原因见上一次的失败说明"))
                    continue
                }
                guard let done = runInvocation(inv) else {
                    print(Ansi.dim("  不认识的动作：" + inv.id))
                    continue
                }
                if done {
                    ViewFeed.markDone(inv)
                    print(Ansi.green("  手机上：") + inv.id)
                } else {
                    let n = ViewFeed.recordFailure(inv, reason: "执行返回失败")
                    print(Ansi.red("  手机上（失败）：") + inv.id
                        + Ansi.dim("  第 \(n)/\(ViewFeed.maxAttempts) 次"))
                }
            }
        }

        // 收手机批的项目方案。要在「空窗填活」之前 ——
        // 刚批的项目本轮就该能被取用，不用等下一轮。
        phase("收批准", 15) {
            for p in Playbook.ingestApprovals() {
                print(Ansi.green("  老板批了 ") + p.name)
                OfficeLog.record(OfficeEvent(
                    kind: .answered, taskID: "", platform: nil,
                    detail: "项目方案获批，从现在起可以自动取用",
                    taskTitle: p.name))
            }
        }

        // 有待决事项就推一条到手机。**只推需要人做决定的事** ——
        // 「跑完了 3 个任务」不发，「有 3 份产出等你验收」才发。
        phase("提醒", 20) { _ = Nudge.run() }

        var incoming: [Inbox.Ingested] = []
        phase("收远程任务", 20) { incoming = Inbox.ingest() }
        for got in incoming {
            print("[\(Format.dateTime(Date()))] " + Ansi.green("收到远程任务 ")
                + got.taskID + Ansi.dim("  来自 " + got.source))
        }

        // 队列空了先看要不要按主线续活 —— runOneTask 只在有活时才被调,
        // 续活不能藏在它里面(见 refillIfIdle 的说明)。
        if TaskStore.nextQueued() == nil { refillIfIdle(quiet: true) }

        if TaskStore.nextQueued() != nil, !lowDisk, Date() >= dispatchHoldUntil {
            if gate.allow() {
                print("\n" + Ansi.dim("[\(Format.dateTime(Date()))] 取到任务"))
                let outcome = try runOneTask(dryRun: false, quiet: true)
                switch outcome {
                case .succeeded:
                    consecutiveFailures = 0
                    ranTotal += 1
                case .failed:
                    consecutiveFailures += 1
                    ranTotal += 1
                case .noPlatform:
                    // 所有平台都在冷却或不可用。不算失败 —— 任务还在队列里，
                    // 等冷却过去自然会跑。但也别急着重试，睡长一点。
                    //
                    // **额度槽要退回去**：这一次一个字都没发出去。
                    // 不退的话，一条跑不了的任务每小时能把 12 个槽全烧光，
                    // 然后上限把所有真活挡在门外 —— 实测就是这么空转的。
                    gate.refund()
                    // 只有真·暂时性的原因才会走到这里 —— 永久性的已经在
                    // runOneTask 里转成 blocked 了，不再堵队列。
                    print(Ansi.dim("  暂时没有可用平台（冷却或额度耗尽），等一等"))
                    // 不睡:只延后派活,末尾刷新/收答复/落地照常每 30s 跑。
                    dispatchHoldUntil = Date().addingTimeInterval(min(300, policy.tickSeconds * 10))
                case .blocked:
                    // 既不算成功也不算失败。而且**立刻去取下一个任务**，
                    // 不睡一个 tick —— 提问的任务已经不在 queued 里了，
                    // 这一刻额度槽是空的，睡过去就是白白浪费。
                    consecutiveFailures = 0
                    print(Ansi.cyan("  任务在等答复，继续取下一个"))
                    continue
                case .noTask:
                    // **额度槽要退回去 —— 这一次什么都没跑。**
                    //
                    // 队列里有任务（外层判过 nextQueued() != nil），但取出来
                    // 之后前提没就绪（基线还差已完成成果没合、上游没让开），
                    // 于是一个字都没发出去。闸必须在跑之前判，所以槽已经扣了。
                    //
                    // 实测（2026-08-19）：3 条待审分支卡在人工验收上 →
                    // main 基线落后 13 个文件 → BaselineFreshness 拦住队列里
                    // 那条证据任务。每一轮取出、扣槽、发现拦着、放回 ——
                    // 20 分钟把每小时 12 个槽烧光（worker.log 里 12 次
                    // 「取到任务」、0 个任务创建、0 个完成），
                    // 然后上限让整台机器空转 40 分钟。
                    //
                    // **拦住不等于跑过。** 把「什么都没发生」记成「发生过」，
                    // 限速就变成了自我封锁。
                    gate.refund()
                    break
                }

                if consecutiveFailures >= policy.stopAfterConsecutiveFailures {
                    let msg = "连续失败 \(consecutiveFailures) 次，循环已停止。"
                        + "多半是所有平台都出问题了，跑 llmq work probe 看看。"
                    print(Ansi.red("\n" + msg))
                    _ = Notifier.feishu(msg, subject: "llmq 循环已停止")
                    break
                }
            } else if let next = gate.nextAllowed() {
                print(Ansi.yellow("[\(Format.dateTime(Date()))] 已达每小时上限 "
                    + "\(policy.maxTasksPerHour) 个，"
                    + Format.duration(next.timeIntervalSinceNow) + "后恢复"))
                // 不睡:只延后派活(见 dispatchHoldUntil)。
                dispatchHoldUntil = next
            }
        } else if Date().timeIntervalSince(lastHeartbeat) >= policy.heartbeatSeconds {
            // 空闲时也要偶尔说句话，否则你无法区分"没任务"和"循环挂了"。
            print(Ansi.dim("[\(Format.dateTime(Date()))] 空闲中"
                + "，本轮已完成 \(ranTotal) 个任务"))
            lastHeartbeat = Date()
        }

        // **每轮都刷新手机看到的一切 —— 哪怕这一轮没派出任何活。**
        //
        // 老板 2026-08-23:「手机端显示半小时没有更新状态了」「flint 任务状态
        // 没有显示」「手机显示啥任务也没有跑」。根子:office.json / 任务板 /
        // ViewFeed 页面原来只在「派活」和「收工」时更新,而队列全在等前置的
        // 那一个多小时里,主循环每轮都因 nextQueued()==nil 跳过这些 publish ——
        // 系统明明在正常运转(在等、在续活、在做家务),手机上却像死了。
        // 「没派活」不等于「状态不用更新」。这里无条件刷一次,手机最多滞后一个 tick。
        // 一份实现:定时器和这里走同一套发布器(Showcase.defaultPublishers)。
        // 抄一份在这里的话,加一页就得记得改两处 —— 这个项目已经因此栽过很多次。
        Showcase.refresh(force: true)

        // **换二进制只在这里、只在空闲时。**
        //
        // runOneTask 是同步的,走到这儿说明本轮的 agent 已经收工;后台落地
        // (跑测试)还在就再等一轮。退出码 0,launchd KeepAlive 用新二进制拉起。
        // 别在别处 kickstart:那会把正在跑的 agent 一起杀掉(fa4e5eeb 2026-08-23
        // 就这么死了两次,每次十几分钟的 Kimi 额度白烧)。
        if BinarySwap.shouldExit(changed: swapWatch.changed(),
                                 inFlight: inFlightAgent() != nil || landingInFlight) {
            print(Ansi.cyan("[\(Format.dateTime(Date()))] 二进制换了,手上没活 —— 退出让 launchd 用新版拉起"))
            break
        }

        // 分片睡眠，这样收到信号能很快响应，而不用等满一个 tick。
        var slept = 0.0
        while slept < policy.tickSeconds && !stopping {
            Thread.sleep(forTimeInterval: 0.5)
            slept += 0.5
        }
    }

    print(Ansi.bold("\n循环已停止") + Ansi.dim("  本轮共完成 \(ranTotal) 个任务"))
}

/// 多机接入诊断。
///
/// 「注册」这件事本身是不存在的 —— 新机器装上跑一次 collect，
/// 快照就出现在 iCloud 共享目录里，其他机器下次采集自动看到。
/// 这个命令的价值在于**接不上时告诉你卡在哪一环**。
func printProfile(_ p: TaskProfile?) {
    guard let p else {
        print(Ansi.dim("  未分诊 —— 调度将只按额度排序"))
        return
    }
    let riskColor: (String) -> String = p.risk == .sensitive ? Ansi.red
        : (p.risk == .safe ? Ansi.green : Ansi.dim)
    print("  " + pad(p.tier.displayName, 6) + pad(riskColor(p.risk.displayName), 8)
        + pad("约 \(p.estimatedMinutes) 分钟", 12)
        + Ansi.dim("由 \(p.classifiedBy?.displayName ?? "?") 分诊"))
    if !p.rationale.isEmpty { print(Ansi.dim("  " + p.rationale)) }
    if !p.isSelfContained {
        print(Ansi.yellow("  ⚠︎ 任务描述不自洽：") + (p.missingContext ?? "缺少必要信息"))
        print(Ansi.dim("  agent 只能靠猜，猜错整轮额度就白烧了。建议改清楚再派。"))
    }
    if p.risk.needsApproval {
        print(Ansi.yellow("  ⚠︎ 高危：会碰构建配置/脚本/CI 这类改错影响面很大的东西"))
    }
}

func cmdRunner(_ args: [String]) throws {
    switch args.first ?? "list" {

    // llmq runner roles [--set <平台> --risk <safe|normal|sensitive> --tier <...> --title <...>]
    case "roles":
        let rest = Array(args.dropFirst())
        func opt(_ k: String) -> String? {
            guard let i = rest.firstIndex(of: k), i + 1 < rest.count else { return nil }
            return rest[i + 1]
        }
        if let name = opt("--set") {
            guard let pf = Platform(rawValue: name) else {
                print(Ansi.red("不认识的平台：\(name)")); exit(2)
            }
            var all = AgentRoles.all()
            var r = all[pf] ?? AgentRole(platform: pf, title: "未分配", maxRisk: .safe)
            if let v = opt("--risk") {
                guard let risk = TaskProfile.Risk(rawValue: v) else {
                    print(Ansi.red("风险等级只能是 safe / normal / sensitive")); exit(2)
                }
                r.maxRisk = risk
            }
            if let v = opt("--tier") {
                r.maxTier = v == "auto" ? nil : TaskProfile.Tier(rawValue: v)
            }
            if let v = opt("--title") { r.title = v }
            // 静音是**按机器**的：同一个平台在不同机器上处境不一样。
            let me = Paths.machineName()
            if rest.contains("--mute-here") {
                if !r.mutedOn.contains(me) { r.mutedOn.append(me) }
                r.muteReason = opt("--reason") ?? r.muteReason
            }
            if rest.contains("--unmute-here") {
                r.mutedOn.removeAll { $0 == me }
                if r.mutedOn.isEmpty { r.muteReason = nil }
            }
            // 留白比例：调度最多能吃掉这个平台额度的多少，剩下的归你自己用。
            // 收百分数（20）而不是小数（0.2）—— 命令行里输 0.2 太容易写成 2，
            // 而 2 会被当成 200% 直接把这个平台永久排除，且不报错。
            if let v = opt("--reserve") {
                if v == "default" {
                    r.reserveFraction = nil
                } else if let pct = Double(v.replacingOccurrences(of: "%", with: "")),
                          pct >= 0, pct <= 100 {
                    r.reserveFraction = pct / 100
                } else {
                    print(Ansi.red("--reserve 要一个 0–100 的百分数，或者 default")); exit(2)
                }
            }
            // 指挥：和静音一样按机器。
            if rest.contains("--dispatcher-here") {
                if !r.dispatcherOn.contains(me) { r.dispatcherOn.append(me) }
            }
            if rest.contains("--no-dispatcher-here") {
                r.dispatcherOn.removeAll { $0 == me }
            }
            all[pf] = r
            try AgentRoles.save(Array(all.values))
            print(Ansi.green("已更新 ") + pf.displayName)
        }

        let dash = LLMQuota.dashboard()
        let history = TaskStore.all()
        print(Ansi.bold(pad("岗位", 12) + pad("agent", 24) + pad("最高风险", 12)
            + pad("难度上限", 12) + pad("留白", 8) + "偏好"))
        for p in Platform.allCases {
            guard let rep = dash.reports.first(where: { $0.platform == p }),
                  rep.enabled, rep.detected || rep.installed else { continue }
            let role = AgentRoles.role(for: p)
            let tier = role.maxTier
                ?? PlatformCapability.effectiveTier(for: p, history: history)
            let tierMark = role.maxTier == nil
                ? Ansi.dim(tier.displayName + "（学的）") : tier.displayName
            let muted = AgentRoles.isMuted(p)
            let name = muted ? Ansi.dim(rep.agentName + "（本机静音）") : rep.agentName
            // 留白要显示出来 —— 配了看不见等于没配，
            // 而「为什么这个平台老是不被选中」正是最难查的那类问题。
            let resv = role.reserveFraction.map { Format.percent($0) }
                ?? Ansi.dim(Format.percent(WorkScheduler().humanReserve) + "*")
            let dispatcher = AgentRoles.isDispatcher(p)
            let name2 = dispatcher ? Ansi.cyan(rep.agentName + "（指挥）") : name
            print(pad(role.title, 12) + pad(name2, 24)
                + pad(role.maxRisk.displayName, 12) + pad(tierMark, 12)
                + pad(resv, 8)
                + Ansi.dim(role.prefers.map(\.displayName).joined(separator: "/")))
            if muted, let why = role.muteReason {
                print(Ansi.yellow("            本机不派活给它：") + Ansi.dim(why))
            } else if muted {
                print(Ansi.yellow("            本机不派活给它"))
            }
            if !role.note.isEmpty { print(Ansi.dim("            " + role.note)) }
        }
        print("\n" + Ansi.dim("改：llmq runner roles --set qwen --risk normal --title 主力"))
        print(Ansi.dim("本机不派活给某个：--set claude --mute-here --reason \"这台的 Claude 是控制面\""))
        print(Ansi.dim("难度上限写 auto 表示交回给学习器"))

    case "set":
        let rest = Array(args.dropFirst())
        guard rest.count >= 1, let p = Platform(rawValue: rest[0]) else {
            print("用法：llmq runner set <平台> [模型]   不给模型表示恢复该 CLI 的默认")
            print("可选平台：" + Platform.allCases.map(\.rawValue).joined(separator: " "))
            exit(2)
        }
        let model = rest.count >= 2 ? rest[1] : nil
        let avail = RunnerConfigStore.availableModels(for: p)
        if let model, !avail.isEmpty, !avail.contains(model) {
            print(Ansi.red("\(p.displayName) 的 CLI 里没有 \(model) 这个模型"))
            print(Ansi.dim("可选：" + avail.joined(separator: "、")))
            exit(1)
        }
        _ = try RunnerConfigStore.setModel(model, for: p)
        print(model == nil
            ? Ansi.green("\(p.displayName) 已恢复为 CLI 默认模型")
            : Ansi.green("\(p.displayName) 固定用 ") + model!)
    case "list":
        let cfg = RunnerConfigStore.load()
        print(Ansi.dim(pad("平台", 10) + pad("执行器", 8) + pad("能改文件", 10) + "模型"))
        for r in RunnerRegistry.reasoning {
            let m = cfg.model(for: r.platform)
            print(pad(r.platform.displayName, 10) + pad(r.binaryName, 8)
                + pad(r.canEdit ? "是" : Ansi.dim("否"), 10)
                + (m.map { Ansi.cyan($0) } ?? Ansi.dim("（CLI 默认）")))
        }
        let avail = RunnerConfigStore.availableModels(for: .qwen)
        if !avail.isEmpty {
            print("\n" + Ansi.dim("Qwen CLI 里可选的模型："))
            print(Ansi.dim("  " + avail.joined(separator: "  ")))
        }
    default:
        print("用法：llmq runner [list|set]")
        exit(2)
    }
}

func cmdRepo(_ args: [String]) throws {
    switch args.first ?? "list" {
    case "add":
        let positional = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard positional.count >= 2 else {
            print("用法：llmq repo add <别名> <路径> [--default]")
            print("      llmq repo verify <别名> \"<命令>\"   登记提交前的验证命令")
            exit(2)
        }
        let e = try RepoRegistry.add(
            alias: positional[positional.startIndex],
            path: positional[positional.index(after: positional.startIndex)],
            makeDefault: args.contains("--default"))
        print(Ansi.green("已登记 ") + e.alias + Ansi.dim("  " + e.path)
            + (e.isDefault ? Ansi.cyan("  [默认]") : ""))

    case "bootstrap-game":
        guard args.count >= 3,
              let ownerFlag = args.firstIndex(of: "--owner"), ownerFlag + 1 < args.count,
              let owner = Platform(rawValue: args[ownerFlag + 1]) else {
            print("用法：llmq repo bootstrap-game <别名> <路径> --owner <平台> [--default]")
            print(Ansi.dim("  创建缺失的游戏契约并登记负责人；已有文件绝不覆盖。"))
            exit(2)
        }
        let result = try GameProjectBootstrap.apply(
            alias: args[1], path: args[2], owner: owner,
            makeDefault: args.contains("--default"))
        print(Ansi.green("游戏项目已初始化：") + result.repo.alias)
        print("  实现负责人  " + owner.displayName)
        print("  质量契约    " + (result.repo.qualityContract ?? "—"))
        if !result.created.isEmpty {
            print("  新建          " + result.created.joined(separator: "、"))
        }
        if !result.preserved.isEmpty {
            print(Ansi.dim("  保留已有文件  " + result.preserved.joined(separator: "、")))
        }
        print(Ansi.yellow("  首次派活前：补全 AGENTS.md、BENCHMARK.md 的“待填写”，"
            + "并登记真实构建命令。"))
        print(Ansi.dim("  llmq repo verify \(result.repo.alias) \"<构建 && 测试命令>\""))
        return

    case "contract-init":
        guard args.count >= 2 else {
            print("用法：llmq repo contract-init <别名|路径> [--profile game|app|service|media|generic]")
            print(Ansi.dim("  只补 .llmq/project-contract.json；已有契约绝不覆盖。"))
            exit(2)
        }
        let target = args[1]
        let repo = RepoRegistry.all().first(where: { $0.alias == target })?.localPath
            ?? NSString(string: target).expandingTildeInPath
        let profile: String
        if let i = args.firstIndex(of: "--profile"), i + 1 < args.count {
            profile = args[i + 1]
        } else {
            profile = "generic"
        }
        guard ["game", "app", "service", "media", "generic"].contains(profile) else {
            print(Ansi.red("未知 Profile：\(profile)")); exit(2)
        }
        switch try ProjectContractBootstrap.apply(repo: repo, profile: profile) {
        case .created(let path):
            print(Ansi.green("已创建项目契约骨架：") + path)
            print(Ansi.yellow("  现在运行 doctor，按报告补目标、路线、验收条款和黄金样板。"))
        case .preserved(let path):
            print(Ansi.dim("已有项目契约，未覆盖：") + path)
        }
        return
    // llmq repo verify <别名> "<命令>" [--timeout 秒]
    // llmq repo focus <别名> [off] —— 标「持续推进」的仓库,队列空了才续活。
    // 老板 2026-08-23:「我们应该专注于项目去派活」「不要瞎续活」。
    // 同时只有一个仓库被 focus:开一个就把别的关掉,不会几个项目一起乱续。
    case "focus":
        var all = RepoRegistry.all()
        let pos = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard let alias = pos.first else {
            let on = all.filter(\.autoRefill).map(\.alias)
            print(on.isEmpty ? "当前没有专注的项目（队列空了不会自动续活）"
                  : "当前专注：" + on.joined(separator: "、"))
            print(Ansi.dim("  开：llmq repo focus <别名>    关：llmq repo focus <别名> off"))
            return
        }
        guard let i = all.firstIndex(where: { $0.alias == alias }) else {
            print(Ansi.red("没有登记过别名 \(alias)")); exit(1)
        }
        let turnOff = pos.contains("off")
        if turnOff {
            all[i].autoRefill = false
            print(Ansi.green("已取消专注 ") + alias + Ansi.dim("  队列空了不再自动续活"))
        } else {
            for j in all.indices { all[j].autoRefill = (j == i) }  // 只留这一个
            print(Ansi.green("已专注 ") + alias
                + Ansi.dim("  队列空了会按它的 PLAN.md 续活；其它项目空着不动"))
        }
        try RepoRegistry.save(all)
        return

    case "owner":
        var all = RepoRegistry.all()
        let pos = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard let alias = pos.first else {
            for r in all where r.implementationOwner != nil {
                print("\(r.alias)：\(r.implementationOwner!.displayName)")
            }
            print(Ansi.dim("  设置：llmq repo owner <别名> <平台>   清除：末尾写 off"))
            return
        }
        guard let i = all.firstIndex(where: { $0.alias == alias }) else {
            print(Ansi.red("没有登记过别名 \(alias)")); exit(1)
        }
        guard pos.count >= 2 else {
            let current = all[i].implementationOwner?.displayName ?? "未固定"
            print("\(alias)：\(current)")
            return
        }
        let value = pos[pos.index(after: pos.startIndex)]
        if value == "off" {
            all[i].implementationOwner = nil
            try RepoRegistry.save(all)
            print(Ansi.green("已取消 \(alias) 的固定实现负责人"))
            return
        }
        guard let platform = Platform(rawValue: value) else {
            print(Ansi.red("未知平台 \(value)"))
            print(Ansi.dim("可选：" + Platform.allCases.map(\.rawValue).joined(separator: " ")))
            exit(2)
        }
        all[i].implementationOwner = platform
        try RepoRegistry.save(all)
        print(Ansi.green("已固定 \(alias) 的功能实现负责人：") + platform.displayName
            + Ansi.dim("（审核、媒体和看效果仍交给专用 agent）"))
        return

    case "quality":
        var all = RepoRegistry.all()
        let pos = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard let alias = pos.first,
              let i = all.firstIndex(where: { $0.alias == alias }) else {
            print("用法：llmq repo quality <别名> <相对路径|off>")
            exit(2)
        }
        guard pos.count >= 2 else {
            print("\(alias)：\(all[i].qualityContract ?? "未配置")")
            return
        }
        let value = String(pos[pos.index(after: pos.startIndex)])
        if value == "off" {
            all[i].qualityContract = nil
        } else {
            guard !value.hasPrefix("/"), !value.contains("..") else {
                print(Ansi.red("质量契约必须是仓库内的相对路径")); exit(2)
            }
            let file = URL(fileURLWithPath: all[i].localPath).appendingPathComponent(value).path
            guard FileManager.default.fileExists(atPath: file) else {
                print(Ansi.red("文件不存在：\(file)")); exit(1)
            }
            all[i].qualityContract = value
        }
        try RepoRegistry.save(all)
        print(value == "off" ? Ansi.green("已清除 \(alias) 的质量契约")
              : Ansi.green("已登记 \(alias) 的质量契约：") + value)
        return

    case "doctor":
        guard args.count >= 2 else {
            print("用法：llmq repo doctor <别名|路径> [--json]")
            print(Ansi.dim("  在派批量任务前检查目标、参考物、生产路线、验收条款和黄金样板。"))
            exit(2)
        }
        let target = args[1]
        let repo = RepoRegistry.all().first(where: { $0.alias == target })?.localPath
            ?? NSString(string: target).expandingTildeInPath
        let report = ProjectDoctor.inspect(repo: repo)
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(report)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            print(Ansi.bold("项目契约检查") + Ansi.dim("  " + report.repo))
            print("  契约  " + report.contractFile)
            if report.issues.isEmpty {
                print(Ansi.green("  ✓ 可以开始生产：目标、路线和验收覆盖完整"))
            } else {
                for issue in report.issues {
                    let mark: String
                    switch issue.severity {
                    case .error: mark = Ansi.red("✗")
                    case .warning: mark = Ansi.yellow("!")
                    case .info: mark = Ansi.cyan("i")
                    }
                    let file = issue.file.map { Ansi.dim("  [\($0)]") } ?? ""
                    print("  \(mark) \(issue.message)" + file)
                    print(Ansi.dim("    " + issue.code))
                }
                let errors = report.issues.filter { $0.severity == .error }.count
                let warnings = report.issues.filter { $0.severity == .warning }.count
                print("\n  " + (report.canStartProduction
                    ? Ansi.yellow("可继续试验，但有 \(warnings) 条警告")
                    : Ansi.red("不能进入批量生产：\(errors) 个错误，\(warnings) 条警告")))
            }
        }
        if !report.canStartProduction { exit(1) }
        return

    case "verify":
        let pos = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard pos.count >= 2 else {
            print("""
            用法：llmq repo verify <别名> "<命令>" [--timeout 秒]

            这条命令在 agent 改完之后、提交之前，在它的工作区里跑一次。
            不过就不提交，任务判失败，改动留在工作区里供人看或接力。

            例：llmq repo verify llmq "swift build && swift test"
                llmq repo verify llmq ""            清掉，不再验证
            """)
            exit(2)
        }
        var all = RepoRegistry.all()
        let alias = pos[pos.startIndex]
        let cmd = pos[pos.index(after: pos.startIndex)]
        guard let i = all.firstIndex(where: { $0.alias == alias }) else {
            print(Ansi.red("没有登记过别名 \(alias)")); exit(1)
        }
        all[i].verifyCommand = cmd.isEmpty ? nil : cmd
        if let t = args.firstIndex(of: "--timeout"), t + 1 < args.count,
           let secs = Int(args[t + 1]) { all[i].verifyTimeout = secs }
        try RepoRegistry.save(all)
        print(cmd.isEmpty ? Ansi.green("已清掉 \(alias) 的验证命令")
              : Ansi.green("已登记 ") + alias + Ansi.dim("  " + cmd
                  + "（上限 \(all[i].verifyTimeout) 秒）"))

    case "list":
        let list = RepoRegistry.all()
        if list.isEmpty {
            print(Ansi.dim("还没登记仓库。llmq repo add <别名> <路径> --default"))
            print(Ansi.dim("从手机派任务时只需要写别名，不用写完整路径。"))
            return
        }
        // 顺手校验路径。
        //
        // 别名是**跨机**用的：手机或另一台机器派活时只写别名，
        // 路径解析在接活那台本地做。于是很容易出现「别名登记了、
        // 那台机器上却没有这个目录」—— 而这个错误直到任务真的派过去、
        // 建工作区失败才暴露，报的还是含糊的「工作区创建失败」。
        // 实际就这么踩过一次：跨机链路全部打通之后，任务派过去必失败。
        var broken = 0
        for r in list {
            let p = NSString(string: r.localPath).expandingTildeInPath
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            let isGit = FileManager.default.fileExists(atPath: p + "/.git")
            let note: String
            if !exists || !isDir.boolValue { note = Ansi.red("  ✗ 目录不存在"); broken += 1 }
            else if !isGit { note = Ansi.yellow("  ⚠ 不是 git 仓库"); broken += 1 }
            else { note = "" }
            print(pad(r.alias, 16) + pad(r.isDefault ? Ansi.cyan("默认") : "", 8)
                + Ansi.dim(r.localPath.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                + (r.implementationOwner.map { Ansi.cyan("  负责人:" + $0.displayName) } ?? "")
                + (r.qualityContract.map { Ansi.dim("  质量:" + $0) } ?? "")
                + note)
        }
        if broken > 0 {
            print(Ansi.dim("\n有问题的别名派活时会失败（报「工作区创建失败」）。"
                + "改路径：llmq repo add <别名> <新路径>"))
        }
    default:
        print("用法：llmq repo [add|bootstrap-game|contract-init|doctor|list|focus|verify|owner|quality]")
        exit(2)
    }
}

func cmdMachines() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func short(_ p: String) -> String { p.replacingOccurrences(of: home, with: "~") }

    print(Ansi.bold("本机"))
    print("  名称      " + Paths.machineName())
    print("  机器 ID   " + Ansi.dim(Paths.machineID()))

    print("\n" + Ansi.bold("共享通道") + Ansi.dim("（本地暂存，由菜单栏 App 镜像到 iCloud）"))
    if let snapDir = Paths.iCloudSnapshotsDir {
        let probe = snapDir.appendingPathComponent(".llmq-probe")
        try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let writable = (try? Data().write(to: probe)) != nil
        try? FileManager.default.removeItem(at: probe)
        print("  快照      " + short(snapDir.path) + "  "
            + (writable ? Ansi.green("可写") : Ansi.red("不可写")))
    } else {
        print("  快照      " + Ansi.red("共享暂存不可用 —— 多机汇总没法工作"))
    }
    printMirrorHealth(indent: "  ")
    if let cfgDir = Paths.iCloudConfigDir {
        let hasPlans = FileManager.default.fileExists(
            atPath: cfgDir.appendingPathComponent("plans.json").path)
        print("  配置      " + short(cfgDir.path) + "  "
            + (hasPlans ? Ansi.green("已共享") : Ansi.yellow("尚未生成")))
    }

    let dash = LLMQuota.dashboard()
    print("\n" + Ansi.bold("已接入的电脑") + Ansi.dim("  共 \(dash.machines.count) 台"))
    if dash.machines.count <= 1 {
        print(Ansi.dim("  只有本机。在另一台电脑上装好并跑一次 llmq collect 即可，"))
        print(Ansi.dim("  不需要任何注册步骤 —— iCloud 同步过来就自动出现在这里。"))
    }
    for m in dash.machines {
        let mark = m.isStale ? Ansi.yellow("○") : Ansi.green("●")
        let self_ = m.machineID == Paths.machineID() ? Ansi.dim("（本机）") : ""
        print("  \(mark) " + pad(m.machineName + self_, 30)
            + Ansi.dim("更新于 " + Format.relative(m.lastSeen, now: dash.generatedAt)))
    }

    print("\n" + Ansi.bold("在新电脑上接入"))
    print("  1. 拷贝或 clone 这个仓库过去")
    print("  2. ./build-app.sh --install")
    print("  3. llmq collect")
    print(Ansi.dim("  额度上限和冷却状态是账号级的，会从 iCloud 自动继承，不用重填。"))
    print(Ansi.dim("  确认同一个 Apple ID、且 iCloud Drive 已开启。"))
}

func cmdSecurity() throws {
    let findings = SecurityAudit.run()
    print(Ansi.bold("暴露面审计") + Ansi.dim(" · " + Paths.machineName()))

    func tag(_ s: SecurityAudit.Severity) -> String {
        switch s {
        case .critical: return Ansi.red("严重")
        case .warning: return Ansi.yellow("注意")
        case .info: return Ansi.dim("提示")
        case .ok: return Ansi.green("正常")
        }
    }

    for f in findings {
        print("\n" + tag(f.severity) + "  " + Ansi.bold(f.area))
        print("  " + f.detail)
        if let fix = f.fix { print(Ansi.dim("  → " + fix)) }
    }

    let crit = findings.filter { $0.severity == .critical }.count
    let warn = findings.filter { $0.severity == .warning }.count
    print("\n" + Ansi.dim("共 \(crit) 项严重 / \(warn) 项注意"))
    print(Ansi.dim("设计前提：本工具只允许开一个端口 —— llmq cluster serve 的双向 mTLS 口，"
                   + "且认证过的对端只能投任务，不能执行任意命令。"))
    print(Ansi.dim("详见 SECURITY.md。"))
    if crit > 0 { exit(1) }
}

/// 磁盘上的角色配置和代码里的默认值哪些不一样。
///
/// 这是个真咬过人的坑：把 volcark 从「新人」升成「审查员」改在了
/// `AgentRoles.defaults()` 里，而磁盘上存着一份旧 roles.json ——
/// 保存的配置永远盖过默认值，于是升级**一整天没生效**，
/// 它继续以「新人·只接低危」的身份被排除在所有常规任务之外，
/// 而排除理由还理直气壮地写着「新人最多只接低危的活」。
///
/// 覆盖本身是对的（人调过的设置不该被升级冲掉），错的是**没人告诉你**
/// 它在覆盖什么。所以 doctor 把差异列出来：改默认值没生效时一眼看见。
func roleDrift() -> [String] {
    let saved = AgentRoles.all()
    var out: [String] = []
    for d in AgentRoles.defaults() {
        guard let s = saved[d.platform] else { continue }
        var diffs: [String] = []
        if s.title != d.title { diffs.append("岗位 \(s.title)≠默认 \(d.title)") }
        if s.maxRisk != d.maxRisk {
            diffs.append("风险上限 \(s.maxRisk.displayName)≠默认 \(d.maxRisk.displayName)")
        }
        if !diffs.isEmpty {
            out.append(d.platform.displayName + "：" + diffs.joined(separator: "、"))
        }
    }
    return out
}

func cmdDoctor(tidy: Bool = false) throws {
    if tidy {
        let d = Debris.scan(root: Inbox.root)
        guard !d.isEmpty else { print(Ansi.green("iCloud 上没有半成品文件")); return }
        print("要删 \(d.files.count) 个半成品文件（\(d.sizeText)）…")
        let r = Debris.remove(d.files)
        print(Ansi.green("删了 \(r.removed) 个")
            + (r.failed > 0 ? Ansi.yellow("，\(r.failed) 个没删掉（iCloud 没响应，下次再试）") : ""))
        // 删完复查 —— 「执行了」不等于「删掉了」。
        let after = Debris.scan(root: Inbox.root)
        print(after.isEmpty ? Ansi.dim("  复查：干净了")
                            : Ansi.yellow("  复查：还剩 \(after.files.count) 个"))
        return
    }

    // **共享暂存有没有人在往 iCloud 搬。**
    //
    // CLI 自己不碰 iCloud 了（launchd 下会永久挂起），只写本地暂存；
    // 搬运靠菜单栏 App 的镜像。App 不在跑的话，这台机器看起来一切正常 ——
    // 采集成功、快照落盘、任务照跑 —— 但数据一个字节都没出本机。
    print(Ansi.bold("iCloud 镜像"))
    printMirrorHealth(indent: "  ")
    print("")

    // 降级过的安全设置要**主动报**，不能等人去翻文件。
    // 一个静默变弱的系统，看起来和没变弱的一模一样。
    let onDisk = ClusterNet.Passphrase.nodesWithPassphraseOnDisk()
    if !onDisk.isEmpty {
        print(Ansi.yellow("⚠ 集群口令在磁盘上：") + onDisk.joined(separator: " "))
        print(Ansi.dim("  钥匙串写不进去时的退路（0600）。弱在：拿到 "
                       + "Application Support 备份的人就拿到了可用身份。"))
        print(Ansi.dim("  想收回钥匙串，在那台机器上**本地**跑（SSH 里不行，"
                       + "登录钥匙串是锁着的）："))
        // **把完整命令打出来，别让人自己拼。**
        //
        // 原来只说「跑一次 llmq cluster import」，路径要靠人现想 ——
        // 而这条命令曾经会在「源路径等于目标路径」时把身份文件删掉，
        // 真的删过两次。那个坑已经填了，但让工具自己吐出正确的一行仍然更稳：
        // 少一次抄错的机会，也少一次替人拼错的机会。
        for n in onDisk {
            let p12 = ClusterCA.dir.appendingPathComponent("\(n).p12").path
            print("    llmq cluster import \(n) '\(p12)' '\(ClusterCA.caCert.path)'")
            print(Ansi.dim("    （口令：cat '"
                           + ClusterNet.Passphrase.fallbackFile(node: n).path + "'）"))
        }
        print("")
    }
    // 常驻 worker 够不够得着这些仓库。
    //
    // 这一条是拿六小时换来的。`~/Documents`、`~/Desktop`、`~/Downloads`
    // 在 macOS 上有访问闸门，而 launchd 起的常驻进程没有终端的授权上下文。
    // 关键在于**它不报错，它挂起**：git 100% 的采样停在
    // `init_git → strbuf_getcwd → open()`，连命令都没分发，直到被超时杀掉。
    // 于是现象是「同一个二进制、同一个仓库，我手敲 7 毫秒，worker 跑满 45 秒」，
    // 而我在 shell 里怎么复现都复现不出来 —— 终端早就有授权了。
    // 判定实验：把仓库换到 ~/dev 下，同一个 worker 90 秒内跑完并提交。
    //
    // 拒绝会立刻返回 EPERM，待决的同意才是无限期阻塞 ——
    // 「权限看起来是给了的」不能用来排除它。
    let guarded = ["Documents", "Desktop", "Downloads"]
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    let workerInstalled = FileManager.default.fileExists(
        atPath: homeDir + "/Library/LaunchAgents/com.llmquotabar.worker.plist")
    if workerInstalled {
        // 用 `localPath` 而不是 `path`。
        //
        // 路径是按机器记的，全局那个 `path` 只是别的机器留下的兜底。
        // 第一版这里读了 `path`，结果**恰好漏掉了本机真正出事的那个仓库**，
        // 只报了另一个 —— 一条查了但查错地方的检查，比没有这条检查更糟，
        // 因为它给的是假的安心。
        let risky = RepoRegistry.all().filter { e in
            let p = URL(fileURLWithPath: e.localPath).standardizedFileURL.path
            return guarded.contains { p.hasPrefix(homeDir + "/" + $0 + "/") }
        }
        if !risky.isEmpty {
            print(Ansi.yellow("⚠ 常驻 worker 可能够不着这些仓库"))
            for e in risky { print(Ansi.dim("    \(e.alias)  \(e.localPath)")) }
            print(Ansi.dim("  它们在受保护目录下（Documents / Desktop / Downloads），"
                + "而 worker 是 launchd 起的、没有你终端的授权上下文。"))
            print(Ansi.dim("  症状不是报错而是**卡住**：任务停在「建 worktree 失败：超时」。"))
            print(Ansi.dim("  两条路，任选其一："))
            print(Ansi.dim("    1) 把仓库挪到不受保护的位置，比如 ~/dev/"))
            print(Ansi.dim("    2) 系统设置 → 隐私与安全性 → 完全磁盘访问权限，"
                + "把下面这个可执行文件加进去，然后重启 worker："))
            // 印**解析后的绝对路径**。要人去系统设置里「添加这个文件」，
            // 结果给一个 argv[0]（很可能就是裸的 "llmq"）等于什么都没说。
            let argv0 = CommandLine.arguments.first ?? "llmq"
            let exePath: String = {
                if argv0.hasPrefix("/") { return argv0 }
                let which = Proc.run("/usr/bin/which", ["llmq"], cwd: homeDir,
                                     env: [:], timeout: 5)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !which.isEmpty { return which }
                return homeDir + "/.local/bin/llmq"
            }()
            // 符号链接要跟到底 —— 授权认的是真实文件，不是链接。
            let real = (try? FileManager.default
                .destinationOfSymbolicLink(atPath: exePath)) ?? exePath
            let resolved = real.hasPrefix("/") ? real
                : URL(fileURLWithPath: exePath).deletingLastPathComponent()
                    .appendingPathComponent(real).standardizedFileURL.path
            print("       " + resolved)
            print("       launchctl kickstart -k gui/$(id -u)/com.llmquotabar.worker")
            print("")
        }
    }

    // **我们自己留在 iCloud 上的半成品。**
    //
    // 原子写是「写临时文件 + rename」，而 iCloud 上的 rename 可以永久阻塞 ——
    // 于是临时文件留下、rename 永不返回。一天攒了 166 个、21MB，一直同步到手机。
    // 阻塞那个根因已经用看门狗兜住，这条检查留着是为了证伪「理论上不该再有」。
    let debris = Debris.scan(root: Inbox.root)
    if !debris.isEmpty {
        print(Ansi.yellow("⚠ iCloud 上有 \(debris.files.count) 个半成品文件（\(debris.sizeText)）"))
        print(Ansi.dim("  这是原子写卡在 rename 留下的，不是你的数据，删掉安全。"))
        if let n = debris.newest {
            let mins = Int(Date().timeIntervalSince(n) / 60)
            print(Ansi.dim("  最新的一个是 \(mins) 分钟前留下的"
                + (mins < 60 ? " —— **还在产生新的，说明阻塞还在发生**" : "（已经不再增加）")))
        }
        print(Ansi.dim("  清掉：llmq doctor --tidy"))
        print("")
    }
    if debris.incomplete {
        print(Ansi.yellow("⚠ 扫半成品时有目录读不动（iCloud 没响应），上面的数字可能不全"))
        print("")
    }

    // **把「自动调度不跨机器」这条规则明写出来。**
    //
    // 它一直是这样的，但从来没在任何地方说过 —— 于是每次有人问
    // 「会不会派到另一台去」都得去翻代码。而这条规则撑着一个很实际的
    // 好处：每台机器的开发目录可以放在它自己喜欢的地方
    //（`RepoAlias.pathByMachine` 就是干这个的）。
    // 一旦自动调度跨机，路径就必须两边一致，这个自由立刻没了。
    let peers = ClusterPresenceStore.all().filter { $0.machineID != Paths.machineID() }
    // **损坏的任务记录要报出来。**
    //
    // tasks.jsonl 是 append-only，而写它的进程今天被杀过很多次
    //（超时、发布重启、机器崩了十小时）。写到一半被杀就留下半行，
    // 那条任务从此不存在 —— 而它的下游会永远等一个不会到来的上游，
    // 从外面看是「图卡住了」，查不出任何原因。
    let all = TaskStore.all()
    if TaskStore.skippedLines > 0 {
        print(Ansi.red("⚠ 任务记录里有 \(TaskStore.skippedLines) 行解不出来"))
        print(Ansi.dim("  这些任务已经不存在了。如果某张图卡住、下游一直等着，多半就是它。"))
        print(Ansi.dim("  文件：" + TaskStore.file.path))
        print(Ansi.dim("  半行通常来自「写到一半进程被杀」，多数情况下删掉那几行就行。"))
        print("")
    }
    _ = all

    // **worker 跑的是不是你刚发布的那份二进制。**
    //
    // 今天真出过：我把 worker 的 plist 指向 app bundle 里的一份 llmq，
    // 而 `llmq release publish` 只更新 ~/.local/bin/llmq —— 两份从此分道扬镳。
    // worker 安静地跑了几小时旧代码（我一直以为发布生效了），
    // 最后那个文件不见了，它直接以 EX_CONFIG(78) 退出，队列停了 80 分钟。
    //
    // 症状是最难查的那种：**发布成功、测试全绿、worker「在跑」，但行为是旧的。**
    if let plist = try? Data(contentsOf: FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.llmquotabar.worker.plist")),
       let obj = try? PropertyListSerialization.propertyList(from: plist, format: nil)
        as? [String: Any],
       let args = obj["ProgramArguments"] as? [String], let exe = args.first {
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/llmq").path
        if !FileManager.default.fileExists(atPath: exe) {
            print(Ansi.red("⚠ worker 要跑的二进制不存在：") + exe)
            print(Ansi.dim("  launchd 会以 EX_CONFIG(78) 退出，而且**不写任何日志** ——"))
            print(Ansi.dim("  从外面看就是「队列不动了」。改回：" + installed))
            print("")
        } else if exe != installed {
            print(Ansi.yellow("⚠ worker 跑的不是发布装上的那份二进制"))
            print(Ansi.dim("  它在跑：" + exe))
            print(Ansi.dim("  发布装的：" + installed))
            print(Ansi.dim("  llmq release publish 只更新后者 —— 前者会一直是旧代码，"
                + "而且没有任何提示。"))
            print("")
        }
    }

    // **手机上的任务列表是从这些文件拼出来的。**
    //
    // 以前任务是塞在 dashboard.json 里发的，而那个文件只有一份、每台机器
    // 都往里写 —— 手机上永远只看得到最后一台采集完的机器的活。
    // 现在一台一个文件，手机读的时候合并。这里报两件事：
    // 看到了几台，以及各自多久没更新（太旧的板子里那些 running 多半早死了）。
    print(Ansi.bold("手机任务板"))
    let boards = TaskBoardStore.loadAll()
    if boards.directoryStalled {
        print(Ansi.red("  ⚠ taskboards/ 目录读不动（iCloud 没响应）"))
        print(Ansi.dim("    这**不代表**没有任务板 —— 这一轮就是没看到，两回事。"))
    } else if boards.directoryMissing {
        print(Ansi.dim("  还没有 taskboards/ 目录 —— 跑一次 llmq collect 就会建出来"))
        print(Ansi.dim("  （老版本手机读 dashboard.json 里的 tasks，那条路一直在，没断）"))
    } else if boards.boards.isEmpty && boards.unreadable.isEmpty {
        print(Ansi.dim("  目录是空的：一台机器都还没发过任务板"))
    } else {
        for b in boards.boards {
            let age = Date().timeIntervalSince(b.generatedAt)
            let stale = age > TaskBoardStore.staleAfter
            let when = Format.relative(b.generatedAt)
            let count = "\(b.tasks.count) 个任务" + (b.tasksTruncated ? "（已截断）" : "")
            print("  " + pad(b.machineName.isEmpty ? b.machineID : b.machineName, 24)
                + pad(count, 18)
                + (stale ? Ansi.yellow(when + "  ← 超过 30 分钟没更新") : Ansi.green(when)))
        }
        if boards.boards.contains(where: {
            Date().timeIntervalSince($0.generatedAt) > TaskBoardStore.staleAfter
        }) {
            print(Ansi.dim("  标黄的那些：采集是 15 分钟一轮，两轮没到了。"
                + "手机会把它们的任务显示成「那台机器 N 分钟前的状态」，不混进「正在干」。"))
        }
    }
    if !boards.unreadable.isEmpty {
        print(Ansi.yellow("  ⚠ \(boards.unreadable.count) 份任务板读不出来："
            + boards.unreadable.prefix(3).joined(separator: " ")))
        print(Ansi.dim("    读不动 ≠ 那台机器没有任务。清理不会碰它们（只删确定是旧的）。"))
    }
    print("")

    // 角色配置漂移：改了代码默认值但被磁盘配置盖住时点名，
    // 否则「升级了却没生效」只能靠人偶然发现（真发生过，一整天）。
    let drift = roleDrift()
    if !drift.isEmpty {
        print(Ansi.bold("角色配置") + Ansi.dim("（磁盘上存的盖过代码默认值）"))
        for d in drift { print(Ansi.yellow("  ⚠︎ ") + d) }
        print(Ansi.dim("  人调过的设置不该被升级冲掉，所以覆盖是对的 —— "
                       + "但改了默认值没生效时得看得见。"))
        print(Ansi.dim("  要用新默认值：删掉 shared/config/roles.json 里对应那条。"))
    }

    print(Ansi.bold("调度范围"))
    print("  自动调度" + Ansi.green("只在本机") + "选平台，"
        + Ansi.dim("从不把任务派到别的机器"))
    print(Ansi.dim("  所以每台机器的仓库可以各放各的位置（别名按机器解析成本地路径）"))
    if peers.isEmpty {
        print(Ansi.dim("  跨机要手动：llmq cluster dispatch <对方节点> \"<任务>\""))
    } else {
        print(Ansi.dim("  跨机要手动，比如："))
        for p in peers.prefix(2) {
            print(Ansi.dim("    llmq cluster dispatch \(p.nodeName ?? p.machineName) \"<任务>\""))
        }
        print(Ansi.dim("  它在对面按**别名**重新解析路径，不会把本机路径发过去"))
    }
    print("")

    print(Ansi.bold("数据源探测"))
    print(Ansi.dim(pad("采集器", 34) + pad("平台", 12) + pad("状态", 16)
        + pad("已验证", 10) + "路径"))

    for a in AdapterRegistry.all {
        let installed = a.isInstalled
        let files = installed ? a.discoverFiles().count : 0
        let status = installed ? Ansi.green("已安装 \(files) 文件") : Ansi.dim("未检测到")
        let verified = a.verified ? Ansi.green("是") : Ansi.yellow("否")
        print(pad(a.displayName, 34) + pad(a.homePlatform.displayName, 12)
            + pad(status, 16) + pad(verified, 10)
            + Ansi.dim(a.roots.joined(separator: " ")))
    }

    print("\n" + Ansi.bold("路径"))
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func short(_ p: String) -> String { p.replacingOccurrences(of: home, with: "~") }
    print("  配置      " + short(Paths.plansFile.path))
    print("  缓存      " + short(Paths.cacheDir.path))
    print("  本地快照  " + short(Paths.localSnapshotsDir.path))
    if let icloud = Paths.iCloudSnapshotsDir {
        // 共享暂存是本地目录，CLI 不再直接碰 iCloud；搬运看镜像心跳。
        let probe = icloud.appendingPathComponent(".llmq-write-probe")
        let writable = (try? Data().write(to: probe)) != nil
        try? FileManager.default.removeItem(at: probe)
        print("  共享暂存  " + short(icloud.path) + "  "
            + (writable ? Ansi.green("可写") : Ansi.yellow("不可写")))
    } else {
        print("  共享暂存  " + Ansi.yellow("不可用（多机汇总会失效）"))
    }
    print("  本机      \(Paths.machineName())")

    print("\n" + Ansi.bold("3D 资源"))
    for d in DashboardHTML.resourceDiagnostics() {
        if let found = d.found {
            print("  " + pad(d.file, 20) + Ansi.green("已找到 ") + Ansi.dim(short(found.path)))
        } else {
            print("  " + pad(d.file, 20) + Ansi.yellow("未找到 —— 看板会退回纯 2D"))
            for p in d.tried.prefix(3) { print(Ansi.dim("      试过 " + short(p.path))) }
        }
    }

    print("\n" + Ansi.dim(
        "标「否」的采集器是按该工具已知的目录布局写的，本机没装、没能用真实数据验证。"))
    print(Ansi.dim(
        "另外：GLM / Kimi / MiniMax / DeepSeek / 火山 若是通过改 Claude Code 或 Codex 的"))
    print(Ansi.dim(
        "BASE_URL 来用，用量会落在 ~/.claude 或 ~/.codex 里，由模型名自动归类，无需单独采集器。"))
}

/// 用指定采集器解析单个文件并打印统计。
///
/// 存在的理由：活跃的会话日志在被持续追加，拿 llmq 的汇总数字跟外部脚本对账永远对不齐 ——
/// 两边读到的字节数不一样。有了这个命令就能把文件复制一份冻结，让两边解析同一份数据，
/// 差异才有意义。调新适配器时验证解析正确性也靠它。
func cmdDebugParse(_ args: [String]) throws {
    guard args.count >= 2 else {
        print("用法：llmq debug-parse <采集器ID> <文件路径>")
        print("采集器ID：" + AdapterRegistry.all.map(\.id).joined(separator: ", "))
        exit(2)
    }
    let adapterID = args[0]
    let path = NSString(string: args[1]).expandingTildeInPath

    guard let adapter = AdapterRegistry.all.first(where: { $0.id == adapterID }) else {
        print(Ansi.red("没有叫 \(adapterID) 的采集器"))
        exit(2)
    }
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url) else {
        print(Ansi.red("读不了文件：\(path)"))
        exit(1)
    }

    let parsed = adapter.parse(file: url, data: data)
    var byPlatform: [Platform: (Int, Int, Int, Int, Int)] = [:]
    for e in parsed.events {
        var c = byPlatform[e.platform] ?? (0, 0, 0, 0, 0)
        c.0 += 1
        c.1 += e.inputTokens
        c.2 += e.outputTokens
        c.3 += e.cacheReadTokens
        c.4 += e.cacheWriteTokens
        byPlatform[e.platform] = c
    }

    print(Ansi.bold("\(adapter.displayName)") + Ansi.dim(" 解析 \(url.lastPathComponent)"
        + " · \(Format.bytes(data.count))"))
    print("事件数 \(parsed.events.count)"
        + (parsed.quotas.isEmpty ? "" : " · 官方额度 \(parsed.quotas.count) 条"))

    for (p, c) in byPlatform.sorted(by: { $0.key.sortIndex < $1.key.sortIndex }) {
        print("  " + pad(p.displayName, 12)
            + pad("\(c.0) 次", 10)
            + "input \(c.1)  output \(c.2)  cacheRead \(c.3)  cacheWrite \(c.4)")
        print("  " + pad("", 12) + Ansi.dim("billable(in+out+cacheWrite) = \(c.1 + c.2 + c.4)"))
    }
    if let last = parsed.lastEventAt {
        print(Ansi.dim("  最后事件 " + Format.dateTime(last)))
    }
}

func cmdStatus() throws {
    let dash = LLMQuota.dashboard()
    guard let top = dash.alerts.first else {
        let active = dash.reports.filter(\.detected).count
        print("LLM 额度正常 · \(active) 个平台在用")
        return
    }
    let waste = top.projectedWaste.map { Format.metricValue($0, metric: top.metric) } ?? ""
    switch top.health {
    case .wasting:
        print("\(top.platform.displayName) \(top.label)将作废 \(waste)"
            + "（\(Format.duration(top.timeToReset))后重置）")
    case .atRisk:
        print("\(top.platform.displayName) \(top.label)将超额 "
            + "\(Format.percent(top.projectedUsedFraction))")
    default:
        print("\(top.platform.displayName) \(top.label) \(top.health.displayName)")
    }
}

func cmdPlan(_ args: [String]) throws {
    let created = try PlansStore.ensureExists()
    if created { print(Ansi.green("已生成配置模板：") + Paths.plansFile.path) }

    if args.first == "edit" {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-t", Paths.plansFile.path]
        try p.run()
        return
    }

    // llmq plan calibrate <平台> <窗口id> <已用百分比>
    // 只给比例不给数字的平台(Kimi)用这条:上限 = 本窗口用量 ÷ 比例。
    if args.first == "calibrate" {
        let rest = Array(args.dropFirst())
        guard rest.count >= 3, let platform = Platform(rawValue: rest[0].lowercased()),
              let pct = Double(rest[2].replacingOccurrences(of: "%", with: "")) else {
            print("用法：llmq plan calibrate <平台> <窗口id> <已用百分比>")
            print("  例：llmq plan calibrate kimi weekly 23    （订阅页显示本周已用 23%）")
            print("  窗口 id 看 llmq plan 的输出（5h / weekly / monthly …）")
            exit(2)
        }
        let limitID = rest[1]
        var cfg = PlansStore.load()
        guard let pi = cfg.plans.firstIndex(where: { $0.platform == platform }),
              let li = cfg.plans[pi].limits.firstIndex(where: { $0.id == limitID }) else {
            print(Ansi.red("plans.json 里没有 \(platform.rawValue) 的窗口 \(limitID)")); exit(1)
        }
        let status = LLMQuota.dashboard().reports
            .first { $0.platform == platform }?
            .statuses.first { $0.limitID == limitID }
        guard let used = status?.used, used > 0 else {
            print(Ansi.red("这个窗口还没有测到用量，除不出来 —— 用一会儿再校")); exit(1)
        }
        let metric = cfg.plans[pi].limits[li].metric
        do {
            let value = try QuotaCalibration.limit(used: used, percentUsed: pct)
            cfg.plans[pi].limits[li].limit = value
            cfg.plans[pi].limits[li].hint = QuotaCalibration.provenance(
                percentUsed: pct, used: used, metric: metric)
            try PlansStore.save(cfg)
            print(Ansi.green("已校准 ") + "\(platform.displayName) \(cfg.plans[pi].limits[li].label)："
                + "上限 ≈ " + Format.metricValue(value, metric: metric)
                + Ansi.dim("（本窗口用量 " + Format.metricValue(used, metric: metric)
                    + " ÷ \(pct)%）"))
            print(Ansi.dim("  页面比例是整数，用量越大越准；过几天用量大了再校一次。"))
        } catch QuotaCalibration.Failure.percentOutOfRange {
            print(Ansi.red("百分比要在 0–100 之间")); exit(2)
        }
        return
    }

    let cfg = PlansStore.load()
    let src = PlansStore.loadedFrom()
    print(Ansi.bold("套餐配置") + Ansi.dim(" · " + (src?.path ?? "两份都读不到，用的是空模板")))
    let filled = PlansStore.load().filledLimitCount
    if filled == 0 {
        print(Ansi.yellow("一条上限都没填 —— 菜单栏因此只显示平台名，算不出剩余和作废量。"))
    }
    for plan in cfg.plans {
        print("\n" + Ansi.bold(plan.platform.displayName) + Ansi.dim(" · \(plan.planName)")
            + (plan.enabled ? "" : Ansi.dim(" [已停用]")))
        if let c = plan.monthlyCost {
            print("  月费 \(c) \(plan.currency)")
        }
        // 没配上限时把**实测下限**显示出来。
        //
        // 「未填」什么都不说，而「实测至少用到过 394 次」是硬信息：
        // 那次确实用出去了、没被拒，所以真实上限不低于它。
        // 查完各家官方文档之后（大多不公布或口径对不上），这往往是唯一的数字。
        let floors = Dictionary(
            LLMQuota.dashboard().reports
                .flatMap(\.statuses)
                .compactMap { st -> (String, Double)? in
                    guard let f = st.observedFloor else { return nil }
                    return ("\(st.platform.rawValue)|\(st.limitID)", f)
                },
            uniquingKeysWith: { a, _ in a })

        for l in plan.limits {
            let cap = l.limit.map { Format.metricValue($0, metric: l.metric) }
                ?? Ansi.yellow("未填")
            var line = "  " + pad(l.label, 8) + pad(l.kind == .periodic ? "周期" : "滚动", 6)
                + pad(l.metric.displayName, 14) + "上限 " + pad(cap, 12)
            if l.limit == nil, let f = floors["\(plan.platform.rawValue)|\(l.id)"] {
                line += Ansi.dim("实测至少 " + Format.metricValue(f, metric: l.metric))
            }
            print(line)
        }
    }
    print("\n" + Ansi.dim("用 llmq plan edit 打开编辑，把各家订阅页面上的实际上限填进 limit 字段。"))
}

/// 把工作循环装成 launchd 常驻服务。
func cmdInstallLoop() throws {
    let label = "com.llmquotabar.worker"
    guard let exe = Bundle.main.executablePath,
          FileManager.default.isExecutableFile(atPath: exe)
    else { print(Ansi.red("无法定位 llmq 路径")); exit(1) }

    let agentsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
    let plistURL = agentsDir.appendingPathComponent("\(label).plist")
    try Paths.ensureDirectories()

    // KeepAlive 让它挂了自动拉起；ThrottleInterval 防止启动失败时疯狂重启。
    // LimitLoadToSessionType=Aqua 是必须的：agent 要访问 Keychain 里的平台凭据，
    // 后台会话（Background）拿不到 GUI 会话的 Keychain 上下文。
    //
    // **AssociatedBundleIdentifiers 决定这个 job 的隐私授权算在谁头上。**
    //
    // 这是 Apple DTS（Quinn）对 launchd job 的明确建议：不设的话，系统
    // 「归属」不到一个有 bundle 身份的程序上，授权就没有稳定的落点 ——
    // 裸的命令行二进制没有 Info.plist，TCC 很难为它建立跨版本的身份。
    //
    // 而 Aqua + 归属不清的组合，症状不是报错而是**永久挂起**：
    // 内核把线程 park 在 `__WAITING_ON_APPROVAL_FROM_SANDBOXD__` 上等一个
    // 永远不会弹出来的对话框。Quinn 说过这条分界 ——
    // **没有 GUI session 就直接 EPERM，归属到 GUI app 才会一直等**，
    // 而我们恰好写了 Aqua，落在「一直等」那一支。
    // 实测就是这样：worker 卡死几小时，内核每 5 秒打一条
    // `watchdog expired for approval entry`，tccd 那边一条记录都没有。
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(label)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(exe)</string>
        <string>work</string>
        <string>loop</string>
      </array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>ThrottleInterval</key><integer>60</integer>
      <key>LimitLoadToSessionType</key><string>Aqua</string>
      <key>AssociatedBundleIdentifiers</key>
      <array><string>com.llmquotabar.menubar</string></array>
      <key>StandardOutPath</key>
      <string>\(Paths.appSupport.path)/worker.log</string>
      <key>StandardErrorPath</key>
      <string>\(Paths.appSupport.path)/worker.err.log</string>
    </dict>
    </plist>
    """
    try plist.write(to: plistURL, atomically: true, encoding: .utf8)

    _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    let out = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])

    print(Ansi.green("工作循环已装为常驻服务"))
    print("  " + plistURL.path.replacingOccurrences(
        of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
    print("  日志  ~/Library/Application Support/LLMQuotaBar/worker.log")
    if !out.isEmpty { print(Ansi.dim("  " + out)) }
    print()
    print(Ansi.yellow("装完请立刻验一次：") + "llmq work probe")
    print(Ansi.dim("  launchd 启动的进程没有你终端的上下文，平台凭据不一定拿得到。"))
    print(Ansi.dim("  停止：launchctl bootout gui/\(getuid())/\(label)"))
}

func cmdInstallAgent(interval: Int) throws {
    let label = "com.llmquotabar.collector"

    // 不能用 CommandLine.arguments[0] 推路径：从 PATH 调用时 argv[0] 只是 "llmq"，
    // 按相对路径解析会拼成当时工作目录下的一个不存在的路径，
    // launchd 加载后直接以 78（配置错误）退出，而且不留任何日志。
    // Bundle.main.executablePath 对命令行工具同样返回真实的可执行文件路径。
    guard let exe = Bundle.main.executablePath,
          FileManager.default.isExecutableFile(atPath: exe)
    else {
        print(Ansi.red("无法定位 llmq 自身的路径，定时任务未安装"))
        exit(1)
    }
    let agentsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
    let plistURL = agentsDir.appendingPathComponent("\(label).plist")

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(label)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(exe)</string>
        <string>collect</string>
      </array>
      <!-- 隐私授权的归属落点。见 worker plist 上的长注释。 -->
      <key>AssociatedBundleIdentifiers</key>
      <array><string>com.llmquotabar.menubar</string></array>
      <key>StartInterval</key><integer>\(interval)</integer>
      <key>RunAtLoad</key><true/>
      <key>StandardOutPath</key>
      <string>\(Paths.appSupport.path)/collector.log</string>
      <key>StandardErrorPath</key>
      <string>\(Paths.appSupport.path)/collector.err.log</string>
    </dict>
    </plist>
    """

    try Paths.ensureDirectories()
    try plist.write(to: plistURL, atomically: true, encoding: .utf8)

    _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
    let out = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])

    print(Ansi.green("已安装定时采集：") + "每 \(interval) 秒跑一次 llmq collect")
    print("  " + plistURL.path)
    if !out.isEmpty { print(Ansi.dim(out)) }
    print(Ansi.dim("卸载：launchctl bootout gui/\(getuid())/\(label) && rm \(plistURL.path)"))
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}


// MARK: - cluster

func cmdCluster(_ rest: [String]) throws {
    func need(_ i: Int, _ what: String) -> String {
        guard rest.count > i else {
            print(Ansi.red("缺少参数：\(what)")); exit(2)
        }
        return rest[i]
    }
    func loadConfig() -> ClusterConfig {
        guard let c = ClusterConfigStore.load() else {
            print(Ansi.red("这台机器还没配置节点。先跑：llmq cluster init <本机节点名>"))
            exit(1)
        }
        return c
    }
    /// 取本机身份的口令。存在钥匙串里，enroll 自己那张证书时放进去的。
    func myPassword(_ node: String) -> String {
        do { return try ClusterNet.Passphrase.load(node: node) } catch {
            print(Ansi.red("\(error.localizedDescription)")); exit(1)
        }
    }

    switch rest.first ?? "status" {

    // llmq cluster init <本机节点名>
    case "init":
        let node = need(1, "本机节点名，比如 mac-mini")
        let created = try ClusterCA.initialize()
        print(created ? Ansi.green("已建立集群 CA ") + Ansi.dim(ClusterCA.caCert.path)
                      : Ansi.dim("CA 已存在，沿用"))

        let pw = ClusterNet.randomPassword()
        _ = try ClusterCA.issue(node: node, password: pw)
        try ClusterNet.Passphrase.save(pw, node: node)

        var cfg = ClusterConfigStore.load() ?? ClusterConfig(nodeName: node)
        cfg.nodeName = node
        try ClusterConfigStore.save(cfg)
        print(Ansi.green("本机节点名 ") + node)
        print(Ansi.dim("下一步：给另一台机器签证书 —— llmq cluster enroll <对方节点名>"))

    // llmq cluster enroll <节点名>
    case "enroll":
        let node = need(1, "要签发的节点名")
        let pw = ClusterNet.randomPassword()
        let p12 = try ClusterCA.issue(node: node, password: pw)

        var cfg = loadConfig()
        if !cfg.allowedNodes.contains(node) { cfg.allowedNodes.append(node) }
        try ClusterConfigStore.save(cfg)

        print(Ansi.green("已签发 ") + p12.path)
        print("")
        print(Ansi.bold("把这两样分开传给那台机器：") + Ansi.dim("（别放在同一条消息里）"))
        print("  1. 文件 " + p12.path)
        print("  2. 口令 " + Ansi.bold(pw))
        print("")
        print(Ansi.dim("再把 CA 证书也带过去：") + ClusterCA.caCert.path)
        print(Ansi.dim("那台机器上跑：llmq cluster import \(node) <p12路径> <ca.crt路径>"))

    // llmq cluster import <节点名> <p12> <ca.crt>
    case "import":
        let node = need(1, "本机节点名")
        let src = URL(fileURLWithPath: NSString(string: need(2, "p12 文件路径")).expandingTildeInPath)
        let caSrc = URL(fileURLWithPath: NSString(string: need(3, "ca.crt 路径")).expandingTildeInPath)

        print("这个 p12 的口令：", terminator: "")
        guard let pw = readLine(strippingNewline: true), !pw.isEmpty else {
            print(Ansi.red("没输入口令")); exit(2)
        }
        try FileManager.default.createDirectory(
            at: ClusterCA.dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: ClusterCA.dir.path)

        // **先删后拷会吃掉文件。**
        //
        // 原来是 removeItem(dst) 然后 copyItem(src → dst)。传的源路径正好
        // 就是目标路径时（「已经在位了，我再导一次」是个很自然的动作，
        // doctor 的提示还专门叫人这么干），第一步把文件删了，
        // 第二步找不到源，抛错退出 —— 身份文件就此消失，集群直接断。
        //
        // 踩了两次：先是我自己拿目标路径当 ca.crt 的源，删掉了从机的 CA 证书；
        // 然后按同样的形式给出的命令，又删掉了从机的 p12。
        //
        // 两条改法一起上：同一个文件就别动它；不同文件也先拷到临时名再替换，
        // 这样拷贝失败时原文件还在。
        func install(_ from: URL, to dest: URL, mode: Int) throws {
            let fm = FileManager.default
            if from.resolvingSymlinksInPath().standardizedFileURL
                == dest.resolvingSymlinksInPath().standardizedFileURL {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dest.path)
                return   // 已经在位了
            }
            guard fm.fileExists(atPath: from.path) else {
                throw ClusterCA.err("找不到 \(from.path)")
            }
            let staged = dest.deletingLastPathComponent()
                .appendingPathComponent(".\(dest.lastPathComponent).new")
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: from, to: staged)
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: staged.path)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: dest)
            }
            // **权限要在替换之后再设一遍。**
            //
            // replaceItemAt 是给「保存文档」用的，它会把**原文件**的属性
            // 搬到替换进来的文件上 —— 于是 staged 上设的 0600 被原来的 0644
            // 顶掉，私钥变成所有人可读。设权限不报错，也不会有任何现象。
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: dest.path)
        }

        let dst = ClusterCA.dir.appendingPathComponent("\(node).p12")
        try install(src, to: dst, mode: 0o600)
        try install(caSrc, to: ClusterCA.caCert, mode: 0o644)

        // 先验一遍能不能真的解开，别等到连不上才发现口令抄错了。
        _ = try ClusterNet.loadIdentity(node: node, password: pw)
        try ClusterNet.Passphrase.save(pw, node: node)

        var cfg = ClusterConfigStore.load() ?? ClusterConfig(nodeName: node)
        cfg.nodeName = node
        try ClusterConfigStore.save(cfg)
        print(Ansi.green("导入成功，本机节点名 ") + node)
        // **别写死「已存进钥匙串」。**
        //
        // save 现在会在钥匙串写不进去时改为落盘，而这行照样打印
        // 「磁盘上只留加密过的 p12」—— 刚刚在 SSH 里亲眼看到它这么撒谎：
        // stderr 说口令落盘了，紧接着 stdout 说磁盘上只有 p12。
        // 结论要从**实际结果**里读，不能从「我们打算做什么」里读。
        if ClusterNet.Passphrase.nodesWithPassphraseOnDisk().contains(node) {
            print(Ansi.yellow("口令存在磁盘上 ")
                  + Ansi.dim("（钥匙串写不进去，多半是在 SSH 会话里）"
                             + "—— 本地再跑一次这条命令可以收回钥匙串"))
        } else {
            print(Ansi.dim("口令已存进钥匙串，磁盘上只留加密过的 p12"))
        }

    // llmq cluster trust <节点名>
    case "trust":
        let node = need(1, "要放行的节点名")
        var cfg = loadConfig()
        if cfg.allowedNodes.contains(node) {
            print(Ansi.dim("\(node) 已经在名单里"))
        } else {
            cfg.allowedNodes.append(node)
            try ClusterConfigStore.save(cfg)
            print(Ansi.green("已放行 ") + node)
        }

    // llmq cluster revoke <节点名>
    case "revoke":
        let node = need(1, "要撤销的节点名")
        var cfg = loadConfig()
        cfg.allowedNodes.removeAll { $0 == node }
        try ClusterConfigStore.save(cfg)
        print(Ansi.green("已撤销 ") + node)
        print(Ansi.dim("证书本身没吊销（私有 CA 没有 CRL），"
                       + "但它连不进来了。serve 要重启才生效。"))

    // llmq cluster selfcheck —— 本机自检（只读）
    //
    // 把「这台到底怎么了」一次说清楚：版本、服务、更新通道、地址、iCloud。
    // 存在的理由：排查另一台机器时我 SSH 过去挨个敲命令，
    // 结论留在了会话里、命令没留下，下次得从头摸一遍。
    case "selfcheck":
        let sc = SelfCheck.run()
        print(SelfCheck.render(sc))
        exit(sc.worst == .bad ? 1 : 0)

    // llmq cluster diagnose <节点> —— 让对面自检，把结果打回来
    //
    // **知识只写一份**（SelfCheck），这里只负责把它送过去执行。
    // 不在这边远程敲一堆命令 —— 那就又变成「跑跑就忘」了。
    case "diagnose":
        let dnode = need(1, "对端节点名")
        let dcfg = loadConfig()
        guard let daddr = dcfg.peers[dnode] else {
            print(Ansi.red("不认识节点 \(dnode)。已知：")
                + dcfg.peers.keys.sorted().joined(separator: "、"))
            exit(2)
        }
        let dhost = daddr.split(separator: ":").first.map(String.init) ?? daddr
        print(Ansi.dim("ssh \(dhost) → llmq cluster selfcheck"))
        // BatchMode：只用密钥，绝不停下来要密码。
        // 要密码就直接失败并说清楚 —— 挂在那儿等输入更糟。
        let dr = Proc.run("/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", dhost,
             "~/.local/bin/llmq cluster selfcheck"],
            cwd: NSTemporaryDirectory(), env: [:], timeout: 90)
        if dr.exitCode != 0 && dr.stdout.isEmpty {
            print(Ansi.red("连不上或跑不起来"))
            let e = dr.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            print(Ansi.dim("  " + (e.isEmpty ? "（没有错误输出）" : String(e.prefix(300)))))
            print(Ansi.dim("  需要免密钥 ssh 到 \(dhost)。要密码的话这里不会停下来问。"))
            exit(1)
        }
        print(dr.stdout)

    // llmq cluster peer <节点名> <host:port>
    case "peer":
        let node = need(1, "对端节点名")
        let addr = need(2, "对端地址 host:port")
        var cfg = loadConfig()
        cfg.peers[node] = addr
        try ClusterConfigStore.save(cfg)
        print(Ansi.green("已记下 ") + "\(node) → \(addr)")

    // llmq cluster set-bind <地址|auto> —— 换绑定地址
    case "set-bind":
        let raw = need(1, "地址，或者 auto / all")
        var cfg = loadConfig()
        switch raw {
        case "auto": cfg.bindAddress = nil
        case "all", "0.0.0.0": cfg.bindAddress = "0.0.0.0"
        default: cfg.bindAddress = raw
        }
        try ClusterConfigStore.save(cfg)
        print(Ansi.green("绑定地址 → ") + (cfg.bindAddress ?? "自动挑局域网地址"))
        if restartClusterServe() { print(Ansi.dim("已重启 cluster serve")) }
        ClusterPresenceStore.publish()

    // llmq cluster reseal <节点> —— 口令从环境变量读，重新写进钥匙串
    //
    // 只在 `ReleaseChannel.install` 里被调用，用来把口令从旧二进制交接给新的：
    // 条目的 ACL 绑创建者，必须由**新二进制自己**写这一次。
    // 口令走环境变量不走 argv —— argv 在 ps 里对所有用户可见。
    case "reseal":
        // `rest` 里含子命令本身，所以参数从 1 开始 —— 上面每个 case 都用
        // need(1,…)。写成 rest.first 会把 "reseal" 当成节点名存进钥匙串，
        // 而真正那条已经被 install 删掉了，于是跨机通信直接消失。
        // 同一个错犯第二次了（`work approve` 多写过一个 dropFirst）。
        let n = need(1, "节点名")
        guard let pw = ProcessInfo.processInfo
            .environment["LLMQ_RESEAL_PW"], !pw.isEmpty else {
            print("用法：LLMQ_RESEAL_PW=… llmq cluster reseal <节点>"); exit(2)
        }
        try? ClusterNet.Passphrase.delete(node: n)
        try ClusterNet.Passphrase.save(pw, node: n)

    // llmq cluster fix-keychain —— 放宽口令条目的访问控制
    //
    // 必须在终端里交互跑：读那一步可能弹一次窗，点「允许」即可。
    case "fix-keychain":
        let cfg = loadConfig()
        do {
            try ClusterNet.Passphrase.relax(node: cfg.nodeName)
            // **别再承诺「以后不会再断」。**
            //
            // 原来这里就是这么写的，而实测在 macOS 26 上放宽根本不管用：
            // 应用列表传 nil 的 SecAccess，换个二进制读照样 errSecAuthFailed。
            // 真正管用的是更新时的交接（install 里的 reseal）和
            // 握有 CA 时的自动重签。这条命令如今只是「重存一遍」。
            print(Ansi.green("重存好了 ")
                  + Ansi.dim("—— 注意放宽 ACL 在 macOS 15+ 上并不生效，"
                             + "真正兜底的是 llmq update 时的口令交接"))
            if restartClusterServe() { print(Ansi.dim("已重启 cluster serve")) }
        } catch {
            print(Ansi.red("\(error.localizedDescription)"))
            print(Ansi.dim("读不到就只能重新导入：llmq cluster import <p12 文件> <口令>"))
            exit(1)
        }

    // llmq cluster set-port <端口> —— 换监听端口
    //
    // 对端不用手动改：presence 里带着端口，别的机器解析地址时优先用自报值。
    // 这也是当初把端口放进 presence 的理由 —— 换端口不该变成一次两台机器的
    // 配置同步操作。
    case "set-port":
        guard let n = UInt16(need(1, "端口号")), n >= 1024 else {
            print(Ansi.red("端口要在 1024–65535 之间")); exit(1)
        }
        var cfg = loadConfig()
        let old = cfg.port
        cfg.port = n
        try ClusterConfigStore.save(cfg)
        print(Ansi.green("监听端口 ") + "\(old) → \(n)")
        if restartClusterServe() {
            print(Ansi.dim("已重启 cluster serve，新端口生效"))
        } else {
            print(Ansi.dim("没装常驻服务；下次跑 llmq cluster serve 时生效"))
        }
        // 立刻报一次，别让对端等下一轮采集（默认 15 分钟）。
        ClusterPresenceStore.publish()
        print(Ansi.dim("已上报新端口，对端会自动跟上"))

    // llmq cluster restart —— 踢一下常驻的监听
    case "restart":
        if restartClusterServe() {
            print(Ansi.green("已重启 cluster serve"))
        } else {
            print(Ansi.yellow("没装常驻服务") + Ansi.dim("，先跑 llmq cluster install-serve"))
        }

    // llmq cluster install-serve —— 把监听装成常驻
    case "install-serve":
        let cfg = loadConfig()
        _ = myPassword(cfg.nodeName)   // 先确认口令拿得到，别装完才发现起不来
        guard !cfg.allowedNodes.isEmpty else {
            print(Ansi.red("允许名单是空的，先跑 llmq cluster trust <节点名>")); exit(1)
        }
        // SECURITY.md 第一节的第 3 条前提是「只在你明确启动时才绑端口」。
        // 装 launchd 看起来违反它，其实不然：**你主动跑这条命令本身就是
        // 那个明确授权**，和「装完默认就开着」是两回事。所以这里要把它
        // 摆到台面上说清楚，而不是悄悄装上。
        print(Ansi.yellow("这会让这台机器一直监听 \(cfg.port) 端口。"))
        print(Ansi.dim("  只认本集群 CA 签发的客户端证书，允许：")
              + cfg.allowedNodes.joined(separator: "、"))
        print(Ansi.dim("  认证过的对端也只能投任务，不能执行任意命令（见 SECURITY.md 第一节）。"))
        print(Ansi.dim("  随时撤销：launchctl bootout gui/$(id -u)/com.llmquotabar.cluster"))

        guard let exe = Bundle.main.executablePath,
              FileManager.default.isExecutableFile(atPath: exe) else {
            print(Ansi.red("无法定位 llmq 自身的路径")); exit(1)
        }
        let label = "com.llmquotabar.cluster"
        let agents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plistURL = agents.appendingPathComponent("\(label).plist")
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/llmquotabar-cluster.log").path
        // LimitLoadToSessionType=Aqua：serve 要从钥匙串取 p12 口令，
        // 而钥匙串只在图形登录会话里可用。装成 Background 的话会静默取不到。
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(exe)</string><string>cluster</string><string>serve</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ThrottleInterval</key><integer>30</integer>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
          <!-- 隐私授权的归属落点。见 worker 那个 plist 上的长注释。 -->
          <key>AssociatedBundleIdentifiers</key>
          <array><string>com.llmquotabar.menubar</string></array>
          <key>StandardOutPath</key><string>\(log)</string>
          <key>StandardErrorPath</key><string>\(log)</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        _ = Proc.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"],
                     cwd: "/", env: [:], timeout: 20)
        let boot = Proc.run("/bin/launchctl",
                            ["bootstrap", "gui/\(getuid())", plistURL.path],
                            cwd: "/", env: [:], timeout: 20)
        guard boot.exitCode == 0 else {
            print(Ansi.red("装载失败：\(boot.stderr)")); exit(1)
        }
        print("\n" + Ansi.green("已装成常驻") + Ansi.dim("  日志 " + log))

    // llmq cluster serve
    case "serve":
        // **日志必须行缓冲。**
        //
        // launchd 把 stdout 接到文件上，而 stdout 不是 TTY 时 libc 默认是
        // 块缓冲（4KB 才刷一次）。这个进程一天也打不满 4KB，于是
        // ~/Library/Logs/llmquotabar-cluster.log **永远是 0 字节**。
        //
        // 代价是真金白银的：排查一次跨机连不通的故障时，我三次让人去看
        // 这个日志、三次拿到空文件，只能靠外部黑盒探测一点点猜服务端状态，
        // 整件事因此慢了一个数量级。而日志里其实早就写好了确切答案。
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
        let stamp = DateFormatter()
        stamp.dateFormat = "MM-dd HH:mm:ss"
        // **第一行就打，什么都别等。**
        //
        // 原来这行在构造 Server 之后 —— 而构造函数要读钥匙串、导 p12，
        // 一旦卡在那儿（实际发生过：SecKeychainSetSettings 等授权等到天荒地老），
        // 日志里连一行「启动」都没有。外面看到的是 launchd 说进程 running、
        // ps 里也有它、端口却没人听，而日志完全空白。
        // 启动日志的价值恰恰在启动失败的时候，所以它必须排在所有可能阻塞的
        // 操作前面。
        print("[\(stamp.string(from: Date()))] 进程起来了，开始读配置和证书…")
        let cfg = loadConfig()
        let server = try ClusterNet.Server(
            config: cfg, password: myPassword(cfg.nodeName),
            // 带上时间戳：没有时间戳就分不清「这是刚才那次的」还是
            // 「几天前留下的」，而重启循环恰恰只能从时间戳看出来。
            log: { print("[\(stamp.string(from: Date()))] \($0)") })
        print("[\(stamp.string(from: Date()))] 启动 —— 节点 \(cfg.nodeName)，"
            + "端口 \(cfg.port)，绑定 \(cfg.bindAddress ?? "自动")")
        try server.start()

        // 绑定不会跟着 DHCP 走。
        //
        // 监听绑的是**启动那一刻**的 IP。地址换了之后，lsof 照样显示
        // LISTEN（所以「在不在服务」看起来是好的），但绑的那个地址
        // 已经不在本机了 —— 从对面看就是 connect 超时，
        // 和「没起服务」「防火墙丢包」长得一模一样，极难分辨。
        //
        // 与其在进程内做重绑（要处理半开连接、端口 TIME_WAIT、
        // 监听器状态机），不如直接退出让 launchd 重启：KeepAlive=true
        // 会在 30 秒内把它拉起来，那时它自然绑到新地址。
        // 让监督者干监督者该干的事。
        let watchdog = DispatchQueue(label: "llmq.cluster.rebind")
        func armWatchdog() {
            watchdog.asyncAfter(deadline: .now() + 60) {
                // 钥匙串会自动上锁，锁上之后私钥签不了名、握手报 -9858，
                // 而外部看一切正常。带口令解锁不需要任何交互，顺手做掉。
                ClusterNet.ensureScratchUnlocked()

                switch ClusterPresenceStore.serveHealth(port: cfg.port) {
                case .ok:
                    break
                case .notListening:
                    // 进程活着但没在监听。老看门狗把这种情况当健康放行了，
                    // 于是服务能这么「假活」好几个小时都没人知道。
                    print(Ansi.red("进程还在但端口 \(cfg.port) 上没有监听 —— "
                        + "退出，让 launchd 重启"))
                    exit(1)
                case .staleAddress(let a):
                    print(Ansi.yellow("本机 IP 变了，监听还绑着 \(a) —— 退出，"
                        + "让 launchd 重启后绑新的"))
                    exit(0)
                }
                armWatchdog()
            }
        }
        armWatchdog()
        // **不能用 dispatchMain()。**
        //
        // 它会把主线程「交出去」：主线程的栈被展开，之后那个线程只作为
        // 调度队列的工作线程存在 —— 这是它的既定行为，不是 bug。
        // 但 macOS 14 上 Network.framework 的监听器要往**主 runloop**
        // 挂 source，挂不上就**不再 accept 新连接**，而且完全不报错。
        //
        // 症状极其难认：socket 还在 LISTEN（内核绑着），lsof 一切正常，
        // 同一台机器上关着的端口照常回 RST、别的服务照常握手，
        // 唯独这个端口的 SYN 石沉大海。重启后能通几秒，然后彻底哑掉。
        // 它一路被误判成防火墙、AP 隔离、端口过滤、代理劫持、
        // 证书链联网校验 —— 查了整整一天。
        //
        // 唯一的线索是进程日志里那一行：
        //   Attempting to add source to main runloop, but the main thread has exited.
        // 而它只打印一次，且在 stdout 块缓冲修好之前根本落不了盘。
        //
        // RunLoop.main.run() 同样永不返回，但主线程还活着、runloop 在转。
        RunLoop.main.run()

    // llmq cluster ping <节点名>
    case "ping":
        let cfg = loadConfig()
        let peer = need(1, "对端节点名")
        let r = try ClusterNet.send(.ping, to: peer, config: cfg,
                                    password: myPassword(cfg.nodeName))
        switch r {
        case .pong(let node, let v):
            print(Ansi.green("通了 ") + "\(node)" + Ansi.dim("  协议 v\(v)"))
        case .failed(let why): print(Ansi.red(why))
        default: print(r)
        }

    // llmq cluster dispatch <节点名> "<任务>" [--repo <别名>] [--no-classify]
    case "dispatch":
        let cfg = loadConfig()
        let peer = need(1, "对端节点名")
        let prompt = need(2, "任务描述")
        var repoAlias: String?
        if let i = rest.firstIndex(of: "--repo"), i + 1 < rest.count {
            repoAlias = rest[i + 1]
        }

        // 分诊在**派发方**这台机器上做，不在对端。
        // 一是让发起的人出这笔调用的钱，二是本机的历史任务记录更全，
        // 分诊器看得到的上下文更多。
        var profile: TaskProfile?
        if !rest.contains("--no-classify"), let local = RepoRegistry.resolve(repoAlias) {
            print(Ansi.dim("本机分诊中…"))
            profile = TaskClassifier.classify(
                prompt: prompt, repo: local,
                history: TaskStore.all(), dashboard: LLMQuota.dashboard())
            printProfile(profile)
        }

        let r = try ClusterNet.send(
            .submit(prompt: prompt, repo: repoAlias, profile: profile),
            to: peer, config: cfg, password: myPassword(cfg.nodeName))
        switch r {
        case .accepted(let id, let repo):
            print(Ansi.green("已派给 \(peer) ") + id + Ansi.dim("  仓库 " + repo))
            print(Ansi.dim("查进度：llmq cluster task \(peer) \(id)"))
        case .failed(let why): print(Ansi.red(why)); exit(1)
        default: print(r)
        }

    // llmq cluster task <节点名> <任务ID>
    case "task":
        let cfg = loadConfig()
        let peer = need(1, "对端节点名")
        let id = need(2, "任务 ID")
        let r = try ClusterNet.send(.task(id: id), to: peer, config: cfg,
                                    password: myPassword(cfg.nodeName))
        switch r {
        case .task(let t):
            print("\(t.id)  \(t.state.rawValue)  \(t.platform?.displayName ?? "—")")
            if let n = t.note { print(Ansi.dim("  " + n)) }
            if let b = t.branch { print(Ansi.dim("  分支 " + b)) }
        case .failed(let why): print(Ansi.red(why)); exit(1)
        default: print(r)
        }

    // llmq cluster remote <节点名>：拉对端的额度看板
    case "remote":
        let cfg = loadConfig()
        let peer = need(1, "对端节点名")
        let r = try ClusterNet.send(.status, to: peer, config: cfg,
                                    password: myPassword(cfg.nodeName))
        guard case .status(let d) = r else { print(r); return }
        print(Ansi.bold("\(peer) 的额度"))
        for rep in d.reports where rep.detected {
            let head = rep.headline
            let pct = head?.usedFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            print("  \(rep.platform.displayName.padded(10))\(head?.label.padded(8) ?? "")\(pct)")
        }

    // llmq cluster doctor —— 把整个集群的实况摊开
    case "doctor":
        let me = Paths.machineID()
        let list = ClusterPresenceStore.all()
        guard !list.isEmpty else {
            print(Ansi.dim("还没有任何机器上报状态。跑一次 llmq collect 就有了。")); return
        }
        print(Ansi.bold(pad("机器", 26) + pad("节点", 20) + pad("地址", 22)
            + pad("在听", 8) + pad("防火墙", 10) + pad("LAN 走", 10) + "上报"))
        for p in list {
            let stale = p.isStale()
            let name = p.machineID == me ? p.machineName + "（本机）" : p.machineName
            let serving = p.serving ? Ansi.green("是") : Ansi.red("否")
            // 防火墙开着 + 没在听，是最容易误诊的组合：从对面看
            // connect 会超时，和「没起服务」一模一样。
            let fw = p.firewallOn ? Ansi.yellow("开") : Ansi.dim("关")
            let route = p.lanHijackedByTunnel
                ? Ansi.red(p.lanRouteInterface ?? "?")
                : Ansi.dim(p.lanRouteInterface ?? "?")
            print(pad(name, 26) + pad(p.nodeName ?? "—", 20)
                + pad((p.lanIP ?? "?") + ":\(p.port)", 22)
                + pad(serving, 8) + pad(fw, 10) + pad(route, 10)
                + (stale ? Ansi.red("已过期") : Ansi.dim(relativeTime(p.updatedAt))))
        }

        // 没在听的机器，直接把它日志的尾巴摊在这儿。
        //
        // 「在听 = 否」只说结果不说原因，而原因有一堆完全不同的可能
        // （钥匙串读不到、端口被占、配置坏了、绑定地址不存在），修法各不相同。
        // 为了拿这几行日志来回折腾过好几轮 —— 它明明就在对端机器上，
        // presence 每轮都在写 iCloud，顺手带上就完了。
        for p in list where !p.serving {
            let who = p.nodeName ?? p.machineName
            print("\n" + Ansi.red("✗ \(who) 没在监听"))
            if let n = p.restartsLastHour, n > 3 {
                print(Ansi.yellow("  最近一小时启动了 \(n) 次 —— 崩溃重启循环"))
                print(Ansi.dim("  （launchd 的 KeepAlive 会一直拉起失败的进程，"
                    + "从外面看是「时好时坏」，实际是每 30 秒死一次）"))
            }
            if let lines = p.lastLogLines, !lines.isEmpty {
                print(Ansi.dim("  它的日志最后几行："))
                for l in lines { print(Ansi.dim("    " + l)) }
            } else {
                print(Ansi.dim("  它那版还没上报日志，升级后再看一次"))
            }
        }

        // 连通性矩阵。方向性是区分「网络本身不通」和「某一端有问题」的唯一办法。
        let named = list.filter { $0.nodeName != nil }
        if named.count > 1 {
            print("\n" + Ansi.bold("谁连得上谁") + Ansi.dim("（每台自己探的）"))
            for p in named {
                let from = p.nodeName ?? "?"
                for (to, ok) in p.canReach.sorted(by: { $0.key < $1.key }) {
                    print("  " + pad(from, 20) + "→ " + pad(to, 20)
                        + (ok ? Ansi.green("通") : Ansi.red("不通")))
                }
            }
            // 双向都不通 = 网络问题；单向 = 被探那端的问题。
            //
            // 只看 an < bn 这一半：外层是双重循环，(a,b) 和 (b,a) 说的是
            // 同一件事，不去重就每对报两遍。
            for a in named {
                for b in named where (b.nodeName ?? "") > (a.nodeName ?? "") {
                    guard let an = a.nodeName, let bn = b.nodeName,
                          let ab = a.canReach[bn], let ba = b.canReach[an] else { continue }
                    if !ab && !ba {
                        print(Ansi.red("\n✗ \(an) 和 \(bn) 双向都不通"))
                        print(Ansi.dim("   两台自身都正常的话，问题在网络本身：路由器开了"))
                        print(Ansi.dim("   AP 隔离 / 客户端隔离，或者两台其实不在同一个二层域"))
                        print(Ansi.dim("   （比如一台连 2.4G 一台连 5G、或者走了不同的 Mesh 节点）"))
                    } else if ab != ba {
                        // ab = a 连得上 b。ab 为真、ba 为假，说明连不进去的是 **a**
                        // —— 是 a 收不到别人的连接。这里曾经写反过，
                        // 结果诊断一直指着无辜的那台。
                        let bad = ab ? an : bn
                        let badP = ab ? a : b
                        print(Ansi.yellow("\n⚠︎ 只有一个方向通 —— 连不进去的是 \(bad)"))
                        print(Ansi.dim("   它连得出去，但别人连不进它。"))
                        // 用 `case .some(false)` 而不是 `case false`：
                        // 新编译器认后者是穷尽的，Swift 6.0.3 不认
                        // （error: switch must be exhaustive, add missing case '.some(_)'）。
                        // 集群里最旧那台机器编不过，等于整台机器上所有验证都失败。
                        switch badP.selfConnectOK {
                        case .some(false):
                            print(Ansi.red("   它自连本机地址也不通 → 服务卡在没 accept 上。"))
                            print(Ansi.dim("   监听队列满了内核就静默丢 SYN、不回 RST，"))
                            print(Ansi.dim("   从外面看就是「端口开着却超时」。重启服务即可："))
                            print(Ansi.dim("   llmq cluster restart"))
                        case .some(true):
                            print(Ansi.dim("   它自己连自己是通的 → 服务本身没问题，是网络层在拦。"))
                            print(Ansi.dim("   防火墙原文：\(badP.firewallRaw ?? "没上报")"))
                            print(Ansi.dim("   应用防火墙会对没签名的程序静默丢包（不回 RST），放行："))
                            print(Ansi.dim("   sudo /usr/libexec/ApplicationFirewall/socketfilterfw \\"))
                            print(Ansi.dim("        --add $(which llmq) --unblockapp $(which llmq)"))
                        case .none:
                            print(Ansi.dim("   它那版还没上报回环自检，升级后再看一次。"))
                        }
                    }
                }
            }
        }

        print()
        for p in list where p.machineID != me {
            if p.isStale() {
                print(Ansi.yellow("⚠︎ \(p.machineName) 超过 15 分钟没上报")
                    + Ansi.dim(" —— 它可能关机了，或者 iCloud 没在同步"))
            } else if !p.serving {
                print(Ansi.yellow("⚠︎ \(p.machineName) 没在监听")
                    + Ansi.dim(" —— 在那台上跑 llmq cluster install-serve"))
            } else if p.lanHijackedByTunnel {
                print(Ansi.red("✗ \(p.machineName) 的局域网流量走 \(p.lanRouteInterface ?? "?")")
                    + Ansi.dim(" —— 被代理客户端的 TUN 接管了"))
                print(Ansi.dim("   现象极具迷惑性：服务在听、防火墙关着、ping 也通，"))
                print(Ansi.dim("   但 TCP 回包被塞进隧道出不来，对面看就是连接超时。"))
                print(Ansi.dim("   在那台的代理客户端里打开「绕过局域网 / Bypass LAN」。"))
            } else if p.firewallOn {
                print(Ansi.yellow("⚠︎ \(p.machineName) 在听，但防火墙开着")
                    + Ansi.dim(" —— 没放行 llmq 的话入站会被**静默丢弃**，"
                             + "表现是连接超时，和没起服务一模一样"))
            }
            if let ip = p.lanIP, let node = p.nodeName,
               let cfg = ClusterConfigStore.load(),
               let recorded = cfg.peers[node], recorded != "\(ip):\(p.port)" {
                print(Ansi.yellow("⚠︎ \(node) 的地址变了")
                    + Ansi.dim("：配置里是 \(recorded)，它自报 \(ip):\(p.port)")
                    + Ansi.dim("（派活时会自动用自报的那个）"))
            }
        }

    case "status", "":
        guard let cfg = ClusterConfigStore.load() else {
            print(Ansi.dim("还没配置集群。先跑：llmq cluster init <本机节点名>")); return
        }
        print(Ansi.bold("本机节点  ") + cfg.nodeName)
        print(Ansi.bold("监听端口  ") + String(cfg.port)
              + Ansi.dim("（只在跑 serve 时才绑）"))
        print(Ansi.bold("允许连入  ") + (cfg.allowedNodes.isEmpty
              ? Ansi.dim("（空 —— serve 会拒绝启动）")
              : cfg.allowedNodes.joined(separator: "、")))
        print(Ansi.bold("已知对端  ") + (cfg.peers.isEmpty ? Ansi.dim("（无）")
              : cfg.peers.map { "\($0.key)→\($0.value)" }.joined(separator: "  ")))
        print(Ansi.bold("已签发    ") + ClusterCA.issuedNodes().joined(separator: "、"))
        if let ip = ClusterNet.lanAddress() {
            print(Ansi.dim("本机内网地址 \(ip) —— 对端要记的是 \(ip):\(cfg.port)"))
        }

    default:
        print("""
        \(Ansi.bold("llmq cluster")) — 局域网跨机派活（双向 mTLS）

        \(Ansi.bold("头一次配"))
          llmq cluster init <本机名>            建 CA、给自己签证书
          llmq cluster enroll <对方名>          给对方签一张，打印文件和口令
          llmq cluster import <本机名> <p12> <ca.crt>
                                               在对方机器上导入
          llmq cluster peer <对方名> <host:port> 记下对方地址

        \(Ansi.bold("日常"))
          llmq cluster serve                    起监听，等活（前台）
          llmq cluster install-serve            装成常驻，开机自启
          llmq cluster restart                  踢一下常驻服务（换了二进制要重启）
          llmq cluster set-port <端口>          换监听端口，对端自动跟上
          llmq cluster set-bind <地址|auto|all>  换绑定地址（all = 0.0.0.0）
          llmq cluster fix-keychain             更新后台进程读不到口令时跑一次
          llmq cluster ping <对方名>            验双向证书通不通
          llmq cluster dispatch <对方名> "<任务>" [--repo <别名>]
          llmq cluster task <对方名> <任务ID>   查进度
          llmq cluster remote <对方名>          看对方的额度
          llmq cluster status                   本机集群配置
          llmq cluster doctor                   整个集群的实况（谁在听、地址、防火墙）

        \(Ansi.bold("撤销"))
          llmq cluster revoke <节点名>          从名单里划掉，重启 serve 生效
        """)
    }
}

extension String {
    /// 按显示宽度补空格。中文算两格。
    func padded(_ width: Int) -> String {
        let w = reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2000 ? 2 : 1) }
        return self + String(repeating: " ", count: max(1, width - w))
    }
}


// MARK: - release / update

/// 「3 分钟前」这种。CLI 里没有 iOS App 那套 Fmt。
func relativeTime(_ d: Date) -> String {
    let t = Date().timeIntervalSince(d)
    if t < 90 { return "刚刚" }
    if t < 3600 { return "\(Int(t / 60)) 分钟前" }
    if t < 86400 { return "\(Int(t / 3600)) 小时前" }
    return "\(Int(t / 86400)) 天前"
}

func releaseWaitSeconds(_ args: [String], default value: Int) -> Int {
    guard let i = args.firstIndex(of: "--wait-seconds"), i + 1 < args.count,
          let parsed = Int(args[i + 1]) else { return value }
    return max(0, parsed)
}

/// 等在线对端亲自确认目标版本。返回 false 就意味着“包发了，但集群发布没完成”。
@discardableResult
func waitForReleaseFanout(target: String, seconds: Int) -> Bool {
    let localID = Paths.machineID()
    func pending() -> [ClusterPresence] {
        ReleaseFanout.pending(target: target, localMachineID: localID,
                              presences: ClusterPresenceStore.all())
    }
    var missing = pending()
    if missing.isEmpty {
        print(Ansi.green("  ✓ 所有在线机器已确认 ") + target.prefix(12))
        return true
    }

    if seconds > 0 {
        print(Ansi.dim("等待在线机器确认（最多 \(seconds) 秒）："
            + missing.map(\.machineName).joined(separator: "、")))
    }
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while !missing.isEmpty, Date() < deadline {
        Thread.sleep(forTimeInterval: min(5, max(0.2, deadline.timeIntervalSinceNow)))
        // CLI 平时只读本地镜像；等待期间主动拉一次，不能要求人另开窗口刷新。
        _ = MirrorService.sync(local: Paths.sharedRoot, cloud: Push.mirrorDir,
                               selfMachineID: localID)
        missing = pending()
    }
    guard missing.isEmpty else {
        print(Ansi.red("集群发布未完成：以下在线机器还没确认 ") + target.prefix(12))
        for p in missing {
            print("  " + Ansi.red("✗ ") + p.machineName + Ansi.dim(
                "  当前 " + (p.installedRelease ?? "未知")))
        }
        print(Ansi.dim("  自动更新每分钟检查；稍后用 llmq release verify 再确认。"))
        return false
    }
    print(Ansi.green("  ✓ 所有在线机器已确认 ") + target.prefix(12))
    return true
}

func cmdRelease(_ rest: [String]) throws {
    switch rest.first ?? "status" {

    // llmq release sign-with "<证书名>" —— 配一个跨重建稳定的签名身份。
    //
    // 身份存本机，**不进仓库也不进 iCloud**：证书名里带邮箱和 Team ID，
    // 而这个项目要开源。别人不配就是现在的 adhoc 行为，什么都不受影响。
    case "sign-with":
        let want = rest.dropFirst().first
        guard let id = want, !id.isEmpty else {
            print("用法：llmq release sign-with \"<证书名>\"   （或 --none 关掉）")
            let list = CodeSigning.available()
            if list.isEmpty {
                print(Ansi.yellow("本机没有可用于代码签名的证书"))
            } else {
                print(Ansi.dim("本机可用的："))
                for i in list { print("    " + i) }
            }
            if let cur = CodeSigning.identity() {
                print(Ansi.dim("当前配置：") + cur)
            } else {
                print(Ansi.dim("当前：没配（adhoc，授权会在每次发布后失效）"))
            }
            return
        }
        if id == "--none" {
            CodeSigning.clearIdentity()
            print(Ansi.yellow("已关掉签名 —— 授权会在每次发布后失效"))
            return
        }
        guard CodeSigning.available().contains(id) else {
            print(Ansi.red("本机没有这张证书：") + id)
            print(Ansi.dim("可用的：")); for i in CodeSigning.available() { print("    " + i) }
            exit(1)
        }
        try CodeSigning.setIdentity(id)
        print(Ansi.green("签名身份已配置 ") + Ansi.dim(CodeSigning.configFile.path))
        print(Ansi.dim("下次 llmq release publish 会用它签名。"))
        print(Ansi.dim("签完需要你**重新授权一次**（系统认的是新身份），之后就不会再失效。"))
        return

    // llmq release publish [--notes "..."]
    case "publish":
        var notes = ""
        if let i = rest.firstIndex(of: "--notes"), i + 1 < rest.count { notes = rest[i + 1] }
        let node = ClusterConfigStore.load()?.nodeName ?? Paths.machineName()

        // **有任务在跑就不许发布。**
        //
        // 发布会重启常驻服务，正在执行的 agent 进程连带被杀 —— 产出即时丢失，
        // 任务被标中断（≤2 次自动重排，第 3 次判死）。一晚上踩了四次，
        // 其中一次差点毁掉 26 分钟的图节点产出。
        //
        // 靠「发布前记得检查」是防不住的：我自己写完这条纪律，
        // 十分钟后就又发了一次。所以改成程序拦 —— 纪律要变成机制才算数。
        // 真急着发（比如修的正是让任务卡死的那个 bug）加 --force。
        // **这道闸已经不需要拦住发布本身了。**
        //
        // 它写在「发布 = 无条件重启常驻服务」的年代。后来
        // `restartResidentServices()` 自己长出了在飞守卫(有活在跑就不踢
        // worker,新二进制等它干完自然生效),所以发布**不会**再杀掉正在跑的
        // agent —— 而这道外层闸却仍然让整个发布 exit(1)。
        //
        // 代价是实打实的(2026-08-22 晚):zcode 适配器修好后,因为产线一直
        // 有任务在跑,连续几小时发不出去,MacBook 一直停在旧版本,
        // 老板看到的是「下午适配的 zcode 手机端看不到」。
        // **产线越忙,越发不了版** —— 这个方向完全反了。
        //
        // 现在只提示,不拦:发布照做,重启那步自己会等。
        let running = TaskStore.all().filter { $0.state == .running }
        if !running.isEmpty {
            print(Ansi.dim("有 \(running.count) 个任务正在跑 —— 照常发布，"))
            print(Ansi.dim("常驻服务会等它们干完再换二进制（restartResidentServices 里的在飞守卫）。"))
        }

        print(Ansi.dim("编译通用二进制（Intel + Apple Silicon）…"))
        let repo = FileManager.default.currentDirectoryPath
        guard FileManager.default.fileExists(atPath: repo + "/Package.swift") else {
            print(Ansi.red("要在 LLMQuotaBar 仓库根目录下跑")); exit(1)
        }
        let build = Proc.run("/usr/bin/env",
            ["swift", "build", "-c", "release", "--arch", "arm64", "--arch", "x86_64"],
            cwd: repo, env: [:], timeout: 1800)
        guard build.exitCode == 0 else {
            print(Ansi.red("编译失败：\n" + build.stderr.suffix(600))); exit(1)
        }
        let pathOut = Proc.run("/usr/bin/env",
            ["swift", "build", "-c", "release", "--arch", "arm64", "--arch", "x86_64",
             "--show-bin-path"], cwd: repo, env: [:], timeout: 300)
        let binDir = pathOut.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // **打包之前先签名。**
        //
        // adhoc 签名的二进制在 TCC 眼里每次重建都是一个新程序，于是
        // 「发布一次 = 把用户给的完全磁盘访问作废一次」。详见 CodeSigning。
        // 没配身份就跳过，行为和以前一样 —— 开源用户不受影响。
        for exe in ["llmq"] {
            let p = binDir + "/" + exe
            guard FileManager.default.fileExists(atPath: p) else { continue }
            let s = CodeSigning.sign(p)
            print((s.signed ? Ansi.green("  ✓ ") : Ansi.yellow("  ⚠︎ ")) + s.detail)
            if s.signed {
                let d = CodeSigning.describe(p)
                print(Ansi.dim("    身份 \(d.identifier ?? "?") / team \(d.team ?? "无")"
                    + (d.team == nil
                       ? "  ← 没有 team，授权还是会随重建失效"
                       : "  ← 跨重建稳定，授权不会再被发布踩掉")))
            }
        }

        print(Ansi.dim("打包…"))
        let tar = try ReleasePacker.pack(binDir: binDir)
        defer { try? FileManager.default.removeItem(at: tar.deletingLastPathComponent()) }

        let m = try ReleaseChannel.publish(tarball: tar, notes: notes, by: node)
        print(Ansi.green("已发布 ") + m.sha256.prefix(12) + Ansi.dim("  " + m.file))
        if !notes.isEmpty { print(Ansi.dim("  " + notes)) }

        // **主机自己也要真装一遍。**
        //
        // 这里原来只调 markInstalled，注释说「否则它会检测到有更新、
        // 再装一遍自己刚发的东西」—— 前提是错的：刚编出来的东西在
        // `.build/release` 里，`~/.local/bin/llmq` 一个字节都没变。
        // 结果是发布机永远跑旧代码，而 `llmq update` 一直回「已是最新」，
        // 因为标记已经被盖上了。
        //
        // 这种「三件事都做了、问题一点没变」正是这个文件 2770 行那段注释
        // 警告过的：换了二进制不等于换了正在跑的进程 —— 而这次连二进制
        // 都没换。
        try ReleaseChannel.install(m, payload: tar)
        ClusterPresenceStore.publish()
        print(Ansi.green("本机已装上 ") + m.sha256.prefix(12))
        let restarted = restartResidentServices()
        if !restarted.isEmpty { print(Ansi.dim("  重启：" + restarted.joined(separator: " "))) }
        // **发布不等于全网到齐。** 过去这里只把旧机器红字列出来，命令仍以 0
        // 退出，于是自动化和人都会把它当成完成。现在在线机器没亲自回报同一
        // 哈希就返回失败；离线机器不阻塞，回来后 updater 会自行追上。
        //
        // 老板 2026-08-23:「发包真的基础的事情,每次都忘记两台全发」。
        // 根子不是我忘,是发布**只把包放进共享目录就宣布完成**,从不回头看
        // 从机跟上没有。MacBook 停在旧版好几个钟头,我每次都是等它出问题
        // 才发现。这种「靠记性做的基础操作」就该让命令自己保证。
        //
        // 这里按 presence 报告的 installedRelease 逐台核对:已跟上的打勾,
        // 没跟上的红着列出来,一眼就知道还差谁 —— 不用记、不用猜。
        guard waitForReleaseFanout(
            target: m.sha256, seconds: releaseWaitSeconds(rest, default: 180))
        else { exit(3) }

    // llmq release install-updater [秒]
    case "install-updater":
        let secs = rest.dropFirst().first.flatMap { Int($0) } ?? 60
        try installUpdater(interval: secs)

    case "verify":
        switch ReleaseChannel.check() {
        case .upToDate(let sha):
            guard waitForReleaseFanout(
                target: sha, seconds: releaseWaitSeconds(rest, default: 0))
            else { exit(3) }
        case .available(let m, _):
            print(Ansi.red("本机还没安装当前发布 ") + m.sha256.prefix(12))
            print(Ansi.dim("  先跑 llmq update")); exit(3)
        case .noChannel:
            print(Ansi.red("还没有发布过")); exit(3)
        case .rejected(let why):
            print(Ansi.red("拒绝：" + why)); exit(1)
        }

    // llmq release bootstrap —— 打印一段自包含的引导脚本
    case "bootstrap":
        // 鸡生蛋：`llmq update` 是后加的命令，老版本的从机上根本没有它，
        // 没法用它把自己更新到有它的版本。
        //
        // 但从机手上有 ca.crt（入职时导入的），所以它**能自己完成全部验证** ——
        // 不需要任何哈希或密钥从别处传过去。这段脚本干的就是 llmq update
        // 内部那几步，只是用 shell 写。
        //
        // 脚本本身必须走可信渠道（你复制粘贴），不能放 iCloud：
        // 放上去就能被人把验证那几行删掉。
        print("""
        # 在那台机器上整段粘贴。它会用本机已有的 ca.crt 自行验证，
        # 证书链、清单签名、包哈希三样都对得上才安装。
        R=~/Library/Mobile\\ Documents/com~apple~CloudDocs/LLMQuotaBar/releases
        C=~/Library/Application\\ Support/LLMQuotaBar/cluster/ca.crt
        ( set -e
          [ -f "$C" ] || { echo "✗ 找不到 ca.crt，这台机器没入过集群"; exit 1; }
          brctl download "$R" 2>/dev/null || true
          for i in $(seq 30); do [ -f "$R/current.json" ] && break; printf '.'; sleep 2; done; echo
          [ -f "$R/current.json" ] || { echo "✗ iCloud 上没有发布清单，或还没同步下来"; exit 1; }
          head -c1 "$R/current.json" >/dev/null 2>&1 || {
            echo "✗ 读不了（TCC）：系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 打开「终端」，重开终端再跑"; exit 1; }
          echo "验签…"
          openssl verify -CAfile "$C" "$R/release-signer.crt" >/dev/null \\
            || { echo "✗ 发布证书不是本集群 CA 签的"; exit 1; }
          openssl x509 -in "$R/release-signer.crt" -noout -subject | grep -q 'CN *= *release-signer' \\
            || { echo "✗ 签名者不是 release-signer"; exit 1; }
          openssl x509 -in "$R/release-signer.crt" -pubkey -noout > /tmp/.rel.pub
          openssl dgst -sha256 -verify /tmp/.rel.pub -signature "$R/current.sig" "$R/current.json" >/dev/null \\
            || { echo "✗ 清单签名验不过 —— 清单被改过"; exit 1; }
          F=$(python3 -c "import json;print(json.load(open('$R/current.json'))['file'])")
          H=$(python3 -c "import json;print(json.load(open('$R/current.json'))['sha256'])")
          echo "$H  $R/$F" | shasum -a 256 -c - >/dev/null \\
            || { echo "✗ 包的哈希和清单对不上"; exit 1; }
          echo "✓ 证书链、清单签名、包哈希都对得上"
          T=$(mktemp -d); tar xzf "$R/$F" -C "$T"
          "$T/llmq-dist/llmq" --help >/dev/null || { echo "✗ 新二进制跑不起来，拒绝安装"; exit 1; }
          pkill -f 'LLMQuotaBar.app/Contents/MacOS' 2>/dev/null || true; sleep 1
          rm -rf /Applications/LLMQuotaBar.app
          cp -R "$T/llmq-dist/LLMQuotaBar.app" /Applications/
          codesign --force --deep --sign - /Applications/LLMQuotaBar.app 2>/dev/null || true
          mkdir -p ~/.local/bin
          cp "$T/llmq-dist/llmq" ~/.local/bin/.llmq.new && chmod +x ~/.local/bin/.llmq.new
          mv -f ~/.local/bin/.llmq.new ~/.local/bin/llmq
          echo "$H" > ~/Library/Application\\ Support/LLMQuotaBar/installed-release
          open /Applications/LLMQuotaBar.app 2>/dev/null || true
          echo "✓ 已更新到 ${H:0:12}"
          echo "  以后 llmq update 就行，或装成自动：llmq release install-updater" )
        """)

    case "status", "":
        switch ReleaseChannel.check() {
        case .noChannel:
            print(Ansi.dim("还没有发布过。在主机上跑：llmq release publish"))
        case .upToDate(let sha):
            print(Ansi.green("已是最新 ") + sha.prefix(12))
            let pending = ReleaseFanout.pending(
                target: sha, localMachineID: Paths.machineID(),
                presences: ClusterPresenceStore.all())
            if !pending.isEmpty {
                print(Ansi.yellow("集群尚未完成：")
                    + pending.map { "\($0.machineName)(\($0.installedRelease ?? "未知"))" }
                        .joined(separator: "、"))
            }
        case .available(let m, _):
            print(Ansi.bold("有新版本 ") + m.sha256.prefix(12))
            print(Ansi.dim("  发布于 \(relativeTime(m.publishedAt))，来自 \(m.publishedBy)"))
            if !m.notes.isEmpty { print(Ansi.dim("  " + m.notes)) }
            print(Ansi.dim("  装它：llmq update"))
        case .rejected(let why):
            print(Ansi.red("拒绝：" + why))
        }

    default:
        print("""
        \(Ansi.bold("llmq release")) — 给集群发版

          llmq release publish [--notes "..."] [--wait-seconds 180]
                                               发布；在线机器未全确认则失败
          llmq release verify                   复核在线机器是否全到齐
          llmq release status                   看当前通道和集群版本
          llmq release install-updater [秒]     装成定时自动更新（默认 60 秒）

        签名链：集群 CA → release-signer 证书 → 清单签名 → 包哈希。
        从机会逐环验证，任何一环对不上就拒绝安装。
        """)
    }
}

/// 装一个定时检查更新的 launchd 任务。
///
/// 每分钟检查一次。安装和重启都有在飞任务保护；检查本身只读两个小文件并验签。
func installUpdater(interval: Int) throws {
    let label = "com.llmquotabar.updater"
    // 同 cmdInstallAgent：不能用 argv[0] 推路径，从 PATH 调用时它只是 "llmq"。
    guard let exe = Bundle.main.executablePath,
          FileManager.default.isExecutableFile(atPath: exe) else {
        print(Ansi.red("无法定位 llmq 自身的路径")); exit(1)
    }
    let agentsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
    let plistURL = agentsDir.appendingPathComponent("\(label).plist")
    let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/llmquotabar-updater.log").path

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(label)</string>
      <key>ProgramArguments</key>
      <array><string>\(exe)</string><string>update</string></array>
      <key>StartInterval</key><integer>\(interval)</integer>
      <key>RunAtLoad</key><true/>
      <key>StandardOutPath</key><string>\(log)</string>
      <key>StandardErrorPath</key><string>\(log)</string>
    </dict>
    </plist>
    """
    try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    _ = Proc.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"],
                 cwd: "/", env: [:], timeout: 20)
    let r = Proc.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path],
                     cwd: "/", env: [:], timeout: 20)
    guard r.exitCode == 0 else {
        print(Ansi.red("装载失败：\(r.stderr)")); exit(1)
    }
    print(Ansi.green("已装自动更新 ") + Ansi.dim("每 \(interval) 秒检查一次"))
    print(Ansi.dim("  日志 " + log))
    print(Ansi.dim("  验签不过会拒绝安装并写进日志，不会静默装上"))
}

func cmdUpdate(_ rest: [String]) throws {
    let checkOnly = rest.contains("--check")
    switch ReleaseChannel.check() {
    case .noChannel:
        print(Ansi.dim("没有发布通道。主机上跑 llmq release publish 之后才有。"))
    case .upToDate(let sha):
        print(Ansi.green("已是最新 ") + sha.prefix(12))
    case .rejected(let why):
        // 这条要吵。签名验不过意味着 iCloud 里的东西被动过。
        print(Ansi.red("拒绝更新：" + why))
        exit(1)
    case .available(let m, let payload):
        if checkOnly {
            print(Ansi.bold("有新版本 ") + m.sha256.prefix(12)
                  + Ansi.dim("  " + m.notes)); return
        }
        print(Ansi.dim("验签通过，安装 \(m.sha256.prefix(12))…"))
        try ReleaseChannel.install(m, payload: payload)
        // 发布端在等这台机器亲自确认。不能等下一轮五分钟采集，安装成功就
        // 立刻上报，再由菜单栏镜像到 iCloud。
        ClusterPresenceStore.publish()
        print(Ansi.green("已更新到 ") + m.sha256.prefix(12))
        if !m.notes.isEmpty { print(Ansi.dim("  " + m.notes)) }
        // 换了二进制不等于换了正在跑的进程。
        //
        // cluster serve 是**常驻**的：更新只是把磁盘上的文件换掉，
        // 那个已经跑了几天的进程还在执行老代码。于是「服务端的 bug 修好了、
        // 也发版了、对方也更新了」三件事同时成立，问题却一点没变 ——
        // 这正好浪费了一轮排查。采集是 StartInterval 每次新起进程,自然用上新的;
        // worker 是 KeepAlive 常驻,下面这句只在它手上没活时踢,有活就不踢 ——
        // 它会在空闲点自己退出换新(BinarySwap),不会杀正在跑的 agent。
        let kicked = restartResidentServices()
        if !kicked.isEmpty {
            print(Ansi.dim("  已重启常驻服务（换二进制不换进程，得踢一下）："
                + kicked.map { $0.replacingOccurrences(of: "com.llmquotabar.", with: "") }
                    .joined(separator: "、")))
        }
    }

    // updater 是独立的每分钟进程，不能只拿来查版本：worker 正在同步跑一个
    // 几十分钟的 agent 时，工作循环走不到「提醒」阶段，期间新出现的验收/
    // 提问就一直静默。借这个已有心跳补跑提醒，不另养第五个 launchd 服务。
    // 横幅本身已经携带总角标；这里不额外发 badge-only，避免每分钟重复打 APNs。
    if !checkOnly { _ = Nudge.run(synchronizeBadge: false) }
}

/// 踢一下所有常驻服务。返回被重启的 label。
///
/// **两个都要踢，不能只踢 cluster。**
/// `work loop` 和 `cluster serve` 一样是常驻的：换了磁盘上的二进制，
/// 那个跑了几天的进程还在执行老代码。只踢 cluster 的后果实测到了 ——
/// 新加的高危路径闸发版、部署、cluster 重启，看起来一切就绪，
/// 而 worker 还是老的，于是一个改了 build-app.sh 的任务照样直接提交，
/// 闸门形同虚设。而这时候「代码写了、测试过了、也部署了」三件事都成立。
@discardableResult

/// 一轮什么都没派出去时,把**原因**记进办公室动态。
///
/// 老板 2026-08-22 一天里问了八次「任务停了」,八次原因都不同,
/// 每次都要人上机器查日志。这些原因系统自己全知道 ——
/// worker.log 里写着「但没有现成的活」,而手机上只是一片安静。
/// 静默超过 10 分钟就记一条,手机的动态流里直接看得到。
func noteIdle(_ verdict: IdleReason.Verdict, quiet: Bool) -> RunOutcome {
    let last = OfficeLog.all().last
    let sinceLast = last.map { Date().timeIntervalSince($0.at) } ?? .greatestFiniteMagnitude
    // 上一条动态就是静默、且刚记过 —— 不重复刷屏。
    let justNoted = last?.kind == .idle && sinceLast < IdleReason.quietAfter
    if sinceLast >= IdleReason.quietAfter, !justNoted {
        OfficeLog.record(OfficeEvent(
            kind: .idle, taskID: "", platform: nil, toPlatform: nil,
            detail: verdict.line, taskTitle: "没人在干活", excluded: []))
        OfficeLog.publish()
    }
    if !quiet { print(Ansi.dim("  静默:" + verdict.line)) }
    return .noTask
}

/// 「有 agent 在飞」的唯一判定。restart-worker、restartResidentServices、
/// 循环末尾的换二进制判断都用它 —— 以前是三份各写各的,`?? false` 和 `?? true`
/// 并存,PID 还没落盘那一小段窗口里就被踢死过(2026-08-22 凌晨一个刚跑 32 秒的任务)。
/// **没记 PID 的 running 也算在飞**:宁可多等一轮。
func inFlightAgent() -> WorkTask? {
    TaskStore.all().first {
        $0.state == .running && ($0.runnerPID.map { kill($0, 0) == 0 } ?? true)
    }
}

func restartResidentServices() -> [String] {
    let listed = Proc.run("/bin/launchctl", ["list"], cwd: "/tmp", env: [:], timeout: 15)
    var done: [String] = []

    // **有活正在跑就别重启 worker。**
    //
    // agent 是 worker 的子进程，踢一下 worker 就把它一起杀了。
    // 亲身踩到：一个跑了 334 秒的任务被一次 `llmq release publish`
    // 干掉，孤儿回收把它标成失败 —— 那 334 秒的额度纯粹烧掉了，
    // 而且图的后续步骤跟着停摆。
    //
    // 换二进制本来就不急：worker 每 30 秒取一次任务，
    // 手上这件干完、下一次自然重启时就换过来了。
    // 为了早几分钟用上新版本而弄死一个正在跑的任务，是亏的。
    // **没记 PID 的 running 也算在飞。** 原来 `?? false` —— 任务刚起、
    // PID 还没落盘的那一小段窗口里，它被当成「没人在跑」，于是这道闸
    // 形同虚设（2026-08-22 凌晨实测踢死一个刚跑 32 秒的任务）。
    // 宁可多等一轮：踢晚一点只是新版本晚几分钟生效，踢错一次是烧掉
    // 一整个任务的额度，还要人来问「任务怎么停了」。
    let inFlight = inFlightAgent()

    for label in ["com.llmquotabar.cluster", "com.llmquotabar.worker"] {
        guard listed.stdout.contains(label) else { continue }
        if label == "com.llmquotabar.worker", let busy = inFlight {
            let ran = busy.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            print(Ansi.yellow("没重启 worker：") + Ansi.dim(
                "\(busy.id) 正在跑（已 \(ran) 秒，\(busy.platform?.displayName ?? "?")）。"
                + "踢它会把这个 agent 一起杀掉。新二进制等它干完自然生效。"))
            continue
        }
        let r = Proc.run("/bin/launchctl",
                         ["kickstart", "-k", "gui/\(getuid())/\(label)"],
                         cwd: "/tmp", env: [:], timeout: 30)
        if r.exitCode == 0 { done.append(label) }
    }
    return done
}

/// 兼容旧调用点。
@discardableResult
func restartClusterServe() -> Bool { !restartResidentServices().isEmpty }

/// 把编译产物打成发布包。和装机包同一个布局，install 那边按这个布局解。
enum ReleasePacker {
    static func pack(binDir: String) throws -> URL {
        let stage = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llmq-pack-\(UUID().uuidString)")
        let root = stage.appendingPathComponent("llmq-dist")
        let app = root.appendingPathComponent("LLMQuotaBar.app")
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"),
                               withIntermediateDirectories: true)

        let bin = URL(fileURLWithPath: binDir)
        try fm.copyItem(at: bin.appendingPathComponent("llmq"),
                        to: root.appendingPathComponent("llmq"))
        try fm.copyItem(at: bin.appendingPathComponent("LLMQuotaBarApp"),
                        to: app.appendingPathComponent("Contents/MacOS/LLMQuotaBar"))
        // 资源包**两个地方都要放**。
        //
        // 原来只放进 App 的 Contents/Resources，于是装到 ~/.local/bin 的
        // CLI 找不到它，凡是碰到 Bundle.module 的命令一律
        // 「Fatal error: unable to find bundle named …」直接崩。
        //
        // 而且这个崩法很难往打包上想：同一份代码从 .build/release 跑得好好的
        // （资源包就在旁边），只有装过之后才崩 —— 于是看起来像「安装坏了」。
        // SwiftPM 的 Bundle.module 是按**可执行文件所在目录**找的，
        // 所以 CLI 旁边必须有一份。
        for f in (try? fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "bundle" {
            try? fm.copyItem(at: f, to: app.appendingPathComponent("Contents/Resources")
                .appendingPathComponent(f.lastPathComponent))
            try? fm.copyItem(at: f, to: root.appendingPathComponent(f.lastPathComponent))
        }
        try infoPlist.write(to: app.appendingPathComponent("Contents/Info.plist"),
                            atomically: true, encoding: .utf8)
        _ = Proc.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path],
                     cwd: stage.path, env: [:], timeout: 120)

        let tar = stage.appendingPathComponent("llmq-dist.tar.gz")
        let r = Proc.run("/usr/bin/tar",
            ["--no-mac-metadata", "-czf", tar.path, "-C", stage.path, "llmq-dist"],
            cwd: stage.path, env: [:], timeout: 300)
        guard r.exitCode == 0 else { throw ClusterCA.err("打包失败：\(r.stderr)") }
        return tar
    }

    static let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleName</key><string>LLMQuotaBar</string>
      <key>CFBundleDisplayName</key><string>LLM 额度</string>
      <key>CFBundleIdentifier</key><string>com.llmquotabar.menubar</string>
      <key>CFBundleExecutable</key><string>LLMQuotaBar</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>1.0</string>
      <key>CFBundleVersion</key><string>1</string>
      <key>LSMinimumSystemVersion</key><string>14.0</string>
      <key>LSUIElement</key><true/>
      <key>NSHighResolutionCapable</key><true/>
    </dict>
    </plist>
    """
}

// MARK: - office

func cmdOffice(_ rest: [String]) throws {
    if rest.contains("--backfill") {
        // 从历史任务补事件。
        //
        // **只补有真实时间戳的两类**：派活用 startedAt，收工用 endedAt。
        // 接力的每一棒当时没记时间，硬要补就只能在起止之间插值 ——
        // 那是编的。宁可历史上的接力在画面里看不到，也不放假数据进去。
        var n = 0
        for t in TaskStore.all() {
            guard let started = t.startedAt else { continue }
            OfficeLog.record(OfficeEvent(
                kind: .dispatched, taskID: t.id, platform: t.platform,
                detail: "接到新活", taskTitle: t.prompt, at: started))
            n += 1
            if let ended = t.endedAt, t.state == .done || t.state == .failed {
                OfficeLog.record(OfficeEvent(
                    kind: .finished, taskID: t.id, platform: t.platform,
                    detail: t.note ?? (t.state == .done ? "干完了" : "没干成"),
                    taskTitle: t.prompt, at: ended))
                n += 1
            }
        }
        OfficeLog.publish()
        print(Ansi.green("从历史补了 \(n) 条事件")
            + Ansi.dim("（接力的每一棒时间当时没记，没补）"))
        return
    }

    let events = OfficeLog.all()
    guard !events.isEmpty else {
        print(Ansi.dim("还没有事件。跑 llmq office --backfill 从历史任务补一批。")); return
    }
    OfficeLog.publish()
    print(Ansi.bold("最近 \(min(20, events.count)) 件事") + Ansi.dim("  共 \(events.count) 条"))
    for e in events.suffix(20) {
        let icon: String
        switch e.kind {
        case .dispatched: icon = "派活"
        case .handoff:    icon = "交接"
        case .asked:      icon = "提问"
        case .answered:   icon = "答复"
        case .finished:   icon = "收工"
        case .exhausted:  icon = "耗尽"
        case .idle:       icon = "静默"
        case .other:      icon = "其它"
        }
        var who = e.platform?.displayName ?? "—"
        if let to = e.toPlatform { who += " → " + to.displayName }
        print(Ansi.dim(Format.dateTime(e.at)) + "  " + Ansi.bold(icon)
            + "  " + pad(who, 18) + Ansi.dim(String(e.detail.prefix(44))))
    }
}

func usage() {
    print("""
    \(Ansi.bold("llmq")) — 多平台 LLM 订阅额度汇总

    \(Ansi.bold("用法"))
      llmq collect [-v]        采集本机各 CLI 的用量，写出快照
      llmq report [--json]     显示所有电脑汇总后的额度情况
      llmq status              一行摘要（菜单栏/脚本用）
      llmq doctor              探测本机有哪些数据源、哪些采集器已验证
      llmq plan [edit]         查看/编辑各平台的套餐额度配置
      llmq learn [--apply]     从真实用量反解各平台的额度上限
      llmq waste               各平台的空窗统计（没有上限也算得出来的浪费口径）
      llmq security            暴露面自查（凭据权限、对外监听）
      llmq install-agent [秒]  安装 launchd 定时采集（默认 900 秒）
      llmq work <子命令>       任务队列与执行
      llmq cluster <子命令>    局域网跨机派活（双向 mTLS）
      llmq release publish     发新版给集群（签名）
      llmq update              拉取并安装新版（验签）
      llmq office              数字员工办公室的事件流

    \(Ansi.bold("典型流程"))
      llmq doctor              先看本机认出了哪些平台
      llmq plan edit           把各家订阅的实际额度上限填进去
      llmq install-agent       让它定时后台采集
      llmq report              随时查看
    """)
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "report"
let rest = Array(args.dropFirst())

do {
    switch command {
    case "collect":
        try cmdCollect(verbose: rest.contains("-v") || rest.contains("--verbose"))
    case "report":
        try cmdReport(json: rest.contains("--json"))
    case "status":
        try cmdStatus()
    case "doctor":
        try cmdDoctor(tidy: rest.contains("--tidy"))
    case "debug-parse":
        try cmdDebugParse(rest)
    case "dashboard":
        try cmdDashboard(rest)
    case "learn":
        try cmdLearn(rest)
    case "brief":
        cmdBrief(rest)
    case "archive":
        try cmdArchive(rest)
    case "waste":
        try cmdWaste()
    case "security":
        try cmdSecurity()
    case "machines":
        try cmdMachines()
    case "repo":
        try cmdRepo(rest)
    case "runner":
        try cmdRunner(rest)
    case "work":
        try cmdWork(rest)
    case "plan":
        try cmdPlan(rest)
    case "stranded":
        // llmq stranded —— 列出所有「跑挂了一步、剩下全冻着」的任务图，
        // 以及领先 main 却没合入的 agent 分支。
        //
        // 这个命令存在的理由：这类东西**原来没有任何界面会显示**。
        // Greed 的 f2872114 完成了 4 步、19 个文件的产出，因为第 5 步挂了
        // 就整条躺了一整天 —— 靠人手工 git branch 才发现。
        let strands = TaskGraph.stranded()
        if strands.isEmpty {
            print(Ansi.green("没有搁浅的任务图。"))
        } else {
            print(Ansi.bold("搁浅的任务图 \(strands.count) 张")
                  + Ansi.dim("  跑挂了一步，剩下的不会自己恢复"))
            for st in strands {
                print("  " + Ansi.cyan(st.branch)
                      + Ansi.dim("  完成 \(st.doneCount) 步 · 冻住 \(st.frozenCount) 步"))
                print(Ansi.dim("    挂在：" + st.failedTitles.joined(separator: "、")))
                if !st.repo.isEmpty {
                    let n = GitWorkspace.git(
                        ["rev-list", "--count", "main.." + st.branch], in: st.repo)
                        .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let c = Int(n), c > 0 {
                        print(Ansi.dim("    分支上有 \(c) 个提交没合入 —— 值得捞"))
                    }
                }
            }
        }
        print()
        print(Ansi.bold("领先 main 但没合入的分支"))
        var orphan = 0
        for r in RepoRegistry.all() {
            let path = NSString(string: r.localPath).expandingTildeInPath
            guard GitWorkspace.isRepo(path) else { continue }
            let bs = GitWorkspace.git(
                ["for-each-ref", "--format=%(refname:short)", "refs/heads/agent/"],
                in: path).stdout.split(separator: "\n").map(String.init)
            for b in bs {
                let n = GitWorkspace.git(["rev-list", "--count", "main.." + b], in: path)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let c = Int(n), c > 0 else { continue }
                orphan += 1
                print("  " + r.alias.padding(toLength: 14, withPad: " ", startingAt: 0)
                      + b + Ansi.dim("  领先 \(c) 个提交"))
            }
        }
        if orphan == 0 { print(Ansi.dim("  没有。")) }
    case "map":
        // llmq map [别名或路径] —— 打印会拼进任务提示词的那份仓库地图。
        // 调试用：改了扫描规则之后不用真派一个活才能看见效果。
        let target = rest.first
            .map { a in RepoRegistry.all().first { $0.alias == a }?.localPath ?? a }
            ?? RepoRegistry.all().first(where: { $0.isDefault })?.localPath
            ?? FileManager.default.currentDirectoryPath
        guard let m = RepoMap.text(repo: target), !m.isEmpty else {
            print("扫不出东西：" + target); break
        }
        print(Ansi.bold(target) + Ansi.dim("  \(m.count) 字符 · 约 \(m.count / 3) token"))
        print(m)
    case "view":
        // llmq view [now] —— 手动生成一次下发内容并打印摘要。
        // 调试用：改了组装逻辑之后不用等 work loop 那一轮。
        // 一次全发。单独调某一页时用 llmq view <页面>。
        // now / board 不在列 —— 见 work loop 里「下发视图」那段的说明。
        let pages: [ViewFeed.Page] = [
            ViewFeed.reviewPage(), ViewFeed.playbookPage(),
        ]
        for p in pages where rest.first == nil || rest.first == p.page {
            _ = ViewFeed.publish(p)
        }
        _ = ViewFeed.publishMenu(ViewFeed.menu())
        let page = pages.first { rest.first == nil || rest.first == $0.page } ?? pages[0]
        print(Ansi.bold("已下发 " + page.page)
              + Ansi.dim("  \(page.sections.count) 个区块"))
        for s in page.sections {
            let n = (s.meters?.count ?? 0) + (s.cards?.count ?? 0)
                + (s.facts?.count ?? 0)
            print("  " + s.kind.padding(toLength: 8, withPad: " ", startingAt: 0)
                  + (s.title ?? "") + Ansi.dim(n > 0 ? "  \(n) 条" : ""))
        }
        let pend = ViewFeed.pendingInvocations()
        if !pend.isEmpty {
            print(Ansi.yellow("\(pend.count) 个动作等着执行"))
            for i in pend { print("  " + i.id) }
        }

    case "mirror":
        try cmdMirror(rest)
    case "push":
        try cmdPush(rest)
    case "playbook":
        try cmdPlaybook(rest)
    case "office":
        try cmdOffice(rest)
    case "release":
        try cmdRelease(rest)
    case "update":
        try cmdUpdate(rest)
    case "cluster":
        try cmdCluster(rest)
    case "install-agent":
        try cmdInstallAgent(interval: rest.first.flatMap { Int($0) } ?? 900)
    case "-h", "--help", "help":
        usage()
    default:
        print(Ansi.red("未知命令：\(command)\n"))
        usage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n".utf8))
    exit(1)
}


// MARK: - 项目清单

/// llmq playbook [list|show|approve|pause|resume|seed]
///
/// 清单里是**提前规划、批过一次方案、之后可反复自动执行**的项目。
/// 空窗填活时先从这里取 —— 一个能卖钱的资产包，价值高于补一条注释。
func cmdPlaybook(_ args: [String]) throws {
    let sub = args.first ?? "list"
    let rest = Array(args.dropFirst())

    // 先收一遍手机批的 —— 看清单的时候理应看到最新状态，
    // 而不是「批了但要等 work loop 跑一轮才认」。
    for p in Playbook.ingestApprovals() {
        print(Ansi.green("收到批准：") + p.name)
    }

    switch sub {
    case "list":
        let all = Playbook.all()
        guard !all.isEmpty else {
            print(Ansi.dim("清单是空的。`llmq playbook seed` 放入内置的起手项目。"))
            return
        }
        for p in all {
            let mark = p.paused ? Ansi.dim("暂停")
                : (p.isApproved ? Ansi.green("已批准") : Ansi.yellow("等你过目"))
            print(mark + "  " + Ansi.bold(p.name)
                  + Ansi.dim("  \(p.id.prefix(8))  \(p.recipes.count) 条配方  跑过 \(p.runs) 次"))
            if !p.isApproved {
                let firstLine = p.brief.split(separator: "\n").first.map(String.init) ?? ""
                print(Ansi.dim("    " + firstLine.prefix(72)))
            }
        }
        let pending = all.filter { !$0.isApproved }
        if !pending.isEmpty {
            print()
            print(Ansi.yellow("\(pending.count) 个项目在等你过目。")
                  + Ansi.dim("看方案：llmq playbook show <id>；批：llmq playbook approve <id>"))
        }

    case "show":
        guard let id = rest.first,
              let p = Playbook.all().first(where: { $0.id.hasPrefix(id) }) else {
            print(Ansi.red("没找到这个项目")); exit(1)
        }
        print(Ansi.bold(p.name) + Ansi.dim("  " + p.id))
        print(p.isApproved ? Ansi.green("已批准") : Ansi.yellow("等你过目 —— 批了才会被自动取用"))
        if let r = p.repo { print(Ansi.dim("仓库 " + r)) }
        print()
        print(p.brief)
        print()
        print(Ansi.bold("配方（会被反复执行的任务）"))
        for r in p.recipes {
            print("  · " + r.title + Ansi.dim("  [\(r.tier)]"
                + (r.platform.map { " 点名 " + $0 } ?? "")
                + (r.publishes ? Ansi.yellow("  产出要对外发布 → 会停下来等你确认") : "")))
        }

    // llmq playbook topics <id>            看方向清单
    // llmq playbook topics <id> "方向一" …   往清单里补
    case "topics":
        guard let id = rest.first else {
            print("用法：llmq playbook topics <项目 id> [\"新方向\" …]"); exit(1)
        }
        let adding = Array(rest.dropFirst())
        if !adding.isEmpty { _ = Playbook.addTopics(id, adding) }
        guard let p = Playbook.all().first(where: { $0.id.hasPrefix(id) }) else {
            print(Ansi.red("没找到这个项目")); exit(1)
        }
        print(Ansi.bold(p.name))
        if p.backlog.isEmpty {
            print(Ansi.yellow("方向清单空了 —— 这个项目暂时不会出活。"))
            print(Ansi.dim("补方向：llmq playbook topics \(p.id) \"下一个方向\""))
        } else {
            print(Ansi.dim("待做（下一个会用第一条）"))
            for (i, t) in p.backlog.enumerated() {
                print((i == 0 ? Ansi.green("  → ") : "    ") + t)
            }
        }
        if !p.shipped.isEmpty {
            print(Ansi.dim("已做：" + p.shipped.joined(separator: "、")))
        }

    case "approve":
        guard let id = rest.first, let p = Playbook.approve(id) else {
            print(Ansi.red("没找到这个项目")); exit(1)
        }
        print(Ansi.green("已批准 ") + p.name)
        print(Ansi.dim("从现在起，额度快过期时会自动从它的配方里取活。"))

    case "pause", "resume":
        guard let id = rest.first,
              var p = Playbook.all().first(where: { $0.id.hasPrefix(id) }) else {
            print(Ansi.red("没找到这个项目")); exit(1)
        }
        p.paused = (sub == "pause")
        Playbook.upsert(p)
        print(p.paused ? "已暂停 " + p.name : "已恢复 " + p.name)

    case "seed":
        let added = Playbook.seedBuiltins()
        if added.isEmpty {
            print(Ansi.dim("内置项目已经在清单里了。"))
        } else {
            for p in added { print(Ansi.green("已放入 ") + p.name) }
            print()
            print(Ansi.yellow("都还没批准。")
                  + Ansi.dim("先看方案：llmq playbook show <id>"))
        }

    default:
        print("用法：llmq playbook [list|show <id>|approve <id>|topics <id> [新方向…]"
              + "|pause <id>|resume <id>|seed]")
    }
}


// MARK: - 推送

/// llmq push [check|test <正文>]
///
/// 这台 Mac 自己给手机发通知 —— APNs 只要一个 ES256 签名的 JWT，
/// 签名在哪儿做都行，不需要服务器，也就不用把任务内容交给第三方。
func cmdPush(_ args: [String]) throws {
    switch args.first ?? "check" {
    case "check":
        for (step, ok, detail) in Push.diagnose() {
            print((ok ? Ansi.green("✓") : Ansi.red("✗")) + "  "
                  + step.padding(toLength: max(step.count, 22), withPad: " ", startingAt: 0)
                  + Ansi.dim(detail))
        }
        if Push.Config.load() == nil {
            print()
            print(Ansi.dim("""
            配置长这样（放 ~/.llmq/apns.json，不要进仓库）：
              {
                "keyID":    "从 Apple 后台建 Key 时给的 10 位",
                "teamID":   "你的 Apple Developer Team ID",
                "bundleID": "你的 App bundle id",
                "keyFile":  "~/.llmq/AuthKey_XXXXXXXXXX.p8"
              }
            """))
        }

    // llmq push pending —— 现在会推什么。只看不发。
    case "pending":
        let items = Nudge.pending()
        if items.isEmpty {
            print(Ansi.green("此刻没有需要打扰你的事。"))
            print(Ansi.dim("判据：只推需要你做决定的 —— 方案等过目、产出等验收、"
                           + "任务被拦下、空窗没活可填。"))
        } else {
            for i in items {
                let muted = Nudge.recentlySent(i.key)
                print((muted ? Ansi.dim("（静默中）") : Ansi.yellow("会推 "))
                      + i.body + Ansi.dim("  角标 \(i.badge)"))
            }
        }

    // llmq push badge [数字] —— 把手机角标改成真实待办数（不响不弹）
    case "badge":
        let n = args.dropFirst().first.flatMap { Int($0) }
            ?? Nudge.pending().reduce(0) { $0 + $1.badge }
        let sent = Push.syncBadge(n)
        print(sent > 0 ? Ansi.green("角标已改成 \(n)") + Ansi.dim("（\(sent) 台设备）")
                       : Ansi.red("没推出去。llmq push check 看卡在哪"))

    case "test":
        let body = args.dropFirst().joined(separator: " ")
        let n = Push.send(.needsYou,
                          body: body.isEmpty ? "推送通了。" : body,
                          subtitle: "来自 " + Paths.machineName())
        print(n > 0 ? Ansi.green("已推给 \(n) 台设备")
                    : Ansi.red("一台都没推出去。跑 llmq push check 看卡在哪"))

    default:
        print("用法：llmq push [check|pending|badge [n]|test <正文>]")
    }
}


// MARK: - 镜像

/// llmq mirror [--run]
///
/// 镜像卡住的时候，症状是「另一台机器掉线了」—— 而它其实好好的，
/// 只是这台机器没把它的快照拉下来。实测过一次：iCloud 上 MacBook 的
/// 快照是 14:28 的，本地那份卡在前一晚 23:08，于是 dashboard 里整台
/// 机器消失、调度以为它上面的平台都没在用。
///
/// 而错误只显示在菜单栏 App 的弹窗里，没有历史、命令行也看不到 ——
/// 等于出了问题只能靠猜。
func cmdMirror(_ args: [String]) throws {
    let local = Paths.sharedRoot
    let cloud = Push.mirrorDir
    let fm = FileManager.default

    print(Ansi.bold("本地 ") + local.path.replacingOccurrences(
        of: fm.homeDirectoryForCurrentUser.path, with: "~"))
    print(Ansi.bold("云端 ") + cloud.path.replacingOccurrences(
        of: fm.homeDirectoryForCurrentUser.path, with: "~"))

    guard fm.fileExists(atPath: cloud.path) else {
        print(Ansi.red("云端目录不存在 —— iCloud 云盘里没有 LLMQuotaBar 文件夹"))
        return
    }

    // 逐个快照比对：谁新谁旧一眼看清。**这是判断「掉线」真假的唯一硬证据。**
    print()
    print(Ansi.bold("快照新鲜度"))
    let selfID = Paths.machineID()
    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"
    for dir in ["snapshots"] {
        let l = local.appendingPathComponent(dir)
        let c = cloud.appendingPathComponent(dir)
        let names = Set((try? fm.contentsOfDirectory(atPath: l.path)) ?? [])
            .union((try? fm.contentsOfDirectory(atPath: c.path)) ?? [])
        for name in names.sorted() where name.hasSuffix(".json") {
            let lm = (try? l.appendingPathComponent(name)
                .resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let cm = (try? c.appendingPathComponent(name)
                .resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let isSelf = name.hasPrefix(selfID)
            let who = isSelf ? "本机" : "对端"
            let lag = (lm != nil && cm != nil) ? cm!.timeIntervalSince(lm!) : 0
            let mark = lag > 600 ? Ansi.red("✗ 落后 " + Format.duration(lag))
                : Ansi.green("✓")
            print("  " + mark + " " + who + " " + String(name.prefix(8))
                  + Ansi.dim("  本地 " + (lm.map { df.string(from: $0) } ?? "无")
                             + "  云端 " + (cm.map { df.string(from: $0) } ?? "无")))
        }
    }

    // **汇总真的读到了几台。** 文件在、时间新，不代表汇总认它 ——
    // 解码失败是静默跳过的（try? decode），症状就是「机器凭空消失」。
    print()
    print(Ansi.bold("汇总读到的机器"))
    let snaps = SnapshotStore.loadAll()
    if snaps.isEmpty {
        print(Ansi.red("  一台都没读到"))
    }
    for s in snaps {
        let age = Date().timeIntervalSince(s.generatedAt)
        print("  " + (age < 3600 ? Ansi.green("●") : Ansi.dim("○")) + " "
              + s.machineName + Ansi.dim("  采集于 " + Format.duration(age) + "前"
                                         + "  " + s.machineID.prefix(8)))
    }
    // 目录里有几个文件，和汇总认了几台，对不上就是解码出了问题。
    let onDisk = [Paths.snapshotsDir, Paths.localSnapshotsDir].flatMap { d -> [String] in
        ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
    }
    let uniqueFiles = Set(onDisk).count
    if uniqueFiles > snaps.count {
        print(Ansi.red("  ✗ 磁盘上有 \(uniqueFiles) 份快照，汇总只认了 \(snaps.count) 台"))
    }
    for f in SafeDecode.failures {
        print(Ansi.red("  ✗ 解不出 " + String(f.file.prefix(16)))
              + Ansi.dim("  " + f.type + " · " + f.reason))
    }
    for (file, err) in SnapshotStore.decodeFailures {
        print(Ansi.red("  ✗ 解不出 " + String(file.prefix(12))) + Ansi.dim("  " + err.prefix(220)))
    }

    guard args.contains("--run") else {
        print()
        print(Ansi.dim("跑一次同步并打印错误：llmq mirror --run"))
        return
    }

    print()
    print(Ansi.bold("同步中…"))
    let stats = MirrorService.sync(local: local, cloud: cloud, selfMachineID: selfID)
    print("  推 \(stats.pushed) · 拉 \(stats.pulled)"
          + (stats.claimed > 0 ? " · 领 \(stats.claimed)" : ""))
    if stats.errors.isEmpty {
        print(Ansi.green("  没有错误"))
    } else {
        for e in stats.errors { print(Ansi.red("  ✗ ") + e) }
    }
}


/// 执行手机点来的动作。
///
/// **动作 id 的含义只有这里知道** —— 客户端原样写回，这里解释。
/// 所以加一种新动作不需要客户端更新，只要这里认得它。
///
/// - Returns: nil 表示不认识这个动作（不记 done，也不算失败）；
///   true/false 是执行结果。
func runInvocation(_ inv: ViewFeed.Invocation) -> Bool? {
    let parts = inv.id.split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return nil }

    switch (parts[0], parts[1]) {
    case ("review", "merge"), ("review", "discard"):
        guard parts.count == 3 else { return false }
        let bits = parts[2].split(separator: "|", maxSplits: 1).map(String.init)
        guard bits.count == 2 else { return false }
        // **分支已经不在 = 已经办过了。** 和 ingestVerdicts 同一条规则:合并成功
        // 会删分支,人双击、或 autoLand/另一条路先合掉了,第二下对着不存在的
        // 分支只会失败 3 次静默放弃(对账实锤:actions/.failures.json 9 条全是这样)。
        if !GitWorkspace.branchExists(bits[1], in: bits[0]) {
            Review.markDecided(repo: bits[0], branch: bits[1])
            return true
        }
        if parts[1] == "merge" {
            guard case .success = Review.merge(repo: bits[0], branch: bits[1]) else { return false }
            Review.markDecided(repo: bits[0], branch: bits[1])   // 卡片要消失,两条路同一台账
            return true
        }
        Review.discard(repo: bits[0], branch: bits[1],
                       reason: inv.note ?? "手机上丢弃")
        Review.markDecided(repo: bits[0], branch: bits[1])
        return true

    // 手机上放行一个被拦下的高危任务。
    //
    // 老板 2026-08-22:「刚刚高危拦截,我确认了,但是手机端一直在重复
    // 弹出来让我确认」。查下来是**推送要求了一个手机做不到的动作**:
    // 通知说「1 个任务被拦下等你放行」,而 App 那边只把 blocked 当成
    // 一个计数显示(「卡住 N 件」),没有任何按钮会写出放行指令 ——
    // 于是他点了也没用,任务永远卡着,提醒永远在。
    // 和成果推送那次一模一样的形状:**别推人做不到的事**。
    case ("task", "approve"), ("task", "discard"):
        guard parts.count == 3,
              let t = TaskStore.all().last(where: { $0.id == parts[2] }),
              t.state == .blocked else { return false }
        // **放行 = 提交已审改动,不是重排。**
        //
        // 2026-08-23 复审(第一轮 H3)逮到:原来这里只把 state 改回 .queued,
        // 而高危拦截时改动是**留在工作区、没提交**的。重排会走 GitWorkspace
        // .prepare → worktree remove --force 铲掉那个工作区 → agent 从头再跑
        // → 又撞同一条高危路径 → 再次 blocked、再弹一张卡。这恰好复现老板
        // 原来报的「确认了但手机端一直重复弹出」,还白烧一份额度、丢掉他看过的 diff。
        //
        // 正确做法和 Ask 卡的「放行并提交」同一条路:Approval.settle 直接把
        // 工作区的改动提交(approve)或丢弃(discard),不重跑。
        let r = Approval.settle(task: t, approve: parts[1] == "approve")
        var x = r.task
        x.pendingAsk = nil
        x.note = (parts[1] == "approve" ? "手机上放行并提交:" : "手机上丢弃:")
            + (inv.note ?? r.note)
        // 同一件事有两个入口(「等你放行」卡片 / 「问题」页)。从卡片放行之后
        // 问题文件还挂在 questions/ 里,手机「问题」页照样显示、再答一次就成了
        // stale-ask(「确认了还弹 / 答了白答」)。两个入口必须互相撤销。
        AskStore.retract(taskID: x.id, machine: Paths.machineID())
        try? TaskStore.append(x)
        return true

    case ("playbook", "approve"):
        guard parts.count == 3 else { return false }
        return Playbook.approve(parts[2]) != nil

    default:
        return nil
    }
}


/// 一轮落地：验收 → 合并 → 刷新 → 派审核 → 补证据。
///
/// **在后台跑,不占派活的时间。** 它里面的 verifyMerge 会同步跑整个
/// 测试套件(几分钟起),挂在派活前面会让产线看起来「停了」——
/// 老板 2026-08-22 一天问了九次,根子就在这里。
nonisolated(unsafe) var landingInFlight = false

func landingRound() {
                for repo in RepoRegistry.all() {
                    let path = NSString(string: repo.localPath).expandingTildeInPath
                    // 标了「要人看」的仓库现在也走全套自动环节 ——
                    // 只是门槛更高（见 Review.autoLand 里 manualReview 那段）。
                    // 上一版我在这里 `continue`，把补证据、agent 审核、
                    // 分支刷新**一起**挡掉了，结果是既要人审又没图可看。
                    if repo.manualReview {
                        // 只数真该交证据的产出分支:审核结论/证据任务自己的分支
                        // 不需要截图,算进去会让这行日志连续 83 轮喊「1 条还没交证据」
                        // 而实际一条证据任务都没派(2026-08-23)—— 日志说谎比不说更糟。
                        let n = Review.list(repo: path).filter {
                            $0.evidence.isEmpty
                                && !($0.prompt ?? "").hasPrefix("【审查")
                                && !($0.prompt ?? "").hasPrefix("【证据】")
                                && !($0.prompt ?? "").hasPrefix("【看效果】")
                        }.count
                        if n > 0 {
                            print(Ansi.dim("  要看效果 " + repo.alias
                                + "：\(n) 条还没交证据，先派它们去跑一遍截图"))
                        }
                    }
                    for o in Review.autoLand(repo: path) {
                        let mark = o.landed ? Ansi.green("  ✓ 落地 ")
                                            : Ansi.yellow("  ⚠︎ 没落 ")
                        print(mark + o.branch + Ansi.dim("  " + o.note))
                    }
                    // 落不下去的里面，分「过期了」和「真撞了设计」两种。
                    // 过期的派回原平台去刷新 —— 它还留着当时的会话。
                    // 详见 StaleBranch 的说明。
                    for o in StaleBranch.dispatchRefresh(repo: path) {
                        let mark = o.enqueued ? Ansi.green("  ↻ 刷新 ")
                                              : Ansi.yellow("  ⚠︎ 没派 ")
                        print(mark + o.branch + Ansi.dim("  " + o.note))
                    }
                    // 改了看得见的东西却没交证据 → 派回原平台跑一遍截图。
                    // 人只看「跑起来什么样」，不该替 agent 补跑（见 EvidenceGate）。
                    // 机械条件判不了的（高危 / 碰构建 CI 签名）→ 派专用评审
                    // agent 出结论，人不参与「这段 diff 要不要合」。
                    for o in MergeReview.dispatch(repo: path) {
                        print(Ansi.green("  ⚖︎ " + o.action + " ") + o.branch
                            + Ansi.dim("  " + o.note))
                    }
                    for o in EvidenceGate.dispatchEvidence(repo: path) {
                        let mark = o.enqueued ? Ansi.green("  📷 补证据 ")
                                              : Ansi.yellow("  ⚠︎ 没派 ")
                        print(mark + o.branch + Ansi.dim("  " + o.note))
                    }
                }
}
