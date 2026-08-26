# 任务状态并发写入架构复核（2026-08-25）

架构师：claude.code（任务 `c13b30c8`）。方法：读代码复核，**未跑 `swift test`、
未在现场复现竞争**——凡属实证、结构推断、现场回放的结论都分开标注，见每节末尾。
验证命令留给执行 Agent，见「验证口径」。

## 0. 结论先行

- **本轮 `a59eba3` 视觉历史票单调性修复：判定通过。** 逻辑正确、有变异验证过的
  回归测试、爆炸半径受限。但它是**局部状态机收紧**，只堵住「视觉否决重开」这一条路；
  并发状态倒退这一类问题它没有、也不该由它解决。见 §2。
- **是否立即引入 task revision/CAS：分两步走，不要大爆炸。**
  - **Phase 1（立即做）**：给 `WorkTask` 加单调 `revision`，`all()` 折叠改成
    「高 revision 优先」，并把「读改写」集中到一个 `TaskStore.mutate` 入口。这是
    廉价、向后兼容、且能**顺带量化真实冲突率**的一步——它同时回答了「要不要现在上
    CAS」这个问题。
  - **Phase 2（结构已证、可预授权的两处先上；其余按 Phase 1 遥测再定）**：跨进程
    `flock` + compare-and-append。先覆盖两处**光看代码就能证明会丢更新**的写入者：
    后台落地线程的 `markDisposition` ‖ 主线程 reconcile 命中同一 done 行；以及
    `runOneTask` 收尾时用**分钟前的内存快照**盲写、跨进程 `llmq work approve` /
    `llmq asks` 在这中间改了同一行。
  - **Phase 3**：所有写入统一走 CAS、加日志文件压实（compaction）。
- **不建议「先只收集更多样本再说」**：Phase 1 本身就是收集样本的手段，且已能提供读侧
  保护，没有理由推迟。但**全量 Phase 2 铺开**可以等 Phase 1 遥测出真实冲突频次再定
  优先级，避免为极低频路径付重构成本。

---

## 1. 事实

### 1.1 存储模型（实证：读 `Sources/LLMQuotaCore/Work.swift:229-335`）

- `tasks.jsonl` 一行一个任务快照，append-only。`TaskStore.all()`
  （`Work.swift:249-281`）把同 `id` 的多行折成**文件里最后出现的那条**
  （`latest[t.id] = t`，第 278 行）——即「后写覆盖先写」，按**文件位置**而非逻辑版本。
- 并发原语只有两层：进程内 `NSLock`（`writeLock`，`Work.swift:242/287`）+ `O_APPEND`
  （`Work.swift:293`）。
  - `NSLock` 只在**同一进程内**串行化单次 `append` 的字节写。
  - `O_APPEND` 只保证**跨进程**单次 write 原子追加到末尾（不撕裂字节）。
  - **两者都不提供逻辑 CAS。** 每个写入者的实际动作是
    `TaskStore.all()`（读到「后写覆盖」的快照）→ 在内存里改 → `append`。读和写之间
    别的进程/线程若追加了更新的快照，会被这个基于**过期读**的后续 append 静默覆盖。
- **文件是本机私有、不跨机同步。**（实证：`Work.swift:251-254` 注释「appSupport
  不同步」；镜像层 `MirrorService.sync` 只镜像 `Paths.sharedRoot`（`shared/`），
  从不碰 `tasks.jsonl`。）所以本复核讨论的并发**全部发生在单台 Mac 上**，
  不是跨机一致性问题。

### 1.2 进程 / 线程图（实证）

单台 Mac 上会追加 `tasks.jsonl` 的执行体：

