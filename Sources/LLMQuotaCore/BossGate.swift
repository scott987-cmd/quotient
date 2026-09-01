import Foundation

/// **哪些拦截该惊动老板,哪些该我自己处置。**
///
/// 老板 2026-08-22 的常设指示:「阻塞任务,你来看处理,这种问题都你来处理,
/// 给我应该就是风险类或者验收类」。
///
/// ## 为什么这条很重要
///
/// 高危路径闸的判据很粗:**任何** `.sh`、`Tools/`、`.github/`、`.xcodeproj/`
/// 都算。它拦下的绝大多数是「改了个生成脚本」这种纯技术活 —— 人看一眼
/// diff 就知道行不行,而那件事我能做,不必把他从生活里叫出来。
///
/// 更糟的是这些噪音会**淹掉真正要他拍板的那两类**。他今天已经因为
/// 「推了人做不到的事」被烦过两次(成果推送没有页面、高危拦截没有按钮),
/// 再加一层「什么都推」,这个通知就会被彻底训练成背景噪音 ——
/// 那时候真出事也叫不动他了。
///
/// ## 分界:后果是钱 / 账号 / 对外影响吗
///
/// 是 → 他;不是 → 我。**签名、证书、密钥、上架发布、付费配置、
/// 广告位**这些一旦错了,损失不可逆或要动他的账号,只有他能决定。
/// 构建脚本、工具链、CI 编排改错了,大不了重跑一次。
public enum BossGate {
    /// 真·风险类的路径特征。判据保守:宁可多问他一次,
    /// 也不要在签名配置上自作主张。
    static let bossPatterns = [
        // 签名与证书
        // **不能用裸的 "sign"** —— `DESIGN.md` 里就含它,一加就把设计文档
        // 判成风险类。用完整词或带连字符的形式(2026-08-22 被测试抓到)。
        "codesign", "notarize", "keychain", "altool", "provision",
        "entitlements", ".p8", ".p12", ".mobileprovision",
        "exportoptions", "signing", "signature",
        // 密钥与凭据
        "secret", "credential", "apikey", "api_key", "token", ".env",
        // 上架与发布
        "fastlane", "appstore", "app_store", "testflight", "release.yml", "publish",
        // 花钱的
        "admob", "ca-app-pub", "billing", "purchase", "iap", "subscription",
    ]

    /// 这批改动要不要老板亲自拍板。
    public static func needsBoss(files: [String]) -> Bool {
        let hay = files.joined(separator: " ").lowercased()
        return bossPatterns.contains { hay.contains($0) }
    }

    /// 给日志/记录用的一句话:为什么归他 / 归我。
    public static func note(files: [String]) -> String {
        if needsBoss(files: files) {
            let hit = bossPatterns.first { files.joined(separator: " ").lowercased().contains($0) }
            return "碰到风险类配置（\(hit ?? "签名/密钥/发布/付费")），只有老板能拍板"
        }
        return "碰高危路径但不涉及账号/签名/发布/付费 —— 按老板 2026-08-22 的"
            + "常设指示由架构师处置，不打扰他"
    }
}
