# 设计：上下文连续性优先的多 Agent 调度

> 状态：修订提案；已综合 Codex 与 Claude 的交叉 review，尚未授权实现或发布。
>
> 决策摘要：**额度决定新任务第一次交给谁；任务一旦形成有效上下文，默认由同一 Runner 持续负责。**
> 多 Agent 的并行度来自不同仓库的独立任务和专业能力分工，不来自同一任务轮流换人。

## 一、问题与边界

当前调度把两件不同的事放在同一套候选遍历里：

1. **首次分配**：谁最适合从零开始。
2. **已开工任务恢复**：谁拥有这条任务已经形成的上下文。

首次分配应综合能力、风险、额度、人工留白和历史成绩；任务恢复首先应保护上下文。
换平台即使保留 worktree、WIP commit 和文件清单，仍会丢掉：

- 为什么选择当前方案；
- 已读过和已排除的代码路径；
- 失败尝试及其原因；
- 原生会话里的任务理解和未落盘假设。

另一方面，“同平台”也不等于“上下文连续”：部分 Runner 根本不支持原生 session，
普通任务当前还按“仓库 × 平台”共用会话，既可能假恢复，也可能把不相关任务串在一起。

### 当前实现中已经确认的事实

- 仓库粘性只是软加分，无法形成负责人约束。
- `timedOut` 和 `platformUnavailable` 会继续遍历其他平台。
- 只有 Claude、Qwen、ZCode 有 session 命令分支；其他 Runner 会忽略传入的 session。
- 主循环未判断 Runner 能力就打印“接上会话”。
- 普通任务的 session key 是“仓库 × 平台”，不含 task ID。
- 普通任务 session 失败时，当前删除路径错误地调用 graph key，可能留下无效映射。
- `triedPlatforms` 只表示“试过谁”，不能表达负责人，也不能还原每次尝试的全过程。

## 二、目标

1. 普通任务从有效开工到完成，默认由同一 Runner 闭环。
2. worker 重启、进程超时和 session 失效时，优先恢复原负责人和原工作区。
3. 任务图按能力泳道保持负责人；只有能力边界或硬资格边界才换专业 Runner。
4. 日志、看板和指标只报告真实可证明的行为。
5. 临期额度通过新任务初选和独立任务并行消耗，不通过接管已开工任务消耗。
6. 保留仓库级写入互斥、风险闸、WIP、人工使用留白和现有任务状态机。

## 三、非目标

- 本轮不做跨机自动调度；产物回传和跨机 session 均未解决。
- 不做同仓库文件级并行写入，也不允许同一 worktree 并行执行。
- 不重写额度引擎或任务状态枚举。
- 不假设所有 CLI 支持原生 session。
- 不用一段无限增长的原生聊天会话代替 `AGENTS.md`、RepoMap、状态文档和磁盘产物。
- 不承诺“所有订阅始终繁忙”；只在有真实独立任务时提高利用率。

## 四、核心模型

### 4.1 负责人精确到 Runner

```text
TaskOwner = ownerPlatform + ownerRunnerID
```

本轮任务库是本机私有的，因此不新增 `ownerMachineID`。如果未来恢复跨机调度，机器身份必须进入
owner 和 session key，不能默认不同机器共享本地 CLI 会话。

`runnerID` 是稳定代码常量，例如：

```text
claude.code
qwen.code
minimax.media
minimax.review
```

展示名称可以变化，`runnerID` 不随 UI 名称变化。未知 ID 的恢复规则是：

1. 先查显式迁移别名；
2. 再按 platform 和任务能力筛选；
3. 只有唯一匹配时才能恢复；
4. 多个或零个匹配时阻塞并报告，禁止猜测。

### 4.2 “开工”与“形成上下文”

仅仅完成首次排序，不算形成上下文。以下任一事实出现后，任务进入 owner 连续性约束：

- Runner 子进程成功启动；
- worktree 相对开工前 HEAD 有修改或提交；
- 原生 session 已创建或尝试恢复；
- Runner 已产生可用分析、问题或验证结果。

派发前发现能力不匹配、Runner 未安装或工作区无法创建时，可以重新选人；这属于首次分配失败，
不是上下文交接。形成上下文之后更换 Runner 才计为 handoff。

### 4.3 额度只参与首次分配

- 新任务：按硬能力、风险、Runner 可用性过滤后，再按额度、人工留白、历史成绩排序。
- 临期套餐：可以在首次排序中获得有界加分，也可以由 IdleFiller 创建真实独立任务。
- 已开工任务：剩余额度排序不能改变 owner。
- owner 额度暂时耗尽且有恢复时间：保留任务、工作区和 session，等待恢复。
- 用户明确要求换人或停用 Runner：按人工配置规则处理。