| # | 执行体 | 拉起方 | 单实例？ | 是否改「已存在的行」 |
|---|--------|--------|----------|----------------------|
| 1a | `llmq work loop` **主线程** | launchd worker | `SingleInstanceLock("work-loop")` flock（`WorkLoop.swift:34-59`，`main.swift:3375`）→ 只挡第二个 loop | 是 |
| 1b | 同进程 **后台落地线程** | `DispatchQueue.global.async`（`main.swift:3635-3641`，`landingInFlight` 限一个） | 与 1a 同进程、**并发** | 是（`markDisposition`） |
| 2 | `llmq cluster serve` | launchd 常驻（plist `main.swift:5375`） | 独立进程，**不受 work-loop 锁约束** | 否（只 new-id 提交） |
| 3 | 临时 `llmq …` CLI | 人工 / 触发 | 无锁、可多开 | 是（`work approve` / `asks`） |
| 4 | 菜单栏 `LLMQuotaBarApp` | 用户 | — | **否**：只 `spawn llmq collect`（读用量）+ `MirrorService`；不写 `tasks.jsonl` |

关键点：`SingleInstanceLock` 只拦第二个 work loop，**拦不住** `cluster serve`（#2）和任意
`llmq` CLI（#3）与 loop 并发追加。所以「同时可能写 `tasks.jsonl` 的执行体」=
1 个 loop（含 2 条线程）+ 1 个 cluster serve + N 个 CLI。

### 1.3 写入者清单（实证；两名探子独立盘点、结论一致）

**改「已存在行」的读改写者（CAS 暴露面）：**

| 写入者 | file:line | 执行体 | 改的字段 |
|--------|-----------|--------|----------|
| `runOneTask` 认领 | `main.swift:2435-2439` | loop 主线程 | `state=running,runnerPID,startedAt` |
| `runOneTask` 收尾 | `main.swift:3324` | loop 主线程 | `state=done/failed/blocked,exitCode,endedAt,outputs,changedFiles`——**基于认领时的内存快照，收尾前不重读** |
| 孤儿回收 | `main.swift:3491` | loop 主线程（启动时） | `state=queued/failed,endedAt,runnerPID=nil,interruptedCount` |
| `TaskGraph.reconcile` 回写 | `TaskGraph.swift:237`，append 于 `main.swift:3337/3497/3617` 等 | loop 主线程 | 图状态 blocked/queued、`frozenBy`、`note`；并委派 `ArchitectReview`/`PostLandRepair`/`VisualQualityGate`/`GoldenSampleGate` |
| `markDisposition` | `Review.swift:1175/1183` | **loop 后台落地线程** | `landedAt` 或 `discardedAt+discardReason` |
| `AskIngest.run` | `Ask.swift:503/515/528` | loop 主线程（`main.swift:3579`）**及** CLI `llmq asks`（`main.swift:1699`，独立进程） | `answeredAsk,state,pendingAsk,startedAt/endedAt,note` |
| `StuckAsk.raise` | `Ask.swift:581` | loop 主线程 | `pendingAsk,state=blocked,triedPlatforms=[]` |
| 手机卡片 approve/discard | `main.swift:6987` | loop 主线程 | 经 `Approval.settle`：`state,discardedAt,branch` |
| CLI `work approve` | `main.swift:1674` | **临时 CLI（独立进程）** | 同上 |

**只 new-id、不覆盖已存在行的追加者**（不丢更新，但证明并发追加者不止一个）：
`Inbox.ingest`（`Inbox.swift:421`，loop）、`enqueuePostLandReview`（`Review.swift:1100`，
后台线程）、`MergeReview.dispatch`/`VerifyRepair`/`StaleBranch`/`EvidenceGate`/`IdleFiller`/
`AutoRefill`/`Milestone`（均 `TaskIntake.enqueue` new-id）、`ClusterService submit`
（`ClusterProtocol.swift:175`，**cluster serve 进程**）。

**不是 `tasks.jsonl` 写入者**（澄清，避免误列入 CAS 面）：`ConfigIntentIngest`
只写 `config/roles.json`（`AgentRoles.save`），不 `TaskStore.append`。

---

## 2. 本轮 `a59eba3` 修复复核

