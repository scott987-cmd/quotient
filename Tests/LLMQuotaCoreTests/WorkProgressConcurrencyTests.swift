import XCTest
@testable import LLMQuotaCore

final class WorkProgressConcurrencyTests: XCTestCase {
    private func waitFor(_ url: URL, seconds: TimeInterval = 15) throws {
        let until = Date().addingTimeInterval(seconds)
        while !FileManager.default.fileExists(atPath: url.path) {
            if Date() >= until { throw NSError(domain: "ProgressBarrier", code: 1) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // Re-exec this test in a separate process; no real task or cloud store is used.
    func testConcurrentProcessesPreserveDeclarationAndCompletion() throws {
        let env = ProcessInfo.processInfo.environment
        if let path = env["LLMQ_PROGRESS_CHILD_ROOT"], let token = env["LLMQ_PROGRESS_CHILD_TOKEN"] {
            let root = URL(fileURLWithPath: path)
            WorkProgressStore.dirOverride = root.appendingPathComponent("progress")
            defer { WorkProgressStore.dirOverride = nil; WorkProgressStore.beforeCommitForTesting = nil }
            WorkProgressStore.beforeCommitForTesting = {
                try! Data().write(to: root.appendingPathComponent(token + ".ready"))
                try! self.waitFor(root.appendingPathComponent(token + ".go"))
            }
            _ = try WorkProgressStore.record(taskID: "task", phase: "持续实现", summary: "检测到新提交",
                nextStep: "继续当前任务", evidence: [], requestedMinutes: 20,
                repo: root.appendingPathComponent("repo").path, automatic: true)
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("progress-process-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        WorkProgressStore.dirOverride = root.appendingPathComponent("progress")
        defer { WorkProgressStore.dirOverride = nil; try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(Proc.run("/usr/bin/git", ["init", "-q"], cwd: repo.path, env: [:], timeout: 10).exitCode, 0)
        let started = Date()
        let first = try WorkProgressStore.record(taskID: "task", phase: "起点", summary: "旧进度",
            nextStep: "旧下一步", evidence: [], requestedMinutes: 20, repo: repo.path,
            now: started.addingTimeInterval(-60))
        func child(_ token: String) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "LLMQuotaCoreTests.WorkProgressConcurrencyTests/testConcurrentProcessesPreserveDeclarationAndCompletion", Bundle(for: Self.self).bundleURL.path]
            var vars = env
            vars["LLMQ_PROGRESS_CHILD_ROOT"] = root.path
            vars["LLMQ_PROGRESS_CHILD_TOKEN"] = token
            process.environment = vars
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return process
        }
        for (index, next) in [Optional("等待独立复验"), nil].enumerated() {
            let token = "writer-\(index)"
            let process = try child(token)
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            try waitFor(root.appendingPathComponent(token + ".ready"))
            _ = try WorkProgressStore.record(taskID: "task", phase: "阶段完成", summary: "真实主动声明",
                nextStep: next, evidence: ["new-evidence.txt"], requestedMinutes: 20, repo: repo.path)
            let declared = try XCTUnwrap(WorkProgressStore.load(taskID: "task"))
            try Data().write(to: root.appendingPathComponent(token + ".go"))
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let stored = try XCTUnwrap(WorkProgressStore.load(taskID: "task"))
            XCTAssertEqual(stored.sequence, declared.sequence + 1)
            XCTAssertEqual(stored.explicitNextStep, next)
            XCTAssertEqual(stored.explicitNextStepSequence, declared.explicitNextStepSequence)
            XCTAssertEqual(stored.explicitNextStepAt, declared.explicitNextStepAt)
            XCTAssertEqual(stored.evidence, declared.evidence)
            XCTAssertEqual(stored.checkpointAt, declared.checkpointAt)
            XCTAssertGreaterThanOrEqual(stored.updatedAt, declared.updatedAt)
            var task = WorkTask(id: "task", prompt: "完整交付", repo: repo.path)
            task.state = .done
            XCTAssertEqual(WorkContinuationGate.requeueIfNeeded(task: &task, startedAt: started,
                baselineSequence: first.sequence, progress: stored), next)
            XCTAssertEqual(task.state, next == nil ? .done : .queued)
        }
        // Simultaneous automatic writers must allocate different sequence numbers.
        let baseline = try XCTUnwrap(WorkProgressStore.load(taskID: "task"))
        let children = try (0..<4).map { try child("parallel-\($0)") }
        defer { for p in children where p.isRunning { p.terminate(); p.waitUntilExit() } }
        for i in 0..<4 { try waitFor(root.appendingPathComponent("parallel-\(i).ready")) }
        for i in 0..<4 { try Data().write(to: root.appendingPathComponent("parallel-\(i).go")) }
        for p in children { p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0) }
        XCTAssertEqual(WorkProgressStore.load(taskID: "task")?.sequence, baseline.sequence + 4)
    }
    func testThreadWritersAndFailedWriteReleaseTheTaskLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("progress-threads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WorkProgressStore.dirOverride = root.appendingPathComponent("progress")
        defer { WorkProgressStore.dirOverride = nil; try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(Proc.run("/usr/bin/git", ["init", "-q"], cwd: root.path, env: [:], timeout: 10).exitCode, 0)
        let blockedFile = WorkProgressStore.file(taskID: "task")
        try FileManager.default.createDirectory(at: blockedFile, withIntermediateDirectories: true)
        XCTAssertThrowsError(try WorkProgressStore.record(taskID: "task", phase: "准备", summary: "写入失败",
            nextStep: nil, evidence: [], requestedMinutes: 20, repo: root.path))
        try FileManager.default.removeItem(at: blockedFile)
        let lock = NSLock()
        var sequences: [Int] = [], errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                let result = try WorkProgressStore.record(taskID: "task", phase: "执行", summary: "writer \(index)",
                    nextStep: "继续", evidence: [], requestedMinutes: 20, repo: root.path)
                lock.lock(); sequences.append(result.sequence); lock.unlock()
            } catch {
                lock.lock(); errors.append(String(describing: error)); lock.unlock()
            }
        }
        XCTAssertEqual(errors, [])
        XCTAssertEqual(sequences.sorted(), Array(1...8))
        XCTAssertEqual(WorkProgressStore.load(taskID: "task")?.sequence, 8)
    }

}
