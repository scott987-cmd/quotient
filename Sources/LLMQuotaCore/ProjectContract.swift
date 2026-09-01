import Foundation

/// 项目结果契约的机器可判定索引。
///
/// 长篇产品事实仍写在 AGENTS.md / QUALITY.md 等文档里；这里不复制正文，只保存
/// 路径、稳定条款 ID 和能力标签。这样调度器能在派活前发现缺口，又不会让每个任务
/// 反复吞一份庞大的 JSON。
public struct ProjectContract: Codable, Sendable {
    public static let relativePath = ".llmq/project-contract.json"

    public var schema: Int
    public var profile: String
    public var outcomeSummary: String
    public var requiredOutcomes: [String]
    public var hardConstraints: [String]
    public var referenceRequired: Bool
    public var experienceRequired: Bool
    public var goldenSampleRequired: Bool
    public var qualityFile: String
    public var referenceFile: String?
    public var productionFile: String?
    public var referenceFiles: [String]
    public var referenceDimensions: [String]
    public var routes: [Route]
    public var criteria: [Criterion]
    public var goldenSamples: [GoldenSample]
    /// 不允许实现者自行放宽的数值门槛。契约保存批准值，分支只能保持或收紧。
    public var qualityGuardrails: [QualityGuardrail]

    public init(schema: Int = 1, profile: String = "generic",
                outcomeSummary: String, requiredOutcomes: [String] = [],
                hardConstraints: [String] = [], referenceRequired: Bool = false,
                experienceRequired: Bool = false, goldenSampleRequired: Bool = false,
                qualityFile: String = "QUALITY.md", referenceFile: String? = nil,
                productionFile: String? = nil, referenceFiles: [String] = [],
                referenceDimensions: [String] = [], routes: [Route] = [],
                criteria: [Criterion] = [], goldenSamples: [GoldenSample] = [],
                qualityGuardrails: [QualityGuardrail] = []) {
        self.schema = schema
        self.profile = profile
        self.outcomeSummary = outcomeSummary
        self.requiredOutcomes = requiredOutcomes
        self.hardConstraints = hardConstraints
        self.referenceRequired = referenceRequired
        self.experienceRequired = experienceRequired
        self.goldenSampleRequired = goldenSampleRequired
        self.qualityFile = qualityFile
        self.referenceFile = referenceFile
        self.productionFile = productionFile
        self.referenceFiles = referenceFiles
        self.referenceDimensions = referenceDimensions
        self.routes = routes
        self.criteria = criteria
        self.goldenSamples = goldenSamples
        self.qualityGuardrails = qualityGuardrails
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? "generic"
        outcomeSummary = try c.decodeIfPresent(String.self, forKey: .outcomeSummary) ?? ""
        requiredOutcomes = try c.decodeIfPresent([String].self,
                                                  forKey: .requiredOutcomes) ?? []
        hardConstraints = try c.decodeIfPresent([String].self,
                                                 forKey: .hardConstraints) ?? []
        referenceRequired = try c.decodeIfPresent(Bool.self,
                                                   forKey: .referenceRequired) ?? false
        experienceRequired = try c.decodeIfPresent(Bool.self,
                                                    forKey: .experienceRequired) ?? false
        goldenSampleRequired = try c.decodeIfPresent(Bool.self,
                                                      forKey: .goldenSampleRequired) ?? false
        qualityFile = try c.decodeIfPresent(String.self, forKey: .qualityFile) ?? "QUALITY.md"
        referenceFile = try c.decodeIfPresent(String.self, forKey: .referenceFile)
        productionFile = try c.decodeIfPresent(String.self, forKey: .productionFile)
        referenceFiles = try c.decodeIfPresent([String].self,
                                                forKey: .referenceFiles) ?? []
        referenceDimensions = try c.decodeIfPresent([String].self,
                                                     forKey: .referenceDimensions) ?? []
        routes = try c.decodeIfPresent([Route].self, forKey: .routes) ?? []
        criteria = try c.decodeIfPresent([Criterion].self, forKey: .criteria) ?? []
        goldenSamples = try c.decodeIfPresent([GoldenSample].self,
                                               forKey: .goldenSamples) ?? []
        qualityGuardrails = try c.decodeIfPresent(
            [QualityGuardrail].self, forKey: .qualityGuardrails) ?? []
    }

    public struct Route: Codable, Sendable {
        public var id: String
        /// 这条路线必须使用的条件，例如 paid-assets、external-api、account-required。
        public var requires: [String]
        /// 这条路线能证明达到的结果，例如 commercial-realistic-character。
        public var provides: [String]
        public var sourceAssets: [String]
        public var requiredCapabilities: [String]
        public var validationStages: [String]