**烧额度不靠同一任务轮流接管，而靠把新的独立任务优先交给临期平台。**

### 4.4 仓库租约

仓库租约只在任务真正进入 `running` 后持有。owner 冷却、静音或等待人工处理时，任务保持
`queued`/`blocked`，不得提前占租约。

当前 `RepoLease` 本来就只把 `running` 任务视为 holder，因此不新增“显式释放租约”机制；
只需要保证未来 owner 检查发生在写入 `running` 之前，并用测试固定该顺序。

## 五、真实会话模型

### 5.1 Runner 必须声明能力

```text
SessionSupport = none | projectLatest | stableID | reportedID
```

- `none`：不创建 session 映射，不打印恢复成功。
- `stableID`：Claude 一类，能显式创建或恢复指定 ID。
- `projectLatest`：Qwen 一类，只能恢复当前项目目录最近一次会话。
- `reportedID`：ZCode 一类，首次只能 fresh；必须从 CLI 的真实输出发现 ID，之后才能恢复。调度器不得生成一个 CLI 从未创建过的随机 ID。

`projectLatest` 不是 `stableID` 的弱版本，两者语义必须保留。只有同时满足下面条件才允许使用：

1. 工作区有明确的 task/graph affinity 标记；
2. 当前 affinity 与待恢复任务一致；
3. 同一工作区不存在并发执行；
4. 没有其他任务在该目录上覆盖“最近会话”。

无法证明时降级为 fresh。不同仓库的独占工作区可以并发；禁止的是同一 cwd 并发，
不是笼统禁止所有 `projectLatest` Runner 并发。

### 5.2 会话作用域

执行会话必须跟随任务上下文，而不是整个仓库：

```text
普通任务：taskID + runnerID + machineID
任务图：graphID + capabilityLane + runnerID + machineID
```

`machineID` 存在 session key 中，因为原生 CLI 会话是机器本地资源；它不需要进入本轮 WorkTask owner 字段。

仓库级长期知识继续由 `AGENTS.md`、RepoMap、ProductBrief、STATUS/WIP 等磁盘事实承载。
原生会话只保存当前任务或当前图能力泳道的短中期执行上下文。

### 5.3 映射生命周期

- create 前可以先保存精确 key，避免进程被杀后丢失刚创建的 session ID。
- 如果子进程根本没有成功启动，删除这个精确 key。
- 任务实现失败、验证失败或超时，**不等于 session 损坏**，不能因此删除 session。
- 只有 CLI 明确报告 session 不存在、已损坏、冲突或无法恢复时，才删除精确 key。
- 删除 API 接收完整 `SessionKey`，禁止用 `graphID == nil` 之类的重载猜该删哪个命名空间。
- session 失效后仍由原 owner 使用 fresh session 和原 worktree 继续。

### 5.4 日志措辞

日志区分以下事实：

```text
Runner 不支持原生会话；沿用工作区和磁盘交接信息
已请求恢复项目最近会话（CLI 不提供显式 ID）
已请求恢复会话 <id>
CLI 拒绝该会话，已删除映射并由原 Runner 新开会话
```

在没有 CLI 回执或语义验证时，不打印“已经接上”“省去重读仓库”这类无法证明的结论。

## 六、任务图：按能力泳道继承 owner

任务图不是“每个节点换一个 Agent”。同一张图按能力形成泳道：

```text
(graphID, coding)  -> coding owner
(graphID, media)   -> media owner
(graphID, review)  -> review owner
```

规则：

1. 每个能力泳道的首个节点通过首次分配建立 owner。
2. 后续同能力节点继承该 owner，并恢复该泳道的 session。
3. 跨能力节点选择专业 Runner，通过明确文件产物交接。
4. 返回原能力时恢复原泳道 owner，不重新按额度排名。
5. 如果后续节点风险或复杂度超过当前 owner 的硬上限，记录 `capabilityEscalation` 后允许交接。
6. 图继续共享分支并串行写入；本方案不放开同仓库并行。

第一版继续复用集中式 `TaskKind` 做编码/媒体/评审分类，不同时引入新的任务类型系统。
统计和测试必须基于真实 `dependsOn` 边，不能把按 `stepIndex` 排序后的相邻节点当成依赖关系。

## 七、普通任务恢复与交接

### 7.1 恢复顺序

1. 原 Runner + 原 session + 原 worktree；
2. 原 Runner + fresh session + 原 worktree；
3. 原 Runner + fresh session + RepoMap/ProductBrief/WIP briefing；
4. 只有满足交接条件时，才选择另一个 Runner。