改动：`VisualQualityGate.reconcileRemediation`（`VisualQualityGate.swift:122-146`）
加两道闸；并把架构复核首选/硬闸从 Codex 切到 Claude（`ArchitectReview.swift`、
`TaskIntake.swift`、`Work.swift:461`）。后者是路由改动，与本主题无关，逻辑一致、有定向
测试，**通过**。前者是本主题核心，评估如下：

**判定：通过（正确、必要、爆炸半径受限），但只是局部收紧，非通用解。**

- 正确性（实证读代码）：
  1. `guard source.state == .done || .failed`（第 125 行）——对账只能重开**已终态**的
     实现，不再改写 running/queued/blocked。这正是现场回放里「Ox 真在跑却被写回
     queued」的直接堵漏。
  2. `visualRemediationReviewID` 升级为「已处理到哪张票」的水位：处理过较新否决后，
     `verdictDate(review) <= verdictDate(handled)` 的旧票永不倒灌（第 137-142 行）。
- 测试（读 `Tests/.../VisualQualityRemediationTests.swift:95-118`）：
  `testHistoricalRejectionCannotOverwriteActiveOrNewerRemediation` 覆盖 running 与
  done 两种收工态；交接文档称删除「较新票屏障」后该测试稳定变红（**变异验证已做**，
  我未复跑，验证命令见 §5）。

**残留缺口（这不是这次修复的锅，但必须记入档，说明为什么还要 Phase 1/2）：**

- a) `reconcileRemediation` 在**读 `source.state` 与调用方 append 之间**仍有窗口。它只在
  loop 主线程跑，主线程内串行没问题；但**后台落地线程**可能在这中间给同一 done 行写上
  `landedAt`，而重开逻辑会把 `landedAt` 置 nil（`VisualQualityGate.swift:173`）——
  于是一次真实落地被静默抹掉。局部状态机管不到跨线程的这一类。
- b) `verdictDate = endedAt ?? createdAt`（第 25-27 行），而 ISO8601 落盘把秒以下抹平
  （项目已知坑，见 `Work.swift:108-113` 关于 `stepIndex` 的说明）。同秒的两张票用 `<=`
  比较会误判，最坏是**少重开一轮**，影响小，但属于「用时间戳当版本」的通病——Phase 1
  的 `revision` 正是要替换这类脆弱比较。

**结论**：本轮修复该合、该保留；它把「视觉否决」这条最先爆的路堵死了，为 Phase 1/2 争取
了时间。但它没有、也不可能覆盖 §1.3 里其它读改写者之间的倒退。

---

## 3. 风险（按可证明程度排序）

**R1 — 后台落地线程 ‖ 主线程命中同一行（结构已证，同进程）。**
`markDisposition`（后台线程）与主线程的 reconcile/AskIngest/收尾写同一 `id`，中间只有
`NSLock` 保字节、不保「读+写」事务。典型倒退：主线程重开某 done 行为 queued（视觉整改
/图解冻），后台线程用几微秒前读到的 done 快照补写 `landedAt` →
queued 被覆盖回 done+landed。后果：手机显示假状态、下游图永远等一个已被写回 done 的上游、
重复调度。`Work.swift:236-241` 的注释本身就是为这条竞争加的 `NSLock`——但它只解决了
「字节级丢写」，没解决「逻辑级过期覆盖」。（未现场复现；结构上必然存在。）

**R2 — `runOneTask` 分钟级过期窗口 ‖ 跨进程改同一行（结构已证，跨进程）。**
`runOneTask` 在 `main.swift:2072` 读队列拿到 `task`，认领为 running，**跑 agent（可数
分钟）后在 `main.swift:3324` 用那份内存快照盲写终态，全程不重读**。这期间跨进程
`llmq work approve` 或 `llmq asks`（消化手机答复）若改了这同一行（`answeredAsk`、
`state=blocked`、`discardedAt`），收尾写会把它整条覆盖掉。后果：老板在手机上点的
「放行/答复」被无声吞掉。（未复现；窗口最宽，是 CAS 收益最大的一处。）

