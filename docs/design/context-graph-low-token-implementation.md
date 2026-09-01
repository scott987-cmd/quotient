# Context Graph：低 Token、上下文亲和的任务大脑落地方案

> 状态：技术设计完成，尚未授权实现。等下一个额度周期重置后再开始开发重构。
>
> 决策：不照搬“300 Agent Swarm”，不建设第二套任务系统，也不引入图数据库。
> 在现有事实源之上建立可重建的关系索引和有硬预算的 `Context Pack`；一个深任务
> 仍由一个上下文亲和的 owner 连续完成，其他 Agent 只承担独立、可验收的专业工作。

## 一、结论先行

当前系统已经具备任务图、项目级原生会话、稳定工作区、协作事件、进度里程碑、
重复任务保护、黄金样板门和架构师裁决。真正缺少的不是另一套“多 Agent 框架”，而是：

1. 把这些分散事实按关系索引起来；
2. 每次只给 Agent 当前任务真正需要的上下文；
3. 派发前先判断任务是否已经做过、是否真的适合拆分、是否值得换 owner；
4. 用可核验指标证明上下文机制减少了消耗，而不是用“消息更多、Agent 更多”冒充收益。

第一版采用四个必需组件，并为 MiniMax 增加一个可旁路的智能整理层：

```text
现有事实源
 WorkTask / WorkAttempt / CollaborationEvent / WorkProgress
 ProjectContract / Evidence / Git / GraphSession
                         │
                         ▼
                ContextProjection
           只读、确定性、随时可重建的关系索引
                         │
               ┌─────────┴─────────┐
               │                   ▼
               │       MiniMax Context Curator
               │       异步增量整理、带事实引用
               │                   │
               └─────────┬─────────┘
                         │
              ┌──────────┴──────────┐
              ▼                     ▼
       DispatchPreflight       ContextPackBuilder
    查重、前提、拆分、换人闸     相关性选择、去旧、硬预算
              │                     │
              └──────────┬──────────┘
                         ▼
               一个 owner 的连续执行
                         │
                         ▼
                 ContextTelemetry
        记录注入量、来源、删减项、接力和落地结果
```

`ContextProjection` 是视图，不是真相源；删掉后可以从现有数据重新生成。这样不会出现
“任务状态一份、协作图又一份，两边不一致”的新故障。

MiniMax Curator 也是可选覆盖层。它不可用、额度变化或输出不合格时，系统直接使用
确定性 Projection 和 Pack，不得因此阻塞正常任务。

## 二、现状判断

### 2.1 可以直接复用的能力

| 已有能力 | 现有实现 | 在新方案中的位置 |
|---|---|---|
| 任务与依赖 | `WorkTask`、`TaskGraph` | Task、Graph、Dependency 节点和边 |
| 精确负责人 | `ownerRunnerID`、`ownerPlatform` | `ownedBy` 关系 |
| 原生会话 | `GraphSession` | 同 owner 隐式上下文，不复制进图 |
| 执行事实 | `WorkAttempt` | Attempt、Runner、SessionAction、失败/接力关系 |
| 跨 Agent 事实 | `CollaborationEvent` | Decision、Finding、Question、Handoff、Artifact |
| 长任务进展 | `WorkProgress` | 最新可核验 Checkpoint |
| 产品与验收 | `AGENTS.md`、Project/Quality Contract | Constraint、Criterion、Route、Golden Sample |
| 实际产物 | Git、branch、commit、outputs、evidence | Artifact、Commit、Evidence |
| 查重 | `DuplicateGuard` | 派发前 WorkFingerprint 的一个输入 |
| 质量闭环 | MiniMax + `ArchitectReview` | 独立验收和负面争议裁决 |

### 2.2 当前浪费发生在哪里

#### A. 上下文是叠加，不是选择

当前派发会依次拼入 RepoMap、AGENTS/QUALITY、Evidence 条款、进度条款、任务图 briefing
和最多 18 条协作事件。各组件单独都有合理上限，但没有一个总预算，也没有统一优先级。

按代码上限估算：

- RepoMap：最多 30,000 字符；
- AGENTS：最多 8,000 字符；
- QUALITY：最多 8,000 字符；
- 协作摘要：最多约 36,000 字符，另有格式开销；
- 再加任务图、固定契约和任务正文。

理论注入上界可超过 80,000 字符。这不是实测平均值，但足以说明“每个模块各自截断”
不能保证整体经济性。