### 7.2 失败决策

| 情况 | 默认动作 | handoff |
|---|---|---|
| worker 重启、进程被系统打断 | 原 owner 恢复 | 否 |
| 首次超时 | 3a 保留现有换人兜底；3b 实验才让原 owner 先续一次 | 3a 可以 |
| 3b 同 owner 重试成功 | 继续由原 owner 完成 | 否 |
| 3b 同 owner 再次超时 | 回到现有单次换人兜底，或转人工 | 可以 |
| session 明确失效 | 删除精确映射，原 owner fresh 恢复 | 否 |
| 临时额度耗尽 | 等恢复时间 | 否 |
| CLI 未安装、认证长期失效、端点持续不可达 | 先区分 Runner 与本机故障，再决定 | 可以 |
| 派发前能力不匹配、工作区创建失败 | 重新首次分配 | 不算 |
| Agent 实现或验证失败 | 原 owner 修复或转独立评审 | 默认否 |
| 人工停用已开工 owner | 保存进度并交接 | 是 |
| 用户明确要求换人 | 保存进度并交接 | 是 |

第一版不依赖“日志是否持续增长”判断卡死：当前执行日志是在进程结束后一次性写入，运行期间没有
这个信号。超时后使用开工前 HEAD、修改文件、提交和 WIP 判断是否有进展。将来若确有需要，
再给 `Proc.run` 增加流式进度心跳。历史可见样本中 12 条超时任务均由换人完成，但现有策略从未提供
同 owner 重试机会，存在选择效应；因此 3b 必须保留原换人兜底，并以 WorkAttempt 数据决定是否默认开启。

### 7.3 人工停用不是 Agent 失败

`mutedOn`、`canTakeWork == false`、风险上限和复杂度上限的人工变更属于 `manualDisabled`：

- 新任务不得分配给被停用 Runner；
- owner 尚未形成上下文时可以重新首次分配，不增加 handoff；
- owner 已经形成上下文时允许交接，`handoffCount += 1`；
- 不增加 Agent failure strike，不降低其历史能力评分；
- 默认不杀死正在执行的进程，除非用户明确要求立即停止。

`handoffCount` 统计全部上下文转移次数，不统计谁应当为失败负责，因此人工停用后的真实交接仍然要计数。
`automaticHandoffCount` 只统计系统因故障自动发起的交接；人工停用不会消耗唯一一次自动交接名额。

### 7.4 永久不可用的判断

任何单一“空输出/非零退出/超时”都不足以证明 Runner 永久不可用。判断顺序：

1. 检查本机全局健康：磁盘、文件描述符、路径访问、进程启动能力；
2. 检查确定性条件：二进制是否存在、配置是否缺失、是否明确额度耗尽；
3. 只有认证、网络或端点状态不确定时，才运行一次短探针；
4. 探针失败后先分类为 host failure 或 runner failure，不能一律归罪平台；
5. 只有 runner failure 且当前任务已有上下文时，才进入交接。

明显的额度耗尽、磁盘不足或全局进程故障不再额外发模型探针，避免无意义消耗。

### 7.5 交接包

发生合法交接时保留：

- 原 platform、runnerID 和交接原因；
- worktree、分支、WIP commit；
- 本轮修改文件和提交；
- 已运行验证及结果；
- 尚未完成事项；
- handoffCount 和 automaticHandoffCount。

一条任务最多因故障自动交接一次；第二次故障交接必须人工授权。用户明确换人和人工停用仍记总交接，
但不占故障自动交接上限。

高危任务不豁免 owner。若执行容量会影响控制面，应给控制面单独预留容量，而不是在最需要上下文的
任务上恢复自由轮转。

## 八、最小数据改动

### 8.1 WorkTask

```text
ownerPlatform: Platform?
ownerRunnerID: String?
ownerAssignedAt: Date?
handoffCount: Int
automaticHandoffCount: Int
```

- 全部使用 `decodeIfPresent`；旧任务按未分配 owner 处理。
- `platform` 继续表示当前/最终实际执行平台，不改变既有语义。
- owner 发生合法交接时显式更新；任务状态枚举不变。

### 8.2 AgentRunner

```text
runnerID: String
sessionSupport: none | projectLatest | stableID | reportedID
```

### 8.3 WorkAttempt：先记录事实，再做指标

最终 WorkTask 会覆盖中间 note，运行日志又可能被归档或被同名重试覆盖，因此不能再从最终状态反推
调度过程。增加轻量的 append-only `WorkAttempt` 记录：