        public init(id: String, requires: [String] = [], provides: [String] = [],
                    sourceAssets: [String] = [], requiredCapabilities: [String] = [],
                    validationStages: [String] = []) {
            self.id = id
            self.requires = requires
            self.provides = provides
            self.sourceAssets = sourceAssets
            self.requiredCapabilities = requiredCapabilities
            self.validationStages = validationStages
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            requires = try c.decodeIfPresent([String].self, forKey: .requires) ?? []
            provides = try c.decodeIfPresent([String].self, forKey: .provides) ?? []
            sourceAssets = try c.decodeIfPresent([String].self, forKey: .sourceAssets) ?? []
            requiredCapabilities = try c.decodeIfPresent([String].self,
                                                          forKey: .requiredCapabilities) ?? []
            validationStages = try c.decodeIfPresent([String].self,
                                                      forKey: .validationStages) ?? []
        }
    }

    public struct Criterion: Codable, Sendable {
        public var id: String
        /// integrity / behavior / experience / release
        public var layer: String
        public var evidenceTypes: [String]
        public var referenceFiles: [String]
        public var rejectConditions: [String]

        public init(id: String, layer: String, evidenceTypes: [String] = [],
                    referenceFiles: [String] = [], rejectConditions: [String] = []) {
            self.id = id
            self.layer = layer
            self.evidenceTypes = evidenceTypes
            self.referenceFiles = referenceFiles
            self.rejectConditions = rejectConditions
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            layer = try c.decodeIfPresent(String.self, forKey: .layer) ?? ""
            evidenceTypes = try c.decodeIfPresent([String].self,
                                                   forKey: .evidenceTypes) ?? []
            referenceFiles = try c.decodeIfPresent([String].self,
                                                    forKey: .referenceFiles) ?? []
            rejectConditions = try c.decodeIfPresent([String].self,
                                                      forKey: .rejectConditions) ?? []
        }
    }

    public struct GoldenSample: Codable, Sendable {
        public var id: String
        public var deliverableKind: String
        public var criterionIDs: [String]

        public init(id: String, deliverableKind: String, criterionIDs: [String]) {
            self.id = id
            self.deliverableKind = deliverableKind
            self.criterionIDs = criterionIDs
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            deliverableKind = try c.decodeIfPresent(String.self,
                                                     forKey: .deliverableKind) ?? ""
            criterionIDs = try c.decodeIfPresent([String].self,
                                                  forKey: .criterionIDs) ?? []
        }
    }

    public struct QualityGuardrail: Codable, Sendable, Equatable {
        public enum Bound: String, Codable, Sendable {
            case minimum, maximum, exact
        }

        public var file: String
        public var symbol: String
        public var bound: Bound
        public var value: Double

        public init(file: String, symbol: String, bound: Bound, value: Double) {
            self.file = file
            self.symbol = symbol
            self.bound = bound
            self.value = value
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
            symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? ""
            bound = try c.decodeIfPresent(Bound.self, forKey: .bound) ?? .exact
            value = try c.decodeIfPresent(Double.self, forKey: .value) ?? 0
        }
    }
}

/// 给已有仓库补结构化契约骨架。只创建缺失文件，绝不覆盖人工内容。
public enum ProjectContractBootstrap {
    public enum Outcome: Sendable {
        case created(String)
        case preserved(String)
    }

    public static func apply(repo: String, profile: String = "generic") throws -> Outcome {
        let root = URL(fileURLWithPath: NSString(string: repo).expandingTildeInPath,
                       isDirectory: true).standardizedFileURL
        let target = root.appendingPathComponent(ProjectContract.relativePath)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return .preserved(target.path)
        }
        let visualProfile = ["game", "app", "media"].contains(profile)
        let contract = ProjectContract(
            profile: profile,
            outcomeSummary: "待填写：用户最终能直接感受到的核心结果",
            referenceRequired: visualProfile,
            experienceRequired: visualProfile,
            goldenSampleRequired: true,
            referenceFile: FileManager.default.fileExists(
                atPath: root.appendingPathComponent("BENCHMARK.md").path)
                ? "BENCHMARK.md" : nil,
            productionFile: FileManager.default.fileExists(
                atPath: root.appendingPathComponent("PRODUCTION.md").path)
                ? "PRODUCTION.md" : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(contract)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard ICloudSafe.write(data, to: target) else {
            throw NSError(domain: "ProjectContractBootstrap", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "项目契约写入失败：\(target.path)"
            ])
        }
        return .created(target.path)
    }
}

