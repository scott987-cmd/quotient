import XCTest
@testable import LLMQuotaCore

/// 源码级不变量：碰 iCloud 的文件里不许有裸的原子写。
///
/// # 为什么要用这么笨的办法
///
/// 这一类 bug 在一小时内咬了两次：
/// 1. `Inbox.publishDashboard` 的 `Data.write(.atomic)` 卡在 `rename()`，
///    `llmq work loop` 整个冻住，进程活着但日志一个字节不长。
/// 2. 手工把 `collect()` 那六处包进看门狗之后，worker 又冻住了 ——
///    这次是 `runOneTask → OfficeLog.publish`，另一条路径，同一个病。
///
/// **手工枚举调用点，我第一次做就漏了。** 靠「下次记得包一下」是防不住的，
/// 而且这个 bug 的表现是「一切正常，只是什么都不动了」——
/// 单元测试跑得再全也照样绿。所以在源码层面立一条硬规矩。
///
/// 新增合法用法：走 `ICloudSafe.write` / `ICloudSafe.move`。
/// 确实需要裸写本地文件时，把文件从下面这张表里去掉，并在这里说明理由。
final class ICloudWriteGuardTests: XCTestCase {

    /// **不维护清单，扫全部。**
    ///
    /// 第一版这里是一张手写的「会碰 iCloud 的文件」名单。然后 worker 又卡死了 ——
    /// 卡在 `CooldownLedger.save()`，而 `Cooldown.swift` **不在那张名单上**。
    /// 手工维护清单和手工枚举调用点是同一个病，只是换了个地方犯。
    ///
    /// 现在的规矩：`Sources/LLMQuotaCore` 下**任何**原子写都必须走
    /// `ICloudSafe`。它自己判路径，非 iCloud 的直接写、零开销，
    /// 所以「一律用它」没有成本，而「判断这个文件碰不碰 iCloud」有成本 ——
    /// 那个判断我已经错了两次。
    private var sourceFiles: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: sourcesDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// 唯一的例外：收口函数自己。
    private let exempt: Set<String> = ["Watchdog.swift"]

    private var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)            // .../Tests/LLMQuotaCoreTests/x.swift
            .deletingLastPathComponent()            // .../Tests/LLMQuotaCoreTests
            .deletingLastPathComponent()            // .../Tests
            .deletingLastPathComponent()            // 包根
            .appendingPathComponent("Sources/LLMQuotaCore")
    }

    func testNoRawAtomicWritesInICloudTouchingFiles() throws {
        XCTAssertGreaterThan(sourceFiles.count, 10,
                             "一个源文件都没扫到，说明路径推错了 —— 别把空扫当成通过")
        for url in sourceFiles {
            let name = url.lastPathComponent
            guard !exempt.contains(name) else { continue }
            let src = try String(contentsOf: url, encoding: .utf8)
            let lines = src.split(separator: "\n", omittingEmptySubsequences: false)

            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), !line.hasPrefix("///") else { continue }
                // 只抓「原子写」。局部的、明确写本地的普通 write 不在管辖范围。
                guard line.contains(".write(") else { continue }
                guard line.contains("options: .atomic") || nextLinesHaveAtomic(lines, from: i)
                else { continue }
                // 走了收口函数就没问题。
                guard !line.contains("ICloudSafe.") else { continue }

                XCTFail("""
                    \(name):\(i + 1) 有一处裸的原子写：
                        \(line)
                    这个路径**可能**落在 iCloud 上，而 iCloud 的写入可以永久阻塞
                    （实测卡在 rename()，把 work loop 整个冻住）。
                    改成 ICloudSafe.write / ICloudSafe.move —— 它会自己判路径，
                    非 iCloud 的直接写，没有额外开销。
                    """)
            }
        }
    }

    /// `.write(` 和 `options: .atomic` 经常被换行拆开，往后看两行。
    private func nextLinesHaveAtomic(_ lines: [Substring], from i: Int) -> Bool {
        for j in (i + 1)...(i + 2) where j < lines.count {
            if lines[j].contains("options: .atomic") { return true }
            if lines[j].contains(")") && !lines[j].contains(",") { return false }
        }
        return false
    }

    func testICloudPathDetection() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(ICloudSafe.isICloud(
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x.json")))
        XCTAssertFalse(ICloudSafe.isICloud(
            home.appendingPathComponent("Library/Application Support/LLMQuotaBar/x.json")))
        XCTAssertFalse(ICloudSafe.isICloud(URL(fileURLWithPath: "/tmp/x.json")))
    }

    /// 不在 iCloud 下的路径要直接写，不进看门狗 —— 否则每次本地写都白等一次调度。
    func testLocalWriteIsNotWatchdogged() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icloudsafe-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertTrue(ICloudSafe.write(Data("{}".utf8), to: tmp))
        XCTAssertEqual(try Data(contentsOf: tmp), Data("{}".utf8))
    }
}