#### B. 相关性主要靠时间，不靠任务关系

协作账现在取最近 18 条。最近不等于相关：一条尚未解决的路线否决可能比十条新 checkpoint
重要；旧决定如果已经被新决定替代，仍可能进入提示词。

#### C. RepoMap 对能读本地文件的 Agent 过重

代码 Agent 通常可以自己打开文件。完整仓库地图适合首次认路或文本型 Reviewer，
不应该在每个普通任务里重复注入。当前 trivial 已跳过地图，但 standard/complex 仍可能
反复携带同一份大地图。

#### D. 查重只覆盖“提示词像不像”

`DuplicateGuard` 已能用路径、符号和文本相似度发现一部分重复任务，但还不知道：

- 同一个缺陷是否已经由另一条任务落地主线；
- 两条派生整改是否来自同一份否决；
- 任务描述不同但目标 criterion / deliverable 相同；
- 审查开始前分支是否已经落地或消失。

#### E. 拆分和接力的收益没有先算成本

任务图能表达依赖，但“能拆”不等于“值得拆”。同一个深任务被多个 Agent 接力时，
会重复理解仓库、目标、失败尝试和局部设计；同仓库共享 worktree 又不能安全并行写。

#### F. 用量记录与任务结果还没有可靠归因

系统能采集平台 token，但不同平台日志粒度不同，有些只能得到会话总量或时间桶。
如果直接把某段时间的全部 token 算给一个任务，会把人工调用或并发任务算进去，产生假精确。

## 三、目标与非目标

### 3.1 目标

1. 深任务默认由同一个 owner、同一个稳定工作区、同一项目会话持续完成。
2. 每次派发的系统注入上下文有统一硬预算，并能解释每一段为什么被选中。
3. 派发之前消灭已完成、已在做、已失效审查和同源派生任务的重复执行。
4. 只有真正独立、可合并、可验收的工作才并行。
5. 额度即将耗尽时，在中断之前形成可恢复交接；额度充足时不为了均摊而换人。
6. 所有收益由落地率、重复率、接力恢复速度和上下文开销证明。

### 3.2 非目标

- 不保存模型隐藏推理或完整聊天记录；
- 不用另一个 LLM 每次总结上下文；
- 不引入 Neo4j、向量数据库、embedding 服务或第三方依赖；
- 不建立第二套任务状态机；
- 不让多个 Agent 同时写一个仓库或 worktree；
- 不以“Agent 数量、消息数量、图节点数量”作为成功指标；
- 不要求所有 Runner 支持 MCP/A2A 才能工作。

MiniMax 可以在后台批量整理新增事实，但不能成为每次派发前必须同步调用的依赖。

## 四、不可破坏的设计原则

### 4.1 事实只存一次

| 事实 | 唯一真相源 |
|---|---|
| 任务状态、owner、依赖 | `TaskStore` / `WorkTask` |
| 每次执行与接力 | `WorkAttemptStore` |
| Agent 显式决定、发现、问题、交接 | `CollaborationStore` |
| 最新可核验进度 | `WorkProgressStore` |
| 代码和产物 | Git / 工作区文件 |
| 产品目标、验收、路线 | Project/Quality Contract |
| 原生会话映射 | `GraphSession` |

Context Graph 只保存或缓存“它们之间怎么关联”，不能复制一份可独立修改的状态。

### 4.2 确定性优先

第一版所有节点、边、相关性和删减规则都由字段、路径、ID、时间和状态确定性生成。
不调用模型构图，不做语义 embedding，不让 Reviewer 先花一轮额度决定“该给执行者看什么”。

### 4.3 一个深任务只有一个实现 owner

同一项目可以同时存在不同能力泳道，但一个具体交付物只能有一个写入 owner。
测试和评审可以独立执行；两个编码 Agent 不对同一个交付物竞稿。

### 4.4 先引用，必要时才复制正文

能读本地文件的 Runner 收到路径、符号和短摘录；文本型 Runner 才需要更多内联内容。
如果关键材料无法在预算内提供、Runner 又读不了文件，该 Runner 判为能力不匹配，
不能靠无限放大提示词硬塞。

### 4.5 不假装精确

Token 归因必须带置信度。拿不到任务级真实用量时只报告 Context Pack 字符量、调用次数和
时间窗口估算，不把平台总量伪装成任务精确消耗。

