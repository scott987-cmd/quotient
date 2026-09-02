# Agent 调度系统级架构复核（2026-08-31）

状态：已经独立复核批准；阶段 A、B、C、D 已实施、验证并提交为 `99bd0ec`，尚未合入或发布。
阶段 E 的健康/额度分层已在后续工作区实施并验证，尚未提交、合入或发布。
复核对象：`LLMQuotaBar` 当前工作区（包含尚未合入的调度、协作和本机并发改动）。
复核方法：静态代码审计、现场任务/进程/分支核验、调度探针行为观察。未修改实现代码，
未以“已有单测”替代端到端结论。

> 给独立复核者：请优先验证本文的事实和因果关系，不要直接开始逐条修补。若根架构判断
> 成立，应先确定控制面内核边界，再安排实现；否则很容易继续出现“修一步、下一步暴露
> 另一个同源错误”的循环。

### 2026-09-01 阶段 A 实施记录

- 任务账本增加完整写入、短写重试和坏尾回滚；新建任务走 `create`，
  状态改变走 `transition`，并原子记录 actor、reason、previousState、
  configVersion 和时间。
- CLI、任务图、提问、评审、手机入站、跨机入站和生产门的业务写入已迁入
  控制内核；`Sources` 中 `TaskStore.append/mutate` 直写为 0，
  `try? TaskStore` 为 0，并有源码形状测试防止回归。
- `blocked` 增加结构化 `waitReason`，兼容推断旧记录；移动端投影传递并显示
  等答复、等依赖、Owner 不可用、生产门、暂停和架构复核等原因。
- CAS 冲突进入 `staleRejections`；提问发布/状态落盘失败会撤回及显式报错，
  不再把失败伪装成成功。
- 反向破坏已分别证明测试能拦住：审计丢失、重复 ID 覆盖、业务层直写、
  旧 blocked 等待原因丢失、CAS 冲突不留痕。恢复后定向 65 项及全量
  1207 项测试通过（2 项按环境跳过，0 失败）。

### 2026-09-01 阶段 B 实施记录

- 全部生产摄入路径已收口到 `TaskIntake`，使用稳定幂等键；手机端仍先分诊，
  跨机/付费方传入的既有画像仍作为显式参数保留。重复提交和并发提交不会再生成
  第二条业务任务或第二张任务图。
- 项目执行范围改为显式 `focused / manualOnly / automaticAll` 三态并对损坏配置
  fail closed；`manualOnly` 禁止自动派发，但允许用户点名的单任务手工启动。
- 每个调度 tick 先在 20 秒边界内摄入答复、配置和远端任务，再冻结一次任务快照，
  只做一次本机派发决策。`SchedulerSnapshot` 持久化任务 revision、执行模式、焦点、
  配置版本、槽位、活跃任务、选择结果和同轮解释，避免看板理由与实际选择分叉。
- 任务 revision、额度 reservation、调度 snapshot 和派发 lease 由一次 CAS 原子绑定；
  子进程只有持正确且未过期的 lease 才能转为 running，启动失败或限流退出会释放
  lease 并退款。多协调器并发领取同一任务的测试只有一个赢家。
- retry 换人会同时清理旧 owner/runner/平台亲和；视觉整改在回投前验证持久化 owner
  的能力，已下线或不具备能力的 owner 会进入可见阻断，不再静默误路由。
- 反向破坏分别覆盖 `manualOnly` 自动派发、幂等键随机化、lease owner 绕过和视觉
  owner 能力绕过，四类变异均被测试拦住。恢复后 `swift build && swift test`
  全量 1220 项通过（2 项按环境跳过，0 失败）。
- 本阶段与 A、C、D 一并提交为 `99bd0ec`，尚未合入或发布；跨机协调、
  控制面/执行面生命周期隔离、完整异步咨询和健康/额度分层不属于本阶段。

### 2026-09-01 阶段 C 实施记录

- 生产运行链路已拆成 Coordinator、Executor、Projector 三个生命周期域。Coordinator
  只领取任务和观察持久化租约/PID；Executor 由每个任务独立的一次性 launchd job 执行，
  不再依赖 Coordinator 进程持有的 `Process` 对象；Projector 使用独立 launch agent 发布共享视图。
- Executor job 使用唯一 label 和持久化 job record，plist 明确 `RunAtLoad=true`、
  `KeepAlive=false`，并携带 `LLMQ_SLOT_CHILD=1`。新 Coordinator 会识别仍存活的 Executor，
  不重复启动；终态后才撤销 job 并清理记录。
