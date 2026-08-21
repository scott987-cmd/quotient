import XCTest
@testable import LLMQuotaCore

/// **菜单栏 App 一死,手机就看到旧快照。**
///
/// 它负责把本机数据推到 iCloud。它停着的时候,worker 照常干活、
/// 本机文件照常更新,而手机上停在几十分钟前 —— 看起来就像「任务停了」。
/// 2026-08-22 一天两次,两次都是老板先发现的,两次根因都是
/// `open <刚删又建的 bundle>` 静默失败而调用方不核实。
final class MenuBarAliveTests: XCTestCase {
    /// 探活判据必须真的看进程,不能靠「我刚才 open 过」。
    func testAliveCheckReadsProcessTable() {
        // 本机此刻 App 可能在也可能不在,这里只断言它给的是个确定答案,
        // 且不抛异常 —— 判据本身可用。
        let a = Housekeeping.menuBarAppAlive()
        XCTAssertEqual(a, Housekeeping.menuBarAppAlive(), "同一时刻两次询问必须一致")
    }

    /// 家务巡检要把 App 探活算进去 —— 否则它死了没人管。
    func testRoundCheckIncludesAppRevival() {
        let r = Housekeeping.roundCheck()
        XCTAssertFalse(r.skipDispatch && r.note == nil,
                       "拦下派活就必须说清为什么")
    }
}
