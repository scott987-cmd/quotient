import Foundation

/// **把各仓库的计划(PLAN.md)搬到手机上给老板看。**
///
/// 老板 2026-08-23:「flint 的后续计划应该在手机端计划清单展示吧,
/// 不然你留他的作用是什么」。
///
/// PLAN.md 之前只有一个读者:AutoRefill(系统自己按它续活)。
/// 老板看不到 —— 于是「计划做什么、做到哪了」对他是个黑盒,
/// 他只能靠不停问「FPS 还在做吗」。计划本来就该是他随时能翻的东西。
///
/// 这一页不设动作按钮:它是**只读的进度视图**。要改方向,改仓库里的
/// PLAN.md(那也是续活读的同一份,一处改、两处生效)。
public enum RoadmapPage {
    /// 一个仓库的计划快照。
    public struct Repo: Sendable {
        public var alias: String
        public var goalExcerpt: String       // PLAN.md 开头，去掉表格噪声
        public var recentLandings: [String]  // 最近几条落地，代表「做到哪了」
        public var openCount: Int            // 还在排/在跑的
    }

    /// 从 PLAN.md 抽一段手机上能扫完的概述。完整计划仍留在仓库里；
    /// 把几千字 Markdown 塞进通用卡片，只会得到一堵没有层级的文字墙。
    static func excerpt(_ plan: String, limit: Int = 360) -> String {
        var out: [String] = []
        for raw in plan.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // 表格分隔行(|---|---|)对人没意义,跳过。
            if line.allSatisfy({ "|-: ".contains($0) }) { continue }
            // 表格正文、代码围栏和大段实现细节不适合摘要。
            if line.hasPrefix("|") || line.hasPrefix("```") { continue }
            line = line.replacingOccurrences(of: "**", with: "")
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { line.removeFirst(2) }
            if line.isEmpty { continue }
            out.append(line)
            if out.count == 6 || out.joined(separator: "\n").count >= limit { break }
        }
        let text = out.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// 收集每个仓库的计划状态。git/文件读取注入,方便测试。
    public static func collect(
        repos: [RepoAlias] = RepoRegistry.all(),
        tasks: [WorkTask] = TaskStore.all(),
        planText: (String) -> String? = { repo in
            for f in ["PLAN.md", "ROADMAP.md"] {
                let p = (repo as NSString).appendingPathComponent(f)
                if let s = try? String(contentsOfFile: p, encoding: .utf8) { return s }
            }
            return nil
        },
        recentLandings: (String) -> [String] = { repo in
            let r = GitWorkspace.git(
                ["log", "--first-parent", "-8", "--format=%s", "main"], in: repo)
            return r.stdout.split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("merge ") || $0.contains("进度") == false }
                .prefix(4).map { $0 }
        }
    ) -> [Repo] {
        var out: [Repo] = []
        for r in repos {
            let path = NSString(string: r.localPath).expandingTildeInPath
            guard let plan = planText(path) else { continue }   // 没计划的仓库不列
            let open = tasks.reduce(into: Set<String>()) { acc, t in
                if NSString(string: t.repo).expandingTildeInPath == path,
                   t.state == .queued || t.state == .running { acc.insert(t.id) }
            }.count
            out.append(Repo(alias: r.alias, goalExcerpt: excerpt(plan),
                            recentLandings: recentLandings(path), openCount: open))
        }
        return out
    }

    public static func page(now: Date = Date(),
                            repos: [Repo]? = nil) -> ViewFeed.Page {
        let data = repos ?? collect()
        guard !data.isEmpty else {
            return ViewFeed.Page(page: "roadmap", sections: [
                ViewFeed.Section(kind: "text", title: "还没有计划",
                    text: "在仓库里放一份 PLAN.md，这里就会显示它的阶段和进度。")
            ], now: now)
        }
        return ViewFeed.Page(page: "roadmap", sections: data.map { repo in
            let latest = repo.recentLandings.first.map { "最近完成：" + $0 }
                ?? "还没有落地记录"
            return ViewFeed.Section(
                kind: "cards", title: repo.alias,
                cards: [ViewFeed.Card(
                    id: "roadmap-" + repo.alias,
                    title: repo.openCount > 0 ? "在做 \(repo.openCount) 项" : "队列空闲",
                    body: latest,
                    detail: repo.goalExcerpt,
                    tone: .neutral, icon: "map")])
        }, now: now)
    }
}