```text
attemptID, taskID, runnerID, platform
startedAt, endedAt, outcome, failureKind
workspacePrepared, headBefore, headAfter
changedFiles, newCommits, timedOut
sessionSupport, sessionAction
handoffReason?
```

它不保存完整 prompt、stdout 或 stderr，只保存调度事实；详细内容仍在 RunLog。指标必须来自
`WorkAttempt`，不能来自日志文件大小、最终 note 或 `triedPlatforms`。

每次真实启动在进程前先追加一条 `outcome=running`，结束时用同一 `attemptID` 再追加终态；
worker 回收孤儿任务时为残留的 running 追加 `failureKind=interrupted`。账本仍然只追加、不原地更新，
指标按 `attemptID` 取最新终态，不能把 running 和终态重复算成两次尝试。写入失败不阻断任务，
但必须输出显眼告警，禁止静默丢失事实。

## 九、落地顺序

### 阶段 0：观测和会话先说真话

- 增加 `runnerID`、`sessionSupport` 和 WorkAttempt。
- 修正恢复日志措辞。
- 修复普通任务 session 删除命名空间错误。
- 只在明确 session 错误时删除映射。
- 按 platform、任务档位记录超时率；在校准前不凭经验硬改时限。
- 用 `llmq work attempts [任务id]` 查看上述事实和两种超时恢复路径的成功率。

验收：不支持 session 的 Runner 不产生映射；一次超时后仍能从 WorkAttempt 看见前后两次尝试，
最终任务 note 是否覆盖不影响统计。

### 阶段 1：收紧会话边界

- 普通任务改为 task 作用域。
- 图改为 graph capability lane 作用域。
- `projectLatest` 增加 workspace affinity 校验。

验收：同仓库两个无关任务不会恢复彼此会话；同一任务中断后能恢复自己的上下文。普通新任务会从
fresh session 开始，token/任务可能上升，这是消除跨任务污染的预期代价，不单独视为回归。

### 阶段 2：任务图能力泳道 owner

- 给 WorkTask 增加 owner 字段。
- 首个能力节点建立 lane owner；后续同能力节点继承。
- 只在跨能力或硬资格升级时交接。

验收：一张“编码 → 编码 → 媒体 → 编码 → 评审”的图只在能力边界换 Runner，最后一个编码节点
回到原 coding owner。

### 阶段 3a：普通任务 owner，保留超时换人兜底

- 已有 owner 的任务不再运行全平台排名。
- 实现人工停用、host/runner failure 分类和交接上限。
- 暂时保留“超时后换一个 Runner”的现有救火路径，并记录完整 WorkAttempt。

验收：额度排名变化不能改变已开工任务 owner；owner 冷却时，同仓库另一条可执行任务不被租约阻塞。

### 阶段 3b：可回滚的同 owner 超时重试

- 先依据 WorkAttempt 按 platform/任务档位校准超时预算。
- 开启实验时，超时后先让原 owner 续一次；失败仍回到 3a 的单次换人兜底。
- 同时展示原 owner 重试成功率与换人成功率；前者持续更差时关闭实验。

实现开关为 `LLMQ_OWNER_TIMEOUT_RETRY=1`，默认关闭；实验重试的时限倍率可用
`LLMQ_OWNER_RETRY_TIMEOUT_MULTIPLIER` 调整（默认 1.5，最小按 1 处理）。实验重试耗时单独记账，
不侵占阶段 3a 原有的跨 owner 兜底预算。

验收：开关关闭时行为与 3a 一致；开启时不会切断原有换人救火路径，且两条路径都有可归因数据。

### 阶段 4：额度利用与独立任务并发

- 临期额度只影响新任务首次排序。
- 继续保持一个仓库一个写入任务、一个 Runner 一个任务。
- 只有前三阶段数据稳定后，才评估每机第二执行槽。

验收：多个仓库可以并行使用不同平台；同仓库和同 cwd 仍保持串行；不存在为了烧额度而接管活跃任务。

## 十、验证矩阵

### 单元测试

1. Runner ID 与展示名解耦；未知 ID 多匹配时阻塞。
2. `sessionSupport == none` 不创建映射、不打印恢复成功。
3. session 映射只因明确 session 错误被删除；任务失败和超时不会误删。
4. 普通任务、图能力泳道和不同机器生成不同 session key。
5. `projectLatest` affinity 不一致时降级 fresh。
6. 图内同能力节点继承 owner，跨能力节点才换 Runner。
7. 已开工任务不因额度变化换 owner。
8. owner 冷却任务不占 RepoLease，不阻塞同仓库其他任务。
9. 人工停用的交接增加 handoffCount，但不增加 failure strike。
10. 第二次超时停止自动轮转。
11. 旧 JSON 不带新字段仍可读取。
12. WorkAttempt 能保留成功接力前的超时事实。
13. 同一 graph、runner、machine 下，不同 capability lane 的会话键和恢复结果互相隔离。

