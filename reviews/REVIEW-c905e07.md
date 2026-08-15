# 合并审查：c905e07

审查通过（附 1 条低严重度的残留观察）。

`c905e07` 是合并落地后的进度台账提交；实际合并是它紧邻的父提交
`b71f742`（来源分支 `agent/codex/c3c604d3`，尖端 `0e7a8ef`，
单提交「修正储备池对文档注释的待办误判」）。以下按第一父提交
`9409285` 到合并结果的净差异审查。

## 实际改动

合并带入 main 的净变化只有三处：

- `Sources/LLMQuotaCore/ReservePool.swift:179` -- `todoNote` 的 guard
  加了 `!line.hasPrefix("///")`，`///` 文档注释不再被当成 TODO 待办。
- `Sources/LLMQuotaCore/ReservePool.swift:54` -- 同文件优先级说明注释里
  的字面词「TODO」改成「代码里的待办标记」。旧代码下这条 `///` 注释
  恰好会被自己的扫描器识别成待办事实（复算过：旧逻辑返回
  「是写代码的人自己留的账」，11 字 ≥ 8 字下限），属自指式假任务，
  本次一并修掉。
- `Tests/LLMQuotaCoreTests/ReservePoolTests.swift:14` -- 新增
  `XCTAssertNil(todoNote("/// TODO 是写代码的人自己留的账"))`。

## 为什么可信

1. **测试是能防回归的真测试。** 用独立脚本复刻新旧两版 `todoNote`
   逻辑验证：新断言的输入在旧代码下返回非 nil（会被当成待办）、
   新代码下返回 nil。即这条断言在改动前会失败，不是永真断言。
2. **逻辑收紧无副作用。** 改动只是缩小识别范围（多排除 `///` 前缀），
   不新增任何识别路径；`todoNote` 全仓只有 `facts()` 扫描循环里两处
   调用（ReservePool.swift:163、166），无其他调用点，也不存在第二份
   重复实现的 TODO 扫描逻辑需要同步改。
3. **没有夹带丢功能。** 分支从 `336aa92` 分叉，早于 main 侧 `9409285`
   （手机批准功能）。diff 里 Mirror.swift / Playbook.swift / main.swift
   的「删除」只是分叉点差异的假象：核对合并结果，`Mirror.swift:122`
   的 `bidirectionalDirs` 仍含 `approvals`，`Playbook.ingestApprovals`
   与 `cmdWorkLoop` 的「收批准」阶段都完整保留，未被这次合并回退。
4. **验证通过。** `swift build` 成功，`swift test --filter ReservePoolTests`
   7 条全过；STATUS.md 的描述与实际改动一致。
5. **高危路径未触碰。** 改动只涉及 `ReservePool.swift`、测试文件和
   STATUS.md，不在 `*.pbxproj`/`Package.swift`/`*.sh`/`Tools/**` 等
   需转人工确认的路径里。

## 发现

- `Sources/LLMQuotaCore/ReservePool.swift:161`（低）-- `// TODO / FIXME：
  写代码的人当场留下的欠账` 是描述规则本身的段落注释，但它是 `//`
  前缀且正文以 TODO 开头，复算确认新旧两版 `todoNote` 都返回非 nil
  （`/ FIXME：写代码的人当场留下的欠账`）；`facts(repo:)` 在仓库
  注册表解析不到时会回退扫当前目录（main.swift:646），对自身仓库
  跑 `llmq work reserve` 仍会从这行生成一条自指式假待办。属改动前
  就存在的问题、非本次合并引入的回归，且受 `limitPerRule` 封顶，
  故记为低；但和本次修掉的是同一类问题，留待后续处理。
