import Foundation

/// 解码状态文件的统一入口：**失败必须留痕**。
///
/// ## 为什么单独做这个
///
/// 一天之内被同一个形状咬了三次：
///
/// 1. 给 `OfficialQuota` 加了个字段，另一台机器（还没升级）写的快照
///    解不出来 —— 整台机器从看板上消失，调度以为它上面的平台都没在用。
///    排查了半小时，因为 `try? decode` 什么都不说。
/// 2. 手机批准的项目找错了目录，文件在那儿躺着没人读。
/// 3. 验收结论执行失败被当成成功，产出永远卡在待审。
///
/// 共同点不是「写错了」，而是**错了以后没有任何痕迹**。
/// 症状全都是「跑通了但没生效」，而这种问题查起来比崩溃贵十倍：
/// 崩溃有堆栈，静默跳过只有一个说不清的现象。
///
/// ## 用法
///
///     let snap: MachineSnapshot? = SafeDecode.json(at: url, as: MachineSnapshot.self)
///
/// 解不出来时：记进 `SafeDecode.failures`，`llmq doctor` / `llmq mirror`
/// 会把它们报出来。**调用方拿到的还是 nil** —— 不改变控制流，
/// 只是让失败不再无声。
public enum SafeDecode {

    public struct Failure: Sendable {
        public var file: String
        public var type: String
        public var reason: String
        public var at: Date
    }

    /// 最近的解码失败。进程内保存，够诊断用了 ——
    /// 这类问题总是「现在就不对劲」，不需要历史。
    public private(set) nonisolated(unsafe) static var failures: [Failure] = []

    /// 记的时候顺手裁掉旧的：一个跑了几天的 worker 不该攒出几万条。
    private static let keep = 50

    public static func note(file: String, type: String, reason: String,
                            now: Date = Date()) {
        failures.append(Failure(file: file, type: type,
                                reason: String(reason.prefix(400)), at: now))
        if failures.count > keep { failures.removeFirst(failures.count - keep) }
    }

    public static func reset() { failures = [] }

    /// 读并解一个 JSON 文件。文件不存在返回 nil 且**不记失败** ——
    /// 「还没有这个文件」是正常状态，不是错误。
    public static func json<T: Decodable>(
        at url: URL, as type: T.Type,
        decoder: JSONDecoder = SafeDecode.iso8601Decoder()
    ) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return json(data, as: type, from: url.lastPathComponent, decoder: decoder)
    }

    public static func json<T: Decodable>(
        _ data: Data, as type: T.Type, from label: String,
        decoder: JSONDecoder = SafeDecode.iso8601Decoder()
    ) -> T? {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            note(file: label, type: "\(T.self)", reason: describe(error))
            return nil
        }
    }

    public static func iso8601Decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// 把 DecodingError 说人话。
    ///
    /// 默认的 `"\(error)"` 是一大段带换行的调试描述，塞进一行日志里没法看。
    /// 而这类错误真正有用的就三样：缺哪个键、路径在哪、期望什么类型。
    public static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "\(error)" }
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            // 这是跨版本最常见的一种：新版加了字段，老版写的文件没有它。
            // Swift 合成的 Decodable **不用属性默认值**，缺键直接抛错。
            return "缺字段「\(key.stringValue)」，位置 \(path(ctx))"
                + "（老版本写的文件？给这个字段写 decodeIfPresent）"
        case .typeMismatch(let t, let ctx):
            return "字段类型不对，期望 \(t)，位置 \(path(ctx))"
        case .valueNotFound(let t, let ctx):
            return "字段是 null 但类型不可空（\(t)），位置 \(path(ctx))"
        case .dataCorrupted(let ctx):
            return "内容坏了：" + ctx.debugDescription
        @unknown default:
            return "\(error)"
        }
    }
}