关键规则做变异验证：临时恢复“超时立即换平台”“按仓库共用 session”“忽略 sessionSupport 仍打印恢复”
中的任一旧逻辑，对应测试必须变红。

### 集成与真机测试

1. 给 stableID Runner 一个随机事实，人工中断后不重复提供，验证同任务恢复。
2. 构造 session ID 不存在，验证仍由原 Runner fresh 恢复且只删除精确 key。
3. 构造有修改的短超时，验证保存 WIP、同 owner 续一次。
4. 构造零产出超时，验证同 owner fresh 一次，第二次转人工。
5. 静音一个已有 owner 的 Runner，验证交接计数与 failure strike 分离。
6. 构造“owner 冷却 + 同仓库另一任务”，验证后者可运行。
7. 构造跨媒体/编码/评审任务图，验证只在能力边界换人。
8. 在两个不同仓库并发 Qwen，验证 cwd 隔离；同 cwd 并发必须被拒绝。
9. 任务板区分“等待 owner”“同 owner 恢复”“人工停用后交接”。

## 十一、观察指标

- 每个任务的 attempt 数、Runner 数、handoffCount。
- 同 owner 恢复成功率。
- 按 failureKind 分类的自动交接率。
- 按 Runner 分开的 session create/resume 请求和明确拒绝次数。
- 图真实依赖边上的同能力 owner 保持率。
- 完成、验证通过、合入落地三个口径分开。
- 临期额度用于多少个**首次分配的独立任务**。
- 没有任务级 token 归因前，不宣称节省了多少 token。

## 十二、review 审计与数据口径修正

Claude review 提出的三个方向已采纳：会话能力先说真话、普通任务不能仓库级串会话、任务图同能力
owner 的优先级高。但原附录部分数字不能作为实施依据，原因记录如下，避免以后再次引用错误口径。

### 12.1 可以复现的数据

对任务库做 last-write-wins 后共有 517 条最终任务：

```text
triedPlatforms = 0   106 条
triedPlatforms = 1   393 条
triedPlatforms = 2    14 条
triedPlatforms = 3     3 条
triedPlatforms = 4     1 条
```

18 条任务试过多个平台，其中 16 条最终 done、2 条 failed。这个结果只说明最终状态，不能说明前一位
是否形成上下文，也不能说明接力是否必要。

### 12.2 已撤回的推断

1. **“无日志或日志小于 2KB 等于没有开工”撤回。**日志会被 Archive 整体搬走，缺失不能证明未启动；
   文件大小也不能证明是否修改过代码。
2. **“9 条超时全部 failed”撤回。**2026-08-24 复核当时的当前日志发现 20 个超时日志、涉及 19 个任务，其中
   10 个最终 done、9 个 failed。最终成功会覆盖 task note，按最终 note 搜索会漏掉成功接力前的超时。
   当前日志还会归档或覆盖，因此该数字也只能视为当前可见下限。
3. **“117 个相邻对里 54 个同能力换人”不作为正式指标。**117 来自有 platform 的图节点按图排序后
   相邻配对，不等于 DAG 依赖边；并行兄弟节点可能被错误配成前后步骤。复核得到两端均有 platform 的
   真实 `dependsOn` 边为 149 条，其中 84 条发生平台变化；能力分类后的正式比例应由 WorkAttempt 和
   真实依赖边重新计算。
4. **“87% 假恢复”保留为回放估计，不当作观测事实。**代码层缺陷确定存在，但当前没有持久化的
   session attempt 事件，无法证明每次控制台是否真的打印、CLI 是否接受或是否语义恢复。

### 12.3 未采纳的策略

- 人工停用后的交接仍计 handoffCount，但不计 Agent 失败。
- 高危任务仍绑定 owner；控制面容量问题通过独立容量解决。
- 未知 runnerID 不直接按 platform 猜测恢复。
- `projectLatest` 只禁止同 cwd 并发，不笼统禁止不同仓库并发。
- 不把短探针作为所有失败的统一前置动作；先排除本机全局故障和确定性原因。

## 十三、最终原则

> 让每个有价值的任务由最合适的 Runner 持续拥有上下文；
> 让不同 Agent 在独立任务和专业能力边界上并行；
> 让临期额度影响下一条真实任务，而不是打断正在形成价值的上下文。

额度是资源约束，不是任务接管权；多 Agent 是能力与产能池，不是同一任务的轮流重读器。