- 现场 launchd 探针证明 `launchctl submit` 会隐含 KeepAlive 并重复执行，因此已拒绝该方案，
  改用显式一次性 LaunchAgent plist；该反例也被固化为回归测试。
- Watchdog 的同键操作加入 operation generation：超时会使旧 generation 失效，晚到结果
  无权提交。Projector generation 持久化，旧投影器不能覆盖新一代共享视图；投影失败不影响
  Executor 继续运行。
- 反向破坏分别证明测试能拦住 Executor `KeepAlive=true` 和 Watchdog 超时后晚到提交。
  恢复后相关回归 31 项通过；最终 `swift build && swift test` 全量 1228 项通过
  （2 项按环境跳过，0 失败）。
- 本阶段与 A、B、D 一并提交为 `99bd0ec`，尚未合入、发布或安装；当前正在运行的服务
  仍不会自动切换到这份代码。跨机与完整异步协作属于阶段 D，健康/额度分层属于阶段 E。

### 2026-09-01 阶段 D 实施记录

- 机器事实只按稳定 `machineID` 去重；同名 Mac 不再互相吞掉快照、用量或 Agent。
  本机人类活动也按注入的 machineID 计算，机器列表以名称再 ID 稳定排序。
- 每个项目通过 `RepoAlias.coordinatorMachineID` 指定唯一补活节点；未指定、节点不匹配或
  二次防重事实写入失败均 fail closed。同机多进程仍由本地 lease 和同步 claim 防止重复入队。
- roles、runners、repos、plans 和 context-pack-rollout 迁入 append-only 配置 journal；写入
  携带 revision/CAS，陈旧写明确拒绝并保留 conflict。离线两机产生同 revision 兄弟事件时，
  镜像执行集合并而非 mtime 覆盖；revision 缓存绑定具体配置路径，切换机器/目录不会串味。
- 新增按 `(machineID, runnerID)` 标识的 Agent 注册表。咨询改为异步 question 事件，问题固定
  接收机器；接收方的一次性独立 job 真正启动后才发布 claim，再发布 answer，发起方不能伪造
  认领。失败和超时形成可见 finding，不占用实现 Owner，也不阻塞无依赖工作。
- 移动端协作页展示提问者、接收者、认领、回答和采用确认，并新增“可用 Agent”区分同名机器、
  标出“可接收咨询/仅执行任务”。没有协作记录时也不会隐藏 Agent 注册事实。
- 反向破坏把 machineID 去重改回 machineName 后，同名不同机器用量门禁稳定失败；恢复实现后
  `PhaseDTests` 11 项、机器身份 4 项、并发补活 4 项均通过。全量首次运行还抓到 revision
  缓存跨配置路径串味，修复后 `swift build` 与最终 `swift test` 全量 1242 项通过
  （2 项按环境跳过，0 失败）。
- 本阶段与 A、B、C 一并提交为 `99bd0ec`，尚未合入、发布或安装；当前服务不会自动
  切换到这份代码。阶段 E 的 runner/capability 健康模型与额度事实分层随后实施。

### 2026-09-01 阶段 E 实施记录

- 健康记录改为 `(runnerID, capability)` 身份，状态显式区分 available、unavailable、unknown，
  每条携带来源、观测时间和失效时间；旧平台级记录继续通过兼容解码读取。
- 平台检查改成纯被动读取本机 Runner 配置，不再创建临时仓库、不再运行执行器命令，也不再
  因探针写入或清除 cooldown。真实任务 attempt 的成功/失败证据优先于本机配置事实。
- cooldown 新记录按 Runner 和能力隔离，调度器使用精确键选择；旧平台级记录仍作为账号级
  兼容事实生效。同平台某个 Runner 的失败不会清除或阻断健康兄弟 Runner。
- 额度展示拆为官方事实、本地估算、额度未知和调度冷却；显示剩余量、来源、观测时间、重置
  与失效时间。未知或过期数据不再按 0%/可用进入仪表，也不会触发自动补活机会。
- 已完成四类反向破坏：被动未知误标可用、精确 cooldown 清除退化成平台清除、未知额度伪装
  为 0%、调度器退化成平台级 cooldown；对应测试均按预期失败，恢复实现后定向测试通过。
  恢复实现后 `swift build && swift test` 全量 1252 项通过（2 项按环境跳过，0 失败，
  测试耗时 863 秒）。

## 1. 结论先行

