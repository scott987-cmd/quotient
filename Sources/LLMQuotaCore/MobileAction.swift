import Foundation
import CryptoKit

/// 来源属于动作身份的一部分。旧消费者不认识 machine:，不能绕过目标校验。
public enum MobileAction {
    public struct Route: Equatable, Sendable {
        public let scope: String
        public let actionID: String
    }

    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func route(_ id: String) -> Route? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "machine", parts[1].count == 64,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !parts[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !parts[2].hasPrefix("machine:") else { return nil }
        return Route(scope: parts[1], actionID: parts[2])
    }

    public static func scoped(_ id: String, machineID: String) -> String? {
        guard !machineID.isEmpty else { return nil }
        let scope = digest(machineID)
        if id.hasPrefix("machine:") { return route(id)?.scope == scope ? id : nil }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "machine:" + scope + ":" + id
    }

    public struct Receipt: Codable, Sendable {
        public var actionID: String
        public var invocationID: String
        public var machineID: String
        public var state: String
        public var message: String
        public var updatedAt: Date
        public var attempts: Int
        public var isTerminal: Bool { state == "succeeded" || state == "failed" }

        public init(actionID: String, invocationID: String, machineID: String,
                    state: String, message: String, updatedAt: Date = Date(), attempts: Int = 0) {
            self.actionID = actionID; self.invocationID = invocationID; self.machineID = machineID
            self.state = state; self.message = message; self.updatedAt = updatedAt; self.attempts = attempts
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            actionID = try c.decodeIfPresent(String.self, forKey: .actionID) ?? ""
            invocationID = try c.decodeIfPresent(String.self, forKey: .invocationID) ?? ""
            machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? ""
            state = try c.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
            message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
            updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
            attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        }
    }

    public static func receiptName(actionID: String, invocationID: String) -> String {
        digest(actionID + "\n" + invocationID) + ".json"
    }

    static func resourceKey(_ id: String) -> String {
        guard let route = route(id) else { return id }
        let parts = route.actionID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, ["review", "task", "playbook", "milestone"].contains(parts[0]) else { return id }
        return route.scope + ":" + parts[0] + ":" + parts[2]
    }

    static func versionFailure(_ id: String) -> String? {
        guard let route = route(id) else { return nil }
        let parts = route.actionID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, ["review", "task", "playbook"].contains(parts[0]) else { return nil }
        let resource = parts[2].split(separator: "|", omittingEmptySubsequences: false)
        let expected = parts[0] == "review" ? 3 : 2
        guard resource.count == expected, resource.allSatisfy({ !$0.isEmpty }) else {
            return "旧版操作缺少资源版本，请刷新来源 Mac 后重新确认"
        }
        return nil
    }

    /// 本机账本不参与镜像；另一台机器的办结/失败记录不能抹掉本机事项。
    static func ledger(machineID: String) -> URL {
        Paths.appSupport.appendingPathComponent("mobile-actions/" + digest(machineID))
    }

    static func hasTerminalReceipt(for invocation: ViewFeed.Invocation,
                                   machineID: String = Paths.machineID()) -> Bool {
        guard let target = route(invocation.id), target.scope == digest(machineID) else { return false }
        let request = invocation.invocationID ?? invocation.key
        let local = ledger(machineID: machineID).appendingPathComponent(
            receiptName(actionID: invocation.id, invocationID: request))
        guard let receipt = SafeDecode.json(at: local, as: Receipt.self) else { return false }
        return receipt.actionID == invocation.id
            && receipt.invocationID == request
            && receipt.machineID == machineID
            && receipt.isTerminal
    }

