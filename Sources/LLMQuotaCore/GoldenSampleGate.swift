import Foundation

/// 一条生产任务在「黄金样板 → 批量扩张」里的位置。
///
/// 只有显式带这份元数据的任务才受阶段 1 的硬闸影响。旧任务没有这个字段，
/// 行为完全不变；这让已有项目可以先观察，再逐类接入。
public struct ProductionContext: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        case goldenSample
        case fanOut

        public var displayName: String {
            switch self {
            case .goldenSample: return "黄金样板"
            case .fanOut: return "批量扩张"
            }
        }
    }

    public var stage: Stage
    public var deliverableKind: String
    public var goldenSampleID: String
    /// 批量任务所依赖的黄金样板任务。样板任务自身为 nil。
    public var fanOutFromTaskID: String?
    /// 样板绑定 experience 条款时，除了构建/落地还必须有质量票。
    public var requiresExperienceApproval: Bool
    /// 人工确认的兜底。视觉项目通常由 VisualQualityGate 自动给票。
    public var approvedAt: Date?
    public var approvalNote: String?
    /// 由 GoldenSampleGate 写入；非空表示这条 blocked 是质量闸，不是人工审批。
    public var blockedReason: String?

    public init(stage: Stage, deliverableKind: String, goldenSampleID: String,
                fanOutFromTaskID: String? = nil,
                requiresExperienceApproval: Bool = false,
                approvedAt: Date? = nil, approvalNote: String? = nil,
                blockedReason: String? = nil) {
        self.stage = stage
        self.deliverableKind = deliverableKind
        self.goldenSampleID = goldenSampleID
        self.fanOutFromTaskID = fanOutFromTaskID
        self.requiresExperienceApproval = requiresExperienceApproval
        self.approvedAt = approvedAt
        self.approvalNote = approvalNote
        self.blockedReason = blockedReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decodeIfPresent(Stage.self, forKey: .stage) ?? .goldenSample
        deliverableKind = try c.decodeIfPresent(String.self, forKey: .deliverableKind) ?? ""
        goldenSampleID = try c.decodeIfPresent(String.self, forKey: .goldenSampleID) ?? ""
        fanOutFromTaskID = try c.decodeIfPresent(String.self, forKey: .fanOutFromTaskID)
        requiresExperienceApproval = try c.decodeIfPresent(
            Bool.self, forKey: .requiresExperienceApproval) ?? false
        approvedAt = try c.decodeIfPresent(Date.self, forKey: .approvedAt)
        approvalNote = try c.decodeIfPresent(String.self, forKey: .approvalNote)
        blockedReason = try c.decodeIfPresent(String.self, forKey: .blockedReason)
    }
}

/// 批量扩张准入：样板没有真正落地并通过适用质量层之前，同类任务只能登记，不能跑。
public enum GoldenSampleGate {
    public struct InvalidProductionContext: LocalizedError, Sendable {
        public var reason: String
        public var errorDescription: String? { reason }
    }

    /// 在统一入队入口补全并验证生产关系。
    public static func prepare(_ requested: ProductionContext, repo: String,
                               tasks: [WorkTask]) throws -> ProductionContext {
        let kind = requested.deliverableKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kind.isEmpty else { throw invalid("交付物类型不能为空") }
        let contract = try loadContract(repo: repo)

        // 架构设计必须发生在实现之前。过去统一入队只核对“样板 ID 存在”，
        // 即使生产路线覆盖不了目标、参考物缺失或 PRODUCTION.md 仍是空壳，
        // 黄金样板也能直接开跑；架构师只能等视觉否决后再救火。这里复用已经
        // 存在的 ProjectDoctor 作为开工闸，不再维护第二套契约判定。
        let design = ProjectDoctor.inspect(contract: contract, repo: repo)
        if !design.canStartProduction {
            let reasons = design.issues
                .filter { $0.severity == .error }
                .prefix(4)
                .map(\.message)
                .joined(separator: "；")
            throw invalid("前置生产设计未通过，禁止开始黄金样板：" + reasons)
        }

        switch requested.stage {
        case .goldenSample:
            let sampleID = requested.goldenSampleID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !sampleID.isEmpty else { throw invalid("黄金样板 ID 不能为空") }
            guard requested.fanOutFromTaskID == nil else {
                throw invalid("黄金样板任务不能同时声明 fan-out 来源")
            }
            guard let sample = contract.goldenSamples.first(where: { $0.id == sampleID }) else {
                throw invalid("项目契约没有黄金样板 \(sampleID)")
            }
            guard sample.deliverableKind == kind else {
                throw invalid("黄金样板 \(sampleID) 的交付物类型是 "
                    + "\(sample.deliverableKind)，不是 \(kind)")
            }
            var out = requested
            out.deliverableKind = kind
            out.goldenSampleID = sampleID
            out.requiresExperienceApproval = requiresExperience(sample: sample,
                                                                 contract: contract)
            out.blockedReason = nil
            return out

        case .fanOut:
            guard let sourceID = requested.fanOutFromTaskID,
                  let source = tasks.first(where: { $0.id == sourceID }) else {
                throw invalid("批量扩张必须引用一条存在的黄金样板任务")
            }
            guard standardized(source.repo) == standardized(repo) else {
                throw invalid("黄金样板和批量任务不在同一个仓库")
            }
            guard let sourceContext = source.production,
                  sourceContext.stage == .goldenSample else {
                throw invalid("任务 \(sourceID) 不是黄金样板任务")
            }
            guard sourceContext.deliverableKind == kind else {
                throw invalid("批量任务类型 \(kind) 与样板类型 "
                    + "\(sourceContext.deliverableKind) 不一致")
            }
            guard contract.goldenSamples.contains(where: {
                $0.id == sourceContext.goldenSampleID && $0.deliverableKind == kind
            }) else {
                throw invalid("项目契约已不再承认样板 \(sourceContext.goldenSampleID)")
            }
            var out = requested
            out.deliverableKind = kind
            out.goldenSampleID = sourceContext.goldenSampleID
            out.requiresExperienceApproval = sourceContext.requiresExperienceApproval
            out.blockedReason = blockReason(source: source, tasks: tasks)
            return out
        }
    }