当前系统已经具备任务队列、Owner/模型选择、项目焦点、本机多槽、worktree、额度、质量门、
协作事件、跨机镜像和移动端投影等大量能力，但还不能视为可靠的自治调度器。

根因不是某一条路由规则写错，而是：

> 多个入口、线程、进程和机器都能改变任务事实，但系统没有唯一的状态转换内核，也没有
> 一次调度周期的原子边界。

由此产生四类系统性后果：

1. **事实漂移**：同一个任务状态被不同写入者从不同旧快照继续推进；冲突虽然能被检测，
   但大量调用方静默吞掉失败。
2. **策略晚生效**：任务可能先按旧的项目焦点、Owner 或额度配置启动，随后才读取本轮新配置。
3. **生命周期重叠**：超时旧线程和旧版本控制面仍会晚到写回，覆盖较新的决策或投影。
4. **协作不可闭环**：事件日志能记录交接，却不能可靠表达提问、认领、回答、采用和超时升级。

继续在现有路径上增加条件、重试和特殊例外，只会使下一次故障换一种表现。建议把下一阶段定义为
“调度控制内核收敛”，而不是再处理一个现场卡死分支。

## 2. 当前现场基线

审计时 Flint 有真实执行，不属于“调度器显示运行、实际没有模型进程”的空壳状态：

- 任务：`91818f53`
- 项目：Flint
- Owner：`kimi.code`
- 真实执行器：存在 `kimi-code` 子进程
- 分支：`agent/kimi/91818f53`
- 最近提交：`bad6f50`，BombMatch 炸弹实体状态机
- 已提交增量：2 个文件、429 行
- 尚未快照：`Flint.xcodeproj/project.pbxproj`、`Flint/Sim/BombMatch.swift`、
  `FlintTests/BombMatchTests.swift`

因此当前任务需要观察 checkpoint/测试证据是否继续增长，但不能仅凭“运行时间长”判定为空转。

工作区本身存在大量正在进行的未提交修改；本文只增加审计文档，不把这些改动归为本次复核产物。

## 3. 关键发现

### P0-1：任务账本仍存在损坏和丢状态风险

证据：`Sources/LLMQuotaCore/Work.swift:437-496`。

`TaskStore.append` 已加入跨进程锁和 revision 拒绝，但持久化仍只调用一次底层 `write`，没有检查
返回字节数或 `errno`。短写、磁盘错误或异常中断可能留下半条 JSONL。读取端跳过坏行后，同一任务
可能退回旧 revision，甚至在视图中消失。

同时当前 `Sources` 中有 32 处 `try? TaskStore.append(...)`。`StaleWrite`、打开文件失败、写入失败
等都可能被调用方静默吞掉。现有 revision 机制只能阻止旧状态覆盖，不能保证业务更新最终成功。

影响：

- 任务看起来长期停在旧状态；
- Owner、用户答复、质量结论或终态丢失；
- 图解冻和下游任务永远等不到应有转换；
- 现场只有“没动”，没有可见错误和重试依据。

### P0-2：项目焦点关闭的语义与自动派发行为相反

证据：`Sources/LLMQuotaCore/ProjectExecutionScope.swift:70-100`，以及
`Sources/llmq/main.swift` 中自动派发对 `scope.filter(TaskStore.readyQueue())` 的调用。

公开语义把 `allowedRepo == nil` 定义为关闭专注：已排队任务只允许手工执行，不应自动启动。
但 `allows(_:)` 在 `allowedRepo == nil` 时返回 `true`。自动派发与手工执行共用了这一个判据，
于是焦点为空、尚未同步或被旧版本读取时，所有仓库的 queued 任务都可能自动启动。

影响：这是“刚指定只做 Flint，下一轮又开始 Maw”的直接结构性出口。

需要把模式显式建模，例如：

- `focused(repo)`：只自动执行该项目；
- `manualOnly`：自动执行数量恒为零；
- 如确有需求，再显式增加 `automaticAll`，不能继续用 `nil` 同时表达两个含义。

### P0-3：调度周期先派活，后摄入用户最新配置

证据：`Sources/llmq/main.swift:4212-4292`。

每轮第一次 `dispatchReadyTasks` 在 4214 行执行；手机答复从 4221 行开始摄入，配置意图从 4247 行
开始摄入。代码注释声称配置在派活之前，但真实顺序相反。后面第二次派发不能撤销第一次已经启动
的错误任务。

影响：项目焦点、Owner、模型禁用、留白比例和额度恢复等指令可能天然晚一个任务生效。

正确顺序应固定为：