    @discardableResult
    public static func process(_ invocation: ViewFeed.Invocation,
                               machineID: String = Paths.machineID(),
                               execute: () -> Bool?) -> Receipt? {
        guard let target = route(invocation.id), target.scope == digest(machineID) else { return nil }
        let request = invocation.invocationID ?? invocation.key
        let name = receiptName(actionID: invocation.id, invocationID: request)
        let directory = ledger(machineID: machineID)
        let fm = FileManager.default
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        let resource = digest(resourceKey(invocation.id))
        let lock = directory.appendingPathComponent(resource + ".lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        let local = directory.appendingPathComponent(name)
        let completedResource = directory.appendingPathComponent(resource + ".completed.json")
        let published = Paths.sharedRoot.appendingPathComponent("action-receipts/" + name)
        let previous = SafeDecode.json(at: local, as: Receipt.self)
        if let previous, previous.isTerminal {
            publish(previous, to: published)
            return previous
        }
        if let completed = SafeDecode.json(at: completedResource, as: Receipt.self), completed.state == "succeeded" {
            let sameAction = completed.actionID == invocation.id
            let receipt = Receipt(actionID: invocation.id, invocationID: request, machineID: machineID,
                state: sameAction ? "succeeded" : "failed",
                message: sameAction ? "目标 Mac 已执行成功" : "这一版事项已经通过另一项操作处理，请刷新后查看")
            guard persist(receipt, to: local) else { return nil }
            publish(receipt, to: published)
            return receipt
        }
        if var previous, previous.attempts >= ViewFeed.maxAttempts {
            previous.state = "failed"
            previous.message = "目标 Mac 处理中断，已停止自动重试；请确认实际状态后重试"
            previous.updatedAt = Date()
            guard persist(previous, to: local) else { return nil }
            publish(previous, to: published)
            return previous
        }
        var receipt = Receipt(actionID: invocation.id, invocationID: request, machineID: machineID,
            state: "running", message: "目标 Mac 正在处理", attempts: (previous?.attempts ?? 0) + 1)
        guard persist(receipt, to: local) else { return nil }
        publish(receipt, to: published)
        let invalidVersion = versionFailure(invocation.id)
        let result = invalidVersion == nil ? execute() : nil
        switch result {
        case .some(true): receipt.state = "succeeded"; receipt.message = "目标 Mac 已执行成功"
        case .some(false):
            receipt.state = receipt.attempts >= ViewFeed.maxAttempts ? "failed" : "retrying"
            receipt.message = receipt.state == "failed"
                ? "目标 Mac 执行失败，已停止自动重试；处理原因后可重新提交"
                : "目标 Mac 执行失败，正在重试（\(receipt.attempts)/\(ViewFeed.maxAttempts)）"
        case .none:
            receipt.state = "failed"
            receipt.message = invalidVersion ?? "目标 Mac 不支持此操作，请更新电脑端"
        }
        receipt.updatedAt = Date()
        if receipt.state == "succeeded", !persist(receipt, to: completedResource) { return nil }
        guard persist(receipt, to: local) else { return nil }
        publish(receipt, to: published)
        return receipt
    }

    private static func persist(_ receipt: Receipt, to url: URL) -> Bool {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(receipt) else { return false }
        if (try? Data(contentsOf: url)) == data { return true }
        return ICloudSafe.write(data, to: url)
    }

    private static func publish(_ receipt: Receipt, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = persist(receipt, to: url)
    }
}

// 同一消费实现供工作循环和隔离契约测试调用。
extension MobileAction {
    static func taskResource(_ task: WorkTask) -> String {
        task.id + "|" + digest(String(task.rev) + "\n" + (task.pendingAsk?.id ?? "")
            + "\n" + String(task.askRounds))
    }

    static func playbookResource(_ project: Playbook.Project) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let content = (try? enc.encode(project)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return project.id + "|" + digest(content)
    }

