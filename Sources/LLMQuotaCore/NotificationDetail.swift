import Foundation
import CryptoKit

/// 通知的只读发送快照，不是新的任务账本。每条按机器+事件+正文寻址，
/// 不会被另一台机器的页面覆盖；处理当前事项仍走原有实时页面。
public enum NotificationDetail {
    public struct Record: Codable, Sendable {
        public var id: String
        public var createdAt: Date
        public var sourcePage: String?
        public var title: String
        public var body: String
        public var content: ViewFeed.Page?
        /// 这次事件必须先同步的媒体。历史卡片仍可读，但其旧媒体不能堵住新成果提醒。
        public var requiredImages: [String]?

        init(id: String, createdAt: Date, sourcePage: String?, title: String,
             body: String, content: ViewFeed.Page?, requiredImages: [String]? = nil) {
            self.id = id; self.createdAt = createdAt; self.sourcePage = sourcePage
            self.title = title; self.body = body; self.content = content
            self.requiredImages = requiredImages
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
            sourcePage = try c.decodeIfPresent(String.self, forKey: .sourcePage)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "提醒详情"
            body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
            content = try c.decodeIfPresent(ViewFeed.Page.self, forKey: .content)
            requiredImages = try c.decodeIfPresent([String].self, forKey: .requiredImages)
        }
    }

    public static func sourcePage(_ page: String, machineID: String) -> String {
        guard ["review", "blocked", "playbook"].contains(page) else { return page }
        let suffix = SHA256.hash(data: Data(machineID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return page + "-" + suffix
    }

    static func make(key: String, kind: Push.Kind, body: String, machineID: String,
                     page: ViewFeed.Page?, now: Date) -> Record {
        let original = Nudge.targetPage(for: key) ?? "now"
        var content = page
        // 历史快照不得重放合入/拒绝/放行动作。图片和全文仍保留。
        if content != nil {
            for i in content!.sections.indices {
                content!.sections[i].actions = []
                if let cards = content!.sections[i].cards {
                    content!.sections[i].cards = cards.map { card in
                        var copy = card; copy.actions = []; return copy
                    }
                }
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let context = (try? enc.encode(content?.sections ?? [])) ?? Data()
        let id = SHA256.hash(data: Data((machineID + "\n" + key + "\n" + body).utf8) + context)
            .map { String(format: "%02x", $0) }.joined()
        let requiredImages: [String]?
        if key.hasPrefix("milestone-"), let sha = key.split(separator: "-").last {
            let current = page?.sections.flatMap { $0.cards ?? [] }
                .filter { $0.id.hasSuffix("|" + sha) } ?? []
            // 未命中当前卡片时不把缺失证据误判为零张；capture 会拒绝发出此提醒。
            requiredImages = current.isEmpty ? nil : current.flatMap(\.images)
        } else { requiredImages = nil }
        return Record(id: id, createdAt: now,
                      sourcePage: sourcePage(original, machineID: machineID),
                      title: kind.title, body: body, content: content, requiredImages: requiredImages)
    }

    static func capture(key: String, kind: Push.Kind, body: String,
                        root: URL = Paths.sharedRoot, now: Date = Date()) -> Record? {
        let target = Nudge.targetPage(for: key)
        var page = target.flatMap { ViewFeed.published(page: $0, root: root) }
        if key.hasPrefix("milestone-"), let sha = key.split(separator: "-").last,
           page?.sections.flatMap({ $0.cards ?? [] }).contains(where: { $0.id.hasSuffix("|" + sha) }) != true {
            return nil
        }
        if key.hasPrefix("progress-stalled-") {
            let taskID = String(key.dropFirst("progress-stalled-".count))
            guard let task = TaskStore.all().first(where: { $0.id == taskID }) else { return nil }
            page = ViewFeed.Page(page: "roadmap", sections: [.init(kind: "cards", cards: [
                .init(id: task.id, title: TaskBrief.title(for: task), body: task.note,
                      detail: "Owner：\(task.ownerRunnerID ?? "待核对")\n"
                        + "分支：\(task.branch ?? "尚未建立")\n任务要求：\(task.prompt)",
                      taskID: task.id)
            ])], now: now)
        } else if key.hasPrefix("question-") {
            let tasks = TaskStore.all()
            let asks = AskStore.pending(machine: Paths.machineID()).filter { ask in
                ask.kind == .question && tasks.contains {
                    $0.state == .blocked && $0.pendingAsk?.id == ask.id
                }
            }
            page = ViewFeed.Page(page: "now", sections: [.init(kind: "cards", cards: asks.map { ask in
                .init(id: ask.id, title: ask.taskPrompt,
                      detail: ask.questions.map(\.text).joined(separator: "\n\n"), taskID: ask.taskID)
            })], now: now)
        }
        if ["review", "blocked", "playbook", "now"].contains(target ?? ""),
           page?.sections.flatMap({ $0.cards ?? [] }).isEmpty != false { return nil }
        return make(key: key, kind: kind, body: body, machineID: Paths.machineID(), page: page, now: now)
    }

    /// 文件在独立目录，手机仅按通知 ID 读一个文件，不加入全局每 15 秒扫描。
    /// 相同 ID 重试保留原始发送内容与时间；云端读回确认成功之后才允许发横幅。
    static func publish(_ record: Record, localRoot: URL, mobileRoot: URL) -> Bool {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let local = localRoot.appendingPathComponent("notification-details/\(record.id).json")
        let mobile = mobileRoot.appendingPathComponent("notification-details/\(record.id).json")
        for url in [local, mobile] {
            let dir = url.deletingLastPathComponent()
            guard Watchdog.run("notification.mkdir:" + dir.path, timeout: 2, {
                (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
            }).valueOr(false) else { return false }
        }
        let data: Data
        if let old = ICloudSafe.read(local, timeout: 2),
           let saved = try? dec.decode(Record.self, from: old), saved.id == record.id {
            data = old
        } else {
            guard let encoded = try? enc.encode(record), ICloudSafe.write(encoded, to: local, timeout: 2)
            else { return false }
            data = encoded
        }
        if ICloudSafe.read(mobile, timeout: 2) == data { return true }
        return ICloudSafe.write(data, to: mobile, timeout: 3)
            && ICloudSafe.read(mobile, timeout: 2) == data
    }

    static func ready(_ record: Record, mobileRoot: URL) -> Bool {
        let url = mobileRoot.appendingPathComponent("notification-details/\(record.id).json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let data = ICloudSafe.read(url, timeout: 2),
              let saved = try? dec.decode(Record.self, from: data), saved.id == record.id else { return false }
        let files = saved.requiredImages
            ?? saved.content?.sections.flatMap { $0.cards ?? [] }.flatMap(\.images) ?? []
        return files.allSatisfy { file in
            !file.contains("/") && file != ".." && ICloudSafe.isRegularFile(
                mobileRoot.appendingPathComponent("evidence").appendingPathComponent(file))
        }
    }
}