```text
摄入所有外部输入
  → 归一化并校验
  → 生成不可变配置快照
  → 生成调度计划与解释
  → 原子领取任务/额度/租约
  → 启动执行器
```

一个周期只能基于一个明确的 `configVersion` 进行一次规划，不能在周期中途混用新旧策略。

### P0-4：任务入队事实没有统一入口

证据：

- `Sources/LLMQuotaCore/TaskIntake.swift:3-124` 声明自己是唯一入口，并负责查重、分诊、Owner、
  生产门禁和拆分；
- `Sources/LLMQuotaCore/Inbox.swift:411-424` 直接构造和追加 `WorkTask`；
- `Sources/LLMQuotaCore/ClusterProtocol.swift:155-178` 同样直接构造和追加任务；
- 自动补活和部分图任务路径也存在独立生成逻辑。

影响：同一需求从手机、跨机、CLI 或补活进入时，可能得到不同的查重、Owner、任务类型和质量策略；
重复任务、错误 Owner 和过细拆分会反复出现。

所有入口必须调用同一个 intake，并携带稳定幂等键。8 位 UUID 前缀只能用作显示短号，不应继续作为
全局幂等身份。

### P1-1：跨机补活认领是“尽力通知”，不是真租约

证据：`Sources/LLMQuotaCore/AutoRefill.swift:105-145`。

认领内容序列化失败时函数返回成功；共享写入失败也继续返回成功。两台机器因此可能同时认为自己
抢到了同一项目的补活权。当前实现只解决同机并发，不能提供跨机排他性。

跨机 claim 必须失败关闭，并返回可验证的 lease；没有 lease 就不能入队。若共享介质无法提供可靠
CAS，应明确把自动补活限制为每项目指定协调节点，而不是伪装成分布式锁。

### P1-2：看门狗超时后仍存在晚到写入

证据：`Sources/LLMQuotaCore/Watchdog.swift:21-29`。

Watchdog 到点只让调用方继续，不能取消已经阻塞的线程。同一个 key 后续虽不再启动新线程，旧线程
仍可能在主循环进入下一阶段、读取新配置或发布新视图以后返回并写回旧结果。

影响：产生“幽灵写入”和时序重叠；现场看到的状态可能被上一轮迟到操作再次改回去。

应把可能阻塞的操作放进可终止的 helper 进程，或至少给每轮结果携带 generation/configVersion，
只允许当前 generation 提交状态。超时结果必须丢弃，不能继续改变事实。

### P1-3：控制面热更新被长任务锁住

证据：`Sources/LLMQuotaCore/BinarySwap.swift:58-61`。

当前只有二进制变化且没有任何 in-flight 工作时才退出。长模型任务会让旧调度器、旧配置解释器和
旧移动端投影继续运行数小时。实现代码即使已经更新，现场仍可能继续表现为旧问题。

执行器生命周期应与协调器生命周期分离：任务子进程继续运行，协调器和投影器可以热重启；新协调器
通过持久化 lease/PID 接管观察，不重复启动任务。

### P1-4：Agent 协作是同步工具调用，不是完整工作流

证据：`Sources/LLMQuotaCore/Collaboration.swift:555-675`、
`Sources/LLMQuotaCore/Collaboration.swift:352-375`。

当前咨询机制的问题：

- 可咨询目标只包括本机 Codex、Claude 和 OpenCode；Kimi、Qwen 没有对等只读咨询适配器；
- 不存在跨机器 Agent 能力注册表；
- `ask` 同步启动另一个模型进程，最长占用当前 Agent，而不是给现有架构师会话发送异步消息；
- 没有独立的待认领、已认领、回答中、已回答、已采用、拒绝和超时升级状态；
- 同任务出现一个较晚 `result` 时，会把此前所有 `needsResponse` 事件判为 resolved，即使问题从未
  得到回答；
- 移动端看到的是事件片段，难以重建真实交流线程。

协作应建模为持久化会话：

```text
question → claim → answer → accepted / rejected
                    ↘ timeout → escalation / cancel
```

只有显式 answer、ack、cancel 或 timeout disposition 可以关闭问题。任务结果不能替代回答。

### P1-5：平台健康探针会调用真实模型并产生副作用

证据：`Sources/llmq/main.swift:2142-2230`。

`work probe` 会给每个 Runner 发送真实请求，并允许 Runner 使用其正常工作命令。现场复核已经观察到：