    public static func execute(_ inv: ViewFeed.Invocation) -> Bool? {
        guard let route = MobileAction.route(inv.id),
              route.scope == MobileAction.digest(Paths.machineID()) else { return nil }
        guard versionFailure(inv.id) == nil else { return false }
        let parts = route.actionID.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        switch (parts[0], parts[1]) {
        case ("review", "merge"), ("review", "discard"):
            guard parts.count == 3 else { return false }
            let bits = parts[2].split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard (2...3).contains(bits.count), !bits[0].isEmpty, !bits[1].isEmpty,
                  GitWorkspace.isRepo(bits[0]) else { return false }
            // merge 已经推进 main、也删掉来源分支之后，进程仍可能在落本机
            // 成功回执前退出。重启后必须按这次页面绑定的 head 对账；只看
            // “分支没了”会把未执行/误删也当成功，只要求分支存在又会把真实
            // 成功误报成失败。
            if !GitWorkspace.branchExists(bits[1], in: bits[0]) {
                guard bits.count == 3,
                      let landed = reviewHeadLandingStatus(bits[2], repo: bits[0]),
                      (parts[1] == "merge") == landed else { return false }
                if !landed {
                    Review.markDisposition(branch: bits[1], landed: false,
                                           reason: inv.note ?? "手机上拒绝")
                }
                Review.markDecided(repo: bits[0], branch: bits[1])
                return true
            }
            // 同一分支整改后是一次新的验收；旧页面不能处置新的提交。
            if bits.count == 3 {
                let head = GitWorkspace.git(["rev-parse", "--verify", "refs/heads/" + bits[1]], in: bits[0])
                guard head.exitCode == 0, !bits[2].isEmpty,
                      head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == bits[2] else { return false }
            }
            if parts[1] == "merge" {
                guard case .success = Review.merge(repo: bits[0], branch: bits[1]) else { return false }
                Review.markDecided(repo: bits[0], branch: bits[1])   // 卡片要消失,两条路同一台账
                return true
            }
            guard Review.reject(repo: bits[0], branch: bits[1],
                                reason: inv.note ?? "手机上拒绝") else { return false }
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
            guard parts.count == 3 else { return false }
            let resource = parts[2].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let taskID = resource.first,
                  let t = TaskStore.all().last(where: { $0.id == taskID }),
                  t.state == .blocked, t.pausedAt == nil, ViewFeed.awaitsBoss(t),
                  resource.count == 1 || parts[2] == taskResource(t),
                  GitWorkspace.isRepo(t.repo) else { return false }
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
            let approving = parts[1] == "approve"
            let oldWorkspace = t.branch.flatMap { Review.worktreePath(repo: t.repo, branch: $0) }
            let r = Approval.settle(task: t, approve: approving)
            guard approving ? r.task.state == .done : r.task.discardedAt != nil else { return false }
            if !approving, let branch = t.branch {
                if branch.hasPrefix("agent/graph/"), let workspace = oldWorkspace {
                    let remaining = GitWorkspace.git(["status", "--porcelain"], in: workspace)
                    guard remaining.exitCode == 0,
                          remaining.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                } else if !branch.hasPrefix("agent/graph/") {
                    guard !GitWorkspace.branchExists(branch, in: t.repo),
                          oldWorkspace.map({ !FileManager.default.fileExists(atPath: $0) }) ?? true else { return false }
                }
            }
            var x = r.task
            x.pendingAsk = nil
            x.note = (parts[1] == "approve" ? "手机上放行并提交:" : "手机上丢弃:")
                + (inv.note ?? r.note)
            // 同一件事有两个入口(「等你放行」卡片 / 「问题」页)。从卡片放行之后
            // 问题文件还挂在 questions/ 里,手机「问题」页照样显示、再答一次就成了
            // stale-ask(「确认了还弹 / 答了白答」)。两个入口必须互相撤销。
            do {
                _ = try TaskStore.transition(
                    x, actor: "mobile-action", reason: "移动端处置高危路径审批")
                AskStore.retract(taskID: x.id, machine: Paths.machineID())
                return true
            } catch {
                fputs("移动端审批状态写入失败：\(error)\n", stderr)
                return false
            }

        case ("playbook", "approve"):
            guard parts.count == 3 else { return false }
            let resource = parts[2].split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            var projects = Playbook.all()
            guard let id = resource.first, let index = projects.firstIndex(where: { $0.id == id }),
                  resource.count == 1 || parts[2] == playbookResource(projects[index]) else { return false }
            let approvedAt = Date()
            projects[index].approvedAt = approvedAt
            Playbook.save(projects)
            let formatter = ISO8601DateFormatter()
            return Playbook.all().contains {
                $0.id == id && $0.approvedAt.map { formatter.string(from: $0) } == formatter.string(from: approvedAt)
            }

        case ("milestone", "approve"), ("milestone", "reject"):
            guard parts.count == 3 else { return false }
            let bits = parts[2].split(separator: "|", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { return false }
            return Milestone.decide(repo: bits[0], mergeSHA: bits[1],
                                    approved: parts[1] == "approve", note: inv.note)

        default:
            return nil
        }
    }

    /// true = 该提交已在 main；false = 提交存在但未在 main；nil = 无法可靠判断。
    private static func reviewHeadLandingStatus(_ expectedHead: String, repo: String) -> Bool? {
        guard expectedHead.count == 40,
              expectedHead.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        let resolved = GitWorkspace.git(
            ["rev-parse", "--verify", expectedHead + "^{commit}"], in: repo)
        guard resolved.exitCode == 0,
              resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expectedHead
        else { return nil }
        let base = GitWorkspace.git(["rev-parse", "--verify", "refs/heads/main"], in: repo)
        guard base.exitCode == 0 else { return nil }
        let relation = GitWorkspace.git(
            ["merge-base", "--is-ancestor", expectedHead, "refs/heads/main"], in: repo
        )
        if relation.exitCode == 0 { return true }
        if relation.exitCode == 1 { return false }
        return nil
    }
}
