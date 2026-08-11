import Foundation
import LLMQuotaCore

// MARK: - Terminal helpers

enum Ansi {
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

func cmdCollect(verbose: Bool) throws {
    let result = try LLMQuota.collect()
    let snap = result.snapshot

    print(Ansi.bold("采集完成") + " · \(snap.machineName) · 耗时 \(String(format: "%.1f", result.duration))s")

    let detected = snap.platforms.filter(\.detected)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    print("检测到 \(detected.count) 个平台的数据源，快照已写入：")
    print("  " + Paths.localSnapshotsDir.path.replacingOccurrences(of: home, with: "~"))

    switch result.iCloudSync {
    case .synced:
        print("  " + Ansi.green("已同步到 iCloud")
            + Ansi.dim(" " + (Paths.iCloudSnapshotsDir?.path
                .replacingOccurrences(of: home, with: "~") ?? "")))
    case .unavailable:
        print(Ansi.yellow("  未检测到 iCloud Drive，快照只存在本地，其他电脑看不到"))
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

// MARK: - work

func cmdWork(_ args: [String]) throws {
    let sub = args.first ?? "list"
    let rest = Array(args.dropFirst())

    switch sub {
    case "add":
        guard let prompt = rest.first(where: { !$0.hasPrefix("--") }) else {
            print("用法：llmq work add \"<任务描述>\" [--repo <路径>]")
            exit(2)
        }
        var repo = FileManager.default.currentDirectoryPath
        if let i = rest.firstIndex(of: "--repo"), i + 1 < rest.count {
            repo = NSString(string: rest[i + 1]).expandingTildeInPath
        }
        guard GitWorkspace.isRepo(repo) else {
            print(Ansi.red("\(repo) 不是 git 仓库。agent 需要在 worktree 里干活。"))
            exit(1)
        }
        var t = WorkTask(id: String(UUID().uuidString.prefix(8)).lowercased(),
                         prompt: prompt, repo: repo)
        if !args.contains("--no-classify") {
            print(Ansi.dim("分诊中…"))
            t.profile = TaskClassifier.classify(
                prompt: prompt, repo: repo,
                history: TaskStore.all(), dashboard: LLMQuota.dashboard())
        }
        try TaskStore.append(t)
        print(Ansi.green("已入队 ") + t.id + Ansi.dim("  仓库 " + repo))
        printProfile(t.profile)

    case "list":
        let tasks = TaskStore.all()
        if tasks.isEmpty { print(Ansi.dim("任务队列是空的。llmq work add \"...\" 加一个。")); return }
        print(Ansi.dim(pad("ID", 10) + pad("状态", 8) + pad("档次", 6)
            + pad("平台", 10) + pad("耗时", 9) + pad("改动", 7) + "任务"))
        for t in tasks {
            let color: (String) -> String = {
                switch t.state {
                case .done: return Ansi.green
                case .failed: return Ansi.red
                case .running: return Ansi.yellow
                case .queued: return Ansi.dim
                case .blocked: return Ansi.cyan
                }
            }()
            print(pad(t.id, 10)
                + pad(color(t.state.rawValue), 8)
                + pad(t.profile?.tier.displayName ?? "—", 6)
                + pad(t.platform?.displayName ?? "—", 10)
                + pad(t.duration.map { String(format: "%.0fs", $0) } ?? "—", 9)
                + pad(t.changedFiles.map { "\($0)" } ?? "—", 7)
                + String(t.prompt.prefix(46)))
            if let n = t.note { print(Ansi.dim("          " + n)) }
            if let b = t.branch { print(Ansi.dim("          分支 " + b)) }
        }

    case "run":
        try runOneTask(dryRun: rest.contains("--dry-run"))

    case "loop":
        try cmdWorkLoop(rest)

    case "install-loop":
        try cmdInstallLoop()

    case "probe":
        try probePlatforms()

    // llmq work reserve [--limit N] [--commit]
    //
    // 储备任务池：额度快作废时拿来填窗口的低危维护任务。
    // 默认只看不写 —— 生成任务是会烧额度的动作，不该是敲错一个词的后果。
    case "reserve":
        let repoPath = RepoRegistry.resolve(nil) ?? FileManager.default.currentDirectoryPath
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
        let repoPath = RepoRegistry.resolve(
            rest.firstIndex(of: "--repo").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil })
            ?? FileManager.default.currentDirectoryPath
        guard GitWorkspace.isRepo(repoPath) else {
            print(Ansi.red("\(repoPath) 不是 git 仓库")); exit(1)
        }

        if let i = rest.firstIndex(of: "--merge"), i + 1 < rest.count {
            switch Review.merge(repo: repoPath, branch: rest[i + 1]) {
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
            var ok = 0, bad = 0
            for it in cands {
                print("\n" + Ansi.bold(it.branch) + Ansi.dim("  验证中…"))
                switch Review.merge(repo: repoPath, branch: it.branch) {
                case .success:
                    // 不用手动记：Review.merge 内部已经把 landedAt 写回任务记录了。
                    ok += 1
                    print(Ansi.green("  ✓ 已落地"))
                case .failure(let e):
                    bad += 1
                    print(Ansi.red("  ✗ " + e.localizedDescription))
                }
            }
            print("\n" + Ansi.bold("落地 \(ok) 份") + (bad > 0 ? Ansi.dim("，\(bad) 份没过，留着待查") : ""))
            return
        }

        let items = Review.list(repo: repoPath)
        if !done.isEmpty {
            let rate = done.isEmpty ? 0 : Double(landed.count) / Double(done.count)
            print(Ansi.dim("产出 \(done.count) 份，落地 \(landed.count) 份"
                + (dropped.isEmpty ? "" : "，丢弃 \(dropped.count) 份")
                + String(format: "  落地率 %.0f%%", rate * 100)))
        }
        guard !items.isEmpty else {
            print(Ansi.dim("没有待审的 agent 分支。")); return
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
        print("用法：llmq work [add|list|run|loop|install-loop|probe|cooldowns|resume|review|reserve]")
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

    print(Ansi.bold("平台可用性探针") + Ansi.dim("  每个平台发一句最短的话，只看认证通不通"))
    print(Ansi.dim(pad("平台", 10) + pad("结果", 12) + pad("耗时", 8) + "说明"))

    for runner in RunnerRegistry.all {
        guard runner.isAvailable else {
            print(pad(runner.platform.displayName, 10) + pad(Ansi.dim("未安装"), 12)
                + pad("—", 8) + runner.binaryName + " 不在 PATH 上")
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
            if let cause = CooldownLedger.classify(r.stdout + " " + r.stderr) {
                let cd = CooldownLedger.record(
                    platform: runner.platform, cause: cause, detail: f.describe)
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
    }
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
func runOneTask(dryRun: Bool, quiet: Bool = false) throws -> RunOutcome {
    guard var task = TaskStore.nextQueued() else {
        if !quiet { print(Ansi.dim("没有排队中的任务。")) }
        return .noTask
    }

    let history = TaskStore.all()
    let dash = LLMQuota.dashboard()
    let decision = WorkScheduler().decide(
        dashboard: dash, runners: RunnerRegistry.all,
        task: task, history: history)

    for r in decision.rejected {
        print(Ansi.dim("  排除 " + pad(r.platform.displayName, 10) + r.reason))
    }
    guard !decision.candidates.isEmpty else {
        if !quiet { print(Ansi.red("没有可用平台，任务留在队列里。")) }
        return .noPlatform
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
    task.startedAt = Date()
    try TaskStore.append(task)
    Inbox.writeResult(for: task)

    var attempts: [String] = []
    /// 上一个平台留下的交接信息。非 nil 表示这是接力，不是新开工。
    var handoff: Handoff?
    /// 这一轮是不是「答复回来了，接着上一轮干」。
    /// 由 ingest 把答案并进任务时设上，见 WorkTask.resumeContext。
    let resumedAnswer: (AskAnswer, Ask)? = task.resumeContext
    let overallStart = Date()
    // 单个任务在所有平台上的总时间预算。防止三个平台各超时 20 分钟拖成一小时。
    let totalBudget: TimeInterval = 1800
    // 单个平台的上限。原来是 20 分钟，一个卡住的平台就把总预算吃光了，
    // 后面的候选根本轮不上。降到 10 分钟，三个平台都试得过来。
    let perAttemptTimeout: TimeInterval = 600

    // 按额度充裕度依次尝试。认证/环境类失败换下一个平台，
    // agent 真跑砸了就停 —— 换平台重试只会重复烧额度。
    for (idx, pick) in decision.candidates.enumerated() {
        task.platform = pick.platform
        if !task.triedPlatforms.contains(pick.platform) {
            task.triedPlatforms.append(pick.platform)
        }
        print(Ansi.bold("\n[\(idx + 1)/\(decision.candidates.count)] " + pick.platform.displayName))
        // 记一笔给办公室画面。第一个候选是「老板派活」，之后的是「同事接手」——
        // 后者是真实的协作，不是编出来的。
        OfficeLog.record(OfficeEvent(
            kind: idx == 0 ? .dispatched : .handoff,
            taskID: task.id,
            platform: idx == 0 ? pick.platform : decision.candidates[idx - 1].platform,
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
                    repo: task.repo, taskID: task.id, platform: pick.platform)
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
                continue
            }
            print(Ansi.dim("  分支 " + ws.branch))
        }
        task.branch = ws.branch

        // 接力说明只追加文件清单和中断原因，**不贴 diff** ——
        // 工作区就在 agent 眼前，让它自己看比塞进提示词便宜得多。
        var effectivePrompt = task.prompt + ((handoff ?? task.handoff)?.briefing() ?? "")
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
        let cmd = pick.runner.command(prompt: effectivePrompt, cwd: ws.path)
        let attemptTimeoutPreview = ProcessInfo.processInfo.environment["LLMQ_ATTEMPT_TIMEOUT"]
            .flatMap(Double.init) ?? task.profile?.timeout ?? perAttemptTimeout
        print(Ansi.dim(String(format: "  执行中…（单次上限 %.0f 秒）", attemptTimeoutPreview)))
        let started = Date()
        // 画像估出来的超时比固定 10 分钟合理：简单任务不该占着 10 分钟的坑，
        // 那会拖垮整个候选轮转。
        // 调试开关：压低单次超时以复现「做了一半被中断」的接力场景。
        // 这类场景自然发生时很难抓，但它恰恰是接力逻辑最该被验证的路径。
        let attemptTimeout = ProcessInfo.processInfo.environment["LLMQ_ATTEMPT_TIMEOUT"]
            .flatMap(Double.init)
            ?? task.profile?.timeout ?? perAttemptTimeout
        let r = Proc.run(cmd.launchPath, cmd.args, cwd: ws.path, env: cmd.env,
                         timeout: attemptTimeout)
        let elapsed = Date().timeIntervalSince(started)
        let changed = GitWorkspace.changedFileCount(in: ws.path)

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
                try? TaskStore.append(task)
                return .noPlatform
            }
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

            // 把平台侧失败记进冷却账本。下次调度直接跳过，不再白建 worktree。
            if let cause = CooldownLedger.classify(r.stdout + " " + r.stderr) {
                let cd = CooldownLedger.record(
                    platform: pick.platform, cause: cause, detail: failure.describe)
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
            let spent = Date().timeIntervalSince(overallStart)
            let hasNext = idx + 1 < decision.candidates.count
            if failure.shouldTryNextPlatform && hasNext && spent < totalBudget {
                print(Ansi.yellow("  换下一个平台重试")
                    + Ansi.dim(String(format: "（已用 %.0f 分钟 / 预算 %.0f 分钟）",
                                      spent / 60, totalBudget / 60)))
                continue
            }
            if failure.shouldTryNextPlatform && hasNext {
                print(Ansi.yellow(String(format: "  还有候选，但总时间已用 %.0f 分钟，超预算，停止重试",
                                         spent / 60)))
            }
            // 所有候选都试完了才清理。有进度就留着分支让人看，没进度才删干净。
            task.state = .failed
            task.endedAt = Date()
            task.exitCode = r.exitCode
            task.changedFiles = touched.count
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
            if !leaks.isEmpty {
                task.state = .failed
                task.note = "改动里疑似含凭据（\(leaks.joined(separator: "、"))），已拒绝提交"
            } else {
                // 提交前先验一次。**在提交之前**是刻意的：提交完再验的话，
                // 坏代码已经落在分支上，还得再回滚一次；而且 work review
                // 会把它当成正常产出列出来，说「能干净合入」。
                let v = Verifier.run(in: ws.path, repoPath: task.repo)
                if v.ran {
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
                    break
                }

                let c = GitWorkspace.commit(
                    in: ws.path,
                    message: "agent(\(pick.platform.rawValue)): \(task.prompt.prefix(60))")
                if c.exitCode == 0 {
                    task.state = .done
                    task.note = "改了 \(changed) 个文件"
                        + (v.ran ? "，\(v.summary)" : "")
                        + "，已提交到 \(ws.branch)"
                    if let h = handoff {
                        task.note! += "（接手 \(h.fromPlatform.displayName) 的进度完成）"
                    }
                } else {
                    task.state = .failed
                    task.note = "提交失败：" + String(c.stderr.suffix(160))
                }
            }
        }
        // 跑通了就把这个平台的冷却清掉，连续失败计数归零。
        if task.state == .done { CooldownLedger.clear(pick.platform) }

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

    print(Ansi.bold("工作循环已启动")
        + Ansi.dim("  每 \(Int(policy.tickSeconds))s 查一次队列"
            + " · 每小时最多 \(policy.maxTasksPerHour) 个任务"
            + " · 连续失败 \(policy.stopAfterConsecutiveFailures) 次就停"))

    var gate = RateGate(maxPerHour: policy.maxTasksPerHour)
    var consecutiveFailures = 0
    var lastCollect = Date.distantPast
    var lastHeartbeat = Date()
    var ranTotal = 0

    while !stopping {
        if Date().timeIntervalSince(lastCollect) >= policy.collectSeconds {
            _ = try? LLMQuota.collect()
            lastCollect = Date()
        }

        // 先看看手机往 iCloud 收件箱里丢了什么。
        // 先收答复再取任务：答复会把 blocked 的任务放回 queued，
        // 这一轮就能立刻接上，不用再等一个 tick。
        for r in AskIngest.run(
            machineID: Paths.machineID(),
            load: { TaskStore.all() },
            save: { try TaskStore.append($0) }
        ) {
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

        for got in Inbox.ingest() {
            print("[\(Format.dateTime(Date()))] " + Ansi.green("收到远程任务 ")
                + got.taskID + Ansi.dim("  来自 " + got.source))
        }

        if TaskStore.nextQueued() != nil {
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
                    print(Ansi.dim("  所有平台都不可用，等冷却过去"))
                    Thread.sleep(forTimeInterval: min(300, policy.tickSeconds * 10))
                case .blocked:
                    // 既不算成功也不算失败。而且**立刻去取下一个任务**，
                    // 不睡一个 tick —— 提问的任务已经不在 queued 里了，
                    // 这一刻额度槽是空的，睡过去就是白白浪费。
                    consecutiveFailures = 0
                    print(Ansi.cyan("  任务在等答复，继续取下一个"))
                    continue
                case .noTask:
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
                Thread.sleep(forTimeInterval: min(600, max(60, next.timeIntervalSinceNow)))
            }
        } else if Date().timeIntervalSince(lastHeartbeat) >= policy.heartbeatSeconds {
            // 空闲时也要偶尔说句话，否则你无法区分"没任务"和"循环挂了"。
            print(Ansi.dim("[\(Format.dateTime(Date()))] 空闲中"
                + "，本轮已完成 \(ranTotal) 个任务"))
            lastHeartbeat = Date()
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
            all[pf] = r
            try AgentRoles.save(Array(all.values))
            print(Ansi.green("已更新 ") + pf.displayName)
        }

        let dash = LLMQuota.dashboard()
        let history = TaskStore.all()
        print(Ansi.bold(pad("岗位", 12) + pad("agent", 24) + pad("最高风险", 12)
            + pad("难度上限", 12) + "偏好"))
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
            print(pad(role.title, 12) + pad(name, 24)
                + pad(role.maxRisk.displayName, 12) + pad(tierMark, 12)
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
    // llmq repo verify <别名> "<命令>" [--timeout 秒]
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
                + note)
        }
        if broken > 0 {
            print(Ansi.dim("\n有问题的别名派活时会失败（报「工作区创建失败」）。"
                + "改路径：llmq repo add <别名> <新路径>"))
        }
    default:
        print("用法：llmq repo [add|list]")
        exit(2)
    }
}

func cmdMachines() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func short(_ p: String) -> String { p.replacingOccurrences(of: home, with: "~") }

    print(Ansi.bold("本机"))
    print("  名称      " + Paths.machineName())
    print("  机器 ID   " + Ansi.dim(Paths.machineID()))

    print("\n" + Ansi.bold("共享通道"))
    if let snapDir = Paths.iCloudSnapshotsDir {
        let probe = snapDir.appendingPathComponent(".llmq-probe")
        try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let writable = (try? Data().write(to: probe)) != nil
        try? FileManager.default.removeItem(at: probe)
        print("  快照      " + short(snapDir.path) + "  "
            + (writable ? Ansi.green("可写") : Ansi.red("不可写")))
    } else {
        print("  快照      " + Ansi.red("iCloud Drive 不可用 —— 多机汇总没法工作"))
    }
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

func cmdDoctor() throws {
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
        // 目录存在不等于写得进去 —— iCloud Drive 受 TCC 管，实际试一次才知道。
        let probe = icloud.appendingPathComponent(".llmq-write-probe")
        let writable = (try? Data().write(to: probe)) != nil
        try? FileManager.default.removeItem(at: probe)
        print("  iCloud    " + short(icloud.path) + "  "
            + (writable ? Ansi.green("可写") : Ansi.yellow("不可写，需要完全磁盘访问权限")))
    } else {
        print("  iCloud    " + Ansi.yellow("未启用（多机汇总会失效）"))
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

    let cfg = PlansStore.load()
    print(Ansi.bold("套餐配置") + Ansi.dim(" · " + Paths.plansFile.path))
    for plan in cfg.plans {
        print("\n" + Ansi.bold(plan.platform.displayName) + Ansi.dim(" · \(plan.planName)")
            + (plan.enabled ? "" : Ansi.dim(" [已停用]")))
        if let c = plan.monthlyCost {
            print("  月费 \(c) \(plan.currency)")
        }
        for l in plan.limits {
            let cap = l.limit.map { Format.metricValue($0, metric: l.metric) }
                ?? Ansi.yellow("未填")
            print("  " + pad(l.label, 8) + pad(l.kind == .periodic ? "周期" : "滚动", 6)
                + pad(l.metric.displayName, 14) + "上限 " + cap)
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

        let dst = ClusterCA.dir.appendingPathComponent("\(node).p12")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: dst.path)
        try? FileManager.default.removeItem(at: ClusterCA.caCert)
        try FileManager.default.copyItem(at: caSrc, to: ClusterCA.caCert)

        // 先验一遍能不能真的解开，别等到连不上才发现口令抄错了。
        _ = try ClusterNet.loadIdentity(node: node, password: pw)
        try ClusterNet.Passphrase.save(pw, node: node)

        var cfg = ClusterConfigStore.load() ?? ClusterConfig(nodeName: node)
        cfg.nodeName = node
        try ClusterConfigStore.save(cfg)
        print(Ansi.green("导入成功，本机节点名 ") + node)
        print(Ansi.dim("口令已存进钥匙串，磁盘上只留加密过的 p12"))

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

    // llmq cluster fix-keychain —— 放宽口令条目的访问控制
    //
    // 必须在终端里交互跑：读那一步可能弹一次窗，点「允许」即可。
    case "fix-keychain":
        let cfg = loadConfig()
        do {
            try ClusterNet.Passphrase.relax(node: cfg.nodeName)
            print(Ansi.green("好了 ") + Ansi.dim("—— 以后 llmq update 换了二进制也不会再断"))
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

func cmdRelease(_ rest: [String]) throws {
    switch rest.first ?? "status" {

    // llmq release publish [--notes "..."]
    case "publish":
        var notes = ""
        if let i = rest.firstIndex(of: "--notes"), i + 1 < rest.count { notes = rest[i + 1] }
        let node = ClusterConfigStore.load()?.nodeName ?? Paths.machineName()

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

        print(Ansi.dim("打包…"))
        let tar = try ReleasePacker.pack(binDir: binDir)
        defer { try? FileManager.default.removeItem(at: tar.deletingLastPathComponent()) }

        let m = try ReleaseChannel.publish(tarball: tar, notes: notes, by: node)
        // 主机自己也标记成已装，否则它会检测到"有更新"再装一遍自己刚发的东西。
        ReleaseChannel.markInstalled(m.sha256)
        print(Ansi.green("已发布 ") + m.sha256.prefix(12) + Ansi.dim("  " + m.file))
        if !notes.isEmpty { print(Ansi.dim("  " + notes)) }
        print(Ansi.dim("从机会在下次检查时自动更新，或者立刻跑：llmq update"))
        print(Ansi.dim("从机上的 llmq 太老、连 update 命令都没有时："
                       + "llmq release bootstrap 打印一段可粘贴的引导脚本"))

    // llmq release install-updater [秒]
    case "install-updater":
        let secs = rest.dropFirst().first.flatMap { Int($0) } ?? 1800
        try installUpdater(interval: secs)

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

          llmq release publish [--notes "..."]   编译、打包、签名、发到 iCloud
          llmq release status                    看当前通道里是什么版本
          llmq release install-updater [秒]      装成定时自动更新（默认 1800 秒）

        签名链：集群 CA → release-signer 证书 → 清单签名 → 包哈希。
        从机会逐环验证，任何一环对不上就拒绝安装。
        """)
    }
}

/// 装一个定时检查更新的 launchd 任务。
///
/// 故意不做成"发现新版就立刻装"：更新会替换正在跑的二进制，
/// 半小时一次已经足够快，而检查本身几乎不花钱（读两个小文件 + 验一次签名）。
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
        print(Ansi.green("已更新到 ") + m.sha256.prefix(12))
        if !m.notes.isEmpty { print(Ansi.dim("  " + m.notes)) }
        // 换了二进制不等于换了正在跑的进程。
        //
        // cluster serve 是**常驻**的：更新只是把磁盘上的文件换掉，
        // 那个已经跑了几天的进程还在执行老代码。于是「服务端的 bug 修好了、
        // 也发版了、对方也更新了」三件事同时成立，问题却一点没变 ——
        // 这正好浪费了一轮排查。采集和 worker 不受影响，它们是
        // StartInterval 每次新起进程，自然就用上了新二进制。
        if restartClusterServe() {
            print(Ansi.dim("  已重启常驻的 cluster serve（换二进制不换进程，得踢一下）"))
        }
    }
}

/// 踢一下常驻的 cluster serve。没装就返回 false。
@discardableResult
func restartClusterServe() -> Bool {
    let label = "com.llmquotabar.cluster"
    let listed = Proc.run("/bin/launchctl", ["list"], cwd: "/tmp", env: [:], timeout: 15)
    guard listed.stdout.contains(label) else { return false }
    let r = Proc.run("/bin/launchctl",
                     ["kickstart", "-k", "gui/\(getuid())/\(label)"],
                     cwd: "/tmp", env: [:], timeout: 30)
    return r.exitCode == 0
}

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
        for f in (try? fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "bundle" {
            try? fm.copyItem(at: f, to: app.appendingPathComponent("Contents/Resources")
                .appendingPathComponent(f.lastPathComponent))
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
        try cmdDoctor()
    case "debug-parse":
        try cmdDebugParse(rest)
    case "dashboard":
        try cmdDashboard(rest)
    case "learn":
        try cmdLearn(rest)
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