- 专用 MiniMax 评审 Runner 把探针当作真实评审并在临时仓库生成结果文件；
- 媒体 Runner 因不接受通用文本而被误判异常；
- 同一平台的多个不同能力 Runner 会分别设置或清除同一个平台级 cooldown；
- 探针消耗真实模型 token。

本次探针没有修改项目仓库，但其行为本身证明“诊断”不是只读且不是无成本。

健康状态应按 `(runnerID, capability)` 保存。探针必须使用能力专用、禁止工具和禁止文件写入的
低成本接口；能够通过被动认证/额度查询得到的状态，不应再发模型请求。

### P1-6：机器身份按名称折叠

证据：`Sources/LLMQuotaCore/QuotaEngine.swift:33-47`。

Dashboard 按 `machineName` 去重而不是稳定 `machineID`。两台同名 Mac 会被折叠成一台，导致任务、
在线状态和额度报告错误合并。旧身份噪声不应通过牺牲真实多机身份来隐藏，应使用稳定 ID、别名迁移和
显式 tombstone。

### P2-1：暂停、等待和失败复用同一个 blocked 状态

`WorkTask.State` 只有 queued/running/done/failed/blocked；暂停通过 blocked 加 `pausedAt` 表达。
同一个 blocked 还承载用户答复、架构决策、依赖冻结、额度、质量门和永久无平台。

每个消费者都必须重新解释 blocked，于是任务板、自动补活、重试、巡检和移动端会得出不同结论。
例如“暂停的历史任务”会显示成“卡住 7 条”。

建议把阶段与等待原因分离：

```text
phase: queued | leased | running | waiting | reviewing | completed | failed | cancelled
waitingReason: user | architecture | dependency | quota | approval | quality | external
paused: Bool
```

### P2-2：调度打分存在重复真相和不可复现决策

Owner/平台偏好同时通过多个 bonus 进入评分；是否配置额度又会改变哪些 bonus 被应用。硬约束和软分数
散落在多处，任务启动后没有持久化完整决策快照，因此事后无法严格复现“为什么选它”。

每次计划应产出并保存解释：候选列表、淘汰原因、硬约束结果、最终分数、配置版本、额度版本、
项目范围、Owner、runnerID 和真实模型。

### P2-3：共享配置和视图使用最终写入者覆盖

跨机镜像对部分配置采用基于 mtime 的双向覆盖；根 Dashboard、Office、Review 等投影也存在最终发布者
获胜的形态。机器时钟漂移、旧版本进程和不完整镜像都可能把新策略或新视图覆盖回去。

共享配置至少需要 revision/CAS；更稳妥的做法是每机追加意图事件，由一个明确协调节点归并成当前配置。
投影是可重建缓存，不能反过来成为任务事实源。

## 4. 已有设计中可保留的部分

本次复核不是推翻全部工作。以下设计方向可以保留：

- 本机只有一个协调器，多槽通过独立任务子进程执行；
- 同仓库串行、不同仓库并行；
- repo lease 和 runner lease 在子进程入口再次校验，能关闭父进程同时派发的同机竞态；
- Owner 忙时等待，不因并发自动换人；
- worktree、日志和任务 PID 按任务隔离；
- TaskDecomposer 已回归“一个 Agent 尽量完成一个大任务”，只在明确跨能力时拆分；
- 协作事件按机器追加、按事件 ID 合并，比多机共同覆盖一个 JSON 更合理；
- revision 拒绝比旧的“文件最后一行获胜”明显进步。

问题在于这些局部机制还没有被一个统一控制内核约束。

## 5. 建议的目标架构

### 5.1 唯一事实源和状态转换器

业务代码不得直接 append 完整任务快照。只允许调用：

```text
transition(taskID, expectedRevision, command, actor, configVersion)
```

转换器负责：

- 校验当前阶段能否接受该 command；
- 原子读取最新 revision；
- 合并调用方真正拥有的字段，而不是重写完整旧快照；
- 完整持久化；
- 写入成功后更新缓存；
- 冲突时重新读取和有界重算，或产生可见失败；
- 记录 actor、原因、旧状态、新状态和决策版本。

### 5.2 单一 intake 和幂等身份

CLI、手机、跨机、自动补活、重试和内部派生任务都必须经过同一个 intake。每个请求携带稳定幂等键，
例如来源设备、原始请求 ID、项目和意图版本的组合。短任务号只用于 UI。

### 5.3 不可变调度快照

一次 tick 只构建一次调度快照：

```text
SchedulerSnapshot {
  configVersion
  machineID
  executionMode
  taskHeads
  runnerCapabilities
  runnerHealth
  quotaSnapshot
  activeLeases
}
```