## 五、Context Graph 数据模型

### 5.1 节点

第一版不新增持久节点表，只在内存索引中投影以下类型：

```text
Project       仓库/产品
Task          WorkTask
Graph         graphID
Attempt       WorkAttempt.attemptID
Runner        runnerID
Session       machine × runner × workspace × lane
Event         CollaborationEvent
Checkpoint    WorkProgress
Decision      kind == decision 的 Event
Finding       kind == finding 的 Event
Question      question/answer/ack 线程
Artifact      outputs / artifacts / evidence 中的路径
Commit        branch / commitSHA / Git HEAD
Criterion     Project Contract 条款 ID
Deliverable   production.deliverableKind / golden sample
```

### 5.2 边

```text
Task       --belongsTo--> Project / Graph / Deliverable
Task       --dependsOn--> Task
Task       --ownedBy----> Runner
Attempt    --executes----> Task
Attempt    --usesSession-> Session
Event      --about-------> Project / Task / Graph
Event      --sentBy------> Runner
Event      --addressedTo-> Runner
Answer/Ack --resolves----> Event
Event      --produced----> Artifact / Commit
Checkpoint --proves------> Task / Artifact
Criterion  --verifiedBy--> Evidence / Review
Handoff    --transfers---> Runner / Artifact / Commit
```

这些边都能从现有字段生成，不需要模型猜。

### 5.3 仅在真实需要时增加的兼容字段

第二阶段可给 `CollaborationEvent` 增加两个可选字段，旧记录和旧机器继续兼容：

```swift
topicKey: String?          // 例如 route:character、criterion:EXP-03、file:Foo.swift
supersedesEventID: String? // 明确说明新决定替代哪条旧决定
```

用途只有两个：

1. 相关任务优先取同 topic 的事实；
2. 已被替代的旧决定不再进入 Context Pack。

没有真实事件证明需要前，不增加通用 `metadata`、任意属性或图查询语言。

### 5.4 索引实现

新增 `ContextProjection`：

- 读取现有 Store 和 Git 元数据；
- 用字典建立 `byTaskID`、`byGraphID`、`byRunnerID`、`byTopicKey`、
  `byArtifactPath`、`resolvedEventIDs`；
- 按源文件 size + mtime 做进程内缓存；发生变化时增量重读或重建；
- 索引缓存不进入 iCloud，不跨机器同步，删除后无损重建；
- 坏行沿用现有“跳过但诊断”的策略，不能让一个坏事件拖垮全图。

第一版不需要数据库。现有数据量用内存字典足够；等真实重建时间或内存超过阈值再决定是否归档。

## 六、Context Pack：有硬预算的增量上下文

### 6.1 输入

`ContextPackBuilder` 接收：

```text
task
selectedRunner + runnerCapabilities
currentWorkspace + currentHead
project/graph/production scope
ContextProjection
```

### 6.2 优先级

| 优先级 | 内容 | 是否允许删 |
|---|---|---|
| P0 | 当前任务、用户最新答复、硬约束、适用验收条款 | 不允许 |
| P1 | 未解决问题、当前路线决定、最新否决、直接依赖产物 | 不允许静默删 |
| P2 | owner 的最近交接、触碰文件、失败路径、相关 commit | 超限时改为引用 |
| P3 | 最近有效 checkpoint、相邻图节点、相关历史结果 | 可删旧项 |
| P4 | 仓库地图、一般项目广播、已完成的远端历史 | 最先删 |

同优先级内按以下顺序排序：明确发给当前 Runner、同 task、直接依赖、同 graph、同
deliverable/topic、同 project。时间只作为最后的排序条件。

### 6.3 默认预算

任务正文和用户明确提供的材料不截断；系统自动注入部分采用总预算：

| 部分 | 默认字符预算 |
|---|---:|
| 固定执行/进度/提问契约 | 2,000 |
| 产品硬约束与当前验收条款 | 5,000 |
| 决定、否决、未解决问题 | 4,000 |
| 依赖、交接、产物和 commit | 4,000 |
| 相关仓库切片 | 6,000 |
| 其他 checkpoint / 图位置 | 3,000 |
| **系统注入总上限** | **24,000** |

24,000 字符只是可解释的第一版安全线，不宣称等于固定 token 数。中文、英文和代码的分词比例
不同；系统同时记录字符数，Runner 能报告 tokenizer 时再记录真实 token。

硬规则：

