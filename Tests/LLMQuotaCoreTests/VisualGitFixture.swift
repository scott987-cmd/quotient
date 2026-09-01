import Foundation
@testable import LLMQuotaCore

/// 视觉对账依赖真实 Git 拓扑；测试也必须给它可验证的分支和提交，不能靠
/// “Git 失败等于没前进”这个已经被修掉的旧漏洞通过。
func makeVisualGitFixture(branch: String) throws -> (repo: URL, head: String) {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("visual-current-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    func git(_ args: [String]) -> Proc.Result { GitWorkspace.git(args, in: repo.path) }
    _ = git(["init", "-q", "-b", "main"])
    _ = git(["config", "user.email", "test@example.com"])
    _ = git(["config", "user.name", "Test"])
    try "fixture\n".write(
        to: repo.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    _ = git(["add", "-A"])
    _ = git(["commit", "-q", "-m", "fixture"])
    _ = git(["branch", branch])
    let head = git(["rev-parse", branch]).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (repo, head)
}
