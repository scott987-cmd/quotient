import XCTest
@testable import LLMQuotaCore

final class ZZTempProbeTests: XCTestCase {
    func testRoundTripCollapsesCreatedAt() throws {
        let steps = TaskDecomposer.parse("""
        {"steps":[{"id":"a","title":"一","prompt":"p","dependsOn":[]},
                  {"id":"b","title":"二","prompt":"p","dependsOn":[]},
                  {"id":"c","title":"三","prompt":"p","dependsOn":[]},
                  {"id":"d","title":"四","prompt":"p","dependsOn":[]},
                  {"id":"e","title":"五","prompt":"p","dependsOn":[]}]}
        """)!
        var t = WorkTask(id: "g1", prompt: "做点事", repo: "/tmp")
        t.profile = nil
        let nodes = TaskDecomposer.build(steps, from: t, planner: .claude, now: Date())!
        let enc = SnapshotCoding.encoder(), dec = SnapshotCoding.decoder()
        let back: [WorkTask] = try nodes.map {
            try dec.decode(WorkTask.self, from: try enc.encode($0))
        }
        print("PROBE distinct createdAt in-memory:", Set(nodes.map { $0.createdAt }).count)
        print("PROBE distinct createdAt after disk:", Set(back.map { $0.createdAt }).count)
        // 模拟 TaskStore.all(): Dictionary(values) -> sorted
        var latest: [String: WorkTask] = [:]
        for n in back { latest[n.id] = n }
        let all = latest.values.sorted { $0.createdAt < $1.createdAt }
        print("PROBE dict order:", all.map { $0.stepTitle! })
        print("PROBE nextReady:", TaskGraph.nextReady(all)?.stepTitle ?? "nil")
        // 任意打乱后仍应稳定选“一”
        for _ in 0..<5 {
            let s = back.shuffled()
            print("PROBE shuffled nextReady:", TaskGraph.nextReady(s)?.stepTitle ?? "nil")
        }
    }
}