- P0/P1 超预算时不静默截掉语义；能读文件的 Runner 改为路径引用；
- 文本型 Runner 若关键材料仍放不下，派发前返回 `insufficientContextCapability`；
- 每个 Pack 都生成 manifest，列出包含、折叠、引用和丢弃的事实 ID；
- 不允许各模块在 Pack 完成后继续向 prompt 尾部自行追加无预算内容。

### 6.4 RepoMap 改造

完整 RepoMap 保留为按需工具，不再默认全量注入。普通代码任务只注入 `RelevantRepoSlice`：

1. 提示词明确出现的文件和符号；
2. 直接依赖任务产出的文件；
3. 当前 owner 最近修改的相关文件；
4. Project Contract 指向的文件；
5. 上述文件的父目录和主要声明。

首次进入完全陌生仓库且没有任何相关锚点时，才退回精简顶层地图。Agent 可以自己读文件，
不重复内联实现正文。

### 6.5 协作事件改造

不再简单取最近 18 条，改为：

1. 未解决且明确发给当前 Runner；
2. 当前 task/graph 的最新有效决定和否决；
3. 当前 owner 的最新 handoff；
4. 直接依赖的 result/artifact；
5. 最新一个有新证据的 checkpoint；
6. 剩余预算才放项目广播。

已被 answer/ack/result 关闭的问题不占核心预算；被 supersede 的决定只保留最新一条，并注明替代关系。

### 6.6 角色化 Pack

| 角色 | 必需上下文 | 不应携带 |
|---|---|---|
| 实现 owner | 任务、硬约束、当前决定、相关代码、失败路径 | 全部评审历史、无关项目广播 |
| MiniMax 测试 | 验收条款、运行命令、目标分支、失败判据 | 长期实现会话、无关设计讨论 |
| MiniMax Review | diff、适用 criterion、证据、已知风险 | 全仓库地图、其他任务 checkpoint |
| 架构师 | 争议点、原始证据、MiniMax 结论、硬约束 | 完整执行流水账 |
| 接力 Agent | 当前目标、WIP、已排除路径、最新证据、下一动作 | 从任务创建至今的全部聊天 |

### 6.7 MiniMax Context Curator

MiniMax 富余额度用于提高 Context Graph 的相关性，不用于替代确定性事实源。它处理的是
“这些事实之间可能是什么关系”，不是“事实本身是什么”。

#### 运行方式

- 后台异步执行，不进入每次派发的同步关键路径；
- 只读取上次 cursor 之后的新事件和受影响邻域，不重读全部项目历史；
- 输入集合按事件 ID + 内容哈希缓存，相同输入不重复调用；
- 测试和正式 Review 优先，只有富余额度才运行历史整理；
- Curator 失败、超时或额度不足时静默降级到确定性 Pack，但留下诊断事实。

触发条件满足任一即可：

1. 累积达到一批尚未整理的新事件；
2. 准备发生真实 owner 交接；
3. 新的深任务准备首次启动；
4. 产品决定、验收标准或生产路线发生变化；
5. MiniMax 明确处于富余额度且没有更高优先级测试/Review。

不按单条事件即时调用，避免“写一条日志就花一轮模型调用”。批量阈值和最小间隔在 shadow
数据出来后确定，不在设计阶段拍脑袋写死。

#### 允许产出的建议

```text
relevantTo       某事实与 task/criterion/deliverable 相关
supersedes       新决定建议替代旧决定
duplicates       两条任务/发现可能是同一件事
contradicts      两条有效事实可能冲突
handoffGap       交接缺目标、WIP、证据、失败路径或 next step
summary          对一组已引用事实的有界摘要
```

每条建议必须输出结构化对象：

```json
{
  "kind": "supersedes",
  "subjectID": "decision-17",
  "objectID": "decision-09",
  "taskID": "abc123",
  "reason": "新的角色生产路线明确替代程序化灰盒路线",
  "confidence": 0.94,
  "evidenceEventIDs": ["decision-17", "decision-09"]
}
```

#### 接受规则

- subject/object/evidence ID 必须存在且属于同一项目；
- 建议不能跨越 Task/Graph/Project 的可见性边界；
- 没有事实引用、引用不存在或只给自由文本的输出直接丢弃；
- `summary` 只能压缩被引用内容，不能添加原文没有的新要求；
- Curator 不能删除事件、修改任务状态、转移 owner、放行质量闸或屏蔽 P0/P1；
- `duplicates` 只进入 `DispatchPreflight` 的辅助信号，不能单独取消任务；
- `supersedes/contradicts` 在 shadow 阶段只展示建议；稳定后也必须通过确定性字段校验，
  涉及产品硬约束时交给架构师确认。