Planner 是纯函数；Executor 只执行已经原子领取的计划。任何输入变化都等下一 tick，不能在当前计划中
半途替换。

### 5.4 协调器、执行器、投影器分离

- **Coordinator**：摄入、规划、领取、回收；可以热重启。
- **Executor**：持有真实模型子进程和任务 lease；独立存活。
- **Projector**：从事件/任务事实重建移动端视图；失败或旧版本不能阻塞执行。

协调器重启后读取 executor lease/PID 继续观察，不能重新启动相同任务。

### 5.5 Agent 能力与咨询会话

统一注册每个 Agent 的：

- 稳定 runnerID；
- 所在 machineID；
- 真实模型；
- read/code/review/media/architecture 能力；
- 是否支持异步咨询；
- 当前会话亲和与占用状态。

咨询是独立工作流，不更换任务 Owner；回答应回到原任务会话，移动端按线程展示。

## 6. 实施顺序

不要把下列项目拆成几十条相互独立的小任务。建议由一个主实现 Agent 在同一上下文中完成每一阶段，
架构师只在阶段边界复核。

### 阶段 A：控制内核和持久化

1. 完整写入与错误检查；
2. `transition/mutate` 唯一入口；
3. 移除所有生产代码中的 `try? TaskStore.append`；
4. 显式状态/等待原因；
5. 冲突、重试和损坏行进入可见诊断。

完成 A 之前，不应继续增加新的状态修正规则。

### 阶段 B：摄入和调度周期

1. 全部入口迁入 TaskIntake；
2. 加稳定幂等键；
3. executionMode 显式化；
4. 调整 tick 顺序；
5. 持久化 SchedulerSnapshot 和选择解释；
6. 任务领取、额度凭据和租约原子提交。

实施状态：2026-09-01 已完成并通过上述阶段 B 实施记录中的全量门禁与反向破坏验证。

### 阶段 C：生命周期隔离

1. Coordinator/Executor/Projector 分离；
2. 控制面热更新不终止 Executor；
3. Watchdog 操作改为可终止 helper，或给晚到结果加 generation 拒绝；
4. 旧版本投影器不得继续发布共享视图。

实施状态：2026-09-01 已完成。控制面换版不再要求终止独立 Executor；新 Coordinator
通过持久化 lease/PID 接管观察且不重复启动；Watchdog 晚到结果和旧 Projector 发布均由
generation 拒绝。已通过上述阶段 C 实施记录中的反向破坏、相关回归和全量门禁。

### 阶段 D：跨机和协作

1. 稳定 machineID，不再按 machineName 折叠；
2. 跨机补活改为真 lease 或指定协调节点；
3. 共享配置加入 revision/CAS；
4. Agent 注册表和异步咨询会话；
5. 移动端展示完整问答关系。

实施状态：2026-09-01 已完成。机器身份、指定协调节点、共享配置 CAS、Agent 注册表、
独立异步咨询和移动端关系闭环均已实现，并通过上述阶段 D 的变异、定向和全量门禁。

### 阶段 E：健康与额度

1. 健康状态按 runnerID+capability 建模；
2. 被动检查优先，主动探针禁止文件和工具副作用；
3. 额度事实、估算、剩余量、cooldown 和 probe 结果分层展示；
4. 明确过期时间和数据来源，禁止未知状态冒充可用。

实施状态：2026-09-01 已完成实现和验证。健康与 cooldown 已按 Runner/能力
隔离，探针改为零模型调用的被动事实读取，额度事实/估算/未知/冷却已分层；变异门禁已证明
上述四条不能静默回退；最终全量 1252 项通过（2 项按环境跳过，0 失败）。当前阶段 E
改动尚未提交、合入、发布或安装。

## 7. 必须通过的验收门

### 状态与持久化

- 注入部分写入、磁盘错误和进程中断，不能产生可接受为最新状态的半条记录；
- 100 个并发转换最终全部可解释：成功、冲突重试成功或明确失败，不能静默丢失；
- 旧 worker 的晚到终态不能覆盖用户答复、暂停、取消或较新质量结论；
- 暂停、等待、失败、取消在任务板和移动端分别显示。

### 调度边界

- 同一 tick 收到“只做 Flint”后，启动 Maw 的次数必须为零；
- `manualOnly` 时自动启动数恒为零；
- 两个协调器并发观察同一 queued 任务，只有一个获得 lease；
- 两台机器同时发现 Flint 需要补活，只能生成一个幂等任务；
- 每个任务都能输出可复现的选择解释，包括真实模型而非工具外壳名称。