public enum ProjectDoctor {
    public enum Severity: String, Codable, Sendable {
        case error, warning, info
    }

    public struct Issue: Codable, Sendable, Equatable {
        public var severity: Severity
        public var code: String
        public var message: String
        public var file: String?

        public init(_ severity: Severity, _ code: String, _ message: String,
                    file: String? = nil) {
            self.severity = severity
            self.code = code
            self.message = message
            self.file = file
        }
    }

    public struct Report: Codable, Sendable {
        public var repo: String
        public var contractFile: String
        public var issues: [Issue]

        public var canStartProduction: Bool {
            !issues.contains { $0.severity == .error }
        }

        public init(repo: String, contractFile: String, issues: [Issue]) {
            self.repo = repo
            self.contractFile = contractFile
            self.issues = issues
        }

        enum CodingKeys: String, CodingKey {
            case repo, contractFile, issues, canStartProduction
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
            contractFile = try c.decodeIfPresent(String.self, forKey: .contractFile) ?? ""
            issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(repo, forKey: .repo)
            try c.encode(contractFile, forKey: .contractFile)
            try c.encode(issues, forKey: .issues)
            try c.encode(canStartProduction, forKey: .canStartProduction)
        }
    }

    public static func inspect(repo: String) -> Report {
        let root = URL(fileURLWithPath: NSString(string: repo).expandingTildeInPath,
                       isDirectory: true).standardizedFileURL
        let contractURL = root.appendingPathComponent(ProjectContract.relativePath)
        guard let data = try? Data(contentsOf: contractURL) else {
            return legacyReport(root: root, contractURL: contractURL)
        }
        do {
            let contract = try JSONDecoder().decode(ProjectContract.self, from: data)
            return Report(repo: root.path, contractFile: contractURL.path,
                          issues: inspect(contract: contract, root: root))
        } catch {
            return Report(repo: root.path, contractFile: contractURL.path, issues: [
                Issue(.error, "contract.invalid-json",
                      "项目契约无法解码：\(error.localizedDescription)",
                      file: ProjectContract.relativePath)
            ])
        }
    }

    public static func inspect(contract: ProjectContract, repo: String) -> Report {
        let root = URL(fileURLWithPath: NSString(string: repo).expandingTildeInPath,
                       isDirectory: true).standardizedFileURL
        return Report(repo: root.path,
                      contractFile: root.appendingPathComponent(ProjectContract.relativePath).path,
                      issues: inspect(contract: contract, root: root))
    }

