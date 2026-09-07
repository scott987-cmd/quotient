import Foundation

/// A handoff transfers the source's current committed tree, including work committed
/// before this attempt. An old handoff note is not a substitute for that tree.
public enum WorkHandoff {
    private static func failure(_ text: String) -> NSError {
        NSError(domain: "WorkHandoff", code: 1,
                userInfo: [NSLocalizedDescriptionKey: text])
    }
    private static func resolve(_ ref: String, in repo: String) throws -> String {
        let r = GitWorkspace.git(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], in: repo)
        guard r.exitCode == 0 else { throw failure("无法核实交接提交：" + ref) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func checkpoint(in path: String, platform: Platform, reason: String) throws -> String {
        let status = GitWorkspace.git(["status", "--porcelain"], in: path)
        guard status.exitCode == 0 else { throw failure("无法读取源工作区，拒绝回退旧交接点") }
        if !status.stdout.isEmpty {
            guard GitWorkspace.commitWIP(in: path, platform: platform, reason: reason) != nil else {
                throw failure("未提交成果保存失败，保留源工作区并停止交接")
            }
        }
        let clean = GitWorkspace.git(["status", "--porcelain"], in: path)
        guard clean.exitCode == 0, clean.stdout.isEmpty else {
            throw failure("源工作区仍有未保存改动，停止交接")
        }
        return try resolve("HEAD", in: path)
    }
    public static func validateWorkspace(_ path: String) throws {
        guard GitWorkspace.occupantsProbe(path).filter({ $0 != getpid() }).isEmpty else {
            throw failure("目标工作区仍有执行器，拒绝在运行中交接")
        }
        let status = GitWorkspace.git(["status", "--porcelain"], in: path)
        guard status.exitCode == 0, status.stdout.isEmpty else {
            throw failure("目标工作区有未提交成果或无法读取，拒绝覆盖")
        }
    }
    /// Only advance an ancestor. Never discard destination work or merge divergent
    /// histories implicitly. Checked-out branches require an idle, clean workspace.
    public static func advanceBranch(repo: String, branch: String, base: String) throws -> String {
        let ref = "refs/heads/" + branch
        guard GitWorkspace.git(["check-ref-format", ref], in: repo).exitCode == 0 else {
            throw failure("非法交接分支")
        }
        let required = try resolve(base, in: repo)
        let read = GitWorkspace.git(["rev-parse", "--verify", ref + "^{commit}"], in: repo)
        if read.exitCode != 0 {
            let made = GitWorkspace.git(["update-ref", ref, required, String(repeating: "0", count: 40)], in: repo)
            guard made.exitCode == 0 else { throw failure("交接分支创建失败或已被其他执行器创建") }
            return required
        }
        let old = read.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyContains = GitWorkspace.git(["merge-base", "--is-ancestor", required, old], in: repo).exitCode == 0
        guard alreadyContains || GitWorkspace.git(["merge-base", "--is-ancestor", old, required], in: repo).exitCode == 0 else {
            throw failure("目标分支与最新成果分叉，保留双方提交，拒绝从旧版本开工")
        }
        let listing = GitWorkspace.git(["worktree", "list", "--porcelain", "-z"], in: repo)
        guard listing.exitCode == 0 else { throw failure("无法核实目标工作区占用") }
        var path: String?
        var checkedOut: String?
        for field in listing.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if field.hasPrefix("worktree ") { path = String(field.dropFirst(9)) }
            if field == "branch " + ref { checkedOut = path }
        }
        if let path = checkedOut { try validateWorkspace(path) }
        // Even a current/ahead destination must be clean before prepare can reuse it.
        if alreadyContains { return old }
        if let path = checkedOut {
            guard try resolve("HEAD", in: path) == old,
                  GitWorkspace.git(["symbolic-ref", "HEAD"], in: path).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == ref else {
                throw failure("目标工作区已变化，停止交接")
            }
            guard GitWorkspace.git(["merge", "--ff-only", required], in: path).exitCode == 0 else {
                throw failure("无法安全推进目标工作区")
            }
        } else {
            guard GitWorkspace.git(["update-ref", ref, required, old], in: repo).exitCode == 0 else {
                throw failure("目标分支已变化，停止交接")
            }
        }
        let actual = try resolve(ref, in: repo)
        guard GitWorkspace.git(["merge-base", "--is-ancestor", required, actual], in: repo).exitCode == 0 else {
            throw failure("目标分支没有继承完整交接成果")
        }
        return actual
    }
}