### 生命周期

- 控制面换版时真实模型任务继续运行，新协调器不会重复启动；
- 超时旧操作恢复后不能改变当前 generation 的状态或视图；
- 投影器挂死、iCloud 卡住或移动端发布失败不影响任务执行。

### 协作

- Kimi 能向 Codex 架构师发起问题，Codex 明确认领并回答，Kimi 继续保持 Owner；
- 移动端展示 sender、recipient、claim、answer、采用状态和耗时；
- 未回答问题不能被任务 result 自动关闭；
- 同一问题重试不重复消费回答 token；
- 跨机器咨询仍使用同一个稳定会话 ID。

### 健康与多机

- 平台探针新增文件数为零、任务 token 消耗为零；
- 媒体/评审 Runner 不会因为通用文本探针被误判；
- 同一平台不同 Runner 的健康和 cooldown 不互相清除；
- 两台同名 Mac 仍作为两个稳定节点显示和调度。

## 8. 请独立复核者重点回答

1. “缺少唯一状态转换内核”是否是这些现场问题的共同根因？若否，请给出更小且能同时解释全部
   现象的根因模型。
2. P0-1 的短写和 32 处静默 append 是否构成数据完整性阻断项？
3. `manualOnly/focused/automaticAll` 是否应取代 `allowedRepo == nil` 的双重语义？
4. 调度周期是否必须改成“先摄入、后冻结快照、再唯一派发”？
5. 是否同意把 Coordinator、Executor、Projector 分离，作为热更新和 Watchdog 晚到写入的共同解？
6. 跨机自动补活应选择共享真 lease，还是明确单项目协调节点？请结合当前 iCloud 能力判断。
7. Agent consultation 是否应成为持久化异步会话，而不是同步新进程调用？
8. 上述实施顺序是否存在会造成二次迁移或无法回滚的依赖错误？

## 9. 与现有文档的关系

- `docs/design/task-state-concurrency-architecture-review.md`：较早的并发状态专项复核。其 revision/CAS
  方向仍有效；本文补充了短写、静默冲突、统一状态转换器和整个调度周期边界。
- `docs/design/local-multi-task-execution.md`：本机多槽隔离设计可保留；本文要求把它纳入统一 lease、
  调度快照和控制面热更新模型。
- `docs/design/agent-collaboration-hub.md`：append-only 事件模型可保留；本文指出当前同步咨询、目标能力、
  自动 resolved 和移动端线程表达仍不足以形成真实协作闭环。
- `docs/design/context-graph-low-token-implementation.md`：增量上下文方向可保留，但上下文投影不能成为
  任务状态或协作状态的替代事实源。

如旧文档与本文在执行顺序、状态语义或“是否已经解决”的判断上冲突，应先由独立架构复核明确裁决，
再开始实现，避免不同 Agent 各自按一份历史设计继续工作。

## 10. 2026-09-03 三机复核收口

本轮按“先数据正确，再调度隔离，再投影可见，最后性能与恢复”的顺序复核现有实现，
没有把问题继续拆成零散补丁，也没有触碰正在运行或冻结的 Flint 任务。结论如下。

### 10.1 已收口的事实边界

1. **机器身份**：所有跨机事实以稳定 machineID 为键，machineName 只用于显示。同名
   Mac 不折叠；显示名经过隐私过滤，用户名、中文姓名和不可控主机名不会下发到手机。
2. **额度身份**：额度配置和运行事实都引入 quota pool。官方额度、估算、剩余量、
   cooldown、学习上限和自适应参数按池隔离；机器/runner 绑定决定调度实际读取哪个池。
   低价值 helper 的可用性按候选自己的池判断，不再读取平台聚合值。
3. **本机并行**：本机容量由槽位决定，同时受 repo lease、Owner lease、能力要求和
   独占资源 lease 限制。不同仓库且资源互不冲突时可并发；同仓库、同 Owner、Blender、
   Unreal/UE 等独占工具仍串行。父规划和子进程入口均校验租约，防止并发协调器绕过。
4. **跨机并行**：每台机器只执行自己领取并持有 lease 的任务；本机 focused 模式不再
   覆盖全局 coordinator 配置。MacBook 与 Mac mini 可以分别运行不同项目，互不修改
   对方执行模式、任务 PID、工作区和额度池。