Curator 输出保存在独立、可删除的 derived overlay 中，并记录 input hash、模型、生成时间和
采用状态。原始 CollaborationEvent 永不被它改写。

## 七、派发前闸门：先决定是否值得调用模型

新增 `DispatchPreflight`，在选择 Runner 和拼 prompt 之前执行，全部是本地确定性检查。

### 7.1 WorkFingerprint

任务指纹由以下信息组成：

```text
normalized repo
task kind / capability lane
明确文件与符号
criterion IDs
deliverable kind + golden sample / fan-out source
派生源事件或 review ID
```

匹配顺序：

1. 同一派生源 + 同一目标：直接幂等，不新增任务；
2. 同指纹任务正在 queued/running/blocked：链接现有任务，不竞跑；
3. 同指纹任务已 landed，且目标文件/criterion 未再次变化：判为已经完成；
4. 只有自由文本时才退回现有 `DuplicateGuard`；
5. 被明确 discard 且原因仍适用时允许重新做，但保留失败路线提醒。

### 7.2 Premise Check

调用模型前检查：

- 目标分支和文件是否还存在；
- review 对象是否已落地、被丢弃或无 diff；
- 提到的缺陷在 main 上是否仍可复现；
- fan-out 的黄金样板是否真的已经通过；
- 上游 artifact 是否存在且版本匹配。

检查失败就终止或改写为诊断任务，不让 Agent 花一轮额度后才说“无物可审”。

### 7.3 并行资格

默认 `executionShape = deepSequential`。只有同时满足以下条件才允许拆分或并行：

1. 子任务有不同、明确的输出；
2. 不会同时写同一 worktree；
3. 子任务之间不依赖未落盘的判断；
4. 每个子任务有独立验收标准；
5. 已指定唯一 synthesis owner；
6. 合并成本明显低于单 owner 连续完成成本。

适合并行：100 个独立来源检索、不同设备只读测试、彼此独立的素材检查。

不适合并行：角色品质连续迭代、同一玩法系统重构、一个架构方案的多文件实现、
同一缺陷由多个 Agent 竞稿。

### 7.4 同项目并发上限

- 写入泳道：最多 1 个 active owner；
- 只读测试/Review：达到明确 checkpoint 后可各 1 个；
- 审查不能追着每个中间提交跑，只对可验收 checkpoint 或候选落地分支运行；
- synthesis 由原 owner 或固定架构泳道完成，不能临时再创建一个陌生 Agent。

## 八、额度耗尽前的交接

### 8.1 不因为额度均摊主动换人

只允许以下原因换 owner：

- 原 Runner 硬不可用或额度确定耗尽；
- 能力不匹配；
- 人工明确停用；
- 同 owner 在保留会话后重复出现同根因失败，且架构闸批准换路线。

“另一家额度快过期”只影响新任务，不接管已经形成上下文的深任务。

### 8.2 提前形成 Handoff Readiness，而不是提前切换

额度进入 `atRisk` 时：

1. 仍让原 owner 继续；
2. 在下一个真实 checkpoint 自动固化 WIP commit、改动文件、测试/证据和 next step；
3. 生成 Context Pack manifest，但不调用接班 Agent；
4. 只有硬耗尽或预计剩余额度不足以完成下一阶段时才正式接力。

这相当于准备好救生艇，但不为了“可能用得上”先启动第二个模型。

### 8.3 交接包

交接包由系统从事实源组合，不再让旧 Agent 写长篇总结：

```text
目标与当前完成定义
owner、workspace、branch、HEAD、session 状态
已完成 checkpoint 和证据
当前 WIP 与改动文件
已经排除的失败路径
尚未解决的问题/否决
下一步唯一推荐动作
适用验收条款
Context Pack manifest
```

旧 Agent 只需在确有新判断时补一条结构化 handoff 事件。

### 8.4 额度预测的可信度

交接触发使用三级置信度：

- `official`：平台直接给百分比/重置时间；
- `learned`：QuotaCeiling 有足够历史样本；
- `unknown`：只有粗略窗口或无法归因。

