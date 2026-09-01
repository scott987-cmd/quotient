import Foundation

/// 把项目契约中的数值质量门槛变成可执行合入闸。实现分支可以收紧门槛，
/// 但不能通过修改验证器常量让现有资产“变绿”。
public enum QualityGuardrailGate {
    public static func violation(repo: String, branch: String) -> String? {
        let root = URL(fileURLWithPath: NSString(string: repo).expandingTildeInPath,
                       isDirectory: true).standardizedFileURL
        let contractURL = root.appendingPathComponent(ProjectContract.relativePath)
        guard let data = try? Data(contentsOf: contractURL),
              let contract = try? JSONDecoder().decode(ProjectContract.self, from: data),
              !contract.qualityGuardrails.isEmpty else { return nil }

        for guardrail in contract.qualityGuardrails {
            let shown = GitWorkspace.git(
                ["show", "\(branch):\(guardrail.file)"], in: root.path, timeout: 5)
            guard shown.exitCode == 0 else {
                return "架构阻断：无法从 \(branch) 读取质量门槛文件 \(guardrail.file)"
            }
            guard let actual = numericValue(of: guardrail.symbol, in: shown.stdout) else {
                return "架构阻断：质量门槛 \(guardrail.symbol) 在 \(guardrail.file) 中缺失或不可解析"
            }
            let approved = guardrail.value
            let tolerance = 0.000_000_001
            let weakened: Bool
            switch guardrail.bound {
            case .minimum: weakened = actual + tolerance < approved
            case .maximum: weakened = actual - tolerance > approved
            case .exact: weakened = abs(actual - approved) > tolerance
            }
            if weakened {
                return "架构阻断：\(guardrail.symbol) 的批准门槛是 "
                    + "\(approved)（\(guardrail.bound.rawValue)），分支改成了 \(actual)；"
                    + "禁止放宽质量门槛换取通过"
            }
        }
        return nil
    }

    static func numericValue(of symbol: String, in text: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: symbol)
        let number = #"([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)"#
        let pattern = #"(?m)^[ \t]*"# + escaped + #"[ \t]*=[ \t]*"# + number
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }
}