5. **状态真相**：SchedulerSnapshot 的 current 文件是当前权威状态，显式记录 idle、
   running、waiting、dispatching、paused 及原因；JSONL 只追加状态转换，不记录每次
   心跳。客户端不再从任务数量、旧日志或进程外壳猜“为什么停了”。
6. **持久化恢复**：任务账本使用 revision/CAS、checkpoint 和增量尾读取；写到一半的
   末尾记录会在下一次 append 前修复，完整但缺换行的记录保留。控制面重启从 checkpoint
   和持久化 executor lease 恢复，不重复启动真实模型。
7. **协作关系**：异步咨询保留原 Owner，问题由目标机器的真实 Agent 认领和回答；手机
   展示 sender、recipient、claim、answer、adoption 和耗时。架构疑问指向 Codex 角色，
   不再因历史文本默认寻找 Claude。
8. **脏数据收敛**：旧机器分片只按稳定 ID 和 30 天失联期回收，绝不按名字删除。清理
   在每次镜像后执行，因此即使没有项目任务，云端旧分片被拉回后也会立即再次对账；
   iCloud 读写、列目录、移动和删除都受有界超时保护，投影失败不能阻塞执行。
9. **上下文与辅助工作**：context pack 以当前目标、决策和增量证据为主，避免重复携带
   陈旧全文。主 Agent 可以把边界明确的低价值工作交给任何具备能力且当前池有额度的
   helper；这是动态能力，不绑定 MiniMax，也不允许 helper 改 Owner 或扩展任务范围。
   选中 helper 后同时固化 runnerID 与 machineID，避免三机同名 Runner 把问题接错。

### 10.2 三机与额度机制判断

用户当前需要的是“各机器在本机运行不同任务”，不是把单个进程跨机器迁移。现有模型
已经覆盖这个场景：每机稳定身份、独立槽位、独立工作区/进程租约、独立 quota pool，
共享层只同步任务事实、配置 journal 和可重建投影。两台 MacBook 使用两个 LiteLLM key
时应绑定两个不同 quota pool；Mac mini 可按本机资源提供两个槽位。

仍有一个明确边界：**同一台机器、同一平台、同时使用多个订阅账号**目前不能被可靠地
独立观测，因为部分上游采集器只给平台/机器级快照。若要支持这个形态，必须先把
runner/account identity 纳入采集协议，再允许同机多个 pool；不能把一个平台读数按配置
复制成两份“余额”。这个限制不影响当前三台机器分别使用各自订阅的部署方式。

### 10.3 验证证据

- 反向移除任务账本坏尾修复后，崩溃尾测试稳定失败；恢复实现后通过。
- 额度池、候选 helper 额度、同名机器、隐私显示、陈旧身份、并发槽位、资源租约、
  UE 能力和协作线程均有定向回归。
- iOS 单元/契约测试 52 项通过；UI 测试 10 项中 8 项通过，2 项按 iPad 宽度条件跳过。
- 云端调度心跳、移动端投影写入和陈旧身份删除均统一走 ICloudSafe；源码级守卫及相关
  37 项定向回归通过。
- 最终 `swift build && swift test` 全量 1357 项通过（2 项按环境跳过，0 失败）。
- 未创建、重试、合并或修改 Flint 任务。

### 10.4 2026-09-03 发布实录

- Mac 源提交 `30cf61e`，iOS 源提交 `568fb13`。
- Mac 签名通用版 `f0057c732317ade313f7e76d6a2c30b42ef6bea53cbb4a44d3e3bbafa4fac141`
  已安装到 Mac mini、Intel MacBook Pro、ARM MacBook Pro；逐台 SSH 核对安装标记、
  CLI/App 文件哈希与常驻进程启动时间。三台 CLI 均为
  `1ef7790e345e1787ed35b0227e6f988fc9bbcb437f01858cf267db363648bc8f`，App 均为
  `3da8e5481694dbd0b80e34024d2315d95528d8d82f90d6ae14a1496bb5fe8d74`。
- 首轮云盘回执等待超时，不算全机完成；M2 仍见旧清单时，通过 SSH 传送同一签名包，
  再由其正常 `llmq update` 验签安装，未强制杀模型或绕过签名。
- 随后 `llmq release verify --wait-seconds 30` 退出码 0，输出“所有在线机器已确认
  f0057c732317”，云盘集群回执也已收齐。
- TestFlight `202609030202`（构建 ID `7427b12b-f4c7-4e78-950a-5180a592371a`）
  实查 `VALID/IN_BETA_TESTING`，内部测试组中复查到同一构建。用户手机是否已更新
  和实际显示效果尚未代替用户确认。