    private static func inspect(contract: ProjectContract, root: URL) -> [Issue] {
        var issues: [Issue] = []
        if contract.schema != 1 {
            issues.append(Issue(.error, "contract.schema.unsupported",
                                "只支持 schema 1，当前是 \(contract.schema)"))
        }
        if isPlaceholder(contract.profile) {
            issues.append(Issue(.error, "outcome.profile.missing", "没有填写质量 Profile"))
        }
        if isPlaceholder(contract.outcomeSummary) {
            issues.append(Issue(.error, "outcome.summary.missing", "没有填写项目核心结果"))
        }
        if contract.requiredOutcomes.isEmpty {
            issues.append(Issue(.error, "outcome.requirements.missing",
                                "没有登记机器可判定的 requiredOutcomes"))
        }
        for outcome in contract.requiredOutcomes where isPlaceholder(outcome) {
            issues.append(Issue(.error, "outcome.requirement.placeholder",
                                "requiredOutcomes 仍有待填写项"))
        }
        for constraint in contract.hardConstraints
        where !constraint.hasPrefix("deny:") && !constraint.hasPrefix("require:") {
            issues.append(Issue(.warning, "constraint.unstructured",
                                "硬约束没有使用 deny:/require: 标签，暂时无法自动判冲突："
                                    + constraint))
        }
        for path in [contract.qualityFile, contract.referenceFile,
                     contract.productionFile].compactMap({ $0 }) {
            inspectRequiredFile(path, root: root, issues: &issues)
        }

        if contract.referenceRequired {
            if contract.referenceFiles.isEmpty || contract.referenceDimensions.isEmpty {
                issues.append(Issue(.error, "reference.incomplete",
                                    "目标要求参考对照，但缺少参考文件或可观察维度"))
            }
        }
        for dimension in contract.referenceDimensions where isPlaceholder(dimension) {
            issues.append(Issue(.error, "reference.dimension.placeholder",
                                "参考维度仍有待填写项"))
        }
        for path in contract.referenceFiles {
            inspectRequiredFile(path, root: root, issues: &issues)
        }

        let duplicateRouteIDs = duplicates(contract.routes.map(\.id))
        for id in duplicateRouteIDs {
            issues.append(Issue(.error, "route.id.duplicate", "生产路线 ID 重复：\(id)"))
        }
        if contract.routes.isEmpty {
            issues.append(Issue(.error, "route.missing", "没有登记任何生产路线"))
        }
        for route in contract.routes {
            if isPlaceholder(route.id) {
                issues.append(Issue(.error, "route.id.missing", "存在没有 ID 的生产路线"))
            }
            if route.provides.isEmpty {
                issues.append(Issue(.error, "route.provides.missing",
                                    "路线 \(route.id) 没有声明能达到什么结果"))
            }
            if route.provides.contains(where: isPlaceholder) {
                issues.append(Issue(.error, "route.provides.placeholder",
                                    "路线 \(route.id) 的结果标签仍有待填写项"))
            }
            if route.sourceAssets.isEmpty {
                issues.append(Issue(.warning, "route.sources.missing",
                                    "路线 \(route.id) 没有登记素材/数据来源"))
            }
            if route.requiredCapabilities.isEmpty {
                issues.append(Issue(.warning, "route.capabilities.missing",
                                    "路线 \(route.id) 没有登记真实执行能力"))
            }
            if route.validationStages.isEmpty {
                issues.append(Issue(.error, "route.validation.missing",
                                    "路线 \(route.id) 没有阶段验证"))
            }
        }
        inspectRouteCoverage(contract, issues: &issues)

        let allowedLayers = Set(["integrity", "behavior", "experience", "release"])
        let duplicateCriterionIDs = duplicates(contract.criteria.map(\.id))
        for id in duplicateCriterionIDs {
            issues.append(Issue(.error, "criterion.id.duplicate", "验收条款 ID 重复：\(id)"))
        }
        if contract.criteria.isEmpty {
            issues.append(Issue(.error, "criterion.missing", "没有结构化验收条款"))
        }
        for criterion in contract.criteria {
            if isPlaceholder(criterion.id) {
                issues.append(Issue(.error, "criterion.id.missing", "存在没有 ID 的验收条款"))
            }
            if !allowedLayers.contains(criterion.layer) {
                issues.append(Issue(.error, "criterion.layer.invalid",
                                    "条款 \(criterion.id) 的层级无效：\(criterion.layer)"))
            }
            if criterion.evidenceTypes.isEmpty {
                issues.append(Issue(.error, "criterion.evidence.missing",
                                    "条款 \(criterion.id) 没有规定证据类型"))
            }
            if criterion.layer == "experience", contract.referenceRequired,
               criterion.referenceFiles.isEmpty {
                issues.append(Issue(.error, "criterion.reference.missing",
                                    "体验条款 \(criterion.id) 没有绑定参考物"))
            }
            if criterion.layer == "experience", criterion.rejectConditions.isEmpty {
                issues.append(Issue(.error, "criterion.reject-conditions.missing",
                                    "体验条款 \(criterion.id) 没有明确否决条件"))
            }
            for path in criterion.referenceFiles {
                inspectRequiredFile(path, root: root, issues: &issues)
            }
        }
        if contract.experienceRequired,
           !contract.criteria.contains(where: { $0.layer == "experience" }) {
            issues.append(Issue(.error, "criterion.experience.missing",
                                "项目要求体验验收，但没有 experience 层条款"))
        }
        let forbidsRelaxation = contract.criteria.contains {
            $0.rejectConditions.contains("quality-gate-relaxed-to-pass")
        }
        if forbidsRelaxation && contract.qualityGuardrails.isEmpty {
            issues.append(Issue(.error, "quality-guardrail.missing",
                                "契约禁止放宽质量门槛，但没有登记可执行的 qualityGuardrails"))
        }
        let duplicateGuardrails = duplicates(contract.qualityGuardrails.map {
            $0.file + "|" + $0.symbol
        })
        for key in duplicateGuardrails {
            issues.append(Issue(.error, "quality-guardrail.duplicate",
                                "质量门槛重复登记：" + key))
        }
        for guardrail in contract.qualityGuardrails {
            if guardrail.file.isEmpty || guardrail.symbol.isEmpty {
                issues.append(Issue(.error, "quality-guardrail.invalid",
                                    "质量门槛缺少文件或符号名"))
            } else {
                inspectRequiredFile(guardrail.file, root: root, issues: &issues)
            }
            if !guardrail.value.isFinite {
                issues.append(Issue(.error, "quality-guardrail.value.invalid",
                                    "质量门槛 \(guardrail.symbol) 的批准值不是有限数字"))
            }
        }

        if contract.goldenSampleRequired && contract.goldenSamples.isEmpty {
            issues.append(Issue(.error, "golden-sample.missing",
                                "批量生产前没有定义黄金样板"))
        }
        let criterionIDs = Set(contract.criteria.map(\.id))
        let experienceIDs = Set(contract.criteria.filter { $0.layer == "experience" }.map(\.id))
        for sample in contract.goldenSamples {
            if isPlaceholder(sample.id) || isPlaceholder(sample.deliverableKind) {
                issues.append(Issue(.error, "golden-sample.identity.missing",
                                    "黄金样板缺少 ID 或交付物类型"))
            }
            if sample.criterionIDs.isEmpty {
                issues.append(Issue(.error, "golden-sample.criteria.missing",
                                    "黄金样板 \(sample.id) 没有绑定验收条款"))
            }
            let unknown = sample.criterionIDs.filter { !criterionIDs.contains($0) }
            if !unknown.isEmpty {
                issues.append(Issue(.error, "golden-sample.criteria.unknown",
                                    "黄金样板 \(sample.id) 引用了不存在的条款："
                                        + unknown.joined(separator: "、")))
            }
            if contract.experienceRequired,
               experienceIDs.isDisjoint(with: Set(sample.criterionIDs)) {
                issues.append(Issue(.error, "golden-sample.experience.missing",
                                    "黄金样板 \(sample.id) 没有绑定任何体验条款"))
            }
        }
        return issues
    }