只有 official/learned 能自动进入 handoff readiness；unknown 只提示，不自动换人。

## 九、Token 与重复工作度量

### 9.1 ContextPackManifest

每次派发追加一条轻量记录：

```text
taskID / attemptID / runnerID
packVersion
totalCharacters
charactersBySection
includedFactIDs
referencedFactIDs
droppedFactIDs + reason
fullRepoMapUsed
sessionAction
createdAt
```

它不保存重复正文，只存 ID 和计数。

### 9.2 用量归因

可选的任务用量记录必须标记：

```text
exact           Runner/会话直接报告任务级 token
isolatedWindow  时间窗内只有这一条 worker 调用，可做估算
unknown         有人工或并发调用，不能归因
```

报表只汇总 exact；isolatedWindow 单列；unknown 不强行分摊。

### 9.3 核心指标

| 指标 | 定义 | 第一版目标 |
|---|---|---:|
| Pack 开销 P95 | 系统自动注入字符数 | ≤ 24,000 |
| Full RepoMap 使用率 | 普通实现任务使用完整地图的比例 | < 10% |
| 活跃任务指纹重复数 | 相同 WorkFingerprint 同时执行 | 0 |
| 过期 Review 调用数 | 无分支/无 diff/已落地后仍调用模型 | 0 |
| 无理由 owner 转移 | 非硬故障/能力/人工原因的交接 | 0 |
| 接力首个有效进展 | 接班到新 commit/新证据的时间 | 先建基线，再要求下降 |
| 落地率 | done 中最终 landed 的比例 | 不低于改造前基线 |
| Context miss | Agent 因缺关键前情重复排查或走旧路线 | 持续下降 |
| Curator 缓存命中 | 相同输入没有重复调用 MiniMax | 100% |
| Curator 有据率 | 建议引用的事实均真实存在且同项目 | 100% |
| Curator 关键路径阻塞 | 因 MiniMax 故障导致任务不能派发 | 0 |

不能先拍一个“节省 50% token”的数字。上线前没有可靠任务级基线，先用一周期 shadow 数据建立基线，
再设节省目标。

## 十、移动端与电脑端可见性

服务端从 ContextProjection 生成只读投影，不把图数据库或内部日志直接下发：

- 当前 owner、Runner、会话是否恢复；
- 当前阶段和最近一份可核验 checkpoint；
- 直接依赖与阻塞原因；
- 最近有效决定/否决；
- 交接 readiness 与预计原因；
- Pack 大小、是否删减、缺失关键材料；
- 哪些 Agent 在实现、测试、Review，彼此是什么关系。

第一版优先用动态页面，无需为了增加一个图页面立刻发新版客户端。iPad 可以增加关系视图，
iPhone 默认展示紧凑时间线；二者消费同一份服务端投影。

## 十一、开发期间怎样避免再次浪费额度

这次重构本身也遵守上下文亲和：

| 角色 | 职责 | 调用策略 |
|---|---|---|
| Codex 架构师 | 维护本设计、审查边界和争议 | 不参与普通编码，不重复全量 Review |
| Claude Opus 4.8 | 唯一实现 owner | 一个稳定项目会话，按阶段连续开发 |
| MiniMax | 测试、首轮 Review、异步 Context Curator | 测试/Review 优先；Curator 批量增量运行 |
| GLM/OpenCode | Claude 硬不可用时接力 | 只有交接包就绪后启用，不预热竞跑 |
| Kimi | 保留 Flint 游戏上下文 | 不为本基础设施重构打断游戏项目会话 |

开发任务不拆成多个并行编码 Agent。阶段内部由 Claude 完成实现和必要测试；MiniMax 只检查候选结果；
MiniMax 通过后不再调用架构师，负面主观结论才按现有规则升级 Codex。

Curator 属于后台辅助泳道，与正式质量 Review 分开记账；它的整理建议不是验收结论，不能触发
“负面 Review → 架构师”链路。只有建议暴露出真实硬约束冲突时，才生成一条明确的架构问题。

## 十二、分阶段落地

### 阶段 0：基线与 shadow mode

范围：只新增确定性投影、Pack 生成和 manifest，不改变实际 prompt 和调度结果。

验证：

- 用历史任务回放 Pack 选择；
- 比较当前注入字符量与新 Pack；
- 检查关键决定、未解决问题、直接依赖、最新否决是否遗漏；
- 建立一周期 P50/P95、Full RepoMap 使用率和重复任务基线。