    /// nil = 可以执行；非 nil = 必须保持 blocked，并把原因发到手机。
    public static func blockReason(for task: WorkTask, in tasks: [WorkTask]) -> String? {
        guard let context = task.production, context.stage == .fanOut else { return nil }
        guard let sourceID = context.fanOutFromTaskID,
              let source = tasks.first(where: { $0.id == sourceID }) else {
            return "找不到来源黄金样板，禁止批量扩张"
        }
        guard standardized(source.repo) == standardized(task.repo),
              let sourceContext = source.production,
              sourceContext.stage == .goldenSample,
              sourceContext.deliverableKind == context.deliverableKind,
              sourceContext.goldenSampleID == context.goldenSampleID else {
            return "来源任务与交付物类型或黄金样板不匹配，禁止批量扩张"
        }
        return blockReason(source: source, tasks: tasks)
    }

    /// 每轮重新对账。样板通过后自动解冻，不需要人逐条重试 fan-out 任务。
    public static func reconcile(_ tasks: [WorkTask]) -> [WorkTask] {
        var changed: [WorkTask] = []
        for task in tasks {
            guard var context = task.production, context.stage == .fanOut,
                  task.state == .queued || task.state == .blocked else { continue }
            let reason = blockReason(for: task, in: tasks)
            if let reason {
                guard task.state == .queued || context.blockedReason != reason else { continue }
                // blocked 但不是我们挡的，不能冒充质量闸接管人工审批。
                guard task.state == .queued || context.blockedReason != nil else { continue }
                var out = task
                out.state = .blocked
                out.waitReason = .productionGate
                context.blockedReason = reason
                out.production = context
                out.note = "黄金样板闸：" + reason
                changed.append(out)
            } else if context.blockedReason != nil {
                var out = task
                context.blockedReason = nil
                out.production = context
                if task.state == .blocked {
                    out.state = .queued
                    out.waitReason = nil
                }
                out.note = "黄金样板已通过，批量扩张重新排队"
                changed.append(out)
            }
        }
        return changed.sorted { $0.createdAt < $1.createdAt }
    }

    private static func blockReason(source: WorkTask, tasks: [WorkTask]) -> String? {
        guard let context = source.production else { return "来源任务缺少黄金样板信息" }
        if source.state == .failed { return "黄金样板任务失败，尚未形成可复制基线" }
        guard source.state == .done else { return "黄金样板还在制作或等待处理" }
        guard source.landedAt != nil else { return "黄金样板尚未合入主线" }
        guard context.requiresExperienceApproval else { return nil }
        if context.approvedAt != nil { return nil }
        guard let branch = source.branch else { return "黄金样板缺少可核对的质量分支" }
        switch VisualQualityGate.latestStatus(branch: branch, tasks: tasks) {
        case .approved:
            return nil
        case .rejected:
            return "黄金样板的体验评审未达标，必须先整改样板"
        case .missing, .pending:
            return "黄金样板还没有通过体验质量评审"
        }
    }

    private static func loadContract(repo: String) throws -> ProjectContract {
        let root = URL(fileURLWithPath: NSString(string: repo).expandingTildeInPath,
                       isDirectory: true).standardizedFileURL
        let url = root.appendingPathComponent(ProjectContract.relativePath)
        guard let data = try? Data(contentsOf: url) else {
            throw invalid("项目还没有 .llmq/project-contract.json，不能启用黄金样板生产")
        }
        do {
            return try JSONDecoder().decode(ProjectContract.self, from: data)
        } catch {
            throw invalid("项目契约无法解码：\(error.localizedDescription)")
        }
    }

    private static func requiresExperience(sample: ProjectContract.GoldenSample,
                                           contract: ProjectContract) -> Bool {
        let experience = Set(contract.criteria.filter { $0.layer == "experience" }.map(\.id))
        return !experience.isDisjoint(with: Set(sample.criterionIDs))
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL.path
    }

    private static func invalid(_ reason: String) -> InvalidProductionContext {
        InvalidProductionContext(reason: reason)
    }
}