    private static func inspectRouteCoverage(_ contract: ProjectContract,
                                             issues: inout [Issue]) {
        guard !contract.routes.isEmpty, !contract.requiredOutcomes.isEmpty else { return }
        let denied = Set(contract.hardConstraints.compactMap { tagged($0, prefix: "deny:") })
        let required = Set(contract.hardConstraints.compactMap { tagged($0, prefix: "require:") })
        let wanted = Set(contract.requiredOutcomes).union(required)
        let covering = contract.routes.filter { wanted.isSubset(of: Set($0.provides)) }
        if covering.isEmpty {
            issues.append(Issue(.error, "route.outcome.uncovered",
                                "没有生产路线声明能覆盖全部目标："
                                    + wanted.sorted().joined(separator: "、")))
            return
        }
        let eligible = covering.filter { denied.isDisjoint(with: Set($0.requires)) }
        if eligible.isEmpty {
            let conflicts = covering.flatMap { Set($0.requires).intersection(denied) }
            issues.append(Issue(.error, "route.constraint.conflict",
                                "能达到目标的路线全部违反硬约束："
                                    + Set(conflicts).sorted().joined(separator: "、")))
        }
    }

    private static func legacyReport(root: URL, contractURL: URL) -> Report {
        var issues = [Issue(.error, "contract.manifest.missing",
                            "缺少结构化项目契约，系统无法证明生产路线和验收覆盖",
                            file: ProjectContract.relativePath)]
        for (path, code, message) in [
            ("AGENTS.md", "outcome.file.missing", "缺少稳定产品事实"),
            ("QUALITY.md", "quality.file.missing", "缺少质量契约"),
            ("BENCHMARK.md", "reference.file.missing", "缺少参考对象拆解"),
            ("PRODUCTION.md", "route.file.missing", "缺少生产路线说明")
        ] where !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            issues.append(Issue(.warning, code, message, file: path))
        }
        let goldenSources = ["QUALITY.md", "PLAN.md", "PRODUCTION.md"].compactMap {
            try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        if !goldenSources.localizedCaseInsensitiveContains("golden sample")
            && !goldenSources.contains("黄金样板") && !goldenSources.contains("垂直切片") {
            issues.append(Issue(.warning, "golden-sample.missing",
                                "没有发现黄金样板/垂直切片定义"))
        }
        return Report(repo: root.path, contractFile: contractURL.path, issues: issues)
    }

    private static func inspectRequiredFile(_ relative: String, root: URL,
                                            issues: inout [Issue]) {
        guard isSafeRelativePath(relative) else {
            issues.append(Issue(.error, "file.path.invalid",
                                "契约文件必须是仓库内相对路径：\(relative)"))
            return
        }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        else {
            issues.append(Issue(.error, "file.missing", "契约引用的文件不存在：\(relative)",
                                file: relative))
            return
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !NSString(string: path).pathComponents.contains("..")
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v.isEmpty || v == "todo" || v == "tbd" || v.contains("待填写")
    }

    private static func tagged(_ value: String, prefix: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        let tag = String(value.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }

    private static func duplicates(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for value in values where !value.isEmpty {
            if !seen.insert(value).inserted { duplicates.insert(value) }
        }
        return duplicates.sorted()
    }
}