**R3 — 现场已回放过的视觉倒退（实证：现已由 `a59eba3` 堵住）。**
交接文档记载：Ox 真在跑，后台视觉对账拿历史否决把任务写回 queued。本轮已修。列此以说明
「这类倒退不是理论」——R1/R2 是同一机制的其它出口。

**R4 — 日志无界增长（实证）。** 每次状态变化都 append 一行，无压实。文件越大，`all()`
每轮全量解析越慢（看板每轮都调 `all()`），也让未来 CAS 的「取当前 head 版本」更贵。
非安全问题，但会拖慢并放大上面几条的窗口。

冲突**单次概率低**（写频约每 30s 一个 tick 级别），但**后果严重且静默**（状态倒退 →
假状态 / 图死锁 / 重复烧额度 / 吞掉人工放行），且**当前无任何计数**能告诉我们它多久发生
一次——这正是 Phase 1 要补的。

---

## 4. 决策

1. **立即引入单调 `revision` + 高版本折叠 + 集中 `mutate` 入口（Phase 1）。** 理由：
   廉价、向后兼容、给读侧真实保护、并把「冲突到底多频繁」从猜变成可计数。
2. **对 R1、R2 两处结构已证的路径，预授权 Phase 2 的跨进程 CAS**（不必等遥测）。其余
   读改写者的 CAS 铺开，按 Phase 1 遥测出的真实冲突率排优先级。
3. **不做**：不给 `tasks.jsonl` 引第三方 KV/DB（违反零依赖）；不把它挪到 iCloud（
   `Work.swift:251-254` 已说明常驻进程碰 iCloud 会永久挂起）；不引入跨机分布式锁
   （文件本机私有，没有跨机竞争）。

---

## 5. 分阶段落地建议

### Phase 1 — revision + 高版本折叠 + 集中写入（立即）

- **加字段**：`WorkTask.revision: Int`。**必须**在手写解码器里
  `decodeIfPresent(Int.self, forKey: .revision) ?? 0`（`Work.swift:173-221` 那一段），
  否则旧记录缺键抛 `keyNotFound`、整条静默消失（项目踩过五次的坑）。
- **改折叠**：`all()`（`Work.swift:278`）由「后写覆盖」改为「**高 revision 优先，
  同版本再按文件位置**」。效果：任何**没能推进版本**的过期 append（遗漏自增、旧二进制、
  legacy rev 0 行）在读侧直接失效。迁移安全：现存文件全是 rev 0，首次读全部同版本 →
  退化回今天的行为，无 flag day。
- **集中入口**：新增 `TaskStore.mutate(id:) { task -> task }`：`writeLock` 内重读该 id
  的最新行、应用闭包、`revision = latest.revision + 1`、append。先把**同进程**读改写者
  （`runOneTask` 收尾、reconcile 回写、`markDisposition`、`AskIngest`、卡片 approve）
  迁到它。
- **加遥测**：仿 `skippedLines`（`Work.swift:247`）加一个计数——折叠时若发现某 id 出现
  「较高版本之后又追加了 ≤ 它的版本」，计一次「观测到过期覆盖」。这**就是**判断要不要
  全量 Phase 2 的样本来源。
- **诚实边界**：Phase 1 的高版本折叠**挡不住**两个写入者从同一 base（如都读到 rev 5）
  各自写 rev 6 的「同版本平局丢更新」。那需要 Phase 2 的原子 CAS。这条要在代码注释和
  本文件都写清，别让人误以为 Phase 1 = 已彻底解决。

### Phase 2 — 跨进程 compare-and-append（先 R1/R2，其余按遥测）

- `TaskStore.append` / `mutate` 增加 `expectedRevision` 语义：在
  **`flock(tasks.jsonl)` 独占**的临界区内（`flock` 跨进程有效，POSIX 自带、零依赖），
  读当前 head 版本 → 与 expected 比对 → 不等就抛 `staleRevision` → 相等才写 rev+1 →
  释放锁。读改写调用方在 `staleRevision` 上**重读+重算**，有界重试（如 3 次）。
