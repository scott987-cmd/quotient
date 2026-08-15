import Foundation

/// 什么时候该打扰人。
///
/// ## 为什么单独一个类型
///
/// 推送本身（`Push`）只管「怎么发」。**发不发是另一个问题**，而且是
/// 更难的那个：通知一多人就关掉，关掉之后等于回到「一次都收不到」的原点。
///
/// 老板点名要被打扰的四件事：新项目的方案、对外发布、产出验收、碰钱和账号。
/// 共同点是**它们都需要一个决定**，而不是「有事发生了」。
/// 所以这里的规则只有一条：**没有待决事项就不发**。
/// 「跑完了 3 个任务」不发，「有 3 份产出等你验收」才发。
public enum Nudge {

    /// 同类通知的最短间隔。人一天看几次手机，不需要每 30 秒被提醒一次
    /// 「还有 3 份待验收」—— 那和没通知是一样的效果（都会被忽略）。
    public static let quietFor: TimeInterval = 2 * 3600

    struct Sent: Codable { var key: String; var at: Date }

    static var path: URL {
        Paths.appSupport.appendingPathComponent("nudges.json")
    }

    static func history() -> [Sent] {
        guard let d = try? Data(contentsOf: path) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Sent].self, from: d)) ?? []
    }

    /// 这条通知最近发过没有。
    ///
    /// key 里要带上**数量**：待验收从 2 份变成 3 份是新情况，值得再响一次；
    /// 一直是 3 份就别重复喊。
    static func recentlySent(_ key: String, now: Date = Date()) -> Bool {
        history().contains { $0.key == key && now.timeIntervalSince($0.at) < quietFor }
    }

    static func remember(_ key: String, now: Date = Date()) {
        var h = history().filter { now.timeIntervalSince($0.at) < 24 * 3600 }
        h.append(Sent(key: key, at: now))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(h).write(to: path)
    }

    /// 现在有什么值得打扰人的。**每条都对应一个待决事项。**
    public static func pending(now: Date = Date()) -> [(key: String, kind: Push.Kind,
                                                        body: String, badge: Int)] {
        var out: [(String, Push.Kind, String, Int)] = []

        // 1. 新项目的方案等过目
        let unapproved = Playbook.all().filter { !$0.isApproved }
        if !unapproved.isEmpty {
            out.append(("playbook-\(unapproved.count)", .needsYou,
                        unapproved.count == 1
                            ? "「\(unapproved[0].name)」的方案等你过目"
                            : "\(unapproved.count) 个项目方案等你过目",
                        unapproved.count))
        }

        // 2. 产出等验收
        let tasks = TaskStore.all()
        let awaiting = tasks.filter {
            $0.state == .done && $0.discardedAt == nil && $0.branch != nil
        }
        if !awaiting.isEmpty {
            out.append(("review-\(awaiting.count)", .needsYou,
                        "\(awaiting.count) 份产出等你验收", awaiting.count))
        }

        // 3. 有活被拦下来等放行（高危 / 碰钱 / 碰账号）
        let blocked = tasks.filter { $0.state == .blocked }
        if !blocked.isEmpty {
            out.append(("blocked-\(blocked.count)", .needsYou,
                        "\(blocked.count) 个任务被拦下等你放行", blocked.count))
        }

        return out
    }

    /// 额度要浪费了 —— 空窗找不到活可干的时候才喊。
    ///
    /// 找到活自动填掉了就不用打扰人，那正是系统该自己解决的事。
    /// **喊的是「我没辙了」，不是「我在干活」。**
    public static func nothingToFill(platform: Platform, reason: String,
                                     now: Date = Date()) {
        let key = "idle-" + platform.rawValue
        guard !recentlySent(key, now: now) else { return }
        remember(key, now: now)
        Push.send(.wasting,
                  body: platform.displayName + "：" + reason
                      + "，但清单里没有能填的活",
                  subtitle: "加个项目就能自动用掉")
    }

    /// 跑一遍：该发的发掉。
    ///
    /// - Returns: 实际发出去的条数。
    @discardableResult
    public static func run(now: Date = Date()) -> Int {
        var sent = 0
        for item in pending(now: now) {
            guard !recentlySent(item.key, now: now) else { continue }
            guard Push.send(item.kind, body: item.body, badge: item.badge) > 0 else { continue }
            remember(item.key, now: now)
            sent += 1
        }
        return sent
    }
}