停止条件：P0/P1 漏项或项目隔离错误，不能进入下一阶段。

### 阶段 1：统一 Context Pack

范围：把 RepoMap、ProductBrief、TaskGraph briefing、Collaboration briefing 和固定条款统一交给
`ContextPackBuilder`，移除后续散落追加入口。

先切换一个低风险仓库，确认后再扩到 Flint 和 LLMQuotaBar。

验证：

- 系统注入绝不超过总预算；
- 能读文件的 Runner 得到引用和相关切片；
- 文本 Runner 材料不足时在派发前被拒，不生成“材料不足”报告；
- 原生项目会话恢复行为不变。

### 阶段 1.5：MiniMax Curator shadow

范围：MiniMax 只对增量事实生成 relation/summary 建议，保存 derived overlay，但真实 Pack 暂不采用。

验证：

- 相同 input hash 不产生第二次调用；
- 所有建议都有存在且同项目的事实引用；
- 与确定性关系冲突的建议被拒绝；
- MiniMax 关闭、失败或额度不足时，派发行为完全不变；
- 对历史事故回放，能识别旧决定、重复任务和交接缺口，同时不制造跨项目关系。

只有有据率和稳定性达到要求，才允许在低风险 P2/P3 排序中采用；P0/P1、owner、任务状态和
质量闸永远不由 Curator 控制。

### 阶段 2：派发前查重与失效检查

范围：增加 WorkFingerprint、派生幂等键和 stale review/premise check，并统一收口到 `TaskIntake`。

验证：

- 同一否决不能生成两条同目标整改；
- 已落地分支的 Review 不调用模型；
- main 上已经存在的实现不再重做；
- discard 后允许按新路线重做。

### 阶段 3：拆分资格和 synthesis owner

范围：默认深任务不拆；只有通过并行资格的工作才进入任务图并发候选。保持同仓库单写 owner。

验证：

- Flint 角色连续迭代不会被拆给多个编码 Agent；
- 多设备只读测试可以并行；
- 任一并行任务都能指出独立输出、验收标准和 synthesis owner。

### 阶段 4：额度感知交接

范围：结合官方额度和 QuotaCeiling 学习结果生成 handoff readiness；硬耗尽才正式换 owner。

验证：

- 额度 atRisk 只固化 checkpoint，不启动第二 Agent；
- 硬耗尽后接班拿到同一 WIP、决定、证据和 next step；
- unknown 预测不会自动转移 owner；
- 接力成功/失败进入 WorkAttemptMetrics。

### 阶段 5：移动端关系视图

只在前四阶段的数据真实可用后做。先动态页面，真实使用证明 iPad 图视图有价值后再考虑客户端原生化。

## 十三、代码落点

预计新增：

```text
Sources/LLMQuotaCore/ContextProjection.swift
Sources/LLMQuotaCore/ContextPack.swift
Sources/LLMQuotaCore/ContextTelemetry.swift
Sources/LLMQuotaCore/ContextCurator.swift
Sources/LLMQuotaCore/DispatchPreflight.swift
Tests/LLMQuotaCoreTests/ContextProjectionTests.swift
Tests/LLMQuotaCoreTests/ContextPackTests.swift
Tests/LLMQuotaCoreTests/ContextCuratorTests.swift
Tests/LLMQuotaCoreTests/DispatchPreflightTests.swift
```

预计修改：

```text
Sources/llmq/main.swift                 统一 prompt 构建入口
Sources/LLMQuotaCore/Collaboration.swift 可选 topic/supersede 与索引接入
Sources/LLMQuotaCore/RepoMap.swift       增加 RelevantRepoSlice
Sources/LLMQuotaCore/TaskIntake.swift    所有入口统一走 preflight
Sources/LLMQuotaCore/TaskDecomposer.swift 增加并行资格，不因“步骤多”自动拆
Sources/LLMQuotaCore/WorkAttempt.swift   关联 Pack manifest / 用量置信度
Sources/LLMQuotaCore/ViewFeed.swift      输出移动端只读投影
```

不修改 `WorkTask` 状态机，不替换 `TaskGraph`，不改变 `GraphSession` 的项目级亲和主键。

## 十四、测试与变异验证

### 14.1 必测场景