- **临界区必须短**：绝不在持锁期间跑 `verifyMerge`（320s）。`markDisposition` 现在就是
  「读完立刻 append」（`Review.swift:1157-1183`），临界区天然短，直接套 CAS 即可。
- **`runOneTask` 收尾**（R2）：从「盲写内存快照」改为 `mutate`——重读该行，只覆盖它真正
  拥有的字段（`state/exitCode/endedAt/outputs/changedFiles`），**保留**并发写入的
  `answeredAsk/landedAt/discardedAt`。这是收益最大的单点改动。
- 顺序：先 R1（`markDisposition` + reconcile 回写）、R2（`runOneTask` 收尾），再按
  Phase 1 遥测决定是否覆盖 CLI `work approve`/`asks`、`StuckAsk` 等。

### Phase 3 — 统一 + 压实

- 所有写入统一走 `mutate`/CAS；除「首次创建」外禁止裸 `append`（可加断言/审查闸）。
- 加周期性 compaction：持 `flock` 时把文件重写成「一 id 一行」（临时文件 + rename 原子
  替换；文件本机私有，`rename` 安全，注意别触发 `ICloudWriteGuardTests` 那条本地写规则）。
  压实后可维护内存版本索引，让 CAS 取 head 版本变 O(1)，也解掉 R4。

---

## 6. 验证口径（留给执行 Agent；本复核未跑）

- **基线全绿**：`swift build && swift test`（AGENTS.md 的合并门槛）。
- **本轮修复变异验证复跑**：临时删掉 `VisualQualityGate.swift:137-142` 的「较新票屏障」，
  确认 `testHistoricalRejectionCannotOverwriteActiveOrNewerRemediation` 变红；恢复后转绿。
  给出两次运行日志。
- **Phase 1 新增测试（每条都要变异验证）**：
  - 高版本折叠：同 id 先 append rev 2 再 append rev 1，`all()` 必须返回 rev 2。把折叠改回
    「后写覆盖」→ 测试必须红。
  - 旧记录兼容：喂一行不含 `revision` 的 JSON，解出 `revision == 0` 且不丢记录。删掉
    `decodeIfPresent ?? 0` 的兜底 → 该记录必须消失/解码失败，证明兜底有效。
  - `mutate` 同进程原子性：多线程对同一 id 并发 `mutate`，末态 revision == 调用次数、
    无丢更新（对照现有 `ConcurrencyFixTests.testConcurrentAppendLosesNothing`）。
- **Phase 2**：
  - 跨进程 CAS：起两个进程对同一 id 各 `mutate`，`expectedRevision` 落后者必须收到
    `staleRevision` 并重试成功；关掉 `flock` 临界区 → 出现丢更新，测试红。
  - R2 端到端复现（**先写一个能复现 bug 的红测**，再修）：认领任务为 running →
    模拟并发写 `answeredAsk` → `runOneTask` 收尾 → 断言 `answeredAsk` 未被抹掉。
    没红过的测试不算覆盖（第 0 条）。
- **端到端**：状态倒退修完后，手机 taskboard 与真实 worker 进程一致——按第 0 条，
  「老板在手机上看得见」才算数，需实机截图为证，不能只凭单测。

---

## 7. 待验证 / 我没做的事（诚实清单）

- 未跑 `swift test`、未现场复现 R1/R2；R1/R2 是**读代码得出的结构性结论**，不是回放。
- 未改任何业务代码（本任务只做架构判断）。Flint 视觉实现由 OpenRouter Ox 执行，不介入。
- MiniMax 通过的常规评审不重复；本文件只处理状态并发这一架构议题。
- Phase 1 遥测上线前，「冲突真实频次」仍是未知数——这是刻意的：先装计数器再决定全量
  Phase 2 的力度，避免为极低频路径过度重构，也避免无数据空谈。
