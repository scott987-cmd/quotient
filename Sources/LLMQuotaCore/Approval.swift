import Foundation

/// 高危改动的放行/丢弃。
///
/// ## 为什么单独一个文件
///
/// 同一件事有两个入口：手机上点按钮（答复经 iCloud 回来，`AskIngest` 处理）
/// 和 Mac 上敲 `llmq work approve`。两边必须**完全一致** ——
/// 一边提交一边只改状态的话，会出现「任务显示 done 但分支上什么都没有」。
///
/// ## 为什么不走飞书
///
/// 飞书交互卡片的按钮回调需要一个飞书能访问的**入站地址**（公网服务或内网穿透），
/// 和 SECURITY.md 第一节「只允许开一个端口」冲突 —— 那个端口是带 mTLS 的
/// 集群口，不该为了一个审批按钮再开一个。
/// Ask 走 iCloud 文件，一个入站端口都不需要，而 iOS App 本来就会把带选项的
/// 问题渲染成按钮。
public enum Approval {

    public struct Outcome: Sendable {
        public var task: WorkTask
        public var note: String
    }

    /// 结算一个卡在高危路径闸上的任务。
    ///
    /// - Parameter approve: true = 提交到它自己的分支；false = 丢弃改动。
    ///
    /// 丢弃时**连分支带工作区一起清掉**：留着一个没人要的半成品分支，
    /// 下次 `work review` 又会把它列出来问一遍，噪音会累积。
    public static func settle(task: WorkTask, approve: Bool) -> Outcome {
        var t = task
        t.pendingAsk = nil
        t.endedAt = Date()

        guard let branch = t.branch,
              let ws = Review.worktreePath(repo: t.repo, branch: branch) else {
            // 工作区没了（被清理、机器重装过），改动已经找不回来。
            // 这时候标 done 是撒谎 —— 分支上什么都没有。
            t.state = .failed
            t.note = "工作区已经不在了，改动找不回来"
            return Outcome(task: t, note: "工作区丢失")
        }

        guard approve else {
            // **丢弃必须真的把改动抹掉，而且要检查它真被抹掉了。**
            //
            // 审查抓到的最严重一条：图内节点共用一个 worktree，而 cleanup
            // 对 `agent/graph/*` 有一道「图没跑完就不删」的守卫 —— 于是这里
            // 一个 git 命令都不执行，直接 return。而下面照样写
            // 「已丢弃并清理工作区」。
            //
            // 后果不是「界面说错话」那么轻：那批碰了高危路径、**故意没提交**
            // 留在工作区里的改动一个字都没少，下一个跑在同一目录里的兄弟节点
            // 走 `git add -A` 会把它一起提交、经 review 合进 main ——
            // **你的人工否决被静默翻转**，而这条路径正是高危闸门唯一的人工出口。
            //
            // 所以图内节点改成「就地还原」：把工作区恢复到 HEAD，
            // 已提交的历史不动（那是前面几步的成果，不能连坐）。
            let isGraph = branch.hasPrefix("agent/graph/")
            var cleaned = true
            var how = "已丢弃并清理工作区"
            if isGraph {
                _ = GitWorkspace.git(["checkout", "--", "."], in: ws)
                _ = GitWorkspace.git(["clean", "-fd"], in: ws)
                // 验证真的干净了。**说了抹掉就必须抹掉** ——
                // 这里报一句假话，被否决的改动就会混进下一次提交。
                let left = GitWorkspace.git(["status", "--porcelain"], in: ws)
                    .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                cleaned = left.isEmpty
                how = cleaned
                    ? "已丢弃，工作区已还原（图共用工作区，保留前面几步的提交）"
                    : "**没能完全还原**，工作区里还剩：" + left.prefix(200)
            } else {
                GitWorkspace.cleanup(repo: t.repo, path: ws, branch: branch)
            }
            t.state = .failed
            t.branch = isGraph ? branch : nil
            t.discardedAt = Date()
            t.discardReason = "高危改动，你选择了丢弃"
            t.note = how
            return Outcome(task: t, note: how)
        }

        let add = GitWorkspace.git(["add", "-A"], in: ws)
        let msg = "agent(\(t.platform?.rawValue ?? "?")): \(t.prompt.prefix(60))"
            + "\n\n碰到高危路径，人工确认后提交。"
        let commit = GitWorkspace.git(["commit", "-m", msg], in: ws)
        guard add.exitCode == 0, commit.exitCode == 0 else {
            // **提交失败就不能标 done。**
            // 标了的话 work review 看不到这个分支（它只列有提交的），
            // 而任务记录说它成功了 —— 产出就这么无声无息地蒸发。
            t.state = .failed
            t.note = "放行了但提交失败：" + commit.stderr.prefix(120)
            return Outcome(task: t, note: "提交失败")
        }
        GitWorkspace.cleanup(repo: t.repo, path: ws)
        t.state = .done
        t.note = "碰到高危路径，人工确认后提交"
        return Outcome(task: t, note: "已提交到 \(branch)")
    }
}