1. 两个项目同名 task/文件，事实不能串线；
2. 同 task 旧决定被新决定替代，Pack 只带最新有效决定；
3. 未解决的定向问题比更新但无关的 checkpoint 优先；
4. Pack 超限时先删 P4/P3，P0/P1 仍完整或明确拒绝派发；
5. 本地可读 Runner 收引用，文本型 Runner 缺材料时提前失败；
6. 相同 source review + target 只生成一个整改任务；
7. Review 分支已落地/消失时不调用模型；
8. atRisk 只进入 readiness，exhausted 才接力；
9. 接力保持 workspace/WIP，不清理原会话映射；
10. 旧 JSON 缺新增字段仍能完整读取。
11. Curator 无引用、跨项目引用和不存在的引用全部被拒绝；
12. Curator 失败时确定性 Pack 与派发结果不变；
13. 相同 input hash 重复触发时不再次调用 MiniMax。

### 14.2 真实事故回放

- Greed 已完成步骤被误当未做，导致重复实现；
- 多份过期 Review 对空 diff 白跑；
- Kimi 长任务超时后 fresh 重跑；
- Flint 多人物/僵尸在错误路线下批量扩张；
- MiniMax 因材料不足生成无效报告；
- 同一 WasteMeter 入口被两个任务重复实现。

### 14.3 变异要求

- 去掉项目隔离，测试必须红；
- 把优先级改成纯时间排序，未解决问题测试必须红；
- 允许 Pack 静默丢 P0，测试必须红；
- 删除派生幂等键，重复整改测试必须红；
- 把 atRisk 当 exhausted，owner 不当转移测试必须红；
- 恢复全量 RepoMap 默认注入，预算测试必须红。
- 允许 Curator 无引用建议进入 Pack，测试必须红；
- 把 Curator 放进同步派发必经路径，降级测试必须红。

## 十五、发布与回滚

1. shadow mode 只写 manifest，可通过开关完全关闭；
2. ContextProjection/Pack 都是派生数据，删除缓存即可回滚；
3. 新字段全部 `decodeIfPresent`；
4. 两台机器先滚动升级，旧版继续读取原任务/协作事实；
5. prompt 切换按仓库白名单启用，不全局一次性切；
6. 如果落地率下降、Context miss 上升或 P0/P1 漏项，立即退回旧 prompt builder；
7. 服务端稳定并完成双机同 SHA 验证后，再决定是否需要移动端发版。

## 十六、实施前锁定的决策

以下事项不再留给实现 Agent 临场发挥：

1. Context Graph 是确定性投影视图，不是新的真相源；
2. 第一版没有图数据库、向量数据库、embedding 和 LLM 摘要器；
3. 系统注入默认硬上限 24,000 字符；
4. 同项目同交付物只有一个写入 owner；
5. 额度 atRisk 只准备交接，不启动接班 Agent；
6. MiniMax 通过即结束，负面主观结论才升级架构师；
7. 实现由一个 Claude 项目会话连续完成，GLM 只做硬故障接力；
8. Kimi 保留 Flint 项目上下文，不参与本轮基础设施重构；
9. 先 shadow、再单仓、再扩面，不允许一次性全局替换；
10. 没有可靠归因就不宣称节省了具体 token 数。
11. MiniMax Curator 是异步、增量、可旁路的智能覆盖层，不是真相源；
12. Curator 的相同输入必须缓存，正式测试和 Review 优先于后台整理。

## 十七、下一周期启动清单

额度重置后只创建一个主实现任务，按以下顺序推进：

1. Claude 读取本设计和相关现有模块，建立阶段 0 分支与稳定会话；
2. 实现 `ContextProjection`、`ContextPackBuilder`、manifest 和历史回放；
3. MiniMax 在阶段 0 checkpoint 跑测试并审查漏项，不启动第二编码 Agent；
4. 用一个完整额度周期观察 shadow 数据；
5. 数据证明 Pack 更小且不漏 P0/P1 后，再批准阶段 1；
6. Context Pack 稳定后启动 MiniMax Curator shadow，不让其影响真实派发；
7. 每阶段单独提交、验证、变异、双机发布，禁止把所有阶段打成一个大任务；
8. 后续阶段的继续条件由指标决定，不因“方案里写了”自动全部实施。

一句话概括：

> **让现有事实形成关系，让关系决定当前需要哪些上下文，让硬预算阻止提示词膨胀；
> 让一个 owner 保持深度，让其他 Agent 只在独立且可验收时贡献能力。**
