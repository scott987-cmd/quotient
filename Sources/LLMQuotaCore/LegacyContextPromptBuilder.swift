import Foundation

/// 92f8861 之前的散落拼装逻辑，原样收进这一个临时入口。
///
/// 为什么还留着它：Context Pack 按「先影子、再单仓、再扩面」灰度，
/// 影子模式下实际派发的必须是旧提示词语义 —— 否则灰度就失去了对照。
/// 这里的每一段和被替换前的 main.swift 逐字一致（顺序、条件、措辞都不动，
/// 动了就不是「旧行为」了）；唯一的结构变化是 TaskStore.all() 由调用方
/// 读好传入。**全部仓库灰度完成后整个文件删除。**
public enum LegacyContextPromptBuilder {

    public static func build(task: WorkTask, allTasks: [WorkTask],
                             runnerID: String, workspacePath: String,
                             handoff: Handoff?,
                             resumedAnswer: AskAnswer?, resumedAsk: Ask?,
                             mayAsk: Bool, askFile: String?) -> String {
        // Runner/CLI 可能在自己的入口再次钳制超长提示词。协作能力若留在
        // 任意长的任务正文之后，会最先从尾部消失，Agent 便只能交接、不能
        // 向另一岗位提问。固定协作契约必须先交付，再给任务正文。
        var effectivePrompt = CollaborationStore.contract(
            project: task.repo, taskID: task.id, graphID: task.graphID,
            runnerID: runnerID)
        if let smart = SmartConsultationPolicy.instruction(
            task: task, runnerID: runnerID, events: CollaborationStore.all()) {
            effectivePrompt += smart.clause
        }
        effectivePrompt += "\n\n---\n## 当前任务\n\n"
            + VisualQualityGate.compactRemediationPrompt(task.prompt)
            + (handoff?.briefing() ?? "")
        // 仓库地图：每个任务都是全新 worktree，agent 一律从零认路。
        //
        // 两种情况不贴：
        // - 接力任务：briefing 里已经有文件清单，再来一份是浪费
        // - trivial：那种活的描述里已经点名了文件和行号（「第 34 行的 foo 补注释」），
        //   地图一个字都用不上
        if handoff == nil, task.profile?.tier != .trivial {
            effectivePrompt += RepoMap.briefing(repo: workspacePath)
        }
        // 产品事实（AGENTS.md）：让每个 agent 知道自己在给什么产品干活、
        // 什么不能动。
        effectivePrompt += ProductBrief.briefing(repo: workspacePath,
                                                 registeredRepo: task.repo)
        // 证据条款（事前）：干活的 agent 在同一次执行里自己交证据。
        effectivePrompt += EvidenceGate.inlineClause(repoPath: task.repo,
                                                     prompt: task.prompt)
        effectivePrompt += WorkProgressContract.clause()
        // 图内节点要知道自己在整件事里的位置 —— 跨厂商的两个 CLI 不可能
        // 共享会话，能交接的只有磁盘上的产物，所以这段必须显式拼进提示词。
        if let brief = TaskGraph.briefing(for: task, in: allTasks) {
            effectivePrompt += "\n\n" + brief
        }
        if let answer = resumedAnswer, let ask = resumedAsk {
            effectivePrompt += answer.briefing(for: ask)
        }
        // 提问契约只给「可能真需要澄清」的任务加。
        if mayAsk, let askFile, !askFile.isEmpty {
            effectivePrompt += AskContract.clause(askFile: askFile)
        }
        return effectivePrompt
    }
}
